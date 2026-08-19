"""Tests — the Spec convergence loop.

The code gates are tested directly (no model); the loop is driven by a scripted
MockLLM: round one extracts a grounded rule plus a HALLUCINATED one, the critics
surface the uncovered spans, round two converges. Asserts the hallucination was
mechanically dropped and the verdict is honest.
"""

import from jaclang.byllm.lib { MockLLM }

glob SKILL: str = """# CSV Extractor
Always write the output as CSV with a header row.
Parse the input file with the standard library.
Never use Unicode subscripts in output.
If the file is a form, read FORMS.md and follow its instructions.
""";

test "ground_rules mechanically drops a rule whose quote is not in the skill" {
    rs = RuleSet(skill_name="csv", rules=[
        Rule(id="r1", quote="Always write the output as CSV with a header row."),
        Rule(id="r2", quote="Compress the output with gzip.")
    ]);
    bad = ground_rules(SKILL, rs);
    assert bad == ["r2"];
}

test "grounding is whitespace/case tolerant but not paraphrase tolerant" {
    rs = RuleSet(rules=[
        Rule(id="a", quote="always   WRITE the output as csv with a header row."),
        Rule(id="b", quote="Write the results as comma separated values.")
    ]);
    bad = ground_rules(SKILL, rs);
    assert bad == ["b"];
}

test "audit_modality flags forbidden drift and conditional inflation" {
    rs = RuleSet(rules=[
        Rule(id="r1", quote="Never use Unicode subscripts in output.", modality=Modality.MANDATORY),
        Rule(id="r2", quote="If the file is a form, read FORMS.md and follow its instructions.",
             modality=Modality.MANDATORY, condition=""),
        Rule(id="r3", quote="Always write the output as CSV with a header row.",
             modality=Modality.MANDATORY)
    ]);
    notes = audit_modality(SKILL, rs);
    assert len(notes) == 2;
    assert "r1" in notes[0];   # forbidden span, non-FORBIDDEN modality
    assert "r2" in notes[1];   # conditional span, unconditional MANDATORY, empty condition
}

glob SKILL_FENCED: str = """# PDF Guide
Always write the output as CSV with a header row.
Here is how you could read a PDF:
```python
reader = PdfReader("document.pdf")
print(len(reader.pages))
```
If the file is a form, read FORMS.md.
Never use Unicode subscripts.
""";

test "demote_examples turns fenced example code (a Maybe) from MANDATORY to DISCRETIONARY" {
    rs = RuleSet(rules=[
        # a genuine DO — has a mandatory marker, left alone
        Rule(id="do", quote="Always write the output as CSV with a header row.",
             modality=Modality.MANDATORY),
        # example code lifted as a MANDATORY step — the over-hardening bug
        Rule(id="ex1", quote='reader = PdfReader("document.pdf")', modality=Modality.MANDATORY),
        Rule(id="ex2", quote="print(len(reader.pages))", modality=Modality.MANDATORY),
        # a WHEN — carries a condition, left alone even if unmarked
        Rule(id="when", quote="If the file is a form, read FORMS.md.",
             modality=Modality.MANDATORY, condition="If the file is a form"),
        # a DON'T — not MANDATORY, untouched
        Rule(id="dont", quote="Never use Unicode subscripts.", modality=Modality.FORBIDDEN)
    ]);
    demoted = demote_examples(SKILL_FENCED, rs);
    assert sorted(demoted) == ["ex1", "ex2"];
    by_id: dict = {};
    for r in rs.rules { by_id[r.id] = r.modality; }
    assert by_id["ex1"] == Modality.DISCRETIONARY;   # Maybe
    assert by_id["ex2"] == Modality.DISCRETIONARY;   # Maybe
    assert by_id["do"] == Modality.MANDATORY;        # Do — marker 'always' protects it
    assert by_id["when"] == Modality.MANDATORY;      # When — condition protects it
    assert by_id["dont"] == Modality.FORBIDDEN;      # Don't — untouched
}

