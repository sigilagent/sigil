"""AI compiler — Stage 1: the Spec convergence loop (SKILL.md -> frozen RuleSet).

The anchor of the LIFT. Everything downstream is audited against the RuleSet, so
it must be faithful and non-hallucinating BEFORE it freezes — which means a loop
whose exit is decided by CODE, not by a model's self-assessment.

The principle: THE MODEL PROPOSES, CODE DISPOSES.
- Soundness (no hallucination) is mechanically checkable: every Rule.quote must
  substring-match the skill text (whitespace-normalized). A hallucinated rule
  cannot produce a matching span, so it is dropped deterministically — the loop
  can never declare victory over an ungrounded spec.
- Completeness (no drop) needs model critics (3 independent lenses), but every
  candidate they propose must itself appear verbatim in the skill before it
  counts — over-production is self-filtering.
- Modality faithfulness is a code audit over the deontic vocabulary, including
  the anti-inflation check: a conditional span extracted as an unconditional
  MANDATORY rule with no recorded condition is drift.

Termination is monotone: each round only drops an ungrounded rule, adds a
grounded rule for an uncovered span, or fixes a modality — and the grounded-rule
set is bounded by the finite set of skill spans. Stop-when-dry + a hard cap
backstop the loop; on exhaustion the spec is returned WITH its honest verdict
(never a silent success).
"""

import re;
import from jaclang.byllm.lib { Model }
import from .lift_types { Rule, RuleSet, ExtractVerdict, SpecResult, Modality, RuleKind, Cohesion }

glob lift_llm: any = Model(model_name="gpt-4o-mini");
glob _LIFT_PINNED: bool = False;   # tests / embedders pin a model (e.g. MockLLM)

def pin_lift_llm(m: any) -> None {
    global lift_llm, _LIFT_PINNED;
    lift_llm = m;
    _LIFT_PINNED = True;
}

# ---------------------------------------------------------------------------
# model proposes
# ---------------------------------------------------------------------------

sem extract_round = """Extract the skill text into a complete RuleSet — every
obligation the prose states, as atomic rules. Segment first: one imperative, one
code block, one conditional clause, one 'see X.md' pointer = one rule. Rules:
(1) quote is VERBATIM from the skill — never paraphrase or invent; a rule whose
quote is not in the skill is mechanically dropped. (2) Read modality from the
deontic vocabulary only (must/always=MANDATORY, may/if-needed=DISCRETIONARY,
never/do-not=FORBIDDEN) — never harden soft guidance. (3) If the span is
conditional or exemplary, copy the condition verbatim into `condition`. (4) An
adaptive tool-using activity ('explore...', 'iterate until...', 'use the tools
to...') is ONE rule with cohesion=INVOKE_UNIT — do not shred it into fragments.
(5) A demand to consult a live source at run time is kind=GROUNDING. (6) Keep
prior rule ids stable; apply the GAPS feedback exactly: remove the listed
invented rules, add grounded rules covering the listed uncovered spans, fix the
listed modality drift.""";
sem extract_round.skill = "The full skill text — the only ground truth.";
sem extract_round.prior = "The previous round's RuleSet (empty on round one). Preserve its grounded rules and ids.";
sem extract_round.gaps = "Code-audit feedback from the previous round: dropped inventions, uncovered spans, modality drift.";
def extract_round(skill: str, prior: RuleSet, gaps: str) -> RuleSet by lift_llm();

sem coverage_critic = """You are ONE completeness lens over a skill text. Find
obligations of the requested kind that are NOT covered by the already-extracted
quotes, and return each as a VERBATIM span copied from the skill (a substring —
a span that does not appear verbatim is discarded). Return an empty list when
nothing of this kind is missing. Do not restate covered material.""";
sem coverage_critic.skill = "The full skill text.";
sem coverage_critic.ctx = "The lens to apply plus a digest of the spans already covered.";
def coverage_critic(skill: str, ctx: str) -> list[str] by lift_llm();

glob _LENSES: dict = {
    "imperative": "unmapped IMPERATIVES: steps the skill tells the agent to perform (must / always / do X / follow ...)",
    "forbidden": "unmapped CONSTRAINTS: things the skill forbids or restricts (never / do not / avoid ...)",
    "subresource": "unmapped SUB-RESOURCE POINTERS: delegations to sibling files or live sources ('see FORMS.md', 'read REFERENCE.md and follow it', 'fetch ...')"
};

# ---------------------------------------------------------------------------
# code disposes
# ---------------------------------------------------------------------------

def _norm(s: any) -> str {
    # whitespace-collapsed, casefolded — the grounding equivalence
    return str(re.sub(r"\s+", " ", str(s))).strip().casefold();
}

def _in_skill(skill_norm: str, span: any) -> bool {
    sp = _norm(span);
    return bool(sp) and (sp in skill_norm);
}

