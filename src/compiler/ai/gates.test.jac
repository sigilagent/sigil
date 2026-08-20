"""Tests — the G4 compile oracle. The happy path is a LIVE round-trip: a minimal
AG-IR through mechanical.transpile_ir + a real `jac check` subprocess. The
failure paths must return routed verdicts, never raise."""

import from .spec_loop { Rule }
import from .workflow { AgirNode }
import from .flows { ToolDef, KnowledgeItem, KnowledgeView, HILView, HILPoint }
import from .spec_loop { RuleSet }
import from .lift_types { Modality, RuleKind }
import from .skeleton { skeleton_ir }

glob GOOD_IR: str = """---
name: note-writer
description: Write a short note to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: NoteAgent
  carries:
    task:
      type: str
      role: input
    note:
      type: str
      produced_by: draft
    report:
      type: str
      produced_by: done
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [note]
    doc: "Write the note the task asks for."
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: done, modality: mandatory}
""";

test "a valid AG-IR round-trips through transpile + jac check" {
    v = compile_gate(GOOD_IR, "note_writer");
    assert v.ok;
    assert "def run(" in v.module_src;
    assert v.errors == "";
}

test "garbage input yields a routed failure, not an exception" {
    v = compile_gate("::: not yaml {{{", "junk");
    assert not v.ok;
    assert v.errors != "";
}

test "transpile without check still requires a run() entrypoint" {
    v = compile_gate(GOOD_IR, "note_writer_nocheck", check=False);
    assert v.ok;
    assert "def run(" in v.module_src;
}

test "G1 standalone: embodied views pass; pointers and empty tools are flagged" {
    good = ViewBundle(kn=KnowledgeView(
        tools=[ToolDef(name="write", sig="(x) -> path", serves=["emit"], body="return 'out.txt'")],
        knowledge=[KnowledgeItem(key="rules", content="The output must include a header row naming every column of the table.")]
    ));
    assert gate_standalone(good) == [];

    bad = ViewBundle(kn=KnowledgeView(
        tools=[ToolDef(name="magic", sig="(x) -> y", serves=["emit"])],
        knowledge=[KnowledgeItem(key="forms", content="See FORMS.md for details.")]
    ));
    issues = gate_standalone(bad);
    assert len([i for i in issues if "'magic'" in i and "prose-pointer" in i]) == 1;
    assert len([i for i in issues if "'forms'" in i and "pointer" in i]) == 1;
}