test "demote_examples is a no-op when the skill has no code fences" {
    rs = RuleSet(rules=[Rule(id="a", quote="do the thing", modality=Modality.MANDATORY)]);
    assert demote_examples("plain prose, no fences here", rs) == [];
    assert rs.rules[0].modality == Modality.MANDATORY;
}

test "flag_ambiguous surfaces both an unmarked Do and a mis-tagged Don't" {
    rs = RuleSet(rules=[
        # underspecified: MANDATORY but no must/never/may/if signal at all
        Rule(id="amb", quote="combine or merge multiple PDFs into one", modality=Modality.MANDATORY),
        # mis-tagged: FORBIDDEN on example code that has no 'never/do-not'
        Rule(id="fake_dont", quote="from pypdf import PdfReader, PdfWriter", modality=Modality.FORBIDDEN),
        # a real Do — has 'always'
        Rule(id="do", quote="Always write a header row.", modality=Modality.MANDATORY),
        # a real Don't — has 'never'
        Rule(id="dont", quote="Never use Unicode subscripts.", modality=Modality.FORBIDDEN),
        # an explicit Maybe
        Rule(id="maybe", quote="You may compress the output.", modality=Modality.DISCRETIONARY),
        # a When (has a condition)
        Rule(id="when", quote="If the file is a form, read FORMS.md.",
             modality=Modality.MANDATORY, condition="If the file is a form")
    ]);
    items = flag_ambiguous("no fences here", rs);
    ids = sorted([c.rule_id for c in items]);
    assert ids == ["amb", "fake_dont"];
    amb = [c for c in items if c.rule_id == "amb"][0];
    assert "MANDATORY" in amb.reason;
    fake = [c for c in items if c.rule_id == "fake_dont"][0];
    assert "FORBIDDEN" in fake.reason;
}

test "skill_quality_lines reports clear vs underspecified" {
    clean = SpecResult(spec=RuleSet(rules=[
        Rule(id="do", quote="Always write a header row.", modality=Modality.MANDATORY)]));
    clean.clarify = flag_ambiguous("x", clean.spec);
    assert "CLEAR" in skill_quality_lines(clean)[0];

    bad = SpecResult(spec=RuleSet(rules=[
        Rule(id="amb", quote="merge the PDFs into one", modality=Modality.MANDATORY)]));
    bad.clarify = flag_ambiguous("x", bad.spec);
    lines = skill_quality_lines(bad);
    assert "1 UNDERSPECIFIED" in lines[0];
    assert any([("amb" in l) for l in lines]);
}

test "resolve_ambiguous_default assumes Maybe and warns to re-run with --clarify" {
    rs = RuleSet(rules=[
        Rule(id="amb", quote="merge the PDFs into one", modality=Modality.MANDATORY),
        Rule(id="do", quote="Always write a header row.", modality=Modality.MANDATORY)
    ]);
    clar = flag_ambiguous("no fences", rs);   # flags only 'amb'
    warns = resolve_ambiguous_default(rs, clar);
    by_id: dict = {};
    for r in rs.rules { by_id[r.id] = r.modality; }
    assert by_id["amb"] == Modality.DISCRETIONARY;   # assumed Maybe (the safe default)
    assert by_id["do"] == Modality.MANDATORY;        # a real Do is untouched
    assert any([("ASSUMED to be MAYBE" in w) for w in warns]);
    assert any([("amb" in w) for w in warns]);
}

test "apply_clarifications binds a human's Do/Maybe/Don't answer to the rule's modality" {
    rs = RuleSet(rules=[
        Rule(id="a", quote="merge the PDFs", modality=Modality.MANDATORY),
        Rule(id="b", quote="rotate pages", modality=Modality.MANDATORY),
        Rule(id="c", quote="delete the source", modality=Modality.MANDATORY)
    ]);
    notes = apply_clarifications(rs, {"a": "maybe", "b": "do", "c": "dont"});
    by_id: dict = {};
    for r in rs.rules { by_id[r.id] = r.modality; }
    assert by_id["a"] == Modality.DISCRETIONARY;   # human said Maybe
    assert by_id["b"] == Modality.MANDATORY;       # human said Do (unchanged)
    assert by_id["c"] == Modality.FORBIDDEN;       # human said Don't
    assert len(notes) == 2;                        # a and c changed; b did not
}

