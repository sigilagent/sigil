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
import from .lift_types { Modality, RuleKind, Cohesion }

# NOTE: objs that ride a `by llm` slot's return schema are defined IN the
# slot's module — byllm's schema builder cannot resolve a nested obj from
# another module ("'str' object has no attribute 'fields'"); cross-module
# ENUMS are fine.

obj Rule {
    has id: str = "";
    has quote: str = "";
    has kind: RuleKind = RuleKind.STEP;
    has modality: Modality = Modality.MANDATORY;
    has condition: str = "";
    has cohesion: Cohesion = Cohesion.ATOMIC;
    has binds: str = "agent";
    has aliases: list[str] = [];
    has statement: str = "";
}

sem Rule = "One atomic obligation extracted from the skill text.";
sem Rule.id = "Stable short id (r1, r2, ...). Keep ids stable across revision rounds.";
sem Rule.quote = "The VERBATIM span from the skill text this rule comes from, copied character-for-character (whitespace may be collapsed). NEVER paraphrase, summarize, or invent — a quote that does not appear in the skill gets the rule mechanically dropped.";
sem Rule.condition = "If the span is conditional or exemplary ('when uncertain...', 'if the task...', 'e.g. ...'), the condition VERBATIM. Empty only when the span is genuinely unconditional. Hardening a conditional into an unconditional mandate is a faithfulness violation.";
sem Rule.binds = "WHO the span binds, read from the sentence's SUBJECT: 'agent' (an obligation the executing agent must obey), 'environment' (a fact about a tool, harness, or system the skill describes — 'the harness never guesses' binds the harness, not the agent), 'user' (a statement about the human), 'none' (pure description). Modal force in a descriptive sentence does NOT make it an agent obligation.";
sem Rule.aliases = "OTHER verbatim spans that RESTATE this same obligation — a cross-reference ('Verify (above).'), a recap bullet, a summary line. Attach them here instead of minting duplicate rules. Each alias must appear verbatim in the skill; non-verbatim aliases are mechanically dropped.";
sem Rule.statement = "ONE plain imperative line restating the obligation for the author ('never apply two different fixes to residues in the same cluster'). Display and authoring aid ONLY — grounding and faithfulness key on the verbatim quote alone.";

obj RuleSet {
    has skill_name: str = "";
    has rules: list[Rule] = [];
    has sub_resources: list[str] = [];
}
sem RuleSet = "The complete extracted spec of a skill: every obligation the prose states — nothing added, nothing dropped, nothing re-modalized.";
sem RuleSet.sub_resources = "Sibling bundle files the skill itself delegates to (FORMS.md, REFERENCE.md, ...).";

obj ExtractVerdict {
    has sound: bool = False;
    has complete: bool = False;
    has drift: bool = True;
    has ungrounded: list[str] = [];
    has uncovered: list[str] = [];
    has drift_notes: list[str] = [];
    has changed: bool = True;
    has rounds: int = 0;
}

obj ClarifyItem {
    has rule_id: str = "";
    has quote: str = "";
    has reason: str = "";
    has question: str = "";   # the compile-time HIL question (for --clarify)
}
sem ClarifyItem = "One obligation whose modal force (Do/Maybe/Don't) the skill leaves unstated — underspecified authoring the compiler surfaces instead of guessing.";

obj SpecResult {
    has spec: RuleSet = RuleSet();
    has verdict: ExtractVerdict = ExtractVerdict();
    has clarify: list[ClarifyItem] = [];   # underspecified obligations (the skill-quality report)
}

glob lift_llm: any = Model(model_name="gpt-4o-mini");
glob _LIFT_PINNED: bool = False;   # tests / embedders pin a model (e.g. MockLLM)

def pin_lift_llm(m: any) -> None {
    lift_llm = m;
    _LIFT_PINNED = True;
}

