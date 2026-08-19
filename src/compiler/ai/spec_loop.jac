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

# STEP GRANULARITY — a numbered/bulleted imperative under a procedure header is
# a MANDATORY STEP of its own, decided mechanically (never by the model).
#
# Bench finding (GRC skills: data-privacy-expert, iso27001-internal-auditor,
# soc2-system-description). These skills write their procedure as bare imperative
# lists — "**Process:** 2. Search all systems for personal data", "### Step 1:
# Assess Breach - Contain the breach", "**Activities**: - Review Information
# Security Policy" — with no must/always wording. Two things then lose them:
#   (1) the modality detector flags them `?`, and with no adjudicator
#       resolve_ambiguous_default ASSUMES MAYBE (optional); a DISCRETIONARY rule
#       gets no mandatory node, G5 never enforces it, and the compiled agent
#       deterministically skips the step. iso27001 lost 99 rules this way — its
#       whole audit procedure — and compiled to a 13-node graph.
#   (2) occasionally the extractor folds such steps into the deliverable rule as
#       `aliases` ("a recap of 'Provide data copy'"), a procedure mistaken for a
#       restatement of its outcome.
# Measured: dpe AMC 50% (vs hand-authored OSP 80%) -> 100% once every procedural
# step had its own node; iso27001 40 -> 80; soc2 70 -> 100.
# _procedural_step_header is the shared detector (_is_procedural_step_line is the
# bool view of it); promote_procedural_aliases fixes (2).
#
# (1) is fixed at TWO points, and which one carries it matters. The reading is
# structural inference — the same class of fact as a heading or a list intro —
# so it belongs in infer_modality, alongside them, where apply_structural_modality
# binds it and records it in `settled`. That is what makes it hold: flag_ambiguous
# skips a settled rule, so the step never becomes a clarify item, the adjudicator
# is never asked about it, and no model answer can demote it. The guard in
# resolve_ambiguous_default stays as a BACKSTOP for the residue — a rule whose
# quote drifted between rounds, or one flagged for a different reason — but it is
# no longer the only thing standing between a procedural step and a MAYBE.
glob _SKILL_FOR_RESOLVE: str = "";
# a step line that starts with one of these is a label/descriptor, not an imperative
glob _NON_IMPERATIVE_STARTS: list = ["most", "least", "the", "a", "an", "this", "that", "these", "those", "four-column", "four", "three", "two", "one", "gdpr", "ccpa", "iso", "soc", "all", "any", "some", "no", "non", "key", "main", "common", "typical", "example", "examples", "note", "notes", "tip", "tips", "optional", "optionally", "consider", "maybe", "if", "when", "unless", "for", "in", "on", "at", "with", "without", "e.g.", "i.e.", "see", "also"];
glob _PROC_HEADERS: list = ["process:", "steps:", "procedure:", "workflow:", "checklist:", "how to:", "actions:", "tasks:"];
# bold stage headers like "**Step 1: Assess Breach (Immediately)**" / "Phase 2: ..." also open a procedure
glob _PROC_HEADER_RX: list = [
    r"^#{0,6}\s*\*{0,2}\s*(step|phase|stage)\s*\d+\s*[:.\-]",        # "### Step 1: Document Review" / "**Step 1: Assess**"
    r"^#{1,6}\s+.*\b(workflow|procedure|process|checklist|handling)\b",  # "## Workflow for AI Agents" / "### Handling Access Requests"
    r"^\*\*[a-z ]*(activities|actions|tasks|steps|process|procedure|checklist|in [a-z]+)\*\*\s*:",  # "**Activities**:" / "**In Vanta**:"
];

def set_skill_for_resolve(skill: str) -> None { _SKILL_FOR_RESOLVE = skill; }

def _is_procedural_step_line(skill: str, span: str) -> bool {
    return bool(_procedural_step_header(skill, span));
}