# ---------------------------------------------------------------------------
# Structural inference — force stated ABOUT a span by its heading or list intro.
# Every assertion below runs with no model in the process at all.
# ---------------------------------------------------------------------------

glob SKILL_SECTIONS: str = """# Release Guide

## Required steps
Run the validator before shipping.
Update the changelog.

## Examples
Bump the minor version.

## Cleanup
You may optionally:
- Prune stale release branches.
- Archive the old tags.

## Notes
Delete the upstream remote.
""";

test "a heading's own modal marker governs the spans under it" {
    rs = RuleSet(rules=[
        Rule(id="r1", quote="Run the validator before shipping.", modality=Modality.DISCRETIONARY),
        Rule(id="r2", quote="Update the changelog.", modality=Modality.DISCRETIONARY)
    ]);
    settled = apply_structural_modality(SKILL_SECTIONS, rs);
    # '## Required steps' carries a mandatory marker; both spans inherit it
    assert rs.rules[0].modality == Modality.MANDATORY;
    assert rs.rules[1].modality == Modality.MANDATORY;
    assert "Required steps" in settled["r1"];    # the binding names its own evidence
    assert "Required steps" in settled["r2"];
}

test "an illustrative heading demotes an unmarked mandate to a maybe" {
    rs = RuleSet(rules=[
        Rule(id="r3", quote="Bump the minor version.", modality=Modality.MANDATORY)
    ]);
    apply_structural_modality(SKILL_SECTIONS, rs);
    assert rs.rules[0].modality == Modality.DISCRETIONARY;
}

test "a list intro governs its items, and outranks the heading above it" {
    rs = RuleSet(rules=[
        Rule(id="r4", quote="Prune stale release branches.", modality=Modality.MANDATORY),
        Rule(id="r5", quote="Archive the old tags.", modality=Modality.MANDATORY)
    ]);
    settled = apply_structural_modality(SKILL_SECTIONS, rs);
    # 'You may optionally:' is the nearer scope; '## Cleanup' states no force anyway
    assert rs.rules[0].modality == Modality.DISCRETIONARY;
    assert rs.rules[1].modality == Modality.DISCRETIONARY;
    assert "may optionally" in settled["r4"];
}

test "a span under a heading that states no force is left alone" {
    # '## Notes' carries no marker and is not in the illustrative vocabulary —
    # structure genuinely does not settle this one, so nothing is invented.
    rs = RuleSet(rules=[
        Rule(id="r6", quote="Delete the upstream remote.", modality=Modality.MANDATORY)
    ]);
    settled = apply_structural_modality(SKILL_SECTIONS, rs);
    assert settled == {};
    assert rs.rules[0].modality == Modality.MANDATORY;   # untouched, still flaggable
}

test "a span that states its own force is never overridden by its container" {
    # 'Never force-push to main.' under '## Required steps' stays a Don't — the
    # span's own marker always wins over the scope enclosing it.
    skill = "## Required steps\nNever force-push to main.\n";
    rs = RuleSet(rules=[
        Rule(id="r1", quote="Never force-push to main.", modality=Modality.FORBIDDEN)
    ]);
    assert apply_structural_modality(skill, rs) == {};
    assert rs.rules[0].modality == Modality.FORBIDDEN;
}

test "a conditional span keeps its own gate rather than the section's force" {
    skill = "## Required steps\nIf the build is tagged, publish the artifact.\n";
    rs = RuleSet(rules=[
        Rule(id="r1", quote="If the build is tagged, publish the artifact.",
             modality=Modality.MANDATORY, condition="If the build is tagged")
    ]);
    assert apply_structural_modality(skill, rs) == {};
}

