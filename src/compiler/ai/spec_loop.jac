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
    has settled: dict = {};                # rule_id -> the heading/intro that stated its force
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

# Code-STYLE guidance is a property of the code a node emits, not a step in the
# procedure. Left as STEP/MANDATORY it acquires RealShape.NODE and demands its
# own node — which no author can plausibly produce ("add a node realizing:
# Avoid unnecessary print statements") — so the compile fails UNFAITHFUL on
# rules that were never steps. Observed live on the SkillsBench xlsx skill:
# 19/23 realized, and all four drops were style rules (r26 comment hardcoded
# values, r89 concise code, r90 verbose variable names, r91 print statements).
# Re-kinded to CONSTRAINT the guidance lands where it belongs: folded into the
# docs of the nodes it governs, still reaching the artifact, no longer demanding
# a step of its own.
glob _STYLE_PATTERNS: list[str] = [
    r"\b(avoid|no|without|minimi[sz]e)\b[^.]{0,40}\b(unnecessary|verbose|redundant|extraneous|superfluous)\b",
    r"\bprint\s+statements?\b",
    r"\b(variable|function|parameter)\s+names?\b",
    r"\b(concise|minimal|readable|idiomatic|clean|tidy)\b[^.]{0,40}\bcode\b",
    r"\bcode\b[^.]{0,40}\b(concise|minimal|readable|idiomatic|clean|tidy)\b",
    r"\b(comment|docstring)s?\b",
    r"\bpep\s?8\b|\blint(ing)?\b|\bcode\s+style\b|\bformatting\s+conventions?\b",
];

def rekind_style_rules(rs: RuleSet) -> list[str] {
    changed: list[str] = [];
    for r in rs.rules {
        if r.kind != RuleKind.STEP { continue; }
        if r.modality == Modality.DISCRETIONARY { continue; }
        q = str(r.quote).lower();
        hit = False;
        for pat in _STYLE_PATTERNS {
            if re.search(pat, q) { hit = True; break; }
        }
        if not hit { continue; }
        r.kind = RuleKind.CONSTRAINT;
        changed.append(r.id);
    }
    return changed;
}


# A section PREAMBLE announces the procedure the steps below it carry out
# ("When editing slides you need to work with the raw OOXML format. This
# involves unpacking the .pptx, editing the XML, and repacking it.") — and the
# unpack/edit/pack steps are themselves extracted, as their own rules. Left as
# STEP/MANDATORY the summary acquires RealShape.NODE and demands a node of its
# own, which can only be a duplicate of the steps it introduces; the author
# rightly declines and the compile fails UNFAITHFUL. Observed live on the
# SkillsBench pptx skill: 22/24 realized, both drops preambles (r123 OOXML
# workflow, r125 template duplicate-and-rearrange). It is reference material —
# KNOWLEDGE — so it reaches the artifact carried verbatim, no longer demanding
# a step that already exists.
glob _PREAMBLE_OPENERS: list[str] = [
    r"^\s*when\b[^.]{0,140}\byou(?:'ll| will)?\s+(?:need|have)\s+to\b",
    r"\bthis involves\b",
];
# function words that carry no action, so they cannot evidence coverage
glob _PREAMBLE_STOP: list[str] = [
    "which", "these", "those", "their", "there", "where", "while", "would",
    "could", "should", "before", "after", "using", "about", "other",
    "existing", "following", "content", "context",
];

def _preamble_stems(quote: str) -> list[str] {
    # the actions the sentence announces: gerunds ("unpacking") plus whatever
    # follows "need to" ("duplicate and re-arrange..."), reduced to 5-char
    # prefixes so unpacking/unpack.py and replacing/replacements both match
    stems: list[str] = [];
    words: list[str] = [];
    for m in re.findall(r"\b([a-z][a-z-]{3,})ing\b", quote) { words.append(str(m)); }
    tail = re.search(r"\bneed\s+to\b(.*)$", quote);
    if tail {
        for m in re.findall(r"\b([a-z][a-z-]{3,})\b", str(tail.group(1))) { words.append(str(m)); }
    }
    for w in words {
        s = str(w).replace("-", "");
        if s in _PREAMBLE_STOP { continue; }
        if len(s) < 5 { continue; }
        p = s[:5];
        if p not in stems { stems.append(p); }
    }
    return stems;
}

