"""Phase-0 skeleton — the completeness-by-construction claim, made falsifiable.

The whole point of the skeleton is that it does not need a model to be COMPLETE.
So the central test is: build a rule set covering every RuleKind, emit the
skeleton mechanically, and run the real faithfulness closure over it. If any
rule comes back DROPPED, the claim is false.
"""

import from .lift_types { Modality, RuleKind, Cohesion }
import from .spec_loop { Rule, RuleSet }
import from .faith { faithfulness_report, parse_ir }


glob SPEC: RuleSet = RuleSet(skill_name="demo-skill", rules=[
    Rule(id="r1", quote="Read the source file the user names.",
         statement="read the named source file",
         kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r2", quote="Run `scripts/completeness_checker.py` to ensure all sections are present.",
         statement="run the completeness checker",
         kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r3", quote="Use `references/common_controls.md` to populate standard controls.",
         statement="use the common controls reference",
         kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r4", quote="Write the finished report to the output path.",
         statement="write the report deliverable",
         kind=RuleKind.IO, modality=Modality.MANDATORY),
    Rule(id="r5", quote="Never invent control names that the evidence does not support.",
         statement="never invent unsupported control names",
         kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN),
    Rule(id="r6", quote="Confirm with the user before overwriting an existing report.",
         statement="confirm before overwrite",
         kind=RuleKind.HIL, modality=Modality.MANDATORY),
    Rule(id="r7", quote="The standard section order is: scope, controls, commitments.",
         statement="standard section order",
         kind=RuleKind.KNOWLEDGE, modality=Modality.MANDATORY),
    Rule(id="r8", quote="Fetch the current control catalogue from the live API before drafting.",
         statement="fetch the live control catalogue",
         kind=RuleKind.GROUNDING, modality=Modality.MANDATORY),
    Rule(id="r9", quote="You may add an appendix if the user asks.",
         statement="optional appendix",
         kind=RuleKind.STEP, modality=Modality.DISCRETIONARY),
    Rule(id="r10", quote="The harness never guesses a missing path.",
         statement="harness does not guess",
         kind=RuleKind.STEP, modality=Modality.MANDATORY, binds="environment")
]);


test "the mechanical skeleton is COMPLETE — the faithfulness closure drops nothing" {
    ir = skeleton_ir(SPEC, "demo_skill");
    fr = faithfulness_report(SPEC, ir);
    assert fr.parsed, "skeleton did not parse as an AG-IR";
    assert len(fr.dropped) == 0,
        "skeleton left rules unrealized: " + str([f.message[:90] for f in fr.dropped]);
}


test "the skeleton adds no behavior — every node traces to a rule" {
    ir = skeleton_ir(SPEC, "demo_skill");
    fr = faithfulness_report(SPEC, ir);
    assert len(fr.added) == 0,
        "skeleton invented untraced behavior: " + str([f.message[:90] for f in fr.added]);
}


test "coverage counts only what the gate actually requires" {
    cov = coverage(SPEC);
    # r9 is DISCRETIONARY and r10 binds the environment -> both OPTIONAL, not stubbed.
    assert cov["n_rules"] == 10, str(cov);
    assert cov["n_required"] == 8, str(cov);
    assert "r9" not in cov["required_ids"], str(cov["required_ids"]);
    assert "r10" not in cov["required_ids"], str(cov["required_ids"]);
}


test "a rule naming a script is bound to THAT script, not to a generic tool" {
    ir = skeleton_ir(SPEC, "demo_skill");
    # the embodiment fault in one assertion: the checker must appear in the program
    assert "scripts/completeness_checker.py" in ir,
        "skeleton did not bind the script the rule names";
    assert "references/common_controls.md" in ir,
        "skeleton did not bind the reference file the rule names";
    pir = parse_ir(ir);
    bound: bool = False;
    for t in pir.tools {
        if "completeness_checker.py" in (t.command + t.body) { bound = True; }
    }
    assert bound, "the checker is named but not EXECUTED by any tool";
}


test "no trace inflation — one claimer never absorbs the whole rule set" {
    ir = skeleton_ir(SPEC, "demo_skill");
    pir = parse_ir(ir);
    worst: int = 0;
    for n in pir.nodes { worst = max(worst, len(n.traces_to)); }
    for t in pir.tools { worst = max(worst, len(t.traces_to)); }
    # a stub realizes its own rule (+ folded prohibitions); it never claims dozens
    assert worst <= 3, "a single element claims " + str(worst) + " rules — that is inflation";
}


test "emission is deterministic — same spec in, identical skeleton out" {
    a = skeleton_ir(SPEC, "demo_skill");
    b = skeleton_ir(SPEC, "demo_skill");
    assert a == b, "skeleton emission is not reproducible";
}


test "an INVOKE_UNIT rule is not shredded into fixed steps" {
    spec2 = RuleSet(skill_name="explore", rules=[
        Rule(id="r1", quote="Use the tools to explore the codebase until you understand it.",
             statement="explore adaptively", kind=RuleKind.STEP,
             modality=Modality.MANDATORY, cohesion=Cohesion.INVOKE_UNIT)
    ]);
    ir = skeleton_ir(spec2, "explore");
    assert "adaptive unit" in ir, "INVOKE_UNIT cohesion was dropped from the skeleton";
    fr = faithfulness_report(spec2, ir);
    assert len(fr.dropped) == 0, str([f.message[:80] for f in fr.dropped]);
}