test "structurally settled obligations are no longer flagged as underspecified" {
    rs = RuleSet(rules=[
        Rule(id="r1", quote="Run the validator before shipping.", modality=Modality.MANDATORY),
        Rule(id="r6", quote="Delete the upstream remote.", modality=Modality.MANDATORY)
    ]);
    settled = apply_structural_modality(SKILL_SECTIONS, rs);
    clar = flag_ambiguous(SKILL_SECTIONS, rs, settled);
    ids = [c.rule_id for c in clar];
    assert "r1" not in ids;      # '## Required steps' stated it
    assert "r6" in ids;          # '## Notes' did not — still the author's call
}

test "the same skill produces the same bindings on every run" {
    # The property the pass exists for: no model, no sampling, no tier — the
    # frozen spec cannot vary with what is compiling it.
    first: dict = {};
    for _i in range(0, 5) {
        rs = RuleSet(rules=[
            Rule(id="r1", quote="Run the validator before shipping.", modality=Modality.DISCRETIONARY),
            Rule(id="r3", quote="Bump the minor version.", modality=Modality.MANDATORY),
            Rule(id="r4", quote="Prune stale release branches.", modality=Modality.MANDATORY)
        ]);
        got = apply_structural_modality(SKILL_SECTIONS, rs);
        got["__mods"] = ",".join([r.modality.name for r in rs.rules]);
        if not first { first = got; }
        assert got == first;
    }
    assert first["__mods"] == "MANDATORY,DISCRETIONARY,DISCRETIONARY";
}

test "a descriptive fact under a prohibiting scope stays a fact" {
    # KNOWLEDGE is not conscripted into a constraint by its container — that
    # kind/modality call belongs to flag_ambiguous and the human, not here.
    skill = "## Never do these\nThe harness refuses to guess.\n";
    rs = RuleSet(rules=[
        Rule(id="r1", quote="The harness refuses to guess.",
             kind=RuleKind.KNOWLEDGE, modality=Modality.MANDATORY)
    ]);
    assert apply_structural_modality(skill, rs) == {};
    assert rs.rules[0].kind == RuleKind.KNOWLEDGE;
}

# ---------------------------------------------------------------------------
# The adjudicator — answering the residue the structural pass could not settle.
# The model only ever proposes; everything below pins what CODE refuses.
# ---------------------------------------------------------------------------

test "section_context hands the model evidence it did not choose" {
    ctx = section_context(SKILL_SECTIONS, "Update the changelog.");
    assert "Release Guide" in ctx;          # outer heading
    assert "Required steps" in ctx;         # the section that governs the span
    assert "Run the validator before shipping." in ctx;   # a neighbour
    assert "Update the changelog." not in ctx;            # never its own evidence
}

test "section_context is empty for a span that is not in the document" {
    assert section_context(SKILL_SECTIONS, "Publish the artifact to npm.") == "";
}

test "ground_adjudications keeps only answers evidenced elsewhere in the skill" {
    clar = [
        ClarifyItem(rule_id="r1", quote="Run the validator before shipping."),
        ClarifyItem(rule_id="r2", quote="Update the changelog."),
        ClarifyItem(rule_id="r3", quote="Bump the minor version.")
    ];
    gs = ground_adjudications(SKILL_SECTIONS, clar, [
        # grounded: cites a DIFFERENT line that is verbatim in the skill
        Adjudication(rule_id="r1", answer="do", evidence="## Required steps"),
        # invented evidence — the whole point of the gate
        Adjudication(rule_id="r2", answer="do", evidence="Releases must always be validated."),
        # evidence only restates the obligation the flag already saw
        Adjudication(rule_id="r3", answer="do", evidence="Bump the minor version."),
        # re-modalizing a rule nobody flagged
        Adjudication(rule_id="r9", answer="do", evidence="## Required steps"),
        # outside the Do/Maybe/Don't vocabulary
        Adjudication(rule_id="r2", answer="sometimes", evidence="## Required steps")
    ]);
    assert len(gs.kept) == 1;
    assert gs.kept[0].rule_id == "r1";
    assert len(gs.dropped) == 4;
    joined = " | ".join(gs.dropped);
    assert "not verbatim" in joined;
    assert "restates the obligation" in joined;
    assert "never flagged" in joined;
    assert "unrecognized answer" in joined;
}

