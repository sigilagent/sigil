"""Tests — the faithfulness core (Layer 0 + Layer 2).

Pure code, no model: the whole point of the core is a deterministic verdict. These
lock in the two properties the rearchitecture turns on:

  1. required_shape maps EVERY (kind, modality) to a realization shape — so
     completeness is defined for prohibitions/gates/knowledge/grounding, not just
     the MANDATORY STEP/IO that today's G5 audits.
  2. the closure FAILS on a dropped rule of ANY kind (a FORBIDDEN prohibition, a
     HIL gate) and on an ADDED (untraced) node — the exact holes the direct path
     ships green today.
"""

# --- Layer 0: the required-realization table ------------------------------

test "required_shape covers every rule kind, and modality dominates kind" {
    # FORBIDDEN is always a prohibition, whatever kind it was tagged
    assert required_shape(RuleKind.CONSTRAINT, Modality.FORBIDDEN) == RealShape.CONSTRAINT;
    assert required_shape(RuleKind.STEP, Modality.FORBIDDEN) == RealShape.CONSTRAINT;
    # DISCRETIONARY is never required
    assert required_shape(RuleKind.STEP, Modality.DISCRETIONARY) == RealShape.OPTIONAL;
    assert required_shape(RuleKind.IO, Modality.DISCRETIONARY) == RealShape.OPTIONAL;
    # MANDATORY: the kind picks the shape
    assert required_shape(RuleKind.STEP, Modality.MANDATORY) == RealShape.NODE;
    assert required_shape(RuleKind.IO, Modality.MANDATORY) == RealShape.EMBODIED_WRITE;
    assert required_shape(RuleKind.HIL, Modality.MANDATORY) == RealShape.CODE_GATE;
    assert required_shape(RuleKind.KNOWLEDGE, Modality.MANDATORY) == RealShape.EMBODIED_KNOWLEDGE;
    assert required_shape(RuleKind.GROUNDING, Modality.MANDATORY) == RealShape.LIVE_TOOL;
}

# --- Layer 2: completeness (nothing dropped) ------------------------------

