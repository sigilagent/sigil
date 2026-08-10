"""AI compiler — the SKILL LINTER.

The spec loop already diagnoses authoring debt (underspecified modality,
kind/modality conflicts) — but its findings speak per-compile: assume Maybe,
or ask the human via --clarify. The linter turns the same findings into
DURABLE skill edits: for each finding it proposes the minimal rewrite that
makes the obligation's true modal force explicit, the human accepts or
rejects each one, and accepted edits land in the SKILL.md itself — so every
later compile (and every raw-skill consumer) reads the same obligation.

The model proposes, code disposes, the human decides:
  - the suggestion slot drafts one minimal edit per finding;
  - mechanical guards drop any edit whose `old` is not verbatim in the skill
    (nothing can be rewritten that was not actually written) and any modality
    edit whose `new` carries no modal marker (the edit must actually fix the
    finding it answers);
  - the human accepts edits one by one — nothing touches the file without an
    explicit yes.
"""

import re;

import from .lift_types { Modality }
import from .spec_loop { lift_llm, SpecResult, ClarifyItem }

# NOTE: objs that ride a `by llm` slot's return schema are defined IN the
# slot's module (byllm's schema builder cannot resolve nested objs across
# modules).

obj FixEdit {
    has rule_id: str = "";
    has old: str = "";
    has new: str = "";
    has modality: str = "";
}
sem FixEdit = "One candidate skill edit: a finding's sentence rephrased with ONE modal force.";
sem FixEdit.rule_id = "The finding's rule id this edit answers (r1, r2, ...).";
sem FixEdit.old = "An EXACT contiguous span currently in the skill text — copied character-for-character, whitespace included, AT MOST one sentence. An old that does not appear verbatim in the skill is mechanically dropped.";
sem FixEdit.new = "The SAME sentence with only its modal force made explicit for this edit's modality — every detail, every backtick code token, and the grammar intact.";
sem FixEdit.modality = "Which modal force this phrasing encodes: 'do' (must/always), 'maybe' (may/optional/if-when), or 'dont' (never/do not).";

obj LintFinding {
    has rule_id: str = "";
    has quote: str = "";
    has reason: str = "";
    has kind: str = "modality";           # modality | conflict
    has old: str = "";
    has variants: dict[str, str] = {};    # modality -> guarded rephrasing
    has new: str = "";                    # the CHOSEN rephrasing (set at review time)
    has applicable: bool = False;         # at least one guarded variant exists
}

sem suggest_fixes = """You are a SKILL LINTER. The human will decide each
finding's true modal force; YOUR job is only to draft the phrasing for ONE
force — the given FORCE — for every finding it can apply to. Return one edit
per finding. Rules: (1) `old` is an EXACT contiguous span from the skill —
character-for-character — AT MOST one sentence (never a whole bullet or
paragraph). (2) `new` is the same sentence with only the FORCE made
explicit: every detail, every backtick code token, and the grammar survive
intact; the sentence stays ONE grammatical sentence — do not split it or
bolt clauses together with periods. Removing or summarizing content is
FORBIDDEN. (3) Ignore how the finding was previously tagged — phrase the
GIVEN force: 'do' with must/always; 'maybe' with may/optionally or an
if/when clause named from the surrounding context ('If a `state` residue
appears, verify the read/set rewrites'); 'dont' with never/do-not. (4) Skip
a finding only when this force genuinely cannot apply to its sentence.""";
sem suggest_fixes.skill = "The full skill text (frontmatter already stripped) — the only ground truth for `old` spans.";
sem suggest_fixes.findings = "The lint findings: one per line, 'rule_id | kind | quote'.";
sem suggest_fixes.force = "The ONE modal force to phrase every edit with: 'do', 'maybe', or 'dont'.";
def suggest_fixes(skill: str, findings: str, force: str) -> list[FixEdit] by lift_llm();

glob _MODAL_MARKERS: list[str] = [
    "must", "always", "never", "do not", "don't", "required",
    "may ", "optional", "optionally", "if ", "when ", "only when", "for each"
];

