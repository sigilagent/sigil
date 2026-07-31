# Tests for author_agent — annex of author_agent.jac
# (`jac test src/compiler/ai/author_agent.jac`). Everything here is offline: the
# agent session itself is not exercised, only the deterministic parts around it —
# the IR->views parse the gates read, and the material handed to the session.

import from .lift_types { Modality, RuleKind }
import from .ir_views { NodeType, Owner }
import from .spec_loop { Rule, RuleSet }
import from .gates { gate_standalone, gate_struct_cov }

glob IR: str = """---
name: demo
description: a demo
---
agir_version: 0.1
walker:
  name: DemoAgent
  carries:
    task: { type: str, role: input }
nodes:
  - id: read_input
    type: SENSE
    owner: code
    doc: Read the file.
    reads: [task]
    writes: [raw]
    traces_to: [r1]
  - id: decide
    type: GEN-RAW
    owner: model
    reads: [raw]
    writes: [plan]
    traces_to: [r2, r3]
  - id: done
    type: TERMINAL
tools:
  read_file:
    sig: "(p) -> str"
    surface: SENSE
    serves: [read_input]
    body: |
      def read_file(p):
          return open(p).read()
  save_it:
    sig: "(s) -> str"
    surface: ACT
    serves: [done]
knowledge:
  house_style:
    content: Always use snake_case headers.
    resident_on: [decide]
edges:
  - { from: read_input, to: decide }
""";

glob SPEC: RuleSet = RuleSet(skill_name="demo", rules=[
    Rule(id="r1", quote="Read the input file.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r2", quote="Decide the plan.", kind=RuleKind.STEP, modality=Modality.MANDATORY),
    Rule(id="r9", quote="You may add a summary.", kind=RuleKind.STEP, modality=Modality.DISCRETIONARY)
]);

test "_views_from_ir reads nodes, owners and the rule traces G5 audits" {
    (wf, vb) = _views_from_ir(IR);
    ids = [n.id for n in wf.nodes];
    assert ids == ["read_input", "decide", "done"];
    byid = {n.id: n for n in wf.nodes};
    assert byid["read_input"].owner == Owner.CODE;
    assert byid["decide"].owner == Owner.MODEL;      # default when not code
    assert byid["read_input"].ntype == NodeType.SENSE;
    assert byid["done"].ntype == NodeType.TERMINAL;
    assert byid["decide"].traces_to == ["r2", "r3"];
    assert byid["read_input"].reads == ["task"];
}

test "_views_from_ir reads the tools and knowledge G1 audits" {
    (wf, vb) = _views_from_ir(IR);
    tools = {t.name: t for t in vb.kn.tools};
    assert "def read_file" in tools["read_file"].body;
    assert tools["read_file"].serves == ["read_input"];
    assert tools["save_it"].body == "";              # the prose-pointer
    assert len(vb.kn.knowledge) == 1;
    assert vb.kn.knowledge[0].key == "house_style";
    assert "snake_case" in vb.kn.knowledge[0].content;
}

test "the parsed views drive the REAL gates, not a private copy of them" {
    # G1 must flag save_it: it has neither body nor command.
    (wf, vb) = _views_from_ir(IR);
    issues = gate_standalone(vb);
    assert len(issues) == 1;
    assert "save_it" in issues[0];
    # G5 must flag r2: it is traced, but only to a node with no lowered ability.
    sc = gate_struct_cov(SPEC, wf, "can n_read_input with X entry { }");
    assert "r1" in sc.gated;          # owner=code + lowered ability
    assert "r2" in sc.missing;        # traced to `decide`, which never lowered
    assert "r9" not in sc.missing;    # DISCRETIONARY rules are not audited
}

test "every node type the compiler accepts round-trips — no silent GEN_RAW" {
    # An unmapped type defaults to GEN_RAW, which would read a CODE node (gated by
    # construction) back as a model slot. Cover the whole alphabet.
    for (name, want) in [("GEN-RAW", NodeType.GEN_RAW), ("GEN-ENUM", NodeType.GEN_ENUM),
                         ("GEN-FILL", NodeType.GEN_FILL), ("GEN-EDIT", NodeType.GEN_EDIT),
                         ("ROUTE", NodeType.ROUTE), ("LOOP", NodeType.LOOP),
                         ("SPAWN", NodeType.SPAWN), ("CALL", NodeType.CALL),
                         ("SENSE", NodeType.SENSE), ("ACT", NodeType.ACT),
                         ("CODE", NodeType.CODE), ("TERMINAL", NodeType.TERMINAL)] {
        (wf, vb) = _views_from_ir("nodes:\n  - id: x\n    type: " + name + "\n");
        assert wf.nodes[0].ntype == want;
    }
}

test "_views_from_ir survives junk instead of raising into the compile" {
    (wf, vb) = _views_from_ir("not: [valid: yaml");
    assert wf.nodes == [];
    (wf2, vb2) = _views_from_ir("");
    assert wf2.nodes == [];
    assert vb2.kn.tools == [];
}

test "_must_trace is exactly the mandatory STEP/IO rules" {
    assert _must_trace(SPEC) == ["r1", "r2"];
}

test "rules.md carries the ids and the verbatim quotes, not a summary" {
    md = _rules_md(SPEC);
    assert "**r1**" in md;
    assert "Read the input file." in md;
    assert "MANDATORY" in md;
    assert "DISCRETIONARY" in md;
}

test "the brief names the oracle, the reading order, and the rules to trace" {
    b = _brief("demo", ["r1", "r2"]);
    assert "gate agent.ir demo" in b;
    assert "writing-agir/SKILL.md" in b;
    assert "rules.md" in b;
    assert "agir-template.md" in b;
    assert "r1, r2" in b;
    assert "Edit `agent.ir` only" in b;
}

test "the authoring meta-skill ships with the contracts and is a real SKILL.md" {
    import os;
    import from pathlib { Path }
    import from src.sigil_runtime { repo_root, skill_description }
    p = os.path.join(repo_root(), "contracts", "writing-agir", "SKILL.md");
    assert os.path.exists(p);
    text = Path(p).read_text();
    assert skill_description(text).startswith("Use when");
    # it has to teach the three things the gates check
    assert "traces_to" in text;
    assert "sigil gate agent.ir" in text;
    assert "verbatim" in text;
}

test "the meta-skill tells the agent how to realize a prohibition" {
    import os;
    import from pathlib { Path }
    import from src.sigil_runtime { repo_root }
    text = Path(os.path.join(repo_root(), "contracts", "writing-agir", "SKILL.md")).read_text();
    # A prohibition is a property of the run, not a step — and the order of
    # preference matters: code beats a sem, because a sem is only observable.
    assert "Prohibitions are not steps" in text;
    assert "In code." in text;
    assert "folds `doc` into the" in text;   # ...the slot's sem (wraps in the source)
}
