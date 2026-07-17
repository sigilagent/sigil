"""Scenario — the Spec convergence loop, MockLLM-scripted. See workflow_loop.jac
for why this runs under `jac run` instead of `jac test`. Exits nonzero on failure."""

import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.lift_types { Modality, RuleKind, Cohesion }
import from src.compiler.ai.spec_loop {
    Rule, RuleSet, extract_spec, pin_lift_llm, ground_rules, _norm, _in_skill
}

glob SKILL: str = """# CSV Extractor
Always write the output as CSV with a header row.
Parse the input file with the standard library.
Never use Unicode subscripts in output.
If the file is a form, read FORMS.md and follow its instructions.
""";

with entry:__main__ {
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
    print("SCENARIO spec_loop OK");
}