# Fine-grained progress hook for the spec loop — the ONE stage that is a
# multi-minute chain of frontier calls (extract → ground → coverage → modality,
# per round) with no sub-structure the coarse compile stage view can show. The
# lint pre-pass installs a renderer here so `[Y/n] Y` stops looking hung; the
# compile path leaves it None (its "spec loop" stage line + heartbeat suffice).
# Deliberately separate from lift.jac's `lift_progress`: different granularity,
# and keeping it local to spec_loop avoids a spec_loop→lift import cycle.
glob spec_progress: any = None;

def set_spec_progress(cb: any) -> None { spec_progress = cb; }

def _emit_spec(ev: dict) -> None {
    if spec_progress is not None {
        try { spec_progress(ev); } except Exception as e {  }
    }
}

# ---------------------------------------------------------------------------
# model proposes
# ---------------------------------------------------------------------------

sem extract_round = """Extract the skill text into a complete RuleSet — every
obligation the prose states, as atomic rules. Segment first: one imperative, one
code block, one conditional clause, one 'see X.md' pointer = one rule. Rules:
(1) quote is VERBATIM from the skill — never paraphrase or invent; a rule whose
quote is not in the skill is mechanically dropped. (2) Classify modality into ONE of four:
a DO (MANDATORY: must/always/required/'follow its instructions'), a DON'T
(FORBIDDEN: never/do-not), a MAYBE (DISCRETIONARY: may/optional/'for advanced...
see'/an ILLUSTRATIVE code block or example command shown to demonstrate HOW to do
something), or a WHEN (any of the above gated by a condition). NEVER default an
unmarked or example span to MANDATORY — a demonstration ('here is how you could
merge PDFs') is a MAYBE, not a DO; reserve MANDATORY for genuine imperatives with
mandatory force. (3) For a WHEN, copy the triggering condition ('if/when/for X')
verbatim into `condition`; also fill it for any conditional or exemplary span. (4) An
adaptive tool-using activity ('explore...', 'iterate until...', 'use the tools
to...') is ONE rule with cohesion=INVOKE_UNIT — do not shred it into fragments.
(5) A demand to consult a live source at run time is kind=GROUNDING. (6) Keep
prior rule ids stable; apply the GAPS feedback exactly: remove the listed
invented rules, add grounded rules covering the listed uncovered spans, fix the
listed modality drift. (7) Set `binds` from the sentence's SUBJECT: an
imperative addressed to the executing agent binds 'agent'; a sentence describing
what a tool, harness, or system does binds 'environment' ('the harness never
guesses' is a fact ABOUT the harness — kind=KNOWLEDGE, binds='environment', even
though it says 'never'); statements about the human bind 'user'. (8) When a span
merely RESTATES an obligation already captured — a cross-reference ('Verify
(above).'), a recap bullet, a summary — attach it to that rule's `aliases`
instead of minting a duplicate rule. (9) Fill `statement` with one plain
imperative line restating the rule for the author; the verbatim `quote` remains
the only anchor.""";
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

def strip_frontmatter(skill: str) -> str {
    # Frontmatter is the ROUTER's contract — `name:`/`description:` say when a
    # harness should reach for the skill (see skill_description / mcp-serve).
    # It is not part of the procedure being compiled: trigger prose left in the
    # spec loop extracts as rules ("use this whenever ...") with no realizable
    # slot in the workflow, the r5 class of DROPPED faithfulness failures.
    # Every compile front-end sheds it here, so grounding never sees it and no
    # frontmatter-sourced rule can survive extraction.
    lines = (skill or "").splitlines(True);
    i = 0;
    n = len(lines);
    while (i < n) and (not lines[i].strip()) { i += 1; }
    if (i >= n) or (lines[i].strip() != "---") { return skill; }
    j = i + 1;
    while j < n {
        if lines[j].strip() == "---" { return "".join(lines[(j + 1):]); }
        j += 1;
    }
    return skill;   # an unterminated fence is a horizontal rule, not frontmatter
}

