"""Replay — re-execute a recorded run's cognition through a (re)compiled module.

The observability log (sigil_observe) records every LLM call's wire content.
ReplayLLM feeds those back as canned litellm-shaped responses, so byllm's
NORMAL parse path runs — structured outputs, enums, and `visit by llm` route
selections all resolve exactly as they did live. No model, no cost, no
nondeterminism: the recorded cognition, the current mechanism.

Uses: regression-test a compiler change against real recorded runs (the
superpowers postmortems), bisect lowering bugs, and turn any expensive live
failure into a permanent free test case.

Limits (honest): a recorded TOOL-CALL round can only be replayed when the log
carries the call arguments (`tool_args`, recorded by sigil_observe going
forward) — older logs raise a ReplayGap naming the call. A replay that
diverges structurally (the new module asks MORE questions than were recorded)
exhausts the recording and raises, which is itself signal: the graph changed
shape.
"""

import os;
import sys;
import json;
import shutil;
import from typing { Generator }
import from jaclang.byllm.llm { BaseLLM }

obj ReplayLLM(BaseLLM) {
    has recorded: list = [];
    has cursor: int = 0;

    override def model_call_no_stream(params: dict) -> dict {
        if self.cursor >= len(self.recorded) {
            raise RuntimeError(
                "replay exhausted: the module made call #" + str(self.cursor + 1)
                + " but the recording has only " + str(len(self.recorded))
                + " — the graph asks more of the model than the recorded run did (shape changed)");
        }
        rec = self.recorded[self.cursor];
        self.cursor += 1;
        msg: dict = {"role": "assistant", "content": str(rec.get("content") or "")};
        tnames = list(rec.get("tool_calls") or []);
        targs = list(rec.get("tool_args") or []);
        if tnames {
            if len(targs) < len(tnames) {
                raise RuntimeError(
                    "replay gap at call #" + str(self.cursor) + ": a tool-call round ("
                    + ", ".join([str(t) for t in tnames])
                    + ") without recorded arguments — re-record with the tool_args-capturing sigil_observe");
            }
            shims: list = [];
            i = 0;
            for nm in tnames {
                fn = SimpleNamespace(name=str(nm), arguments=str(targs[i]));
                shims.append(SimpleNamespace(id="replay_" + str(self.cursor) + "_" + str(i), function=fn));
                i += 1;
            }
            msg["tool_calls"] = shims;
        }
        return {"model": "replay/recorded", "choices": [{"message": msg}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}};
    }

    override def model_call_with_stream(params: dict) -> Generator[str, None, None] {
        raise RuntimeError("replay does not stream");
    }
}

::py::
from types import SimpleNamespace
::py::

def load_recording(obs_path: str) -> list {
    recs: list = [];
    with open(obs_path) as f {
        for line in f {
            if not str(line).strip() { continue; }
            d = json.loads(line);
            recs.append({"content": d.get("content") or "",
                         "tool_calls": d.get("tool_calls") or [],
                         "tool_args": d.get("tool_args") or []});
        }
    }
    return recs;
}

def replay_run(module_path: str, obs_path: str, task: str, workdir: str = ".") -> dict {
    # Stage the module as <workdir>/_replay_mod/agent.jac (one replay per
    # process: python caches the module under the stem 'agent').
    recs = load_recording(obs_path);
    m = ReplayLLM(model_name="replay/recorded", recorded=recs);
    wd = os.path.abspath(workdir);
    os.makedirs(wd, exist_ok=True);
    stage = os.path.join(wd, "_replay_mod");
    os.makedirs(stage, exist_ok=True);
    shutil.copy(module_path, os.path.join(stage, "agent.jac"));
    trace = os.path.join(wd, "replay_node_trace.jsonl");
    if os.path.exists(trace) { os.remove(trace); }
    os.environ["AGIR_PROGRESS"] = trace;
    cwd0 = os.getcwd();
    os.chdir(wd);
    sys.path.insert(0, stage);
    rep = "";
    err = "";
    try {
        import agent;
        rep = str(agent.run(task, m, ""));
    } except Exception as e {
        err = str(e)[:600];
    } finally {
        os.chdir(cwd0);
    }
    nodes = 0;
    try {
        with open(trace) as f { for _l in f { nodes += 1; } }
    } except Exception {  }
    return {"report": rep, "error": err, "nodes": nodes,
            "calls_used": m.cursor, "calls_recorded": len(recs)};
}
