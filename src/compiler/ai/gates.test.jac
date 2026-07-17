"""Tests — the G4 compile oracle. The happy path is a LIVE round-trip: a minimal
AG-IR through mechanical.transpile_ir + a real `jac check` subprocess. The
failure paths must return routed verdicts, never raise."""

import from .spec_loop { Rule }
import from .workflow { AgirNode }
import from .flows { ToolDef, KnowledgeItem, KnowledgeView }

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