test "an ungrounded answer cannot harden a rule into a Do" {
    # The failure this gate exists for: a MAYBE silently upgraded to a mandate on
    # reasoning the skill does not contain.
    rs = RuleSet(rules=[Rule(id="r6", quote="Delete the upstream remote.", modality=Modality.MANDATORY)]);
    clar = flag_ambiguous(SKILL_SECTIONS, rs);
    gs = ground_adjudications(SKILL_SECTIONS, clar, [
        Adjudication(rule_id="r6", answer="do",
                     evidence="Removing stale remotes is standard git hygiene.")
    ]);
    warns = resolve_ambiguous_auto(rs, clar, gs);
    assert rs.rules[0].modality == Modality.DISCRETIONARY;   # fell back to the safe default
    assert any([("rejected by the grounding check" in w) for w in warns]);
}

test "resolve_ambiguous_auto binds answered obligations and defaults the rest" {
    rs = RuleSet(rules=[
        Rule(id="r6", quote="Delete the upstream remote.", modality=Modality.MANDATORY),
        Rule(id="r7", quote="Notify the release channel.", modality=Modality.MANDATORY)
    ]);
    clar = [
        ClarifyItem(rule_id="r6", quote="Delete the upstream remote."),
        ClarifyItem(rule_id="r7", quote="Notify the release channel.")
    ];
    gs = ground_adjudications(SKILL_SECTIONS, clar, [
        Adjudication(rule_id="r6", answer="dont", evidence="## Notes")
    ]);
    warns = resolve_ambiguous_auto(rs, clar, gs);
    by_id: dict = {};
    for r in rs.rules { by_id[r.id] = r.modality; }
    assert by_id["r6"] == Modality.FORBIDDEN;        # answered
    assert by_id["r7"] == Modality.DISCRETIONARY;    # unanswered -> standing default
    assert any([("ANSWERED by the adjudicator" in w) for w in warns]);
    assert any([("skill evidence" in w) for w in warns]);
    assert any([("ASSUMED to be MAYBE" in w) for w in warns]);
    # --strict keeps its teeth, and the report names the model that decided
    assert any([(adjudge_model_name(adjudge_llm) in w) for w in warns]);
}

test "answers are labelled by provenance, not passed off as the human's" {
    rs = RuleSet(rules=[Rule(id="a", quote="merge the PDFs", modality=Modality.MANDATORY)]);
    assert "(adjudicator)" in apply_clarifications(rs, {"a": "dont"}, "adjudicator")[0];
    rs2 = RuleSet(rules=[Rule(id="a", quote="merge the PDFs", modality=Modality.MANDATORY)]);
    assert "(human)" in apply_clarifications(rs2, {"a": "dont"})[0];   # default unchanged
}

glob FM_SKILL: str = """---
name: csv-extractor
description: >-
  Use this whenever you need CSV extraction. Do NOT use it for JSON.
---

# CSV Extractor
Always write the output as CSV with a header row.
""";

test "strip_frontmatter sheds the router block and keeps the body" {
    body = strip_frontmatter(FM_SKILL);
    assert "Use this whenever" not in body;
    assert "csv-extractor" not in body;
    assert "Always write the output as CSV with a header row." in body;
}

test "strip_frontmatter is a no-op without frontmatter" {
    assert strip_frontmatter(SKILL) == SKILL;
    assert strip_frontmatter("") == "";
}

test "an unterminated fence is a horizontal rule, not frontmatter" {
    hr = "---\nAlways write the output as CSV.\n";
    assert strip_frontmatter(hr) == hr;
}

test "leading blank lines before the fence still count as frontmatter" {
    padded = "\n\n" + FM_SKILL;
    assert "Use this whenever" not in strip_frontmatter(padded);
}

