"""Scenario — the walker step budget aborts a non-converging loop LOUDLY.

A 3-node cycle whose exit guard never fires (the superpowers brainstorming
spin, miniaturized): ask -> assess -> route(back). With AGIR_STEP_BUDGET set
low, _progress must raise a diagnostic RuntimeError naming the node and count
— never spin to the harness timeout. Exits nonzero on failure."""

import os;
import from jaclang.byllm.lib { MockLLM }
import from src.compiler.ai.gates { compile_gate }

glob LOOP_IR: str = """---
name: spin-probe
description: A clarify loop with no converging guard.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: SpinAgent
  carries:
    task:
      type: str
      role: input
    question:
      type: str
      produced_by: ask
    notes:
      type: str
      produced_by: assess
nodes:
  - id: ask
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [question]
    doc: "Ask one clarifying question."
  - id: assess
    type: GEN-RAW
    owner: model
    reads: [question]
    writes: [notes]
    doc: "Assess clarity."
  - id: loop_route
    type: ROUTE
    owner: code
    reads: [notes]
  - id: done
    type: TERMINAL
edges:
  - {from: ask, to: assess, modality: mandatory}
  - {from: assess, to: loop_route, modality: mandatory}
  - {from: loop_route, to: ask, modality: discretionary, guard: "more"}
  - {from: loop_route, to: done, modality: mandatory, guard: "finished"}
""";

with entry:__main__ {
    v = compile_gate(LOOP_IR, "spin_probe", check=False);
    assert v.ok, v.errors;
    with open("/tmp/spin_probe.jac", "w") as f { f.write(v.module_src); }
    import sys;
    sys.path.insert(0, "/tmp");
    os.environ["AGIR_STEP_BUDGET"] = "25";
    import spin_probe;
    outs: list = ["q?", "unclear"] * 200;   # cognition never converges
    m = MockLLM(model_name="mockllm", config={"outputs": outs});
    hit = False;
    try {
        spin_probe.run("spin forever", m, "");
    } except Exception as e {
        msg = str(e);
        assert "step budget exhausted" in msg, msg;
        assert "25" in msg;
        hit = True;
    }
    assert hit, "budget never fired — the loop ran to completion?!";
    print("SCENARIO runtime_budget OK (loop aborted loudly at 25 visits)");
}
