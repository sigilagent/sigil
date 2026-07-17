"""Scenario — ReplayLLM re-executes recorded cognition through a compiled module.

A toy with a model-owned ROUTE fan-out is compiled live; a synthetic recording
(contents shaped exactly like sigil_observe captures them, including the
`schema_object_wrapper` visit-by selection) is replayed. The route must resolve
through byllm's NORMAL parse path (MockLLM cannot do this — it bypasses parsing),
the chosen branch must run, and the exhaustion + gap errors must be loud.
Exits nonzero on failure."""

import os;
import json;
import tempfile;
import from src.compiler.ai.gates { compile_gate }
import from src.compiler.ai.replay { replay_run, load_recording, ReplayLLM }

glob ROUTE_IR: str = """---
name: replay-probe
description: A branching pipeline for replay validation.
---
agir_version: 0.1
standalone: true
shape: dispatch-router
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
      produced_by: emit_b
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [body_text]
    doc: "Draft the content."
  - id: pick_lane
    type: ROUTE
    owner: model
    reads: [body_text]
    doc: "Choose the lane that fits the draft."
  - id: emit_a
    type: ACT
    owner: code
    surface: "ACT·artifact"
    reads: [body_text]
    writes: [artifact]
    doc: "Emit via lane A."
  - id: emit_b
    type: ACT
    owner: code
    surface: "ACT·artifact"
    reads: [body_text]
    writes: [artifact]
    doc: "Emit via lane B."
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: pick_lane, modality: mandatory}
  - {from: pick_lane, to: emit_a, modality: discretionary, guard: "lane_a"}
  - {from: pick_lane, to: emit_b, modality: discretionary, guard: "lane_b"}
  - {from: emit_a, to: done, modality: mandatory}
  - {from: emit_b, to: done, modality: mandatory}
""";

with entry:__main__ {
    v = compile_gate(ROUTE_IR, "replay_probe", check=False);
    assert v.ok, v.errors;
    wd = tempfile.mkdtemp(prefix="sigil_replay_probe_");
    modp = os.path.join(wd, "probe_agent.jac");
    with open(modp, "w") as f { f.write(v.module_src); }

    # a synthetic recording, shaped like sigil_observe output: the draft slot's
    # text, then the visit-by selection of the B lane by ARCHETYPE NAME.
    obsp = os.path.join(wd, "live.jsonl");
    with open(obsp, "w") as f {
        f.write(json.dumps({"content": "the drafted body", "tool_calls": [], "tool_args": []}) + chr(10));
        f.write(json.dumps({"content": "{\"schema_object_wrapper\": [\"EmitB\"]}", "tool_calls": [], "tool_args": []}) + chr(10));
    }

    rr = replay_run(modp, obsp, "probe task", wd);
    assert rr["error"] == "", rr["error"];
    assert rr["calls_used"] == 2, rr;
    # the replay must have taken the B lane and reached TERMINAL with the artifact
    trace = open(os.path.join(wd, "replay_node_trace.jsonl")).read();
    assert "emit_b" in trace, trace;
    assert "emit_a" not in trace, trace;
    assert "done" in trace, trace;
    assert not str(rr["report"]).startswith("INCOMPLETE"), rr["report"];
    print("SCENARIO replay OK (visit-by selection replayed through the live parse path)");

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
