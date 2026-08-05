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

# NOTE: the MockLLM convergence run lives in scenarios/spec_loop.jac (run via
# `jac run` in CI) — same runtime bug as above.