def _norm(s: any) -> str {
    # the grounding equivalence: casefolded, punctuation and markdown decoration
    # replaced by spaces, whitespace collapsed. Verbatim about WORDS, indifferent
    # to typography — `**bold**`, list numbering, backticks and smart quotes are
    # exactly what extracted quotes drift on run to run. NOT paraphrase-tolerant:
    # every word must still appear, in order.
    t = str(s).casefold();
    t = re.sub(r"[^\w\s]+", " ", t);
    return str(re.sub(r"\s+", " ", t)).strip();
}

def _in_skill(skill_norm: str, span: any) -> bool {
    sp = _norm(span);
    return bool(sp) and (sp in skill_norm);
}

def ground_rules(skill: str, rs: RuleSet) -> list[str] {
    # Soundness: ids of rules whose quote does NOT appear in the skill.
    # This is the mechanical anti-hallucination backbone — never model-judged.
    # Aliases are held to the same bar individually: a non-verbatim alias is
    # dropped from the rule (the rule survives on its primary quote).
    sn = _norm(skill);
    bad: list = [];
    for r in rs.rules {
        if not _in_skill(sn, r.quote) { bad.append(r.id); continue; }
        if r.aliases { r.aliases = [a for a in r.aliases if _in_skill(sn, a)]; }
    }
    return bad;
}

glob _FORBID_MARKERS: list = ["never ", "do not ", "don't ", "must not "];
glob _COND_MARKERS: list = ["if ", "when ", "unless ", "e.g.", "for example", "in case "];
glob _MAND_MARKERS: list = ["must ", "always ", "required", "ensure ", "shall ",
                            "make sure", "you need to", "it is mandatory", "important:"];
glob _DISCR_MARKERS: list = ["may ", "may:", "optional", "optionally", "if you ",
                             "if desired", "if needed", "consider ", "recommend",
                             "you can ", "could ", "for advanced", "as needed", "prefer "];

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

# ---------------------------------------------------------------------------
# Do / Don't / Maybe / When — the modal robustness of the spec.
#
# The extractor defaults an unmarked span to MANDATORY (a 'Do'), and reads
# modality "from deontic vocabulary only". But a reference manual states most of
# its content as ILLUSTRATIVE CODE ('here is how you could merge PDFs') — which
# carries no deontic words, so every snippet keeps the default and becomes a
# mandate. That is the over-hardening the PDF lift exposed: 20 example lines
# tagged MANDATORY. A 'maybe' shipped as a 'Do' is a faithfulness error as real
# as a dropped rule — the compiled agent is forced to do what the skill merely
# demonstrated.
#
# The fix, in the loop's own idiom (model proposes, CODE disposes): a span that
# is verbatim from inside a ``` fence, tagged MANDATORY, with NO mandatory deontic
# marker and NO condition, is a demonstration — demote it to DISCRETIONARY. The
# fence is DOCUMENT STRUCTURE, not a model judgment, so the demotion is
# deterministic. A genuine 'you MUST run exactly this' keeps its marker (or its
# mandating prose) and is left a Do.
# ---------------------------------------------------------------------------

def _fenced_lines(skill: str) -> list {
    inside = False;
    out: list = [];
    for ln in str(skill).splitlines() {
        s = ln.strip();
        if s.startswith("```") { inside = not inside; continue; }
        if inside {
            n = _norm(ln);
            if n { out.append(n); }
        }
    }
    return out;
}

def _has_mand_marker(q: any) -> bool {
    qq = " " + _norm(q) + " ";
    for m in _MAND_MARKERS { if m in qq { return True; } }
    return False;
}

def demote_examples(skill: str, rs: RuleSet) -> list[str] {
    fenced = _fenced_lines(skill);
    if not fenced { return []; }
    demoted: list = [];
    for r in rs.rules {
        if r.modality != Modality.MANDATORY { continue; }   # only 'Do' can be over-hardened
        if r.condition.strip() { continue; }                # a 'When' is not a bare Do
        if _has_mand_marker(r.quote) { continue; }          # an explicit Do stays a Do
        qlines: list = [_norm(x) for x in str(r.quote).splitlines() if _norm(x)];
        if not qlines { continue; }
        all_fenced = True;
        for ql in qlines { if ql not in fenced { all_fenced = False; break; } }
        if all_fenced {
            r.modality = Modality.DISCRETIONARY;   # Do -> Maybe: it was a demonstration
            demoted.append(r.id);
        }
    }
    return demoted;
}