def rekind_preamble_rules(rs: RuleSet) -> list[str] {
    changed: list[str] = [];
    for r in rs.rules {
        if r.kind != RuleKind.STEP { continue; }
        if r.modality == Modality.DISCRETIONARY { continue; }
        q = str(r.quote).lower();
        hit = False;
        for pat in _PREAMBLE_OPENERS {
            if re.search(pat, q) { hit = True; break; }
        }
        if not hit { continue; }
        # Guard: only demote when the actions it announces are ALREADY covered
        # by other rules. A lone "when you need to X, you'll need to Y" with no
        # steps behind it is the only realization of Y and must stay a STEP.
        stems = _preamble_stems(q);
        covered: list[str] = [];
        for s in stems {
            for other in rs.rules {
                if other.id == r.id { continue; }
                if s in str(other.quote).lower().replace("-", "") {
                    if s not in covered { covered.append(s); }
                    break;
                }
            }
        }
        if len(covered) < 2 { continue; }
        r.kind = RuleKind.KNOWLEDGE;
        changed.append(r.id);
    }
    return changed;
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

# ---------------------------------------------------------------------------
# Structural inference — the modal force the document states ABOUT a span
# rather than IN it.
#
# demote_examples already reads one structural signal (a ``` fence) and settles
# the spans inside it. The same move generalizes: markdown puts obligations
# under headings and inside lists, and either can carry a force the item itself
# omits.
#
#     ## Required steps           <- the heading mandates its whole section
#     Run the validator.          <- states no marker, but is not a maybe
#
#     You may optionally:         <- the intro governs the list under it
#     - Bump the minor version.   <- states no marker, but is not a mandate
#
# This is DOCUMENT STRUCTURE, exactly like the fence: which heading encloses a
# line and which intro opens a list are facts about the markdown, and the force
# is then read with the SAME deontic marker tables the rest of the module uses.
# No model is consulted anywhere in this pass.
#
# That last point is the requirement, not a bonus. The spec is the anchor every
# later stage is audited against, so a decision here that varied with the model
# doing the compiling would make the anchor itself model-dependent — and unlike
# extraction, where ground_rules mechanically drops anything not verbatim, a
# modality verdict has no such check behind it. Two models could read the same
# heading oppositely and both pass every gate. Code has to own this or nothing
# does.
#
# Deliberately narrow, for the same reason. Inheritance fires only when the
# governing line states exactly one force under the standing precedence, and
# only for a span that states none of its own. Open-vocabulary reading of
# headings ('## Recipes', '## Common tasks') is NOT attempted — that is
# interpretation, and interpretation is what --clarify and the standing
# assume-Maybe default are for. Whatever structure cannot settle stays flagged
# exactly as before, so this pass only ever shrinks the guesswork.
# ---------------------------------------------------------------------------

glob _LIST_ITEM: str = r"^\s*([-*+]|\d+[.)])\s+";

# A CLOSED vocabulary of heading words that mark a section as demonstration.
# Kept explicit and short on purpose: it is the same kind of table as
# _MAND_MARKERS, auditable by reading it, and it does not grow by inference.
glob _ILLUSTRATIVE_HEADINGS: list[str] = [
    "example", "examples", "sample", "samples", "demo", "demos",
    "demonstration", "demonstrations", "illustration", "illustrations"
];

def _force_of(line: any) -> str {
    # The single force a line states, under the module's standing precedence: a
    # prohibition outranks a mandate ("you must never" is a Don't), a mandate
    # outranks discretion. "" when the line states none.
    if _has_forbid_marker(line) { return "dont"; }
    if _has_mand_marker(line) { return "do"; }
    if _has_discr_marker(line) { return "maybe"; }
    return "";
}

def _illustrative_heading(line: any) -> bool {
    for w in _norm(str(line).lstrip("#")).split(" ") {
        if w in _ILLUSTRATIVE_HEADINGS { return True; }
    }
    return False;
}

def _heading_chain(lines: list, upto: int) -> list[str] {
    # The markdown heading stack governing line `upto`, outermost first.
    stack: list = [];
    for i in range(0, upto) {
        m = re.match(r"^(#{1,6})\s+(.*)$", str(lines[i]).rstrip());
        if not m { continue; }
        lvl = len(str(m.group(1)));
        while stack and (stack[-1][0] >= lvl) { stack.pop(); }
        stack.append([lvl, str(m.group(2)).strip()]);
    }
    return [str(s[1]) for s in stack];
}

def _locate(lines: list, quote: str) -> int {
    # Where a rule's span starts, matched under the SAME normalization grounding
    # uses — so a quote that survived ground_rules is still findable here despite
    # markdown decoration.
    first = "";
    for ln in str(quote).splitlines() {
        if _norm(ln) { first = _norm(ln); break; }
    }
    if not first { return -1; }
    for i in range(0, len(lines)) {
        n = _norm(lines[i]);
        if not n { continue; }
        # a short line contained in the quote only evidences the right spot when
        # it is substantial — otherwise a stray "ok" matches half the document
        if (first in n) or ((n in first) and (len(n) >= 12)) { return i; }
    }
    return -1;
}

def _governing_lines(lines: list, at: int) -> list {
    # The lines that can govern line `at`, NEAREST SCOPE FIRST: the intro that
    # opens the list block it belongs to, then the nearest enclosing heading.
    out: list = [];
    if re.match(_LIST_ITEM, str(lines[at])) {
        i = at - 1;
        blanks = 0;
        while i >= 0 {
            t = str(lines[i]).strip();
            if not t {
                # one blank inside a list is normal; two means the block ended
                # and whatever is above it governs something else
                blanks += 1;
                if blanks >= 2 { break; }
                i -= 1;
                continue;
            }
            if re.match(_LIST_ITEM, str(lines[i])) { i -= 1; continue; }
            if t.startswith("#") { break; }        # a heading is not a list intro
            # the intro must actually READ as one — a paragraph that happens to
            # sit above a list is not governing it
            if t.endswith(":") { out.append(["intro", t]); }
            break;
        }
    }
    chain = _heading_chain(lines, at);
    if chain { out.append(["heading", str(chain[-1])]); }
    return out;
}

def infer_modality(skill: str, rs: RuleSet) -> dict {
    # {rule_id: [force, governing span]} for each rule whose force the DOCUMENT
    # states even though the span itself does not. Reads only; the caller binds.
    lines = str(skill).splitlines();
    out: dict = {};
    for r in rs.rules {
        if r.condition.strip() { continue; }     # a 'When' already carries its gate
        if _force_of(r.quote) { continue; }      # the span states its own force
        at = _locate(lines, r.quote);
        if at < 0 { continue; }
        for g in _governing_lines(lines, at) {
            f = _force_of(g[1]);
            if (not f) and (g[0] == "heading") and _illustrative_heading(g[1]) { f = "maybe"; }
            if not f { continue; }
            out[r.id] = [f, str(g[1])];
            break;                               # nearest governing scope wins
        }
    }
    return out;
}

def apply_structural_modality(skill: str, rs: RuleSet) -> dict {
    # Bind what structure settles, and report {rule_id: governing span} so the
    # decision is never anonymous. Mirrors demote_examples: mutate, return ids.
    settled: dict = {};
    inferred = infer_modality(skill, rs);
    for r in rs.rules {
        if r.id not in inferred { continue; }
        pair = inferred[r.id];
        f = str(pair[0]);
        m = Modality.DISCRETIONARY;
        if f == "do" { m = Modality.MANDATORY; }
        elif f == "dont" { m = Modality.FORBIDDEN; }
        # A descriptive fact under a prohibiting heading is still a fact —
        # the kind/modality conflict is flag_ambiguous's to raise, not this
        # pass's to silently resolve.
        if (m == Modality.FORBIDDEN) and (r.kind == RuleKind.KNOWLEDGE) { continue; }
        r.modality = m;
        settled[r.id] = str(pair[1]);
    }
    return settled;
}

def flag_ambiguous(skill: str, rs: RuleSet, settled: any = None) -> list[ClarifyItem] {
    # An obligation whose asserted modal force is NOT supported by the skill text is
    # underspecified — surface it, don't guess. `settled` carries the rules whose
    # force the document already stated structurally (heading or list intro); those
    # are not underspecified and are not flagged. Two mirror cases:
    #   - a Do   (MANDATORY) with no modal signal at all (no must/always/never/may/if)
    #   - a Don't (FORBIDDEN) with no never/do-not marker (a prohibition the skill
    #     never actually forbade — usually a mis-tagged example or capability)
    # (A When has a condition; a real Do/Don't has its marker; a fenced demonstration
    # was already demoted to a Maybe.)
    done = settled if settled else {};
    out: list = [];
    for r in rs.rules {
        q = str(r.quote).strip();
        if r.id in done { continue; }   # the document stated this one structurally
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

def _settled_lines(sr: SpecResult) -> list[str] {
    # Structural bindings are REPORTED but never warned: the document did state
    # the force, so this is the compiler reading correctly, not authoring debt —
    # making it fatal under --strict would punish a well-organized skill.
    if not sr.settled { return []; }
    out: list[str] = [str(len(sr.settled)) + " obligation(s) took their force from the section"
                      + " or list that governs them:"];
    for rid in sr.settled.keys() {
        out.append('  · ' + str(rid) + ' ← "' + str(sr.settled[rid]).replace(chr(10), " ")[:70] + '"');
    }
    return out;
}

def skill_quality_lines(sr: SpecResult) -> list[str] {
    # The linter output: the compiler telling the author their SKILL.md is unclear
    # BEFORE it ships a wrong agent.
    n = len(sr.clarify);
    if n == 0 {
        return ["skill quality: CLEAR — every obligation states its modal force."] + _settled_lines(sr);
    }
    lines: list = ["skill quality: " + str(n) + " UNDERSPECIFIED obligation(s) — the skill gives"
                   + " no signal whether these are Do / Maybe / Don't:"];
    for c in sr.clarify {
        lines.append("  ? " + c.rule_id + ': "' + str(c.quote)[:80] + '"');
    }
    lines.append("  → make each explicit in SKILL.md ('always/must', 'may/optionally', or 'never'),"
                 + " or compile with --clarify to answer inline.");
    return lines + _settled_lines(sr);
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
    _settled: dict = {};   # survives the loop: the last round's structural bindings
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
        # dispose 1.6 — the same structural read, one scope out: a heading or a
        # list intro that states a force the item itself omits. Deterministic,
        # so the frozen spec stays independent of which model compiled it.
        _settled = apply_structural_modality(skill, rs);
        if _settled {
            _emit_spec({"phase": "structure", "round": rnum, "rules": len(rs.rules),
                        "settled": len(_settled)});
        }
        _styled = rekind_style_rules(rs);
        if _styled {
            _emit_spec({"phase": "style", "round": rnum, "rules": len(rs.rules),
                        "restyled": len(_styled)});
        }
        _pre = rekind_preamble_rules(rs);
        if _pre {
            _emit_spec({"phase": "preamble", "round": rnum, "rules": len(rs.rules),
                        "rekinded": len(_pre)});
        }

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
    clar = flag_ambiguous(skill, prior, _settled);
    return SpecResult(spec=prior, verdict=verdict, clarify=clar, settled=_settled);
}