def _procedural_step_header(skill: str, span: str) -> str {
    # The procedure header that CLAIMS this span, or "" when none does. The span
    # must be (a) a list item ("2. …", "- …", "* …") on its own line in the skill
    # and (b) sit under a procedure-style header within a short window.
    # Returns the header rather than a bool because infer_modality has to CITE
    # it: a structural binding is always reported with the span that governed it
    # (see _settled_lines), never anonymously.
    sp = str(span).strip();
    if not sp { return ""; }
    # must read as an IMPERATIVE: reject labels/descriptors ("Most reliable evidence",
    # "Four-Column Format", "GDPR applies when:") — a step starts with a bare verb.
    body0 = re.sub(r"^(\d+[.)]|[-*•])\s+", "", sp).strip();
    if body0.endswith(":") { return ""; }
    w0 = re.split(r"[\s,]+", body0.lower())[0] if body0 else "";
    if (not w0) or (w0 in _NON_IMPERATIVE_STARTS) or w0.endswith("est") or w0.endswith("ly") { return ""; }
    lines = skill.split("\n");
    for i in range(len(lines)) {
        ln = lines[i].strip();
        if not re.match(r"^(\d+[.)]|[-*•])\s+", ln) { continue; }
        body = re.sub(r"^(\d+[.)]|[-*•])\s+", "", ln).strip();
        if _norm(body) != _norm(sp) and _norm(ln) != _norm(sp) { continue; }
        # walk UP to the nearest header (<=25 lines). A procedure header claims
        # the line; any OTHER markdown heading or bold label closes the section
        # first — so a "## Quick Decision Tree" bullet is never claimed by a
        # "### Step 1:" block sitting above it.
        lo = i - 25 if i - 25 > 0 else 0;
        j = i - 1;
        while j >= lo {
            raw = lines[j].strip();
            hl = raw.lower().replace("**", "");
            is_proc = False;
            for h in _PROC_HEADERS {
                if hl.endswith(h) or hl == h.rstrip(":") { is_proc = True; }
            }
            for rx in _PROC_HEADER_RX {
                if re.search(rx, raw.lower()) { is_proc = True; }
            }
            # a bold label that introduces a list ("**Activities**:", "**Three Evidence
            # Collection Techniques**:") opens a procedure block too
            if re.match(r"^\*\*[^*]+\*\*\s*:\s*$", raw) { is_proc = True; }
            if is_proc { return raw; }
            # only a markdown heading closes the section
            if re.match(r"^#{1,6}\s+", raw) { return ""; }
            j = j - 1;
        }
    }
    return "";
}

