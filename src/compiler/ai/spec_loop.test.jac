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

# NOTE: the MockLLM convergence run lives in scenarios/spec_loop.jac (run via
# `jac run` in CI) — same runtime bug as above.
