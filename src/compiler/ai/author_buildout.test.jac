"""Build-out authoring — the monotonicity invariant.

Phase 0 hands the model a document that already realizes everything. The only
way build-out can make things worse is by a round REMOVING a realization, so
that is what these tests attack: a round that drops coverage must be discarded
and the prior document kept, no matter how plausible the answer looks.
"""

import from jaclang.byllm.lib { MockLLM }

import from .lift_types { Modality, RuleKind }
import from .spec_loop { Rule, RuleSet }


glob SPEC: RuleSet = RuleSet(skill_name="two-step", rules=[
    Rule(id="r1", quote="Read the input file the user names.",
         statement="read the input", kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r2", quote="Write the summary to the output path.",
         statement="write the summary", kind=RuleKind.IO, modality=Modality.MANDATORY)
]);

# A filled document that realizes BOTH rules — the well-behaved round.
glob GOOD_FILL: str = """---
name: two_step
description: read a file and write a summary
---
agir_version: 0.1
walker:
  name: two_step_agent
  carries:
    task: {type: str, role: input, doc: user task}
    text: {type: str, produced_by: read_input, doc: file text}
    out:  {type: str, produced_by: write_summary, doc: written path}
nodes:
  - id: read_input
    type: SENSE
    owner: code
    tool: read_file
    doc: Read the input file the user names.
    writes: [text]
    traces_to: [r1]
  - id: write_summary
    type: ACT
    surface: artifact
    owner: code
    tool: write_out
    doc: Write the summary to the output path.
    reads: [text]
    writes: [out]
    traces_to: [r2]
  - id: done
    type: TERMINAL
    owner: code
    doc: Report the written path.
    traces_to: []
tools:
  read_file:
    surface: SENSE
    sig: "(path) -> str"
    body: |
      with open(path) as f:
          return f.read()
    traces_to: [r1]
  write_out:
    surface: ACT·artifact
    sig: "(content, path) -> str"
    body: |
      with open(path, 'w') as f:
          f.write(content)
      return path
    traces_to: [r2]
edges:
  - {from: read_input, to: write_summary}
  - {from: write_summary, to: done}
""";

# The dangerous round: tidy, plausible, and it silently loses the deliverable.
glob LOSSY_FILL: str = """---
name: two_step
description: read a file and write a summary
---
agir_version: 0.1
nodes:
  - id: read_input
    type: SENSE
    owner: code
    tool: read_file
    doc: Read the input file the user names.
    writes: [text]
    traces_to: [r1]
  - id: done
    type: TERMINAL
    owner: code
    doc: Report.
    traces_to: []
tools:
  read_file:
    surface: SENSE
    sig: "(path) -> str"
    body: |
      with open(path) as f:
          return f.read()
    traces_to: [r1]
edges:
  - {from: read_input, to: done}
""";


test "phase 0 alone already realizes every required rule" {
    r = realized_ids(SPEC, skeleton_ir(SPEC, "two_step"));
    assert sorted(r) == ["r1", "r2"], str(r);
}


test "a well-behaved fill round is adopted" {
    pin_buildout_llm(MockLLM(model_name="mockllm", config={"outputs": [GOOD_FILL]}));
    res = author_buildout("# two-step skill", SPEC, "two_step");
    assert "read_file" in res["ir_text"], "the filled document was not adopted";
    assert sorted(realized_ids(SPEC, res["ir_text"])) == ["r1", "r2"], str(res["notes"]);
}


test "a round that drops a realization is REJECTED and the prior kept" {
    pin_buildout_llm(MockLLM(model_name="mockllm", config={"outputs": [LOSSY_FILL]}));
    res = author_buildout("# two-step skill", SPEC, "two_step");
    # r2 (the deliverable) must survive even though the model deleted it
    assert sorted(realized_ids(SPEC, res["ir_text"])) == ["r1", "r2"],
        "coverage regressed: " + str(res["notes"]);
    joined = " ".join(res["notes"]);
    assert "REJECTED" in joined, joined;
    assert "r2" in joined, joined;
}


test "an unparseable round is discarded without losing the skeleton" {
    pin_buildout_llm(MockLLM(model_name="mockllm", config={"outputs": ["not: [valid: yaml"]}));
    res = author_buildout("# two-step skill", SPEC, "two_step");
    assert sorted(realized_ids(SPEC, res["ir_text"])) == ["r1", "r2"], str(res["notes"]);
}