test "a frontmatter-sourced rule can no longer survive grounding" {
    # The r5 class: trigger prose from `description:` extracted as a rule.
    # Grounded against the stripped body, it is mechanically dropped.
    rs = RuleSet(rules=[
        Rule(id="r5", quote="Use this whenever you need CSV extraction."),
        Rule(id="r1", quote="Always write the output as CSV with a header row.")
    ]);
    bad = ground_rules(strip_frontmatter(FM_SKILL), rs);
    assert bad == ["r5"];
}

test "grounding is markdown/typography tolerant but still word-exact" {
    rs = RuleSet(rules=[
        Rule(id="a", quote="**Always** write the `output` as CSV with a header row."),
        Rule(id="b", quote="1. Never use Unicode subscripts in output."),
        Rule(id="c", quote="Always write the CSV output.")
    ]);
    bad = ground_rules(SKILL, rs);
    # a: bold/backtick decoration normalizes away; b: fails — '1.' adds a WORD
    # ('1') the skill never wrote; c: fails — reordered words are a paraphrase
    assert bad == ["b", "c"];
}

test "a non-verbatim alias is dropped; the rule survives on its quote" {
    rs = RuleSet(rules=[
        Rule(id="a", quote="Always write the output as CSV with a header row.",
             aliases=["Parse the input file with the standard library.",
                      "Compress the output with gzip."])
    ]);
    bad = ground_rules(SKILL, rs);
    assert bad == [];
    assert rs.rules[0].aliases == ["Parse the input file with the standard library."];
}

test "an aliased span counts as covered — no duplicate rule gets re-extracted" {
    rs = RuleSet(rules=[
        Rule(id="a", quote="Always write the output as CSV with a header row.",
             aliases=["Parse the input file with the standard library."])
    ]);
    assert _covered(rs, "Parse the input file with the standard library.");
    assert not _covered(rs, "Never use Unicode subscripts in output.");
}

test "a KNOWLEDGE+FORBIDDEN conflict is flagged even with a forbid marker" {
    conflict_skill = "The harness converts what it can prove safe. it never silently guesses.\nNever use tabs.\n";
    rs = RuleSet(rules=[
        Rule(id="r_fact", quote="it never silently guesses.",
             kind=RuleKind.KNOWLEDGE, modality=Modality.FORBIDDEN),
        Rule(id="r_real", quote="Never use tabs.",
             kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN)
    ]);
    items = flag_ambiguous(conflict_skill, rs);
    # r_real has its marker and agrees with its kind -> not questioned;
    # r_fact's marker does NOT settle the kind/modality conflict -> questioned
    assert len(items) == 1;
    assert items[0].rule_id == "r_fact";
    assert items[0].reason.startswith("kind/modality conflict");
    assert "prohibition the agent itself must obey" in items[0].question;
}