# ---------------------------------------------------------------------------
# Ambiguity — the skill-quality signal.
#
# demote_examples handles the case with POSITIVE evidence of illustration (a
# fence). The harder case is PURE SILENCE: a span tagged MANDATORY with no modal
# signal AT ALL — no must/always, no never, no may/optional, no if/when. The
# extractor defaulted it to a mandate with nothing to go on. That is not the
# compiler's ambiguity to resolve; it is the SKILL that is underspecified. Flag
# it (do NOT silently flip — that would be another guess) so the compiler can
# WARN the author, or, with a human present, ASK. Same principle as the gates:
# never guess silently, diagnose precisely, let the contract owner decide.
# ---------------------------------------------------------------------------

def _has_forbid_marker(q: any) -> bool {
    qq = " " + _norm(q) + " ";
    for m in _FORBID_MARKERS { if m in qq { return True; } }
    return False;
}

def _has_discr_marker(q: any) -> bool {
    qq = " " + _norm(q) + " ";
    for m in _DISCR_MARKERS { if m in qq { return True; } }
    return False;
}

def flag_ambiguous(skill: str, rs: RuleSet) -> list[ClarifyItem] {
    # An obligation whose asserted modal force is NOT supported by the skill text is
    # underspecified — surface it, don't guess. Two mirror cases:
    #   - a Do   (MANDATORY) with no modal signal at all (no must/always/never/may/if)
    #   - a Don't (FORBIDDEN) with no never/do-not marker (a prohibition the skill
    #     never actually forbade — usually a mis-tagged example or capability)
    # (A When has a condition; a real Do/Don't has its marker; a fenced demonstration
    # was already demoted to a Maybe.)
    out: list = [];
    for r in rs.rules {
        q = str(r.quote).strip();
        if r.modality == Modality.MANDATORY {
            if r.condition.strip() { continue; }
            if _has_mand_marker(r.quote) or _has_forbid_marker(r.quote) or _has_discr_marker(r.quote) { continue; }
            out.append(ClarifyItem(rule_id=r.id, quote=q,
                reason="tagged MANDATORY (a Do) but the skill states no modal force"
                     + " (no must/always, no never, no may/optional, no if/when) — the reading is a guess",
                question='The skill says: "' + q[:180]
                     + '". Should the agent ALWAYS do this (Do), do it ONLY when the task calls for'
                     + " it (Maybe), or NEVER (Don't)?"));
        } elif r.modality == Modality.FORBIDDEN {
            if r.kind == RuleKind.KNOWLEDGE {
                # kind/modality CONFLICT — marker presence does NOT settle this:
                # a descriptive 'never' ("the harness never guesses") carries the
                # marker yet binds the tool, not the agent. Markers gate questions,
                # not conclusions.
                out.append(ClarifyItem(rule_id=r.id, quote=q,
                    reason="kind/modality conflict: tagged KNOWLEDGE (a fact to carry) yet FORBIDDEN"
                         + " (a prohibition) — a descriptive 'never' about a tool or the environment"
                         + " is knowledge, not a mandate on the agent",
                    question='The skill says: "' + q[:180]
                         + '". Is this a prohibition the agent itself must obey (Don\'t), background'
                         + " knowledge to carry verbatim (Do), or optional context (Maybe)?"));
                continue;
            }
            if _has_forbid_marker(r.quote) { continue; }   # a genuine Don't
            out.append(ClarifyItem(rule_id=r.id, quote=q,
                reason="tagged FORBIDDEN (a Don't) but the skill uses no never/do-not — likely a"
                     + " mis-tagged example or capability, not a real prohibition",
                question='The skill says: "' + q[:180]
                     + '". Must the agent NEVER do this (Don\'t), MAY it when relevant (Maybe), or'
                     + " must it ALWAYS (Do)?"));
        }
    }
    return out;
}