test "G5 STRUCT-COV classifies gated / slotted / monolithic / missing" {
    spec = RuleSet(rules=[
        Rule(id="r1", quote="parse", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="write", kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r3", quote="verify", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    wf = WorkflowView(nodes=[
        AgirNode(id="parse", ntype=NodeType.SENSE, owner=Owner.CODE, traces_to=["r1"]),
        AgirNode(id="write", ntype=NodeType.GEN_RAW, owner=Owner.MODEL, traces_to=["r2"])
        # r3 traced by nothing -> missing
    ]);
    src_slotted = "can n_parse with X entry {}\ncan n_write with Y entry {}\ndef write(data: str) -> str by llm;";
    sc = gate_struct_cov(spec, wf, src_slotted);
    assert sc.gated == ["r1"];
    assert sc.slotted == ["r2"];
    assert sc.missing == ["r3"];
    assert len([i for i in sc.issues if "'r3'" in i]) == 1;

    src_monolith = "can n_parse with X entry {}\ncan n_write with Y entry {}";   # no dedicated slot for write
    sc2 = gate_struct_cov(spec, wf, src_monolith);
    assert sc2.monolithic == ["r2"];
    assert len([i for i in sc2.issues if "MONOLITHIC" in i]) == 1;
}

test "G5 does not score a HOLLOW code station as gated" {
    # The ability exists but its body is only the marker the mechanical half
    # emits when nothing bound a tool: the walker visits the station and does
    # nothing. Scoring that `gated` reports a hollow gate as the strongest
    # realization there is, which is how a compile goes green with its
    # verification stations empty.
    spec = RuleSet(rules=[
        Rule(id="r1", quote="compile checkpoint", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    wf = WorkflowView(nodes=[
        AgirNode(id="compile_checkpoint", ntype=NodeType.CODE, owner=Owner.CODE, traces_to=["r1"])
    ]);
    hollow = "can n_compile_checkpoint with Z entry {\n    # CODE compile_checkpoint\n    visit [-->];\n}";
    sc = gate_struct_cov(spec, wf, hollow);
    assert sc.gated == [];
    assert sc.missing == ["r1"];
    assert len([i for i in sc.issues if "HOLLOW" in i and "compile_checkpoint" in i]) == 1;

    # the same node WITH a lowered body still earns `gated`
    real = "can n_compile_checkpoint with Z entry {\n    self.compile_log = _jac_check(self.decl_surface);\n    visit [-->];\n}";
    sc2 = gate_struct_cov(spec, wf, real);
    assert sc2.gated == ["r1"];
    assert sc2.issues == [];
}

test "G3-hard: IO mandates must chain to an embodied artifact write" {
    spec = RuleSet(rules=[
        Rule(id="r1", quote="write the plan", kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r2", quote="write the log", kind=RuleKind.IO, modality=Modality.MANDATORY),
        Rule(id="r3", quote="may export csv", kind=RuleKind.IO, modality=Modality.DISCRETIONARY)
    ]);
    author = AgirNode(id="author", ntype=NodeType.GEN_RAW, owner=Owner.MODEL,
                      writes=["plan"], traces_to=["r1"]);
    emit = AgirNode(id="emit", ntype=NodeType.ACT, owner=Owner.CODE,
                    reads=["plan"], writes=["artifact"], traces_to=["r1"]);
    orphan = AgirNode(id="log_note", ntype=NodeType.GEN_RAW, owner=Owner.MODEL,
                      writes=["log_text"], traces_to=["r2"]);
    wf = WorkflowView(nodes=[author, emit, orphan]);
    vb = ViewBundle(kn=KnowledgeView(tools=[
        ToolDef(name="write_plan", sig="(plan) -> path", serves=["emit"], body="return 'plan.md'")
    ]));

    issues = gate_artifact_boundary(spec, wf, vb);
    # r1: satisfied via the served ACT; r3: discretionary, exempt; r2: authored
    # into a carry nothing writes -> flagged.
    assert len(issues) == 1, issues;
    assert "'r2'" in issues[0];
}

test "G3-hard: the _write_artifact fallback (ACT with a content read) counts as embodied" {
    spec = RuleSet(rules=[Rule(id="r1", quote="write it", kind=RuleKind.IO, modality=Modality.MANDATORY)]);
    author = AgirNode(id="author", ntype=NodeType.GEN_RAW, owner=Owner.MODEL,
                      writes=["doc"], traces_to=["r1"]);
    emit = AgirNode(id="emit", ntype=NodeType.ACT, owner=Owner.CODE, reads=["doc"]);
    wf = WorkflowView(nodes=[author, emit]);
    assert gate_artifact_boundary(spec, wf, ViewBundle()) == [];
}

test "G6: a model-owned route consuming human feedback is flagged; code-owned passes" {
    wait_n = AgirNode(id="wait_review", ntype=NodeType.SENSE, owner=Owner.CODE,
                      writes=["feedback"], traces_to=["r1"]);
    bad_route = AgirNode(id="approved_route", ntype=NodeType.ROUTE, owner=Owner.MODEL,
                         reads=["feedback"], traces_to=["r1"]);
    wf = WorkflowView(nodes=[wait_n, bad_route]);
    vb = ViewBundle(hil=HILView(points=[HILPoint(node="wait_review", kind="APPROVE", prompt="review the spec")]));
    issues = gate_hil_gates(wf, vb);
    assert len(issues) == 1, issues;
    assert "'approved_route'" in issues[0] and "model-owned" in issues[0];

    bad_route.owner = Owner.CODE;
    assert gate_hil_gates(wf, vb) == [];
}

test "_diagnostic keeps the ERROR blocks, not just the tail of the output" {
    # A long module can push every error far above the end of `jac check` output,
    # so tailing it hands the repair loop a diagnostic with no error in it — the
    # repair then "fixes" a warning and the gate fails again identically.
    out = ("✖ Error: error[E1001]: Cannot assign <Unknown> to list[str]\n"
           "  --> m.jac:908:9\n"
           + ("⚠ warning[W3030]: noise\n  --> m.jac:1:1\n" * 60));
    d = _diagnostic(out);
    assert "error[E1001]" in d;
    assert "Cannot assign" in d;
}

test "_diagnostic falls back to the tail when there is no error block" {
    out = "some\noutput\nFAILED with no diagnostic codes at all\n";
    assert "FAILED" in _diagnostic(out);
}

test "_diagnostic stays within its budget and says what it dropped" {
    one = "✖ Error: error[E1001]: " + ("x" * 300) + "\n";
    d = _diagnostic(one * 20, budget=900);
    assert len(d) < 1400;
    assert "more error(s)" in d;
}

# ---------------------------------------------------------------------------
# G9-TY — the fault this gate exists for was caught LIVE: a fresh compile
# shipped a model slot typed `-> str` into a tool body demanding `list`,
# green through every gate, TypeError at runtime.
# ---------------------------------------------------------------------------

glob TY_CONFLICT_IR: str = """---
name: ty-conflict
description: model slot typed str feeding a tool that demands list[str].
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: TyAgent
  carries:
    task:
      type: str
      role: input
    proposed:
      type: str
      produced_by: decide
    out_path:
      type: str
      produced_by: emit
nodes:
  - id: decide
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [proposed]
    doc: "Propose one clean name per input item."
  - id: emit
    type: ACT
    owner: code
    reads: [proposed]
    writes: [out_path]
    doc: "Write the proposed names to out.txt."
  - id: done
    type: TERMINAL
edges:
  - {from: decide, to: emit, modality: mandatory}
  - {from: emit, to: done, modality: mandatory}
tools:
  write_out:
    sig: "(proposed) -> path"
    serves: [emit]
    body: |
      def write_out(proposed):
          if not isinstance(proposed, list) or not all(isinstance(h, str) for h in proposed):
              raise TypeError('proposed must be a list of strings')
          with open('out.txt', 'w') as f:
              f.write(','.join(proposed))
          return 'out.txt'
""";

test "G9: a str carry feeding a tool that guard-raises on non-list is a conflict" {
    issues = gate_type_unification(TY_CONFLICT_IR);
    assert len([i for i in issues if "'proposed'" in i and "list[str]" in i]) == 1, issues;
}

test "G9 autofix adopts the consumer's demand and the patched IR passes clean" {
    fx = autofix_carry_types(TY_CONFLICT_IR);
    assert len(list(fx["fixes"])) == 1, fx["fixes"];
    assert "list[str]" in str(fx["fixes"][0]);
    fixed = str(fx["ir_text"]);
    assert gate_type_unification(fixed) == [];
    # the oracle stays the authority: the patched IR must still lower + check,
    # and the slot's return schema now derives from the unified carry type.
    v = compile_gate(fixed, "ty_conflict_fixed");
    assert v.ok, v.errors;
    assert "-> list[str] by llm" in v.module_src;
}

test "G9: an annotated tool param is a demand too" {
    ir = TY_CONFLICT_IR.replace(
        "      def write_out(proposed):\n          if not isinstance(proposed, list) or not all(isinstance(h, str) for h in proposed):\n              raise TypeError('proposed must be a list of strings')\n",
        "      def write_out(proposed: list):\n");
    issues = gate_type_unification(ir);
    assert len([i for i in issues if "'proposed'" in i]) == 1, issues;
}

test "G9: a coercion branch is NOT read as a demand" {
    # `if isinstance(x, str): ...` ACCEPTS str — only a guard that raises (or
    # an assert) states a contract.
    ir = TY_CONFLICT_IR.replace(
        "          if not isinstance(proposed, list) or not all(isinstance(h, str) for h in proposed):\n              raise TypeError('proposed must be a list of strings')\n",
        "          if isinstance(proposed, str):\n              proposed = [proposed]\n");
    assert gate_type_unification(ir) == [];
    assert autofix_carry_types(ir)["fixes"] == [];
}

glob TY_UNTYPED_IR: str = """---
name: ty-untyped
description: a model-written carry crosses into embodied code untyped.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: UntypedAgent
  carries:
    task:
      type: str
      role: input
    plan:
      type: any
      produced_by: draft
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [plan]
    doc: "Draft the plan."
  - id: apply
    type: CODE
    owner: code
    reads: [plan]
    doc: "Apply the plan."
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: apply, modality: mandatory}
  - {from: apply, to: done, modality: mandatory}
tools:
  apply_plan:
    sig: "(plan) -> str"
    serves: [apply]
    body: |
      def apply_plan(plan):
          return str(plan)
""";

test "G9: an untyped model->code carry with no stated demand is flagged" {
    issues = gate_type_unification(TY_UNTYPED_IR);
    assert len([i for i in issues if "'plan'" in i and "untyped" in i]) == 1, issues;
    # nothing states the true type, so there is no mechanical fix — only a report
    assert autofix_carry_types(TY_UNTYPED_IR)["fixes"] == [];
}

glob TY_PROVENANCE_IR: str = """---
name: ty-provenance
description: an embodied ACT writing from a carry nothing produces.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: ProvAgent
  carries:
    task:
      type: str
      role: input
    content:
      type: str
nodes:
  - id: emit
    type: ACT
    owner: code
    reads: [content]
    writes: [out_path]
    doc: "Write content to disk."
  - id: done
    type: TERMINAL
edges:
  - {from: emit, to: done, modality: mandatory}
tools:
  write_it:
    sig: "(content) -> path"
    serves: [emit]
    body: |
      def write_it(content):
          with open('out.txt', 'w') as f:
              f.write(str(content))
          return 'out.txt'
""";

test "G9: an embodied ACT reading a producer-less carry is a disconnected artifact" {
    # Caught live: a relearned agent ran green to TERMINAL while its write node
    # consumed a carry nothing produced — the 'artifact' was the carry's seed
    # (the task string) echoed into the input file.
    issues = gate_type_unification(TY_PROVENANCE_IR);
    assert len([i for i in issues if "'emit'" in i and "'content'" in i and "no node produces" in i.lower()]) == 1, issues;

    # the same carry declared role: input is a legitimate boundary — clean.
    ir2 = TY_PROVENANCE_IR.replace("    content:\n      type: str\n", "    content:\n      type: str\n      role: input\n");
    assert gate_type_unification(ir2) == [];
}

test "G9 + autofix never raise on garbage input" {
    assert gate_type_unification("::: not yaml {{{") == [];
    fx = autofix_carry_types("::: not yaml {{{");
    assert fx["fixes"] == [];
}


# ===========================================================================
# G10 (trace fan-out) + G11 (artifact embodiment) — the two holes that let a
# hollow agent certify as faithful. Both fixtures are shrunk-down reproductions
# of real v0.5.1 output: soc2's `append_file` claiming dozens of procedural
# mandates, and a graph that never touches the scripts its own rules name.
# ===========================================================================
glob SPEC_SCRIPTS: RuleSet = RuleSet(skill_name="grc", rules=[
    Rule(id="r1", quote="Run `scripts/completeness_checker.py` to ensure all sections are present.",
         statement="run the completeness checker", kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r2", quote="Run `scripts/control_coverage_validator.py` to validate TSC coverage.",
         statement="run the coverage validator", kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r3", quote="Draft each required section of the description.",
         statement="draft the sections", kind=RuleKind.STEP, modality=Modality.MANDATORY)
]);

# The observed pathology: generate prose, append it, claim everything.
glob HOLLOW_IR: str = """---
name: grc
description: draft a description
---
agir_version: 0.1
nodes:
  - id: draft_all
    type: GEN-RAW
    owner: model
    doc: Draft every section of the description.
    writes: [body]
    traces_to: [r1, r2, r3]
  - id: done
    type: TERMINAL
    owner: code
    doc: Report.
    traces_to: []
tools:
  append_file:
    surface: ACT·artifact
    sig: "(content, path) -> str"
    body: |
      with open(path, 'a') as f:
          f.write(content)
      return path
    traces_to: [r1, r2, r3]
edges:
  - {from: draft_all, to: done}
""";


test "G11 catches a graph that never touches the scripts its rules name" {
    issues = gate_artifact_embodiment(SPEC_SCRIPTS, HOLLOW_IR);
    assert len(issues) >= 2, "G11 missed the unbound scripts: " + str(issues);
    joined = " ".join(issues);
    assert "completeness_checker.py" in joined, joined;
    assert "control_coverage_validator.py" in joined, joined;
    for m in issues { assert m.startswith("G11: "), m; }
}


test "G11 passes a skeleton — it binds every artifact its rules name" {
    ir = skeleton_ir(SPEC_SCRIPTS, "grc");
    issues = gate_artifact_embodiment(SPEC_SCRIPTS, ir);
    assert len(issues) == 0, "skeleton failed artifact embodiment: " + str(issues);
}


test "G10 catches one element standing in for many procedures" {
    os.environ["SIGIL_INFL_CAP"] = "2";
    try {
        issues = gate_trace_inflation(SPEC_SCRIPTS, HOLLOW_IR);
        assert len(issues) >= 1, "G10 missed the fan-out: " + str(issues);
        for m in issues { assert m.startswith("G10: "), m; }
    } finally {
        os.environ["SIGIL_INFL_CAP"] = "12";
    }
}


test "G10 passes a skeleton — one stub per procedure, no fan-out" {
    os.environ["SIGIL_INFL_CAP"] = "2";
    try {
        ir = skeleton_ir(SPEC_SCRIPTS, "grc");
        issues = gate_trace_inflation(SPEC_SCRIPTS, ir);
        assert len(issues) == 0, "skeleton tripped the fan-out gate: " + str(issues);
    } finally {
        os.environ["SIGIL_INFL_CAP"] = "12";
    }
}


test "G10 does not punish folded prohibitions" {
    spec = RuleSet(skill_name="p", rules=[
        Rule(id="r1", quote="Draft the summary.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Never invent numbers.", kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN),
        Rule(id="r3", quote="Never speculate.", kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN),
        Rule(id="r4", quote="Never omit caveats.", kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN)
    ]);
    ir = """---
name: p
description: d
---
agir_version: 0.1
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    doc: Draft the summary. Never invent numbers. Never speculate. Never omit caveats.
    traces_to: [r1, r2, r3, r4]
  - id: done
    type: TERMINAL
    owner: code
    doc: Report.
    traces_to: []
edges:
  - {from: draft, to: done}
""";
    os.environ["SIGIL_INFL_CAP"] = "1";
    try {
        issues = gate_trace_inflation(spec, ir);
        assert len(issues) == 0, "G10 counted prohibitions as procedures: " + str(issues);
    } finally {
        os.environ["SIGIL_INFL_CAP"] = "12";
    }
}