test "default policy carries a conflict as knowledge instead of demoting it" {
    rs = RuleSet(rules=[
        Rule(id="r_fact", quote="it never silently guesses.",
             kind=RuleKind.KNOWLEDGE, modality=Modality.FORBIDDEN),
        Rule(id="r_vague", quote="merge the PDFs", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    items = [
        ClarifyItem(rule_id="r_fact", quote="it never silently guesses.",
                    reason="kind/modality conflict: tagged KNOWLEDGE ..."),
        ClarifyItem(rule_id="r_vague", quote="merge the PDFs", reason="tagged MANDATORY ...")
    ];
    warns = resolve_ambiguous_default(rs, items);
    by_id: dict = {};
    for r in rs.rules { by_id[r.id] = r.modality; }
    assert by_id["r_fact"] == Modality.FORBIDDEN;        # kept — carried as knowledge
    assert by_id["r_vague"] == Modality.DISCRETIONARY;   # demoted as before
    assert any(["CARRIED as background knowledge" in w for w in warns]);
}

test "a human 'dont' on a KNOWLEDGE rule reclassifies it as a real prohibition" {
    rs = RuleSet(rules=[
        Rule(id="r_fact", quote="it never silently guesses.",
             kind=RuleKind.KNOWLEDGE, modality=Modality.FORBIDDEN)
    ]);
    notes = apply_clarifications(rs, {"r_fact": "dont"});
    assert rs.rules[0].kind == RuleKind.CONSTRAINT;
    assert rs.rules[0].modality == Modality.FORBIDDEN;
    assert any(["KNOWLEDGE -> CONSTRAINT" in n for n in notes]);
}

test "code-style guidance is re-kinded off STEP so it stops demanding a node" {
    # the four live drops from the SkillsBench xlsx compile (19/23 realized)
    rs = RuleSet(rules=[
        Rule(id="r26", quote="Add a comment explaining any hardcoded value."),
        Rule(id="r89", quote="Write concise code"),
        Rule(id="r90", quote="Avoid verbose variable names and redundant operations"),
        Rule(id="r91", quote="Avoid unnecessary print statements"),
        Rule(id="r5", quote="Recalculate the workbook before saving.")
    ]);
    changed = rekind_style_rules(rs);
    assert sorted(changed) == ["r26", "r89", "r90", "r91"];
    by_id: dict[str, Rule] = {};
    for r in rs.rules { by_id[r.id] = r; }
    for rid in ["r26", "r89", "r90", "r91"] {
        # CONSTRAINT is folded into the docs it governs — no node of its own
        # (kind -> RealShape.CONSTRAINT is asserted in faith.test.jac)
        assert by_id[rid].kind == RuleKind.CONSTRAINT;
    }
    # a genuine step is untouched
    assert by_id["r5"].kind == RuleKind.STEP;
}

test "a section preamble is carried as knowledge, not demanded as a step" {
    # the two live drops from the SkillsBench pptx compile (22/24 realized):
    # both announce a workflow whose steps are extracted separately below them
    rs = RuleSet(rules=[
        Rule(id="r123", quote="When edit slides in an existing PowerPoint presentation, "
             + "you need to work with the raw Office Open XML (OOXML) format. This involves "
             + "unpacking the .pptx file, editing the XML content, and repacking it."),
        Rule(id="r125", quote="When you need to create a presentation that follows an "
             + "existing template's design, you'll need to duplicate and re-arrange template "
             + "slides before then replacing placeholder context."),
        # ... the steps themselves, which are what the preambles announce
        Rule(id="r127", quote="Unpack the presentation: python ooxml/scripts/unpack.py"),
        Rule(id="r128", quote="Edit the XML files (primarily ppt/slides/slideN.xml)"),
        Rule(id="r129", quote="Pack the final presentation: python ooxml/scripts/pack.py"),
        Rule(id="r130", quote="Duplicate, reorder, and delete slides using rearrange.py"),
        Rule(id="r131", quote="Apply replacements using the replace.py script")
    ]);
    changed = rekind_preamble_rules(rs);
    assert sorted(changed) == ["r123", "r125"];
    by_id: dict[str, Rule] = {};
    for r in rs.rules { by_id[r.id] = r; }
    for rid in ["r123", "r125"] {
        # KNOWLEDGE is carried verbatim (RealShape.EMBODIED_KNOWLEDGE) instead
        # of demanding a node that would duplicate the steps it introduces
        assert by_id[rid].kind == RuleKind.KNOWLEDGE;
    }
    for rid in ["r127", "r128", "r129", "r130", "r131"] {
        assert by_id[rid].kind == RuleKind.STEP;
    }
}

test "a preamble whose actions nothing else covers stays a STEP" {
    # the guard: with no steps behind it, this sentence is the ONLY realization
    # of the work it names — demoting it to knowledge would silently drop it
    rs = RuleSet(rules=[
        Rule(id="r1", quote="When you need to publish, you'll need to sign the bundle "
             + "and then upload it to the registry."),
        Rule(id="r2", quote="Read the manifest first.")
    ]);
    assert rekind_preamble_rules(rs) == [];
    assert rs.rules[0].kind == RuleKind.STEP;
}

test "an explicitly optional preamble is left alone" {
    rs = RuleSet(rules=[
        Rule(id="r1", quote="When you need to convert, you'll need to export the sheet "
             + "and then import it.", modality=Modality.DISCRETIONARY),
        Rule(id="r2", quote="Export the sheet as CSV."),
        Rule(id="r3", quote="Import it into the workbook.")
    ]);
    assert rekind_preamble_rules(rs) == [];
    assert rs.rules[0].kind == RuleKind.STEP;
}

# NOTE: the MockLLM convergence run lives in scenarios/spec_loop.jac (run via
# `jac run` in CI) — same runtime bug as above.

# ---------------------------------------------------------------------------
# Step granularity: a numbered/bulleted imperative under a procedure header is
# MANDATORY by structure. Born from the GRC bench (data-privacy-expert 50 vs
# hand-OSP 80; iso27001 lost 99 rules): such steps carry no must/always wording,
# so the modality detector flagged them `?` and, with no adjudicator,
# resolve_ambiguous_default assumed MAYBE and the graph dropped them.
# ---------------------------------------------------------------------------

glob PROC_SKILL: str = """# Access requests

### Handling Access Requests

**Process:**
1. Verify identity of requester
2. Search all systems for personal data
3. Compile data in readable format
4. Review for third-party rights or confidential information

## Breach Response

### Step 1: Assess Breach (Immediately)
- Contain the breach
- Document facts: what happened, when, how many affected

**Three Evidence Collection Techniques**:
- Most reliable evidence
- Use open-ended questions

## Quick Decision Tree
- Access request → Provide data copy (30 days GDPR, 45 days CCPA)
- Consider using a DPIA tool for large assessments
""";

test "procedural step lines are recognised under Process:/Step N: headers" {
    assert _is_procedural_step_line(PROC_SKILL, "2. Search all systems for personal data");
    assert _is_procedural_step_line(PROC_SKILL, "Search all systems for personal data");
    assert _is_procedural_step_line(PROC_SKILL, "- Contain the breach");
    assert _is_procedural_step_line(PROC_SKILL, "Contain the breach");
}

test "labels, tips, decision-tree bullets and hedged lines are NOT procedural steps" {
    assert not _is_procedural_step_line(PROC_SKILL, "Most reliable evidence");
    assert not _is_procedural_step_line(PROC_SKILL, "Access request → Provide data copy (30 days GDPR, 45 days CCPA)");
    assert not _is_procedural_step_line(PROC_SKILL, "Consider using a DPIA tool for large assessments");
    assert not _is_procedural_step_line(PROC_SKILL, "Three Evidence Collection Techniques:");
}

test "promote_procedural_aliases lifts a step hiding as an alias into its own MANDATORY STEP rule" {
    rs = RuleSet(rules=[
        Rule(id="r1", quote="Access request → Provide data copy (30 days GDPR, 45 days CCPA)",
             aliases=["2. Search all systems for personal data", "3. Compile data in readable format"])
    ]);
    promoted = promote_procedural_aliases(PROC_SKILL, rs);
    assert len(promoted) == 2;
    assert len(list(rs.rules)) == 3;
    assert rs.rules[0].aliases == [];
    for r in rs.rules[1:] {
        assert r.kind == RuleKind.STEP;
        assert r.modality == Modality.MANDATORY;
    }
}

test "resolve_ambiguous_default keeps a procedural step MANDATORY but still demotes a hedged line" {
    set_skill_for_resolve(PROC_SKILL);
    rs = RuleSet(rules=[
        Rule(id="r68", quote="Search all systems for personal data", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r90", quote="Contain the breach", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r99", quote="Consider using a DPIA tool for large assessments", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    clarify = [
        ClarifyItem(rule_id="r68", quote="Search all systems for personal data", reason="ambiguous modality"),
        ClarifyItem(rule_id="r90", quote="Contain the breach", reason="ambiguous modality"),
        ClarifyItem(rule_id="r99", quote="Consider using a DPIA tool for large assessments", reason="ambiguous modality")
    ];
    resolve_ambiguous_default(rs, clarify);
    assert rs.rules[0].modality == Modality.MANDATORY;
    assert rs.rules[1].modality == Modality.MANDATORY;
    assert rs.rules[2].modality == Modality.DISCRETIONARY;
}