def skill_quality_lines(sr: SpecResult) -> list[str] {
    # The linter output: the compiler telling the author their SKILL.md is unclear
    # BEFORE it ships a wrong agent.
    n = len(sr.clarify);
    if n == 0 {
        return ["skill quality: CLEAR — every obligation states its modal force."];
    }
    lines: list = ["skill quality: " + str(n) + " UNDERSPECIFIED obligation(s) — the skill gives"
                   + " no signal whether these are Do / Maybe / Don't:"];
    for c in sr.clarify {
        lines.append("  ? " + c.rule_id + ': "' + str(c.quote)[:80] + '"');
    }
    lines.append("  → make each explicit in SKILL.md ('always/must', 'may/optionally', or 'never'),"
                 + " or compile with --clarify to answer inline.");
    return lines;
}

def resolve_ambiguous_default(rs: RuleSet, clarify: list[ClarifyItem]) -> list[str] {
    # The DEFAULT policy when no human is present: assume every underspecified
    # obligation is a MAYBE (optional) — the safe, non-blocking reading — and WARN,
    # so the author can re-run with --clarify to set the ones that should be a Do
    # or a Don't. This is the counterpart to apply_clarifications (the HIL path):
    # both resolve the ambiguity, one by assumption + warning, one by asking.
    demote: list = [c for c in clarify if not str(c.reason).startswith("kind/modality conflict")];
    keep: list = [c for c in clarify if str(c.reason).startswith("kind/modality conflict")];
    ids: list[str] = [c.rule_id for c in demote];
    for r in rs.rules {
        if (r.id in ids) and (r.modality != Modality.DISCRETIONARY) {
            r.modality = Modality.DISCRETIONARY;
        }
    }
    if not clarify { return []; }
    warns: list[str] = [];
    if demote {
        warns.append(str(len(demote)) + " underspecified obligation(s) ASSUMED to be MAYBE"
                     + " (optional) — the skill states no Do/Don't. Re-run with --clarify to set"
                     + " these by hand:");
        for c in demote { warns.append("  ? " + c.rule_id + ': "' + str(c.quote)[:70] + '"'); }
    }
    if keep {
        # KNOWLEDGE+FORBIDDEN keeps its modality: with required_shape treating it
        # as embodied knowledge, the faithful default is to CARRY the fact, not to
        # conscript it into a constraint or silently drop it.
        warns.append(str(len(keep)) + " descriptive prohibition(s) CARRIED as background knowledge"
                     + " (KNOWLEDGE tagged FORBIDDEN — a fact about a tool, not an agent mandate)."
                     + " Re-run with --clarify if any is a real Don't:");
        for c in keep { warns.append("  ? " + c.rule_id + ': "' + str(c.quote)[:70] + '"'); }
    }
    return warns;
}

glob _ANSWER_MODALITY: dict[str, Modality] = {
    "do": Modality.MANDATORY, "always": Modality.MANDATORY, "mandatory": Modality.MANDATORY,
    "maybe": Modality.DISCRETIONARY, "may": Modality.DISCRETIONARY, "optional": Modality.DISCRETIONARY,
    "dont": Modality.FORBIDDEN, "don't": Modality.FORBIDDEN, "never": Modality.FORBIDDEN
};