def _has_modal_marker(s: str) -> bool {
    t = " " + str(s).casefold() + " ";
    for m in _MODAL_MARKERS {
        if m in t { return True; }
    }
    return False;
}

def _mangled(s: str) -> bool {
    # punctuation wreckage a sentence-splitting rewrite leaves behind:
    # ".," / " . " artifacts, or a lowercase clause bolted on after a period
    # (exempting the usual abbreviations).
    if (".," in s) or (" . " in s) { return True; }
    if re.search(r"(?<!e\.g)(?<!i\.e)(?<!etc)(?<!vs)\. \(?[a-z]", s) { return True; }
    return False;
}

def validate_edits(skill: str, findings: list[LintFinding], edits: list) -> None {
    # code disposes: attach each surviving edit as a modality VARIANT on its
    # finding. An edit survives only when its old is verbatim in the skill,
    # actually changes something, and its new states a modal force. Content-
    # preservation guards (an accept-everything human must still be safe):
    # old is a narrow span shared by all of a finding's variants, new keeps
    # every backtick code token, may not materially shorten what it replaces,
    # and may not leave sentence-splitting punctuation wreckage.
    by_id: dict = {};
    for f in findings { by_id[f.rule_id] = f; }
    for e in edits {
        f = by_id.get(str(e.rule_id));
        if not f { continue; }
        m = str(e.modality).strip().lower();
        if m not in ["do", "maybe", "dont"] { continue; }
        if m in f.variants { continue; }              # first valid variant per modality wins
        old = str(e.old); new = str(e.new);
        if (not old.strip()) or (not new.strip()) { continue; }
        if old == new { continue; }
        if old not in skill { continue; }             # nothing to rewrite that was not written
        if f.old and (old != f.old) { continue; }     # one span per finding, shared by variants
        if old.count("\n") > 1 { continue; }          # one sentence, not a bullet block
        if len(new.strip()) < (0.7 * len(old.strip())) { continue; }   # no summarizing away detail
        if _mangled(new) { continue; }                # no punctuation wreckage
        toks = re.findall(r"`[^`]+`", old);
        kept = True;
        for t in toks {
            if t not in new { kept = False; break; }  # every code token survives
        }
        if not kept { continue; }
        if not _has_modal_marker(new) { continue; }   # the variant must state its force
        f.old = old;
        f.variants[m] = new;
        f.applicable = True;
    }
}

def lint_findings(skill: str, sr: SpecResult) -> list[LintFinding] {
    # Assemble findings from the spec loop's clarify items, then draft guarded
    # fix suggestions in ONE batched slot call.
    out: list[LintFinding] = [];
    for c in sr.clarify {
        k = "conflict" if str(c.reason).startswith("kind/modality conflict") else "modality";
        out.append(LintFinding(rule_id=c.rule_id, quote=str(c.quote), reason=str(c.reason), kind=k));
    }
    if not out { return out; }
    # The digest omits the extractor's guess on purpose: told "tagged
    # MANDATORY", the model drafts only mandatory phrasings. One slot call
    # per force — each call has a single unambiguous job — and the modality
    # is stamped from call context, never trusted from the model's label.
    digest = "\n".join([
        f.rule_id + " | " + f.kind + " | " + str(f.quote)[:200]
        for f in out
    ]);
    forces: list[str] = ["maybe", "do"];
    if [f for f in out if f.kind == "conflict"] { forces.append("dont"); }
    for force in forces {
        edits: list = [];
        try { edits = list(suggest_fixes(skill, digest, force)); } except Exception { edits = []; }
        for e in edits { e.modality = force; }
        validate_edits(skill, out, edits);
    }
    return out;
}

def apply_edits(source: str, findings: list[LintFinding]) -> str {
    # Apply ACCEPTED edits (callers pass only those) to the FULL source —
    # first occurrence each, sequentially; an edit whose old has vanished
    # (overlapped by an earlier edit) is skipped rather than misapplied.
    text = str(source);
    for f in findings {
        if (not f.applicable) or (not str(f.new).strip()) { continue; }   # no chosen phrasing -> untouched
        if f.old not in text { continue; }
        text = text.replace(f.old, f.new, 1);
    }
    return text;
}
