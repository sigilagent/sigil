"""Scenario — ReplayLLM re-executes recorded cognition through a compiled module.

VERSION-PORTABLE assertions only: a linear pipeline (str slot -> ACT -> TERMINAL)
replays from a synthetic recording and must reach TERMINAL with the artifact
written; the exhaustion and tool-gap guards must be loud.

Deliberately NOT asserted here: `visit by llm` route selection from a synthetic
recording. The wire format of a visit-selection is coupled to the byllm that
RECORDED it — a hand-forged wrapper breaks whenever CI's jac is newer than the
author's (typed-retry then consumes an extra recorded call: "replay exhausted").
Route-replay fidelity is validated against REAL recordings instead (the
superpowers requesting-code-review run replays 20/20 calls over its exact
23-node live path — see superpowers-exp/REPORT.md); recordings replay under the
byllm that made them. Exits nonzero on failure."""

import os;
import json;
import tempfile;
import from src.compiler.ai.gates { compile_gate }
import from src.compiler.ai.replay { replay_run, ReplayLLM }

glob LINEAR_IR: str = """---
name: replay-probe
description: A linear pipeline for replay validation.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: ProbeAgent
  carries:
    task:
      type: str
      role: input
    body_text:
      type: str
      produced_by: draft
    artifact:
      type: str
      produced_by: emit
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [body_text]
    doc: "Draft the content."
  - id: emit
    type: ACT
    owner: code
    surface: "ACT·artifact"
    reads: [body_text]
    writes: [artifact]
    doc: "Write the drafted content out."
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: emit, modality: mandatory}
  - {from: emit, to: done, modality: mandatory}
""";

with entry:__main__ {
    v = compile_gate(LINEAR_IR, "replay_probe", check=False);
    assert v.ok, v.errors;
    wd = tempfile.mkdtemp(prefix="sigil_replay_probe_");
    modp = os.path.join(wd, "probe_agent.jac");
    with open(modp, "w") as f { f.write(v.module_src); }

    # a synthetic recording shaped like sigil_observe output: one str-slot reply
    obsp = os.path.join(wd, "live.jsonl");
    with open(obsp, "w") as f {
        f.write(json.dumps({"content": "the drafted body", "tool_calls": [], "tool_args": []}) + chr(10));
    }

    rr = replay_run(modp, obsp, "probe task", wd);
    assert rr["error"] == "", rr["error"];
    assert rr["calls_used"] == 1, rr;
    trace = open(os.path.join(wd, "replay_node_trace.jsonl")).read();
    assert "emit" in trace and "done" in trace, trace;
    assert not str(rr["report"]).startswith("INCOMPLETE"), rr["report"];
    print("SCENARIO replay OK (recorded cognition drove the module to TERMINAL)");

    # exhaustion is LOUD: an empty recording must raise, not underrun silently
    m = ReplayLLM(model_name="replay/recorded", recorded=[]);
    loud = False;
    try { m.model_call_no_stream({}); }
    except Exception as e { loud = "replay exhausted" in str(e); }
    assert loud;
    # a tool round without recorded args is an explicit gap, not a guess
    m2 = ReplayLLM(model_name="replay/recorded",
                   recorded=[{"content": "", "tool_calls": ["ws_write"], "tool_args": []}]);
    gap = False;
    try { m2.model_call_no_stream({}); }
    except Exception as e2 { gap = "replay gap" in str(e2); }
    assert gap;
    print("SCENARIO replay guards OK (exhaustion + tool-gap are loud)");
}