def apply_clarifications(rs: RuleSet, answers: dict[str, str]) -> list[str] {
    # The interactive tier: a human's answer to a clarify question BINDS the rule's
    # modality directly (Do/Maybe/Don't -> MANDATORY/DISCRETIONARY/FORBIDDEN), the
    # same way a run-time gate binds control flow. Unanswered rules are untouched.
    notes: list[str] = [];
    for r in rs.rules {
        a = str(answers.get(r.id, "")).strip().lower();
        if not a { continue; }
        if a not in _ANSWER_MODALITY { notes.append("clarify '" + r.id + "': unrecognized answer '" + a + "' — left unchanged"); continue; }
        m = _ANSWER_MODALITY[a];
        if (m == Modality.FORBIDDEN) and (r.kind == RuleKind.KNOWLEDGE) {
            # The human resolved a kind/modality conflict as a REAL prohibition:
            # it stops being a fact to carry and becomes a constraint to trace.
            notes.append("clarify '" + r.id + "': KNOWLEDGE -> CONSTRAINT (human: a real prohibition)");
            r.kind = RuleKind.CONSTRAINT;
        }
        if m != r.modality {
            notes.append("clarify '" + r.id + "': " + r.modality.name + " -> " + m.name + " (human)");
            r.modality = m;
        }
    }
    return notes;
}

def _covered(rs: RuleSet, span: str) -> bool {
    sp = _norm(span);
    if not sp { return True; }
    for r in rs.rules {
        for anchor in ([r.quote] + list(r.aliases)) {
            rq = _norm(anchor);
            if rq and ((sp in rq) or (rq in sp)) { return True; }
        }
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

def extract_spec(skill: str, name: str, max_rounds: int = 0) -> SpecResult {
    # Returns the frozen spec plus its honest verdict. Callers gate on
    # verdict.sound/complete rather than trusting the set blindly.
    sn = _norm(skill);
    prior = RuleSet(skill_name=name);
    verdict = ExtractVerdict();
    dry = 0;
    rounds = 0;
    # auto budget (max_rounds=0): caps tuned on 5-rule toys starve gpt-5-scale
    # specs (40-140 rules) — scale with observed size, bounded.
    cap = max_rounds if (max_rounds > 0) else 5;
    while (rounds < cap) and (dry < 2) {
        rnum = rounds + 1;
        _emit_spec({"phase": "extract", "round": rnum, "cap": cap});
        rs = extract_round(skill, prior, _gaps_digest(verdict));
        rs.skill_name = name;

        # dispose 1 — soundness: mechanically drop hallucinated rules
        _emit_spec({"phase": "ground", "round": rnum, "rules": len(rs.rules)});
        bad = ground_rules(skill, rs);
        if bad { rs.rules = [r for r in rs.rules if r.id not in bad]; }

        # dispose 1.5 — modal robustness (Do/Don't/Maybe/When): demote illustrative
        # example code from MANDATORY to DISCRETIONARY (a 'maybe', not a 'Do').
        # Deterministic, fence-grounded — see demote_examples.
        demote_examples(skill, rs);

        # dispose 2 — completeness: 3 lenses, self-filtered against the skill
        _emit_spec({"phase": "coverage", "round": rnum, "rules": len(rs.rules), "lenses": len(_LENSES)});
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
        _emit_spec({"phase": "modality", "round": rnum, "rules": len(rs.rules)});
        notes = audit_modality(skill, rs);

        rounds += 1;
        if max_rounds <= 0 { cap = min(9, max(5, 3 + len(rs.rules) // 20)); }
        changed = _fingerprint(rs) != _fingerprint(prior);
        verdict = ExtractVerdict(
            sound=(len(bad) == 0), complete=(len(uncovered) == 0),
            drift=(len(notes) > 0), ungrounded=bad, uncovered=uncovered,
            drift_notes=notes, changed=changed, rounds=rounds
        );
        prior = rs;
        _emit_spec({"phase": "round_done", "round": rounds, "rules": len(rs.rules),
                    "sound": verdict.sound, "complete": verdict.complete,
                    "drift": verdict.drift, "uncovered": len(uncovered)});
        if verdict.sound and verdict.complete and (not verdict.drift) { break; }
        if not changed { dry += 1; } else { dry = 0; }
    }
    # skill-quality pass: surface obligations whose modal force the skill never
    # stated (underspecified authoring) — warned, not guessed.
    _emit_spec({"phase": "clarify", "rules": len(prior.rules)});
    clar = flag_ambiguous(skill, prior);
    return SpecResult(spec=prior, verdict=verdict, clarify=clar);
}

