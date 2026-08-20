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

import re;
import from .spec_loop { flag_ambiguous, resolve_ambiguous_default }

# --- Layer 0: the required-realization table ------------------------------

test "required_shape covers every rule kind; force never outranks KNOWLEDGE" {
    # FORBIDDEN is a prohibition for act-kinds ...
    assert required_shape(RuleKind.CONSTRAINT, Modality.FORBIDDEN) == RealShape.CONSTRAINT;
    assert required_shape(RuleKind.STEP, Modality.FORBIDDEN) == RealShape.CONSTRAINT;
    # ... but a descriptive 'never' tagged KNOWLEDGE is a fact to CARRY, not a
    # constraint to trace — the r71 class ("the harness never silently guesses")
    assert required_shape(RuleKind.KNOWLEDGE, Modality.FORBIDDEN) == RealShape.EMBODIED_KNOWLEDGE;
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

test "required_shape: a non-agent bearer cannot be obligated, only carried" {
    # an obligation on a tool/user is unrealizable-by-design -> OPTIONAL ...
    assert required_shape(RuleKind.STEP, Modality.MANDATORY, "environment") == RealShape.OPTIONAL;
    assert required_shape(RuleKind.STEP, Modality.FORBIDDEN, "user") == RealShape.OPTIONAL;
    # ... except facts, which are still worth embodying verbatim
    assert required_shape(RuleKind.KNOWLEDGE, Modality.FORBIDDEN, "environment") == RealShape.EMBODIED_KNOWLEDGE;
    # default / explicit agent unchanged
    assert required_shape(RuleKind.STEP, Modality.MANDATORY, "agent") == RealShape.NODE;
    assert required_shape(RuleKind.STEP, Modality.MANDATORY, "") == RealShape.NODE;
}

glob FOLD_IR: str = """agir_version: 0.1
shape: pipeline
nodes:
  - id: fix
    type: GEN-RAW
    doc: Resolve the residue cluster.
    traces_to: [r_step]
  - id: verify
    type: CODE
    owner: code
    doc: Run the typecheck.
    traces_to: [r_check]
  - id: done
    type: TERMINAL
""";

test "fold_untraced_prohibitions traces the prohibition on model nodes only" {
    spec = RuleSet(rules=[
        Rule(id="r_step", quote="Resolve the residue", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r_forbid", quote="do not solve the same thing 12 different ways",
             statement="never apply inconsistent fixes to one cluster",
             kind=RuleKind.CONSTRAINT, modality=Modality.FORBIDDEN)
    ]);
    folded = fold_untraced_prohibitions(FOLD_IR, spec, ["r_forbid"]);
    assert folded;
    pir = parse_ir(folded);
    by_id: dict = {};
    for n in pir.nodes { by_id[n.id] = n; }
    # the model node carries the prohibition + trace; code/terminal untouched
    assert "r_forbid" in by_id["fix"].traces_to;
    assert "PROHIBITION (r_forbid): never apply inconsistent fixes" in by_id["fix"].doc;
    assert "r_forbid" not in by_id["verify"].traces_to;
    assert by_id["done"].doc == "";
    # and the closure that failed before now passes for the prohibition
    d = check_completeness(spec, pir);
    assert [f.rule for f in d] == [];
}

glob ALL_CODE_IR: str = """agir_version: 0.1
shape: pipeline
nodes:
  - id: parse
    type: CODE
    owner: code
    doc: Parse the route table.
    traces_to: [r_step]
  - id: emit
    type: CODE
    owner: code
    doc: Write the report.
    traces_to: [r_write]
  - id: done
    type: TERMINAL
""";

test "fold falls back to code nodes when the pipeline is fully deterministic" {
    # azure-bgp's shape: every node owner=code, one CONSTRAINT rule dropped.
    # Model-only folding wrote nowhere and returned "", so the gate could never
    # be satisfied and the compile failed at 5/6 with no autofix rung logged.
    spec = RuleSet(rules=[
        Rule(id="r_step", quote="Parse the route table", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r_write", quote="Write the report", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r_policy", quote="Fix problems using routing policy rather than changing topology",
             statement="fix via routing policy, never by changing topology",
             kind=RuleKind.CONSTRAINT, modality=Modality.MANDATORY)
    ]);
    folded = fold_untraced_prohibitions(ALL_CODE_IR, spec, ["r_policy"]);
    assert folded;
    pir = parse_ir(folded);
    by_id: dict = {};
    for n in pir.nodes { by_id[n.id] = n; }
    assert "r_policy" in by_id["parse"].traces_to;
    assert "r_policy" in by_id["emit"].traces_to;
    assert "PROHIBITION (r_policy): fix via routing policy" in by_id["parse"].doc;
    # the end marker is not a slot a prohibition can govern, fallback or not
    assert "r_policy" not in by_id["done"].traces_to;
    assert by_id["done"].doc == "";
    # and the gate the compile stalled on is now closed
    assert [f.rule for f in check_completeness(spec, pir)] == [];
}

test "an unparseable IR ranks WORSE than a parseable one with real gaps" {
    # The pptx failure: the authored IR did not parse, so its report carried one
    # coherence finding and scored 1 — beating the repair round's parseable IR
    # with 31 real gaps. The ladder "kept prior", lowering found no nodes, and
    # the compile was reported as UNFAITHFUL 0/130 instead of uncompilable.
    spec = RuleSet(rules=[
        Rule(id="r1", quote="Parse the route table", kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Write the report", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    unparseable = faithfulness_report(spec, "not: [valid yaml at all");
    assert not unparseable.parsed;
    assert len(unparseable.dropped) == 1;          # one coherence finding ...
    assert gap_score(unparseable) > 1000;          # ... but it must not score 1

    # a PARSEABLE candidate that drops BOTH rules is still preferable
    parseable_but_bad = faithfulness_report(spec, """agir_version: 0.1
shape: pipeline
nodes:
  - id: x
    type: GEN-RAW
    doc: does something unrelated
    traces_to: []
""");
    assert parseable_but_bad.parsed;
    assert gap_score(parseable_but_bad) < gap_score(unparseable);
}

test "fold refuses non-constraint drops and unknown rules" {
    spec = RuleSet(rules=[
        Rule(id="r_step", quote="Resolve the residue", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    # unknown id -> nothing to fold -> ""
    assert fold_untraced_prohibitions(FOLD_IR, spec, ["r_ghost"]) == "";
    # unparseable IR -> ""
    assert fold_untraced_prohibitions("not: [valid", spec, ["r_step"]) == "";
}

test "check_completeness skips a non-agent step but demands the knowledge" {
    spec = RuleSet(rules=[
        Rule(id="r_env", quote="the harness rewrites the imports",
             kind=RuleKind.STEP, modality=Modality.MANDATORY, binds="environment"),
        Rule(id="r_fact", quote="it never silently guesses",
             kind=RuleKind.KNOWLEDGE, modality=Modality.FORBIDDEN, binds="environment"),
        Rule(id="r_step", quote="Resolve the residue", kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    pir = ParsedIR(nodes=[
        PNode(id="fix", ntype="GEN_RAW", traces_to=["r_step"]),
        PNode(id="done", ntype="TERMINAL")
    ]);
    d = check_completeness(spec, pir);
    # r_env is not the agent's to perform -> no drop; r_fact must be carried -> drop
    assert len(d) == 1;
    assert d[0].rule == "r_fact";
    assert d[0].shape == "EMBODIED_KNOWLEDGE";
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

# ---------------------------------------------------------------------------
# cognition preservation — the check the default path never had
# ---------------------------------------------------------------------------

glob _SHRED_IR: str = """---
name: explorer
---
agir_version: 0.1
shape: pipeline
walker:
  name: ExplorerAgent
  carries:
    task: { type: str, role: input }
nodes:
  - id: look
    type: GEN-RAW
    owner: model
    traces_to: [r1]
  - id: decide
    type: GEN-ENUM
    owner: model
    traces_to: [r1]
edges: []
""";

glob _WHOLE_IR: str = """---
name: explorer
---
agir_version: 0.1
shape: pipeline
walker:
  name: ExplorerAgent
  carries:
    task: { type: str, role: input }
nodes:
  - id: explore
    type: GEN-RAW
    owner: model
    traces_to: [r1]
edges: []
""";

glob _CODE_IR: str = """---
name: explorer
---
agir_version: 0.1
shape: pipeline
walker:
  name: ExplorerAgent
  carries:
    task: { type: str, role: input }
nodes:
  - id: explore
    type: CODE
    owner: code
    traces_to: [r1]
edges: []
""";

def _invoke_spec() -> RuleSet {
    return RuleSet(skill_name="explorer", rules=[
        Rule(id="r1", quote="Use the tools to explore the repo until you understand it.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY, cohesion=Cohesion.INVOKE_UNIT)
    ]);
}

test "an INVOKE_UNIT rule split across nodes is flagged as shredded" {
    c = check_cohesion(_invoke_spec(), parse_ir(_SHRED_IR));
    assert len(c) == 1;
    assert "shredded" in c[0].message;
    assert "'r1'" in c[0].message;
}

test "an INVOKE_UNIT rule kept as one adaptive model node is clean" {
    assert check_cohesion(_invoke_spec(), parse_ir(_WHOLE_IR)) == [];
}

test "an INVOKE_UNIT rule lowered to a code node loses its loop" {
    c = check_cohesion(_invoke_spec(), parse_ir(_CODE_IR));
    assert len(c) == 1;
    assert "non-cognitive" in c[0].message;
}

test "an ATOMIC rule is never subject to the anti-shred check" {
    spec = RuleSet(skill_name="explorer", rules=[
        Rule(id="r1", quote="Write the file.", kind=RuleKind.STEP,
             modality=Modality.MANDATORY, cohesion=Cohesion.ATOMIC)
    ]);
    assert check_cohesion(spec, parse_ir(_SHRED_IR)) == [];
}

test "shredding is reported but does NOT flip the faithfulness verdict" {
    fr = faithfulness_report(_invoke_spec(), _SHRED_IR);
    assert len(fr.cohesion) == 1;
    # warn-level: it rides the proof, it does not fail the compile
    assert gap_score(fr) == len(fr.dropped) + len(fr.added);
    assert "SHRED" in " ".join(proof_lines(fr));
}

# ---------------------------------------------------------------------------
# vacuity — a faithfulness verdict over an empty required set
# ---------------------------------------------------------------------------

glob _TOY_SKILL: str = "# Toy\n\nLoad the rows from data.csv.\nYou must always emit a CSV with a header row.\n";

# Realizes r2 only — no loading step. This is the gpt-5 arm in pilot/RESULTS.md:
# "emitted no loading at all".
glob _IR_NO_LOADING: str = """---
name: toy
---
agir_version: 0.1
shape: pipeline
tools:
  emit_csv:
    sig: "(task) -> str"
    surface: ACT·artifact
    serves: [emit]
    traces_to: [r2]
    body: |
      def emit_csv(task):
          return "col_a\\n1\\n"
walker:
  name: ToyAgent
  carries:
    task: { type: str, role: input }
    out:  { type: str, produced_by: emit }
nodes:
  - id: emit
    type: ACT
    owner: code
    op: emit_csv
    tool: emit_csv
    reads: [task]
    writes: [out]
    doc: "Always emit a CSV with a header row."
    traces_to: [r2]
  - id: done
    type: TERMINAL
edges:
  - {from: emit, to: done, modality: mandatory}
""";

def _toy_spec() -> RuleSet {
    return RuleSet(skill_name="toy", rules=[
        Rule(id="r1", quote="Load the rows from data.csv.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="You must always emit a CSV with a header row.",
             kind=RuleKind.IO, modality=Modality.MANDATORY)
    ]);
}

test "an unmarked imperative is demoted, and the missing step stops being checked" {
    # This is the compiler-layer gap: the SAME agent, which never loads its
    # input, flips from unfaithful to faithful because the modal-force fallback
    # assumed the loading step was optional.
    before = faithfulness_report(_toy_spec(), _IR_NO_LOADING);
    assert not before.ok;
    assert len(before.dropped) == 1;
    assert "'r1'" in before.dropped[0].message;

    spec = _toy_spec();
    resolve_ambiguous_default(spec, flag_ambiguous(_TOY_SKILL, spec));
    after = faithfulness_report(spec, _IR_NO_LOADING);
    assert after.ok;                      # the gap, pinned
    assert len(after.dropped) == 0;
    assert after.rules_total == 1;        # r1 is no longer required of anyone
}

test "a spec whose every obligation resolved to optional is reported VACUOUS" {
    # search-cities is the real case: its one MANDATORY rule carries no modal
    # marker, so after the fallback nothing at all is required and the verdict
    # is a vacuous truth rather than a proof.
    spec = RuleSet(skill_name="cities", rules=[
        Rule(id="r1", quote="Map states to their cities from the background text file.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY)
    ]);
    skill = "# Search Cities\n\nMap states to their cities from the background text file.\n";
    resolve_ambiguous_default(spec, flag_ambiguous(skill, spec));
    fr = faithfulness_report(spec, _IR_NO_LOADING);
    assert fr.rules_total == 0;
    assert fr.vacuous;
    assert "vacuous" in " ".join(proof_lines(fr));
}

test "a spec that still requires something is NOT vacuous" {
    fr = faithfulness_report(_toy_spec(), _IR_NO_LOADING);
    assert fr.rules_total == 2;
    assert not fr.vacuous;
}

test "an empty spec is not vacuous — there was nothing to lose" {
    fr = faithfulness_report(RuleSet(skill_name="none", rules=[]), _IR_NO_LOADING);
    assert not fr.vacuous;
}

glob POINTER_IR: str = """agir_version: 0.1
shape: pipeline
nodes:
  - id: fill
    type: GEN-RAW
    doc: Fill the form.
    traces_to: [r_guide]
  - id: done
    type: TERMINAL
tools:
  read_forms_guide:
    surface: SENSE
    traces_to: [r_guide]
    body: |
      for candidate in ("forms.md", "./forms.md"):
          if os.path.exists(candidate):
              return open(candidate).read()
      return "forms.md was not found"
""";

glob EMBODIED_IR: str = """agir_version: 0.1
shape: pipeline
nodes:
  - id: fill
    type: GEN-RAW
    doc: Fill the form.
    traces_to: [r_guide]
  - id: done
    type: TERMINAL
knowledge:
  forms_guide:
    traces_to: [r_guide]
    content: |
      If the PDF has fillable form fields, set each field by field_id and mark
      checkboxes with their checked_value.
""";

test "a tool that only OPENS a sibling doc does not embody it" {
    # the live SkillsBench pdf case: compiled `faithful` with a tool whose body
    # was a search for forms.md, then shipped without the file and produced a
    # blank PDF. Pointing at content is not carrying it.
    spec = RuleSet(rules=[
        Rule(id="r_guide", quote="Read forms.md completely before filling the form.",
             kind=RuleKind.KNOWLEDGE, modality=Modality.MANDATORY)
    ]);
    d = check_completeness(spec, parse_ir(POINTER_IR));
    assert [f.rule for f in d] == ["r_guide"];
    assert d[0].shape == "EMBODIED_KNOWLEDGE";
}

test "the same rule passes once the content is actually carried" {
    spec = RuleSet(rules=[
        Rule(id="r_guide", quote="Read forms.md completely before filling the form.",
             kind=RuleKind.KNOWLEDGE, modality=Modality.MANDATORY)
    ]);
    assert [f.rule for f in check_completeness(spec, parse_ir(EMBODIED_IR))] == [];
}

test "a tool that computes still counts as embodiment" {
    # the guard is narrow: only a body whose work IS opening a document is a
    # pointer. A real tool body must keep satisfying the shape.
    ir = re.sub(r"body: \|\n(      .*\n)+",
                "body: |\n      return {\"field_id\": fid, \"checked_value\": \"On\"}\n",
                POINTER_IR);
    spec = RuleSet(rules=[
        Rule(id="r_guide", quote="Read forms.md completely before filling the form.",
             kind=RuleKind.KNOWLEDGE, modality=Modality.MANDATORY)
    ]);
    assert [f.rule for f in check_completeness(spec, parse_ir(ir))] == [];
}

glob REPORT_ONLY_IR: str = """agir_version: 0.1
shape: pipeline
nodes:
  - id: compute
    type: ACT
    doc: Find the farthest point and report it.
    traces_to: [r_deliver]
    serves: [distance_report]
  - id: done
    type: TERMINAL
tools:
  distance_report:
    surface: ACT
    serves: [compute]
    traces_to: [r_deliver]
    body: |
      d = furthest(points, boundaries)
      return "report_text=furthest_point_id=%s" % d["id"]
""";

glob REAL_WRITE_IR: str = """agir_version: 0.1
shape: pipeline
nodes:
  - id: emit
    type: ACT
    doc: Write the answer file.
    traces_to: [r_deliver]
    serves: [write_answer]
  - id: done
    type: TERMINAL
tools:
  write_answer:
    surface: ACT
    serves: [emit]
    traces_to: [r_deliver]
    body: |
      with open(out_path, "w") as f:
          json.dump({"id": d["id"]}, f)
      return out_path
""";

test "an ACT that only REPORTS does not realize a deliverable" {
    # the live SkillsBench geospatial case: the tool computed the right answer
    # (furthest_point_id=hv74103036), returned it as report_text, wrote no file,
    # and the cell scored 0/8 — yet the skill compiled `faithful`.
    spec = RuleSet(rules=[
        Rule(id="r_deliver", quote="Write the farthest earthquake to answer.json.",
             kind=RuleKind.IO, modality=Modality.MANDATORY)
    ]);
    d = check_completeness(spec, parse_ir(REPORT_ONLY_IR));
    assert [f.rule for f in d] == ["r_deliver"];
    assert d[0].shape == "EMBODIED_WRITE";
}

test "an ACT whose body actually writes does realize it" {
    spec = RuleSet(rules=[
        Rule(id="r_deliver", quote="Write the farthest earthquake to answer.json.",
             kind=RuleKind.IO, modality=Modality.MANDATORY)
    ]);
    assert [f.rule for f in check_completeness(spec, parse_ir(REAL_WRITE_IR))] == [];
}

test "an external command stays acceptable — it is opaque, not provably inert" {
    # `python scripts/pack.py in out` writes, but nothing in the string says so.
    # Rejecting commands would fail every script-delegating skill.
    ir = REPORT_ONLY_IR.replace(
        "    body: |\n      d = furthest(points, boundaries)\n"
        + "      return \"report_text=furthest_point_id=%s\" % d[\"id\"]\n",
        "    command: python scripts/emit_answer.py {points} {out}\n");
    spec = RuleSet(rules=[
        Rule(id="r_deliver", quote="Write the farthest earthquake to answer.json.",
             kind=RuleKind.IO, modality=Modality.MANDATORY)
    ]);
    assert [f.rule for f in check_completeness(spec, parse_ir(ir))] == [];
}
