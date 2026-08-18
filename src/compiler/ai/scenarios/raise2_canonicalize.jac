"""Scenario — raise2 end to end, with a MALFORMED authored AG-IR.

Nothing drove `raise2` in CI before this, even though it is the DEFAULT front-end.
A MockLLM author returns the shape a real compile of skillsbench constraint-parser
produced — `constraints: { type: list[str], ... }`, where `[` opens a flow sequence
YAML never sees closed, so the document parses only because load_agir relaxes it.

Asserted:

  · the raise still reaches a runnable, faithful result on a malformed document
    (the relaxer has always handled this — that part is not new)
  · the IR the raise RETURNS is strict YAML, so what gets persisted as the skill's
    provenance is an actual YAML document
  · the lowered module is byte-identical to the one the malformed text produced —
    the canonicalization changed the artifact's form and not its meaning

Exits nonzero on failure.
"""

import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.lift_types { Modality, RuleKind }
import from src.compiler.ai.spec_loop { Rule, RuleSet }
import from src.compiler.ai.raise2 { raise_from_spec, pin_raise2_llms }
import from src.compiler.mechanical.compiler { transpile_ir }
import from src.compiler.ai.lift { set_lift_progress }
import from src.sigil_agir_yaml { strict_parses }

glob SKILL: str = """# Constraint Toy
Extract the scheduling constraints from the email text.
Always format the result as a JSON object with a "constraints" array.
""";

# `constraints: { type: list[str], ... }` — authored text that is NOT strict YAML.
glob AUTHORED_MALFORMED: str = """---
name: constraint-toy
description: Extract scheduling constraints and emit JSON.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  format_json:
    sig: "(constraints) -> str"
    surface: ACT·artifact
    serves: [emit]
    traces_to: [r2]
    body: |
      def format_json(constraints):
          import json
          return json.dumps({"constraints": [str(c) for c in (constraints or [])]})
walker:
  name: ConstraintToy
  carries:
    task:        { type: str,       role: input }
    constraints: { type: list[str], produced_by: extract }
    payload:     { type: str,       produced_by: emit }
nodes:
  - id: extract
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [constraints]
    doc: "Extract the scheduling constraints from the email text."
    traces_to: [r1]
  - id: emit
    type: ACT
    owner: code
    op: format_json
    tool: format_json
    reads: [constraints]
    writes: [payload]
    traces_to: [r2]
  - id: done
    type: TERMINAL
edges:
  - {from: extract, to: emit, modality: mandatory}
  - {from: emit, to: done, modality: mandatory}
""";

glob _events: list = [];
def _collect(ev: dict) -> None { _events.append(ev); }

def _spec() -> RuleSet {
    return RuleSet(skill_name="constraint-toy", rules=[
        Rule(id="r1", quote="Extract the scheduling constraints from the email text.",
             kind=RuleKind.STEP, modality=Modality.MANDATORY),
        Rule(id="r2", quote="Always format the result as a JSON object with a \"constraints\" array.",
             kind=RuleKind.IO, modality=Modality.MANDATORY)
    ]);
}

with entry:__main__ {
    assert not strict_parses(AUTHORED_MALFORMED), "fixture must not be strict YAML";

    set_lift_progress(_collect);
    pin_raise2_llms(MockLLM(model_name="mockllm", config={"outputs": [AUTHORED_MALFORMED]}));
    rr = raise_from_spec(SKILL, "constraint_toy", _spec());

    assert rr.ir_text, "raise produced no IR";
    assert "def run(" in rr.module_src, "raise did not lower to a runnable module";
    assert rr.status == "faithful", "unexpected status: " + rr.status;

    # what gets persisted is a real YAML document
    assert strict_parses(rr.ir_text), "the returned IR still needs the relaxer";
    assert "relaxer" in " ".join(rr.repairs), str(rr.repairs);

    # ...and the graph it lowers to did not move
    m_before = str(transpile_ir(AUTHORED_MALFORMED, "constraint_toy_id"));
    m_after = str(transpile_ir(rr.ir_text, "constraint_toy_id"));
    assert m_before == m_after, "canonicalization changed what the IR lowers to";

    print("SCENARIO raise2 canonicalize OK (status=" + rr.status
          + ", IR " + str(len(AUTHORED_MALFORMED.splitlines())) + " -> "
          + str(len(rr.ir_text.splitlines())) + " lines, module identical)");
}