test "a dropped FORBIDDEN prohibition is caught (today's G5 ignores it)" {
    # the PDF skill's real rule: 'Never use Unicode subscript characters'
    spec = RuleSet(rules=[
        Rule(id="r_forbid", quote="Never use Unicode subscript/superscript characters",
             kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN),
        Rule(id="r_step", quote="Merge the PDFs", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    # IR realizes the step but NEVER traces the prohibition — exactly what a direct
    # author does when it is only told to trace MANDATORY STEP/IO.
    pir = ParsedIR(nodes=[
        PNode(id="merge", ntype="CODE", owner="code", traces_to=["r_step"]),
        PNode(id="done", ntype="TERMINAL")
    ]);
    d = check_completeness(spec, pir);
    assert len(d) == 1;
    assert d[0].rule == "r_forbid";
    assert d[0].shape == "CONSTRAINT";
    assert "DROPPED" in d[0].message;
}

test "the same prohibition, once traced onto its slot, is realized" {
    spec = RuleSet(rules=[
        Rule(id="r_forbid", quote="Never use Unicode subscript/superscript characters",
             kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN),
        Rule(id="r_step", quote="Create the PDF", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    pir = ParsedIR(nodes=[
        PNode(id="create", ntype="GEN_RAW", owner="model",
              doc="Author the PDF. NEVER use Unicode subscripts.", traces_to=["r_step", "r_forbid"]),
        PNode(id="done", ntype="TERMINAL")
    ]);
    assert check_completeness(spec, pir) == [];
}

test "a dropped HIL gate is caught; a code-owned route realizes it" {
    spec = RuleSet(rules=[
        Rule(id="r_gate", quote="confirm before deleting", kind=RuleKind.HIL, modality=Modality.MANDATORY)
    ]);
    # a model slot that 'asks' is NOT a gate (the G6 failure) -> dropped
    bad = ParsedIR(nodes=[PNode(id="ask", ntype="GEN_RAW", owner="model", traces_to=["r_gate"])]);
    db = check_completeness(spec, bad);
    assert len(db) == 1;
    assert db[0].shape == "CODE_GATE";
    # an owner=code ROUTE traced to the rule IS a gate
    ok = ParsedIR(nodes=[PNode(id="gate", ntype="ROUTE", owner="code", traces_to=["r_gate"])]);
    assert check_completeness(spec, ok) == [];
}

test "a MANDATORY IO rule needs an embodied write, not just a node" {
    spec = RuleSet(rules=[
        Rule(id="r_io", quote="save the result to the output file",
             kind=RuleKind.IO, modality=Modality.MANDATORY)
    ]);
    # traced only to a model node that authors content but nothing writes it
    authored = ParsedIR(nodes=[
        PNode(id="draft", ntype="GEN_RAW", owner="model", writes=["out"], traces_to=["r_io"]),
        PNode(id="done", ntype="TERMINAL")
    ]);
    assert len(check_completeness(spec, authored)) == 1;
    # add an embodied ACT that consumes the carry -> realized
    written = ParsedIR(nodes=[
        PNode(id="draft", ntype="GEN_RAW", owner="model", writes=["out"], traces_to=["r_io"]),
        PNode(id="save", ntype="ACT", owner="code", tool="write_file", reads=["out"], writes=["path"]),
        PNode(id="done", ntype="TERMINAL")
    ], tools=[PTool(name="write_file", surface="ACT", serves=["save"],
                    body="def write_file(content, path):\n    open(path,'w').write(content)\n    return path")]);
    assert check_completeness(spec, written) == [];
}

test "DISCRETIONARY guidance is never required" {
    spec = RuleSet(rules=[
        Rule(id="r_may", quote="you may compress the output", kind=RuleKind.STEP,
             modality=Modality.DISCRETIONARY)
    ]);
    empty = ParsedIR(nodes=[PNode(id="done", ntype="TERMINAL")]);
    assert check_completeness(spec, empty) == [];
}

# --- Layer 2: soundness (nothing added) -----------------------------------

test "an untraced non-terminal node is an ADDED behavior; TERMINAL is exempt" {
    spec = RuleSet(rules=[Rule(id="r1", quote="x", kind=RuleKind.STEP, modality=Modality.MANDATORY)]);
    pir = ParsedIR(nodes=[
        PNode(id="a", ntype="CODE", owner="code", traces_to=["r1"]),
        PNode(id="b", ntype="GEN_RAW", owner="model", traces_to=[]),   # ADDED
        PNode(id="done", ntype="TERMINAL", traces_to=[])               # exempt
    ]);
    s = check_soundness(spec, pir);
    assert len(s) == 1;
    assert "node 'b'" in s[0].message;
    assert s[0].axis == "faithfulness";
}

test "dangling provenance (traces to a non-existent rule) is caught" {
    spec = RuleSet(rules=[Rule(id="r1", quote="x", kind=RuleKind.STEP, modality=Modality.MANDATORY)]);
    pir = ParsedIR(nodes=[PNode(id="a", ntype="CODE", owner="code", traces_to=["r_nope"])]);
    s = check_soundness(spec, pir);
    assert any([("unknown rule 'r_nope'" in f.message) for f in s]);
}

# --- parse + the proof object ---------------------------------------------

glob IR_YAML: str = """---
name: t
---
agir_version: 0.1
nodes:
  - id: build
    type: CODE
    owner: code
    reads: []
    writes: [out]
    traces_to: [r_step]
  - id: write_out
    type: ACT
    owner: code
    tool: write_file
    reads: [out]
    writes: [path]
    traces_to: [r_io]
  - id: done
    type: TERMINAL
tools:
  write_file:
    surface: ACT
    serves: [write_out]
    body: |
      def write_file(content, path):
          open(path, 'w').write(content)
          return path
walker:
  name: T
  carries:
    out: {type: str, produced_by: build}
""";

test "parse_ir reconstructs nodes, tools, carries, and the ACT is embodied" {
    pir = parse_ir(IR_YAML);
    assert pir.ok;
    assert len(pir.nodes) == 3;
    assert len(pir.tools) == 1;
    assert "out" in pir.carries;
    wo = [n for n in pir.nodes if n.id == "write_out"][0];
    assert _is_embodied_act(pir, wo);
}

test "faithfulness_report is UNFAITHFUL when a required rule is dropped, with an inspectable proof" {
    spec = RuleSet(rules=[
        Rule(id="r_step", quote="build it", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r_io", quote="write it", kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r_forbid", quote="never overwrite the input", kind=RuleKind.CONSTRAINT,
             modality=Modality.FORBIDDEN)   # NOT traced anywhere in IR_YAML
    ]);
    fr = faithfulness_report(spec, IR_YAML);
    assert not fr.ok;
    assert fr.rules_total == 3;
    assert fr.realized == 2;
    assert len(fr.dropped) == 1;
    assert fr.dropped[0].rule == "r_forbid";
    lines = proof_lines(fr);
    assert "UNFAITHFUL" in lines[0];
    assert any([("r_forbid" in l) for l in lines]);
}

test "faithfulness_report is FAITHFUL when every required rule is realized" {
    spec = RuleSet(rules=[
        Rule(id="r_step", quote="build it", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r_io", quote="write it", kind=RuleKind.IO, modality=Modality.MANDATORY)
    ]);
    fr = faithfulness_report(spec, IR_YAML);
    assert fr.ok;
    assert fr.realized == 2;
    assert "FAITHFUL" in proof_lines(fr)[0];
}