test "monotonic() names exactly what a candidate lost" {
    lost = monotonic(SPEC, GOOD_FILL, LOSSY_FILL);
    assert lost == ["r2"], str(lost);
    assert monotonic(SPEC, LOSSY_FILL, GOOD_FILL) == [], "adding coverage is not a loss";
}


test "regions chunk the required rules into bounded rounds" {
    many = RuleSet(skill_name="big", rules=[
        Rule(id="r" + str(i), quote="Do step " + str(i) + ".", statement="step " + str(i),
             kind=RuleKind.STEP, modality=Modality.MANDATORY) for i in range(1, 26)
    ]);
    regs = regions(many, 10);
    assert len(regs) == 3, str([len(x) for x in regs]);
    assert len(regs[0]) == 10 and len(regs[2]) == 5, str([len(x) for x in regs]);
    flat: list = [];
    for g in regs { flat += g; }
    assert len(flat) == 25, str(len(flat));
}


# ===========================================================================
# LOCALIZED REPAIR — the failure mode it exists to prevent is a repair round
# that "fixes" one gap by quietly dropping coverage elsewhere, or that returns
# a document which no longer parses. Both are what whole-document re-authoring
# actually did in the field, so both are asserted here.
# ===========================================================================

# The incumbent: r1 realized, r2 has NO realization (the gap to close).
glob GAPPY_IR: str = """---
name: two_step
description: read a file and write a summary
---
agir_version: 0.1
nodes:
  - id: read_input
    type: SENSE
    owner: code
    tool: read_file
    doc: Read the input file the user names.
    writes: [text]
    traces_to: [r1]
  - id: done
    type: TERMINAL
    owner: code
    doc: Report.
    traces_to: []
tools:
  read_file:
    surface: SENSE
    sig: "(path) -> str"
    body: |
      with open(path) as f:
          return f.read()
    traces_to: [r1]
edges:
  - {from: read_input, to: done}
""";

glob GAP_MSG: list = [
    "DROPPED IO/MANDATORY rule 'r2' — no EMBODIED_WRITE realization. add an ACT "
    "(write-tool or content read) traced to 'r2' that writes the deliverable: write the summary"
];


test "localized repair adopts a round that closes the gap without losing coverage" {
    pin_buildout_llm(MockLLM(model_name="mockllm", config={"outputs": [GOOD_FILL]}));
    res = repair_localized("# two-step skill", SPEC, GAPPY_IR, GAP_MSG);
    got = sorted(realized_ids(SPEC, res["ir_text"]));
    assert got == ["r1", "r2"], "gap not closed: " + str(got) + " " + str(res["notes"]);
}


test "a repair round that drops existing coverage is REJECTED" {
    # LOSSY_FILL realizes r1 only — it would close nothing and lose nothing here,
    # so invert: start from a COMPLETE ir and hand back the lossy one.
    pin_buildout_llm(MockLLM(model_name="mockllm", config={"outputs": [LOSSY_FILL]}));
    res = repair_localized("# two-step skill", SPEC, GOOD_FILL, GAP_MSG);
    got = sorted(realized_ids(SPEC, res["ir_text"]));
    assert got == ["r1", "r2"], "coverage regressed: " + str(got);
    joined = " ".join(res["notes"]);
    assert "REJECTED" in joined, joined;
    assert "r2" in joined, joined;
}


test "an unparseable repair round cannot un-parse the document" {
    pin_buildout_llm(MockLLM(model_name="mockllm", config={"outputs": ["not: [valid: yaml"]}));
    res = repair_localized("# two-step skill", SPEC, GOOD_FILL, GAP_MSG);
    assert sorted(realized_ids(SPEC, res["ir_text"])) == ["r1", "r2"], str(res["notes"]);
    assert "did not parse" in " ".join(res["notes"]), str(res["notes"]);
}


test "repair chunks the gap list so prompt size does not track skill size" {
    many: list = [];
    for i in range(1, 21) { many.append("DROPPED STEP/MANDATORY rule 'r" + str(i) + "' — no NODE realization. add a node: step " + str(i)); }
    # every chunk answers with the incumbent unchanged -> all kept, none adopted
    pin_buildout_llm(MockLLM(model_name="mockllm", config={"outputs": [GOOD_FILL] * 10}));
    res = repair_localized("# skill", SPEC, GOOD_FILL, many, 5);
    rounds = [n for n in res["notes"] if "repair " in str(n)];
    assert len(rounds) == 4, "expected 20 gaps / 5 per round = 4 rounds, got " + str(rounds);
}