def ground_rules(skill: str, rs: RuleSet) -> list[str] {
    # Soundness: ids of rules whose quote does NOT appear in the skill.
    # This is the mechanical anti-hallucination backbone — never model-judged.
    sn = _norm(skill);
    bad: list = [];
    for r in rs.rules {
        if not _in_skill(sn, r.quote) { bad.append(r.id); }
    }
    return bad;
}

glob _FORBID_MARKERS: list = ["never ", "do not ", "don't ", "must not "];
glob _COND_MARKERS: list = ["if ", "when ", "unless ", "e.g.", "for example", "in case "];

def audit_modality(skill: str, rs: RuleSet) -> list[str] {
    # Deontic-vocabulary audit + the anti-inflation check (A.5.1): flag, don't fix
    # — the fixes go back through the extractor so the spec stays model-authored.
    notes: list = [];
    for r in rs.rules {
        q = " " + _norm(r.quote) + " ";
        forbids = False;
        for m in _FORBID_MARKERS { if m in q { forbids = True; } }
        if forbids and (r.modality != Modality.FORBIDDEN) {
            notes.append(f"{r.id}: quote forbids ('never/do not') but modality is {r.modality.name}");
        }
        conditional = False;
        for c in _COND_MARKERS { if c in q { conditional = True; } }
        if conditional and (r.modality == Modality.MANDATORY) and (not r.condition.strip()) {
            notes.append(f"{r.id}: conditional/exemplary span lifted as unconditional MANDATORY with empty condition (inflation)");
        }
    }
    return notes;
}

def _covered(rs: RuleSet, span: str) -> bool {
    sp = _norm(span);
    if not sp { return True; }
    for r in rs.rules {
        rq = _norm(r.quote);
        if rq and ((sp in rq) or (rq in sp)) { return True; }
    }
    return False;
}

def _fingerprint(rs: RuleSet) -> str {
    parts: list = [];
    for r in rs.rules { parts.append(r.id + "|" + _norm(r.quote) + "|" + r.modality.name); }
    parts.sort();
    return ";".join(parts);
}

def _gaps_digest(v: ExtractVerdict) -> str {
    if v.rounds == 0 { return "(first round — extract the full rule set)"; }
    parts: list = [];
    if v.ungrounded {
        parts.append("INVENTED (dropped — these quotes are NOT in the skill; do not re-add unless re-quoted verbatim): " + ", ".join(v.ungrounded));
    }
    if v.uncovered {
        parts.append("UNCOVERED (add a grounded rule for each): " + " | ".join(v.uncovered));
    }
    if v.drift_notes {
        parts.append("MODALITY DRIFT (fix): " + " | ".join(v.drift_notes));
    }
    if not parts { return "(no gaps — refine only if something is genuinely wrong)"; }
    return "\n".join(parts);
}

# ---------------------------------------------------------------------------
# the loop
# ---------------------------------------------------------------------------

def extract_spec(skill: str, name: str, max_rounds: int = 5) -> SpecResult {
    # Returns the frozen spec plus its honest verdict. Callers gate on
    # verdict.sound/complete rather than trusting the set blindly.
    sn = _norm(skill);
    prior = RuleSet(skill_name=name);
    verdict = ExtractVerdict();
    dry = 0;
    rounds = 0;
    while (rounds < max_rounds) and (dry < 2) {
        rs = extract_round(skill, prior, _gaps_digest(verdict));
        rs.skill_name = name;

        # dispose 1 — soundness: mechanically drop hallucinated rules
        bad = ground_rules(skill, rs);
        if bad { rs.rules = [r for r in rs.rules if r.id not in bad]; }

        # dispose 2 — completeness: 3 lenses, self-filtered against the skill
        covered_digest = " | ".join([r.quote for r in rs.rules])[:4000];
        uncovered: list = [];
        for lens in _LENSES.keys() {
            ctx = "LENS: " + str(_LENSES[lens]) + "\nALREADY COVERED: " + covered_digest;
            for cand in coverage_critic(skill, ctx) {
                if _in_skill(sn, cand) and (not _covered(rs, str(cand))) and (str(cand) not in uncovered) {
                    uncovered.append(str(cand));
                }
            }
        }

        # dispose 3 — modality faithfulness
        notes = audit_modality(skill, rs);

        rounds += 1;
        changed = _fingerprint(rs) != _fingerprint(prior);
        verdict = ExtractVerdict(
            sound=(len(bad) == 0), complete=(len(uncovered) == 0),
            drift=(len(notes) > 0), ungrounded=bad, uncovered=uncovered,
            drift_notes=notes, changed=changed, rounds=rounds
        );
        prior = rs;
        if verdict.sound and verdict.complete and (not verdict.drift) { break; }
        if not changed { dry += 1; } else { dry = 0; }
    }
    return SpecResult(spec=prior, verdict=verdict);
}