def promote_procedural_aliases(skill: str, rs: RuleSet) -> list[str] {
    # Any alias that is a procedural step line becomes its own MANDATORY STEP
    # rule (inheriting the host rule's binds); returns the new rule ids.
    promoted: list[str] = [];
    new_rules: list[Rule] = [];
    base_n: int = 0;
    for _r0 in rs.rules { base_n = base_n + 1; }
    for r in rs.rules {
        if not r.aliases { continue; }
        keep: list[str] = [];
        for a in r.aliases {
            if _is_procedural_step_line(skill, a) {
                nid = "r" + str(base_n + len(new_rules) + 1);
                nr = Rule(id=nid, quote=str(a), kind=RuleKind.STEP, modality=Modality.MANDATORY,
                          binds=r.binds, statement=re.sub(r"^(\d+[.)]|[-*•])\s+", "", str(a)).strip());
                new_rules.append(nr);
                promoted.append(nid + " <- alias of " + r.id + ": " + str(a)[:60]);
            } else { keep.append(a); }
        }
        r.aliases = keep;
    }
    for nr in new_rules { rs.rules.append(nr); }
    return promoted;
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
    # step granularity: a procedural step hiding as an alias is promoted to a rule
    promote_procedural_aliases(skill, rs);
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
        if at >= 0 {
            for g in _governing_lines(lines, at) {
                f = _force_of(g[1]);
                if (not f) and (g[0] == "heading") and _illustrative_heading(g[1]) { f = "maybe"; }
                if not f { continue; }
                out[r.id] = [f, str(g[1])];
                break;                           # nearest governing scope wins
            }
        }
        # STEP GRANULARITY — the last structural read, and the weakest signal, so
        # it fires only when no governing line stated a force at all: the span is
        # a list item under a procedure header, and the list IS the procedure, so
        # the author means it as a Do. An explicit force still wins outright —
        # a list under '## Examples' is demoted by the loop above and never
        # reaches here.
        #
        # This is the TIER the reading has to live at. #176 put the same detector
        # at the bottom (resolve_ambiguous_default), which only sees obligations
        # the adjudicator declined to answer — so a model answering 'maybe' on a
        # procedural step demoted it anyway, and two identical steps in one list
        # could end up MANDATORY and DISCRETIONARY depending on which the model
        # happened to answer. Settling here closes that: a settled rule is never
        # flagged, so the adjudicator is never asked and cannot answer it away.
        # _locate is deliberately not required — _procedural_step_header does its
        # own line scan, so a quote _locate cannot place is still protected.
        if (r.id not in out) and (r.kind == RuleKind.STEP) {
            ph = _procedural_step_header(skill, str(r.quote));
            if ph { out[r.id] = ["do", ph]; }
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
    # STEP-GRANULARITY BACKSTOP (bench finding, data-privacy-expert): a
    # numbered/bulleted imperative under a procedure header ("Process: 2. Search
    # all systems…", "**Step 1: Assess Breach** - Contain the breach") carries no
    # must/always wording, so it was ASSUMED MAYBE and dropped from the graph (no
    # node → the agent deterministically skipped it; AMC 50 vs hand-OSP 80). The
    # list IS the procedure: such a step is MANDATORY by structure. Keep it a DO.
    #
    # infer_modality now settles these one tier up, so in the ordinary case they
    # never reach here at all. This remains for what still can: a quote the last
    # extraction round rephrased past the detector at settle time, or a step
    # flagged for some other reason. Reaching this line is the exception, not the
    # mechanism — the mechanism is that structure decided before anyone asked.
    protected: list[str] = [];
    for r in rs.rules {
        if (r.id in ids) and (r.kind == RuleKind.STEP) and _is_procedural_step_line(_SKILL_FOR_RESOLVE, str(r.quote)) {
            protected.append(r.id);
            r.modality = Modality.MANDATORY;
        }
    }
    ids = [x for x in ids if x not in protected];
    demote = [c for c in demote if c.rule_id not in protected];
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

def apply_clarifications(rs: RuleSet, answers: dict[str, str], source: str = "human") -> list[str] {
    # The binding tier: an answer to a clarify question BINDS the rule's modality
    # directly (Do/Maybe/Don't -> MANDATORY/DISCRETIONARY/FORBIDDEN), the same way
    # a run-time gate binds control flow. Unanswered rules are untouched.
    # `source` is PROVENANCE, not policy — the binding is identical whether the
    # answer came from the human (--clarify) or the adjudicator; only the note
    # differs, so a reader of the warnings can always tell which decided.
    notes: list[str] = [];
    for r in rs.rules {
        a = str(answers.get(r.id, "")).strip().lower();
        if not a { continue; }
        if a not in _ANSWER_MODALITY { notes.append("clarify '" + r.id + "': unrecognized answer '" + a + "' — left unchanged"); continue; }
        m = _ANSWER_MODALITY[a];
        if (m == Modality.FORBIDDEN) and (r.kind == RuleKind.KNOWLEDGE) {
            # The kind/modality conflict resolved as a REAL prohibition: it stops
            # being a fact to carry and becomes a constraint to trace.
            notes.append("clarify '" + r.id + "': KNOWLEDGE -> CONSTRAINT (" + source + ": a real prohibition)");
            r.kind = RuleKind.CONSTRAINT;
        }
        if m != r.modality {
            notes.append("clarify '" + r.id + "': " + r.modality.name + " -> " + m.name + " (" + source + ")");
            r.modality = m;
        }
    }
    return notes;
}

# ---------------------------------------------------------------------------
# The ADJUDICATOR — answering the clarify questions with no human present.
#
# Two tiers already stand between a flagged obligation and a guess:
# apply_structural_modality settles the ones whose heading or list intro states
# a force outright (deterministic, already applied by the time we get here), and
# resolve_ambiguous_default assumes MAYBE for everything left. This tier sits
# between them: it ANSWERS the residue — the obligations structure could not
# settle and the author never marked — instead of demoting them all alike.
#
# It stands in for the human that --clarify would ask, and it is held to the
# rules that human is not: the answer must be sourced from the document, and
# code decides whether it counts.
#
#   THE MODEL PROPOSES               one batched call over every residual item,
#                                    each carrying its deterministic evidence
#                                    packet (heading chain, neighbouring lines,
#                                    which of them state a force of their own)
#
#   CODE DISPOSES                    ground_adjudications drops any answer whose
#                                    cited span is not verbatim in the skill, or
#                                    which only restates the obligation, or which
#                                    re-modalizes a rule nobody flagged
#
#   ANYTHING DROPPED                 falls through to the standing MAYBE default
#
# On the model dependence this introduces, honestly: it is real and it is NOT
# eliminated. Two models can read one heading differently and both cite it
# verbatim, so grounding constrains WHERE an answer may come from, never WHICH
# answer it is. That is why the deterministic tier runs first and keeps as much
# as possible out of here, why every decision is reported with the model that
# made it and the span it came from, and why --no-adjudicate exists to skip the
# tier entirely for a reproducible compile. What this tier must never do is
# decide silently.
# ---------------------------------------------------------------------------

obj Adjudication {
    has rule_id: str = "";
    has answer: str = "";       # do | maybe | dont
    has evidence: str = "";
    has rationale: str = "";
}
sem Adjudication = "One underspecified obligation answered from the skill's own text.";
sem Adjudication.rule_id = "The flagged obligation's id (r1, r2, ...) — exactly as given in the ITEM.";
sem Adjudication.answer = "The modal force the DOCUMENT shows the author intended: 'do' (always), 'maybe' (only when the task calls for it), or 'dont' (never).";
sem Adjudication.evidence = "A span copied VERBATIM from the skill, from somewhere OTHER than the obligation's own sentence, that shows this intent — the section heading it sits under, a neighbouring line whose modal force it shares, the intro line governing its list. Evidence that is not verbatim in the skill, or that merely restates the obligation, is mechanically dropped and the obligation falls back to MAYBE.";
sem Adjudication.rationale = "One short line: how that evidence settles this obligation.";

obj AdjudicationSet {
    has kept: list[Adjudication] = [];
    has dropped: list[str] = [];
}

# Its OWN model handle rather than lift_llm: byllm's `__call__` writes call_params
# onto the shared instance, and the adjudicator is the one slot whose answer is a
# DECISION rather than a proposal — keeping it separately pinnable means it can be
# aimed at a different tier (or a MockLLM in tests) without disturbing extraction.
glob adjudge_llm: any = Model(model_name="gpt-4o-mini");

def pin_adjudge_llm(m: any) -> None { adjudge_llm = m; }

def adjudge_model_name(m: any) -> str {
    # Named in the report: a decision this tier makes is model-dependent, so the
    # compile output must say WHICH model made it.
    try { return str(m.model_name); } except Exception as e { return "unknown"; }
}

sem adjudicate_ambiguous = """You are standing in for the SKILL'S AUTHOR to answer
questions their prose left open. For each ITEM, decide whether the skill means it
as a DO (the agent always does this), a MAYBE (only when the task calls for it), or
a DON'T (never).

Answer from THIS DOCUMENT ALONE. You are not being asked what is good practice in
general, what the wider ecosystem does, or what you would recommend — only what
this skill's own text shows its author intended. Domain knowledge is NOT evidence
here: an obligation hardened into a DO because it sounds like sensible practice
forces the compiled agent to do something the author never required, and nothing
downstream can detect that.

Every answer MUST carry `evidence`: a span copied VERBATIM from the skill, from
somewhere OTHER than the obligation's own sentence. The obligation was flagged
precisely because its own sentence carries no modal force, so quoting it back
settles nothing. Useful evidence looks like: the heading of the section it lives in
('## Required steps' vs '## Examples'), a sibling line in the same list that DOES
state a force, or an intro line governing that list ('Always do each of the
following:').

When the document does not settle an item, OMIT it entirely. Omission is the correct,
safe answer — it falls back to MAYBE, which never forces the agent's hand. Returning
five well-evidenced answers and omitting three is better than guessing at all
eight.""";
sem adjudicate_ambiguous.skill = "The full skill text — the only admissible evidence.";
sem adjudicate_ambiguous.items = "The flagged obligations: for each, its id, its sentence, why it was flagged, and the deterministic in-document context (heading chain and neighbouring lines, with any modal markers already noted).";
def adjudicate_ambiguous(skill: str, items: str) -> list[Adjudication] by adjudge_llm();

def section_context(skill: str, quote: str, radius: int = 3) -> str {
    # The deterministic evidence packet for one flagged obligation, built from the
    # same document walk apply_structural_modality uses. Everything here is read
    # off the markdown by code; the model only gets to INTERPRET it, never to
    # supply it — and ground_adjudications then checks the interpretation cites
    # something that is actually in the document.
    lines = str(skill).splitlines();
    at = _locate(lines, quote);
    if at < 0 { return ""; }
    chain = _heading_chain(lines, at);
    lo = max(0, at - radius);
    hi = min(len(lines), at + radius + 1);
    sibs: list[str] = [];
    for i in range(lo, hi) {
        if i == at { continue; }
        t = str(lines[i]).strip();
        if not t { continue; }
        f = _force_of(t);
        mark = "";
        if f == "do" { mark = "   [states a DO]"; }
        elif f == "dont" { mark = "   [states a DON'T]"; }
        elif f == "maybe" { mark = "   [states a MAYBE]"; }
        sibs.append("    " + t[:140] + mark);
    }
    out: list[str] = ["SECTION: " + (" > ".join(chain) if chain else "(no heading)")];
    if sibs {
        out.append("NEIGHBOURING LINES:");
        out = out + sibs;
    }
    return "\n".join(out);
}

def ground_adjudications(skill: str, clarify: list[ClarifyItem],
                         adjs: list[Adjudication]) -> AdjudicationSet {
    # CODE DISPOSES — the bar ground_rules holds the spec to, applied to the
    # adjudicator's answers. An answer survives only if:
    #   (1) it answers an obligation that was actually FLAGGED (no drive-by
    #       re-modalizing of rules nobody asked about);
    #   (2) its answer is in the Do/Maybe/Don't vocabulary;
    #   (3) its evidence appears VERBATIM in the skill — sourcing the answer in
    #       the document rather than in the model's world knowledge;
    #   (4) that evidence is NOT inside the obligation's own sentence — the flag
    #       fired because that sentence states no force, so quoting it back is a
    #       restatement, not evidence.
    # Everything else falls through to the assume-Maybe default. This cannot make
    # the tier deterministic — see the header — but it does bound every answer to
    # text the author actually wrote.
    sn = _norm(skill);
    by_id: dict = {};
    for c in clarify { by_id[c.rule_id] = c; }
    out = AdjudicationSet();
    seen: list[str] = [];
    for a in adjs {
        rid = str(a.rule_id).strip();
        ans = str(a.answer).strip().lower().replace("'", "");
        if rid not in by_id {
            out.dropped.append(rid + ": adjudicated but never flagged — ignored");
            continue;
        }
        if rid in seen {
            out.dropped.append(rid + ": duplicate adjudication — ignored");
            continue;
        }
        if ans not in _ANSWER_MODALITY {
            out.dropped.append(rid + ": unrecognized answer '" + str(a.answer)[:30] + "'");
            continue;
        }
        ev = str(a.evidence).strip();
        if not _in_skill(sn, ev) {
            out.dropped.append(rid + ": evidence is not verbatim in the skill");
            continue;
        }
        if _norm(ev) in _norm(by_id[rid].quote) {
            out.dropped.append(rid + ": evidence only restates the obligation itself");
            continue;
        }
        seen.append(rid);
        out.kept.append(a);
    }
    return out;
}

def resolve_ambiguous_auto(rs: RuleSet, clarify: list[ClarifyItem],
                           adjs: AdjudicationSet) -> list[str] {
    # Bind what the adjudicator answered, default the rest, and REPORT both —
    # naming the model, because a decision that depends on the model must say so.
    answers: dict[str, str] = {};
    for a in adjs.kept { answers[str(a.rule_id)] = str(a.answer).strip().lower().replace("'", ""); }
    warns: list[str] = [];
    if answers {
        before: dict = {};
        for r in rs.rules { before[r.id] = r.modality.name; }
        notes = apply_clarifications(rs, answers, "adjudicator");
        warns.append(str(len(answers)) + " underspecified obligation(s) ANSWERED by the adjudicator ("
                     + adjudge_model_name(adjudge_llm) + ") from the skill's own text — re-run with --clarify"
                     + " to answer them yourself, or --no-adjudicate to assume Maybe:");
        for a in adjs.kept {
            rid = str(a.rule_id);
            now = "";
            for r in rs.rules { if r.id == rid { now = r.modality.name; } }
            warns.append("  ~ " + rid + ": " + str(before.get(rid, "?")) + " -> " + now
                         + '  (skill evidence: "' + str(a.evidence).strip().replace(chr(10), " ")[:60] + '")');
        }
        # a kind change is a bigger move than a modality change — surface it plainly
        for n in notes { if "CONSTRAINT" in n { warns.append("    " + n); } }
    }
    if adjs.dropped {
        # No silent caps: the adjudicator answered these and was REFUSED, so they
        # fall to the default below. Saying so is how a reader tells "the document
        # settled nothing" apart from "the adjudicator was never asked".
        warns.append(str(len(adjs.dropped)) + " adjudication(s) rejected by the grounding check"
                     + " (falling back to Maybe):");
        for d in adjs.dropped { warns.append("  x " + str(d)[:110]); }
    }
    left = [c for c in clarify if c.rule_id not in answers];
    return warns + resolve_ambiguous_default(rs, left);
}

def adjudicate_spec(skill: str, sr: SpecResult) -> list[str] {
    # The tier end to end. Note what it is NOT asked to answer: everything
    # apply_structural_modality already settled deterministically is absent from
    # sr.clarify by now, so the model only ever sees the genuine residue.
    if not sr.clarify { return []; }
    _emit_spec({"phase": "adjudicate", "items": len(sr.clarify)});
    items: list[str] = [];
    for c in sr.clarify {
        ctx = section_context(skill, c.quote);
        items.append("---\nID: " + c.rule_id
                     + "\nOBLIGATION: " + str(c.quote)[:300]
                     + "\nWHY FLAGGED: " + str(c.reason)
                     + (chr(10) + ctx if ctx else ""));
    }
    adjs: list = [];
    try { adjs = list(adjudicate_ambiguous(skill, "\n".join(items))); }
    except Exception as e {
        # The adjudicator is an IMPROVEMENT on the standing default, never a
        # dependency of it: a failed call degrades to assume-Maybe + warn, which
        # is exactly the behavior --no-adjudicate selects on purpose.
        return ["adjudicator unavailable (" + str(e)[:60] + ") — assuming Maybe"]
             + resolve_ambiguous_default(sr.spec, sr.clarify);
    }
    return resolve_ambiguous_auto(sr.spec, sr.clarify, ground_adjudications(skill, sr.clarify, adjs));
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
    _SKILL_FOR_RESOLVE = skill;   # the resolver's demotion guard needs the source text
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

