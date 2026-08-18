"""Scenario — raise2 with phase 2 wired in.

The unit tests drive `run_passes` in isolation; this drives the DEFAULT front-end
end to end with a MockLLM author that returns a MALFORMED AG-IR — the shape a real
compile of skillsbench constraint-parser produced, where `[` inside a flow map
opens a sequence YAML never sees closed.

Three things are asserted, and they are the whole contract of the phase:

  · ON  — the phase adopts canonicalize, and the raise still compiles and is faithful
  · OFF — the same run reaches the same verdict with the IR left exactly as authored,
          which is what makes `--no-phase2` a real escape hatch rather than a flag
  · the module is IDENTICAL either way, because a refinement may change the IR's
    form and may not change what it lowers to

Exits nonzero on failure.
"""

import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.lift_types { Modality, RuleKind }
import from src.compiler.ai.spec_loop { Rule, RuleSet }
import from src.compiler.ai.raise2 { raise_from_spec, pin_raise2_llms }
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

    # ---- phase 2 ON (the default) ----
    _events = [];
    set_lift_progress(_collect);
    pin_raise2_llms(MockLLM(model_name="mockllm", config={"outputs": [AUTHORED_MALFORMED]}));
    on = raise_from_spec(SKILL, "constraint_toy_on", _spec());

    assert on.ir_text, "raise produced no IR";
    assert "def run(" in on.module_src, "raise did not lower to a runnable module";
    assert strict_parses(on.ir_text), "phase 2 left the IR needing the relaxer";
    assert "canonicalize" in " ".join(on.repairs), str(on.repairs);

    _done = [str(e["stage"]) for e in _events if str(e.get("state")) == "done"];
    assert "passes" in _done, _done;

    # ---- phase 2 OFF ----
    _events = [];
    pin_raise2_llms(MockLLM(model_name="mockllm", config={"outputs": [AUTHORED_MALFORMED]}));
    off = raise_from_spec(SKILL, "constraint_toy_off", _spec(), 2, "off");

    assert off.ir_text == AUTHORED_MALFORMED.strip(), "off must leave the authored IR alone";
    assert not strict_parses(off.ir_text), "off must not canonicalize";
    assert "canonicalize" not in " ".join(off.repairs), str(off.repairs);
    _done_off = [str(e["stage"]) for e in _events if str(e.get("state")) == "done"];
    assert "passes" not in _done_off, "off must not even open the phase: " + str(_done_off);

    # ---- and the phase changed the form, not the meaning ----
    assert on.module_src == off.module_src, "phase 2 changed what the IR lowers to";
    assert on.status == off.status, on.status + " != " + off.status;

    print("SCENARIO raise2 phase2 OK (status=" + on.status
          + ", IR " + str(len(AUTHORED_MALFORMED.splitlines())) + " -> "
          + str(len(on.ir_text.splitlines())) + " lines, module identical)");
}
