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

test "the loop drops hallucinations, closes coverage, and converges" {
    r1 = Rule(id="r1", quote="Always write the output as CSV with a header row.",
              kind=RuleKind.IO, modality=Modality.MANDATORY);
    fake = Rule(id="r2", quote="Compress the output with gzip.",
                kind=RuleKind.STEP, modality=Modality.MANDATORY);
    r3 = Rule(id="r3", quote="Parse the input file with the standard library.",
              kind=RuleKind.STEP, modality=Modality.MANDATORY);
    r4 = Rule(id="r4", quote="Never use Unicode subscripts in output.",
              kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN);
    r5 = Rule(id="r5", quote="If the file is a form, read FORMS.md and follow its instructions.",
              kind=RuleKind.KNOWLEDGE, modality=Modality.DISCRETIONARY,
              condition="If the file is a form");

    pin_lift_llm(MockLLM(model_name="mockllm", config={"outputs": [
        # round 1: extract (one grounded + one hallucinated), then the 3 lenses
        RuleSet(skill_name="csv", rules=[r1, fake]),
        ["Parse the input file with the standard library."],
        ["Never use Unicode subscripts in output."],
        ["If the file is a form, read FORMS.md and follow its instructions."],
        # round 2: extract converges; lenses find nothing
        RuleSet(skill_name="csv", rules=[r1, r3, r4, r5]),
        [], [], []
    ]}));

    res = extract_spec(SKILL, "csv-extractor");
    spec = res.spec;
    v = res.verdict;

    assert v.sound;                    # round 2 introduced no ungrounded rules
    assert v.complete;                 # all three lens candidates covered
    assert not v.drift;
    assert v.rounds == 2;
    ids = [r.id for r in spec.rules];
    assert "r2" not in ids;            # the hallucination never survives
    assert len(spec.rules) == 4;
    sn = _norm(SKILL);
    for r in spec.rules { assert _in_skill(sn, r.quote); }   # frozen spec is fully grounded
}
