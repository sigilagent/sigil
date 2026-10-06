"""Regression tests for the mechanical lowering and its injected runtime.

Every test here locks in a fault that was observed in a RUNNING compiled agent, where
`jac check` stayed green and the walker reported success while doing nothing:

  * a `command` tool ran its shell string as argv, so `&&` was an argument, `/usr/bin/cd`
    was the executable, and a `{param}` placeholder was never substituted;
  * a `dict` carry was never assigned, so every node downstream of the reader ran on `{}`
    and the model invented ungrounded content;
  * an `int` carry was never assigned, so a route guarded on a round budget could not move;
  * the task text was bound to EVERY unproduced string input, so a `path` input became a
    whole sentence and a reviewer-decision input silently satisfied its own gate;
  * a model node declaring several `writes` assigned only the first, so the carry feeding
    the next write step stayed empty and that step became a no-op;
  * a `::py::` marker inside emitted Python closed the block early and the rest of the
    module was parsed as Jac, failing far from the cause.

Run with `jac test src/lowering_fix_tests.jac`.
"""

import os;
import re;
import ast;
import from .compiler.mechanical.compiler { transpile_ir }

::py::
import os as _os


def _runtime_ns():
    """Exec the injected runtime asset and hand back its namespace.

    Same approach as report_fix_tests.jac: the asset is the thing that ships inside
    every compiled agent, so the helpers are tested as text, exactly as emitted.
    """
    import subprocess as _subprocess, sys, json as _json, tempfile, glob as _glob
    here = _os.path.dirname(_os.path.abspath(__file__))
    path = _os.path.join(here, "compiler", "mechanical", "assets", "osp_runtime.py.txt")
    src = open(path).read()
    ns = {"os": _os, "sys": sys, "_subprocess": _subprocess, "_json": _json,
          "tempfile": tempfile, "_glob": _glob}
    exec(src, ns)
    return ns


def _asset_text():
    here = _os.path.dirname(_os.path.abspath(__file__))
    return open(_os.path.join(here, "compiler", "mechanical", "assets",
                             "osp_runtime.py.txt")).read()
::py::


# ---------------------------------------------------------------- the injected runtime

test "a command tool runs through the shell, with && and | intact" {
    ns = _runtime_ns();
    run_cmd = ns["_run_cmd"];
    # argv execution turned `&&` into an argument of /usr/bin/cd; a shell runs the chain
    out = run_cmd(["echo", "one", "&&", "echo", "two"], []);
    assert "one" in out;
    assert "two" in out;
    assert "&&" not in out;
}

test "a {param} placeholder is substituted, not appended" {
    ns = _runtime_ns();
    run_cmd = ns["_run_cmd"];
    out = run_cmd(["echo", "dir={target_dir}"], [("target_dir", "react-out")]);
    assert "dir=react-out" in out;
    assert "{target_dir}" not in out;
}

test "a value with no placeholder still appends, and is shell-quoted" {
    ns = _runtime_ns();
    run_cmd = ns["_run_cmd"];
    out = run_cmd(["echo"], [("word", "a b")]);
    assert "a b" in out;
}

test "_as_dict is total: mapping, JSON object, else the default" {
    ns = _runtime_ns();
    as_dict = ns["_as_dict"];
    assert as_dict({"a": 1}, {}) == {"a": 1};
    assert as_dict('{"a": 1}', {}) == {"a": 1};
    assert as_dict(None, {"keep": 1}) == {"keep": 1};
    assert as_dict("not json", {"keep": 1}) == {"keep": 1};
    assert as_dict(7, {}) == {};
}

test "_as_num is total: a counter carry can never be lost to a raise" {
    ns = _runtime_ns();
    as_num = ns["_as_num"];
    assert as_num(3, 0, True) == 3;
    assert as_num("round 4 of 9", 0, True) == 4;
    assert as_num(None, 2, True) == 2;         # int(None) would raise
    assert as_num("", 2, True) == 2;           # int("") would raise
    assert as_num("nope", 5, True) == 5;
    assert as_num("2.5", 0, False) == 2.5;
}

test "the bundle stager refuses to stage a git root" {
    # An eject living in a real repo would otherwise copy the WHOLE checkout into the
    # invoking cwd; a skill bundle never has a .git of its own.
    text = _asset_text();
    assert 'os.path.join(here, ".git")' in text;
}


# ---------------------------------------------------------------- the lowering

glob CARRY_IR: str = """---
name: carries
description: Carries of several shapes.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  gather:
    sig: "(task) -> dict"
    surface: SENSE
    doc: "Collect the inputs."
    body: |
      def gather(task):
          return {"bundle": {"n": 1}, "rounds": 1, "ratio": 1.5}
walker:
  name: CarryAgent
  carries:
    task:     { type: str,  role: input }
    bundle:   { type: dict, produced_by: collect }
    rounds:   { type: int,  produced_by: collect }
    ratio:    { type: float, produced_by: collect }
nodes:
  - id: collect
    type: SENSE
    owner: code
    op: gather
    tool: gather
    reads: [task]
    writes: [bundle, rounds, ratio]
  - id: done
    type: TERMINAL
edges:
  - {from: collect, to: done, modality: mandatory}
""";

test "a dict carry is ASSIGNED, not left at its default" {
    src = transpile_ir(CARRY_IR, "carries_dict");
    assert "self.bundle = dict(_as_dict(" in src;
    assert "-> bundle (dict); carry keeps default" not in src;
}

test "an int carry is ASSIGNED, so a round budget can move" {
    src = transpile_ir(CARRY_IR, "carries_int");
    assert "self.rounds = int(_as_num(" in src;
    assert "-> rounds (int); carry keeps default" not in src;
}


glob CMD_IR: str = """---
name: harness
description: Call a bundle CLI.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  report:
    sig: "(target_dir) -> str"
    surface: SENSE
    doc: "Report on the target."
    command: "cd tools/harness && npm run report -- {target_dir}"
walker:
  name: HarnessAgent
  carries:
    task:       { type: str,  role: input }
    target_dir: { type: path, role: input }
    out:        { type: str,  produced_by: look }
nodes:
  - id: look
    type: SENSE
    owner: code
    op: report
    tool: report
    reads: [target_dir]
    writes: [out]
  - id: done
    type: TERMINAL
edges:
  - {from: look, to: done, modality: mandatory}
""";

test "a command tool passes NAMED args so the placeholder can be filled" {
    src = transpile_ir(CMD_IR, "harness_cmd");
    assert '[("target_dir", target_dir)]' in src;
}

test "the task text is not bound to a non-str input, nor to one the entry node ignores" {
    # `target_dir` is a path the ENTRY node reads: it must come from a direct arg, and
    # must NOT fall back to the task sentence (which is how it became
    # "burn down the migration residue in react-out" live).
    src = transpile_ir(CMD_IR, "harness_bind");
    assert "target_dir=str(params.get('target_dir', ''))" in src;
    assert "target_dir=str(params.get('target_dir', task))" not in src;
}


glob MULTIWRITE_IR: str = """---
name: picker
description: A model node that produces two carries.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  save:
    sig: "(chosen_file, note) -> str"
    surface: ACT
    doc: "Save the note."
    body: |
      def save(chosen_file, note):
          return str(chosen_file)
walker:
  name: PickAgent
  carries:
    task:        { type: str,  role: input }
    choice:      { type: dict, produced_by: choose }
    chosen_file: { type: path, produced_by: choose }
    note:        { type: str,  produced_by: choose }
    saved:       { type: str,  produced_by: store }
nodes:
  - id: choose
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [choice, chosen_file, note]
  - id: store
    type: ACT
    owner: code
    op: save
    tool: save
    reads: [chosen_file, note]
    writes: [saved]
  - id: done
    type: TERMINAL
edges:
  - {from: choose, to: store, modality: mandatory}
  - {from: store, to: done, modality: mandatory}
""";

test "a model node's writes AFTER the first are resolved, not left empty" {
    # Only writes[0] was assigned, so `chosen_file` stayed "" and the write step it feeds
    # became a silent no-op on an empty path.
    src = transpile_ir(MULTIWRITE_IR, "picker_multi");
    assert "self.choice = choose(" in src;
    assert '_unwrap(self.choice, "chosen_file", 1, False)' in src;
    assert '_unwrap(self.choice, "note", 2, False)' in src;
}


glob PY_MARKER_IR: str = """---
name: marker
description: A tool body that mentions the py-block marker.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  describe:
    sig: "(task) -> str"
    surface: SENSE
    doc: "Describe the jac py-block syntax."
    body: |
      def describe(task):
          # a Jac-authoring skill quotes the marker: ::py:: opens an inline block
          return "use ::py:: for inline python"
walker:
  name: MarkerAgent
  carries:
    task: { type: str, role: input }
    text: { type: str, produced_by: say }
nodes:
  - id: say
    type: SENSE
    owner: code
    op: describe
    tool: describe
    reads: [task]
    writes: [text]
  - id: done
    type: TERMINAL
edges:
  - {from: say, to: done, modality: mandatory}
""";

test "a py-block marker inside a tool body cannot split the emitted block" {
    # The delimiter is not line-anchored: an inner occurrence closed the block early and
    # the rest of the module (the entry point) was parsed as Jac.
    src = transpile_ir(PY_MARKER_IR, "marker_seal");
    body = src.split("::py::");
    assert len(body) == 3, "expected exactly one balanced py block, got "
        + str(len(body) - 1) + " delimiter(s)";
    assert ":: py ::" in src;                 # the inner marker was defused, not dropped
    assert "inline python" in src;            # …and the body still rode along
}


# ------------------------------------------------- sibling skills as run-time tools

glob SKILL_TOOL_IR: str = """
name: shelf_agent
standalone: true
shape: pipeline
types: {}
tools:
  read_rows:
    sig: "(path) -> list"
    surface: SENSE
    doc: "Read the rows."
    body: |
      def read_rows(path):
          return [1, 2, 3]
walker:
  name: ShelfAgent
  carries:
    task:  { type: str, role: input }
    notes: { type: str, produced_by: think }
    final: { type: str, produced_by: wrap }
nodes:
  - id: think
    type: GEN-RAW
    owner: model
    doc: "Work out what the rows say."
    reads: [task]
    writes: [notes]
    autonomy: { tools: [read_rows] }
  - id: wrap
    type: GEN-RAW
    owner: model
    doc: "Write the summary."
    reads: [notes]
    writes: [final]
  - id: done
    type: TERMINAL
    reads: [final]
edges:
  - {from: think, to: wrap, modality: mandatory}
  - {from: wrap, to: done, modality: mandatory}
""";

test "an autonomy slot can reach the rest of the library; a plain slot is untouched" {
    # A compiled skill handing a sub-job to another compiled skill: the shelf Sigil
    # publishes (SIGIL_SKILL_TOOLS) joins the tools the IR already gave the slot.
    # A slot with NO tools must stay toolless — tools turn a single typed
    # generation into a ReAct loop with a finish_tool, a different program.
    src = transpile_ir(SKILL_TOOL_IR, "shelf_agent");
    assert "def think(task: str) -> str by llm(tools=[read_rows, *_skill_tools()], max_tokens=" in src, src[-2000:];
    assert "def wrap(notes: str) -> str by llm(max_tokens=" in src, src[-2000:];
    # SPLAT, not `+`: the helper is defined in the ::py:: prelude, so `list + Unknown`
    # would be a type error and G4 (the compile oracle runs jac's checker) would fail.
    assert "] + _skill_tools()" not in src;
    assert "def _skill_tools():" in src;      # …and the helper actually ships
}

test "no shelf in the environment means no extra tools, so an eject stays standalone" {
    ns = _runtime_ns();
    ns["os"].environ.pop("SIGIL_SKILL_TOOLS", None);
    assert ns["_skill_tools"]() == [];
}

test "each shelf entry becomes one named, described tool" {
    import json;
    ns = _runtime_ns();
    ns["os"].environ["SIGIL_SKILL_TOOLS"] = json.dumps([
        {"name": "skill_clean_csv", "signature": "clean_csv",
         "module": "clean_csv_v1", "description": "Clean a messy CSV."}
    ]);
    tools = ns["_skill_tools"]();
    ns["os"].environ.pop("SIGIL_SKILL_TOOLS", None);
    assert len(list(tools)) == 1, str(tools);
    assert tools[0].get_name() == "skill_clean_csv";
    fn = tools[0].get_json_schema()["function"];
    assert "Clean a messy CSV" in str(fn["description"]);
    assert "task" in dict(fn["parameters"]["properties"]);
}

test "a malformed shelf is ignored, never raised" {
    # The manifest crosses a process boundary as text; a bad one must cost the
    # slot its extra tools, not the run.
    ns = _runtime_ns();
    ns["os"].environ["SIGIL_SKILL_TOOLS"] = "{not json";
    assert ns["_skill_tools"]() == [];
    ns["os"].environ["SIGIL_SKILL_TOOLS"] = "[{\"no_name\": 1}]";
    ns["_SKILL_TOOL_CACHE"] = None;
    assert ns["_skill_tools"]() == [];
    ns["os"].environ.pop("SIGIL_SKILL_TOOLS", None);
}

glob SEED_IR: str = """---
name: seeds
description: A model slot extracts a list from the task.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  fetch:
    sig: "(station_ids) -> str"
    surface: ACT
    doc: "Download for each station."
    body: |
      def fetch(station_ids):
          return ",".join(station_ids)
walker:
  name: SeedAgent
  carries:
    task:        { type: str,  role: input }
    station_ids: { type: list, produced_by: plan }
    data:        { type: str,  produced_by: pull }
nodes:
  - id: plan
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [station_ids]
    doc: "Extract the station ids the task names."
  - id: pull
    type: ACT
    owner: code
    op: fetch
    tool: fetch
    reads: [station_ids]
    writes: [data]
  - id: done
    type: TERMINAL
edges:
  - {from: plan, to: pull, modality: mandatory}
  - {from: pull, to: done, modality: mandatory}
""";

glob EMITCODE_IR: str = """---
name: emitcode
description: A tool that emits a python module as a string.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  build_module:
    sig: "(seed) -> str"
    surface: CODE
    doc: "Emit a runnable module."
    body: |
      def build_module(seed: str) -> str:
          src = '''import numpy as np
      from math import sin


      def plan(x):
          return sin(x)
      '''
          return src
walker:
  name: EmitAgent
  carries:
    task:   { type: str, role: input }
    seed:   { type: str, role: input }
    module: { type: str, produced_by: emit }
nodes:
  - id: emit
    type: CODE
    owner: code
    op: build_module
    tool: build_module
    reads: [seed]
    writes: [module]
    doc: "Emit the module."
  - id: done
    type: TERMINAL
edges:
  - {from: emit, to: done, modality: mandatory}
""";

test "a float carry is ASSIGNED through str(), the only wrap jac's float accepts" {
    # `int(_as_num(...))` checks clean but `float(_as_num(...))` does not: float's
    # parameter is `str | Buffer | SupportsFloat | SupportsIndex` and a py-block
    # return is Unknown, so the bare wrap raised E1053 and the artifact came out
    # `uncompilable` (first hit: mesh-analysis, the first skill with a float carry).
    src = transpile_ir(CARRY_IR, "carries_float");
    assert "self.ratio = float(str(_as_num(" in src;
    assert "self.ratio = float(_as_num(" not in src;
    assert "-> ratio (float); carry keeps default" not in src;
    # the SAME wrap on the ejected spawn line: `ratio=float(_as_param(...))`
    # raised E1053 too (8 SkillsBench trees came out `uncompilable` after the
    # carry arm was fixed: state-space-linearization, stepinfo-3d, ...)
    assert "float(_as_param(" not in src;
    if "_as_param(params.get('ratio'" in src {
        assert "ratio=float(str(_as_param(params.get('ratio', '', " in src or "ratio=float(str(_as_param(params.get('ratio', ''), " in src;
    }
}

test "the entry appends the deliverable-format contract, and the runtime recovers wrapped JSON" {
    src = transpile_ir(SEED_IR, "seedskill");
    assert "_format_contract(task)" in src, "format contract missing from the entry";
    assert "_note_task_text(" in src, "the entry must stash the task text for the schema check";
    ns = _runtime_ns();
    fc = ns["_format_contract"];
    assert "[DELIVERABLE FORMAT]" in fc("Save the answer to /root/mass_report.json");
    assert "[DELIVERABLE FORMAT]" not in fc("Write the summary to notes.md");
    ex = ns["_extract_json"];
    assert ex("```json\n{\"a\": 1}\n```") is not None;
    assert ex("Here you go: {\"a\": [1, 2]} -- done") is not None;
    assert ex("# Report\n\nprose only") is None;
    jg = ns["_json_guard"];
    assert jg("x.md", "# md")[0] == "# md";
    assert jg("x.json", "{\"k\": 1}")[1] == False;
    assert jg("x.json", "# md")[0] is None;
    # an unanchored save verb inside a path is not a save verb (civ6: /output/scenario_3.json)
    on = ns["_outname"];
    assert on("Save result to `/output/scenario_3.json` using the format below", "solution_json.out") == "/output/scenario_3.json";
}

test "the runtime writer skips empty content and the format contract exempts intermediate drafts" {
    import os;
    import tempfile;
    ns = _runtime_ns();
    d = tempfile.mkdtemp(prefix="sigil_wa_");
    open(d + "/answer.json", "w").write("{\"keep\": 1}");
    r = ns["_write_artifact"]("", d + "/answer.json");
    assert "skipped" in r and open(d + "/answer.json").read() == "{\"keep\": 1}", r;
    fc = ns["_format_contract"]("Save the answer to /root/answer.json");
    assert "intermediate steps" in fc and "deliverable FILE" in fc, fc;
}

test "list/dict carries are capped at MODEL slots, shape preserved; the runtime writer guards .csv" {
    # exoplanet gpt4o: {"time": [...], "flux": [...]} into choose_sigma -> 801,120 tokens on a 128k model
    ns = _runtime_ns();
    cs = ns["_cap_seq"];
    big = {"time": list(range(5000)), "flux": [0.5] * 5000, "meta": "x"};
    c = cs(big);
    assert isinstance(c, dict) and len(c["time"]) <= 401 and c["meta"] == "x", str(c)[:200];
    assert isinstance(cs(list(range(1000))), list) and len(list(cs(list(range(1000))))) <= 401;
    assert cs("plain") == "plain";
    src = transpile_ir(SEED_IR.replace("station_ids: { type: list, produced_by: plan }", "station_ids: { type: list, produced_by: plan }\n    curve: { type: dict, produced_by: plan }")
                       .replace("    writes: [station_ids]", "    writes: [station_ids, curve]")
                       .replace("  - id: pull\n    type: ACT\n    owner: code\n    op: fetch\n    tool: fetch\n    reads: [station_ids]",
                                "  - id: judge\n    type: GEN-ENUM\n    owner: model\n    reads: [task, curve]\n    writes: [data]\n    doc: \"Judge the curve.\"\n  - id: pull\n    type: ACT\n    owner: code\n    op: fetch\n    tool: fetch\n    reads: [station_ids]"), "seedskill");
    assert "dict(_cap_seq(self.curve))" in src, "dict carry not capped at the model slot";
    cg = ns["_csv_guard"];
    assert cg("x.csv", "# Report\n\nprose")[0] is None;
    assert cg("x.csv", "id,snr\n1,2\n")[0].startswith("id,snr");
    assert cg("x.csv", "see:\n```csv\nid,snr\n1,2\n```")[1] == True;
    assert cg("x.txt", "# Report")[0] == "# Report";
}

test "a code carry that does not parse is recovered from the shapes a model emits" {
    # drone glm: the planner source arrived as a preamble line + indented code -> IndentationError x3
    ns = _runtime_ns();
    sf = ns["_strip_fences"];
    assert sf("Here is the planner:\n```python\nimport math\ndef plan(x):\n    return x\n```\nUse it.") == "import math\ndef plan(x):\n    return x";
    assert sf("planner code\n    import math\n    def plan(x):\n        return x") == "import math\ndef plan(x):\n    return x";
    assert sf("```python\nprint(1)\n```") == "print(1)";
    # non-code text is never rewritten
    assert sf("# Report\n\nAll good: 3 of 3.") == "# Report\n\nAll good: 3 of 3.";
    assert sf("{\"a\": 1}") == "{\"a\": 1}";
}

test "a file the run wrote is never registered as an INPUT when re-read, so it can be rewritten" {
    # xlsx build/verify loop: repair_file.py written, re-read via _text_or_file (registered as input),
    # next write refused as "INPUT" -> the build step executed the refusal message as a shell command
    import os;
    import tempfile;
    ns = _runtime_ns();
    d = tempfile.mkdtemp(prefix="sigil_wr_");
    f = d + "/repair_file.py";
    assert ns["_write_artifact"]("print(1)", f) == f;
    ns["_note_input_path"](f);
    assert not ns["_is_input_path"](f), "a program-written file must not become an input";
    assert ns["_write_artifact"]("print(2)", f) == f and open(f).read() == "print(2)";
    # a genuine caller input still is one
    g = d + "/data.xlsx";
    open(g, "wb").write(b"PK\x03\x04");
    ns["_note_input_path"](g);
    assert ns["_is_input_path"](g);
}

test "a dict carry restores values the dict[str, str] widening flattened into reprs" {
    # byLLM cannot schematize a bare `dict`, so the slot is widened to dict[str, str] and
    # every value comes back a STRING. r2r-mpc-control's model_spec carries lists
    # ('states', 'inputs', 'f'); the consumer sympified "['T1', 'T2']" and died with
    # "could not parse '['" on BOTH runtimes — structural, not a model fault.
    ns = _runtime_ns();
    ad = ns["_as_dict"];
    d = ad({"states": "['T1', 'T2']", "f": "[\"-a*T1 + u1\", \"-b*T2\"]", "dt": "0.01", "note": "linearize [around] the reference"}, {});
    assert d["states"] == ["T1", "T2"], "python-literal list not restored: " + str(d["states"]);
    assert d["f"] == ["-a*T1 + u1", "-b*T2"], "JSON list not restored: " + str(d["f"]);
    assert d["dt"] == "0.01", "a scalar string must not be touched";
    assert d["note"] == "linearize [around] the reference", "prose containing a bracket must not be touched";
    # nested one level deeper, and a JSON-object string carry
    d2 = ad("{\"x_ref\": \"{\\\"T1\\\": 0.5}\", \"u\": \"[1, 2]\"}", {});
    assert d2["x_ref"] == {"T1": 0.5}, str(d2);
    assert d2["u"] == [1, 2], str(d2);
    # totality is unchanged: a non-mapping keeps the default
    assert ad(42, {"k": 1}) == {"k": 1};
}

test "a tool body's multi-line string literal is emitted verbatim, not re-indented" {
    # drone-planning-control: the emitter prefixed 4 spaces to EVERY line of the body,
    # so `src = '''import numpy...'''` came back valid on line 1 and indented on every
    # line after it; exec(planner_src) died with IndentationError on both runtimes.
    src = transpile_ir(EMITCODE_IR, "emitcode");
    L = src.splitlines();
    i = next((k for (k, ln) in enumerate(L) if "src = " in ln and "import numpy as np" in ln), -1);
    assert i >= 0, "emitted body not found; lines mentioning the body: " + str([ln[:70] for ln in L if ("build_module" in ln) or ("numpy" in ln) or ("sin(" in ln) or ("refused to emit" in ln)][:8]);
    assert L[i + 1] == "from math import sin", "string interior was re-indented: " + repr(L[i + 1]);
    assert L[i + 4] == "def plan(x):", "string interior line 4: " + repr(L[i + 4]);
    assert L[i + 5] == "    return sin(x)", "real indentation inside the emitted module must survive: " + repr(L[i + 5]);
    # the body's own STATEMENTS are still nested inside the impl wrapper
    assert "    def build_module(" in src, "tool body should stay nested in its __impl";
    assert "        return src" in src, "body statements must still be indented";
    # and the whole python block still parses
    py = src.split("::py::")[1];
    ast.parse(py);
}

test "a path the task names as the DESTINATION is not registered as an input" {
    # crystallographic-wyckoff: "Write your script at: /root/workspace/solution.py" registered the
    # deliverable as an INPUT, so the write guard refused it and wrote solution.py.out instead —
    # the verifier found no solution and both runtimes scored 0.36 against prose 0.45.
    import os;
    import tempfile;
    ns = _runtime_ns();
    d = tempfile.mkdtemp();
    src = os.path.join(d, "data.csv");
    dst = os.path.join(d, "solution.py");
    open(src, "w").write("a,b\n1,2\n");
    open(dst, "w").write("# stub\n");          # a stub already sitting at the destination
    ns["_INPUT_PATHS"].clear();
    task = "Read the measurements in " + src + " and write your script at: " + dst;
    ns["_note_task_files"](task, "");
    assert ns["_is_input_path"](src), "a file the task READS must still be an input";
    assert not ns["_is_input_path"](dst), "a file the task says to WRITE must never be an input";
}

test "a JSON deliverable that misses the schema the task shows says so" {
    # energy-market-pricing: the task shows {"base_case": ..., "counterfactual": ...}; the LMP
    # skill wrote its own generic report.json and reported the path as success, and the verifier
    # failed on a missing base_case. A generic tool cannot know the shape — but it can say so.
    import os;
    import tempfile;
    ns = _runtime_ns();
    d = tempfile.mkdtemp();
    task = "Analyse the network. Finally, create report.json with the following structure:\n```json\n{\n  \"base_case\": {\"total_cost\": 1.0},\n  \"counterfactual\": {\"total_cost\": 2.0}\n}\n```\n";
    ns["_note_task_text"](task);
    gap = ns["_schema_gap"](os.path.join(d, "report.json"), "{\"lmp_by_bus\": []}");
    assert "schema gap" in gap, "a missing top-level key must be named: " + repr(gap);
    assert "base_case" in gap and "counterfactual" in gap, gap;
    # a conforming document says nothing
    ok = ns["_schema_gap"](os.path.join(d, "report.json"), "{\"base_case\": {}, \"counterfactual\": {}}");
    assert ok == "", repr(ok);
    # and a non-JSON destination is never second-guessed
    assert ns["_schema_gap"](os.path.join(d, "notes.md"), "# hello") == "";
}

# PIP NOISE. An installer the caller did not capture wrote pip's own diagnostics —
# a ~20K-char traceback on a failed build — into the terminal of whoever called the
# program; the agent read all of it on every call (SkillsBench travel: 20,124 of
# 27,206 chars). Uncaptured installs now go to a log; captured output is untouched.
import from .compiler.mechanical.envbind { preflight_src }

::py::
def _popen_probe(ns):
    """Drive the runtime's Popen wrapper with a stand-in for the real __init__ and
    return the keyword arguments each call would have spawned with."""
    seen = []
    def fake(self, args, *a, **kw):
        seen.append(dict(kw))
    ns["_orig_popen_init"] = fake
    pin = ns["_popen_init"]
    pin(None, ["python3", "-m", "pip", "install", "pandas"])
    pin(None, ["python3", "-m", "pip", "install", "pandas"], stdout=-1, stderr=-1)
    pin(None, ["python3", "script.py"])
    return seen
::py::

test "an uncaptured pip install is routed to a log; everything else is untouched" {
    ns = _runtime_ns();
    isp = ns["_is_pip_install"];
    assert isp(["/usr/bin/python3", "-m", "pip", "install", "pandas"]);
    assert isp(["pip", "install", "-q", "pandas"]);
    assert isp("pip3 install pandas==2.0");
    assert isp(["/opt/venv/bin/pip", "install", "x"]);
    assert not isp(["python3", "-m", "pip", "list"]);
    assert not isp(["python3", "script.py", "install"]);
    assert not isp("echo pip install");
    seen = _popen_probe(ns);
    # an uncaptured installer is diverted to the log
    assert ("stdout" in seen[0]) and ("stderr" in seen[0]);
    assert str(seen[0]["stderr"].name).endswith(".log");
    # a caller's own capture always wins
    assert (seen[1]["stdout"] == -1) and (seen[1]["stderr"] == -1);
    # anything that is not an installer is untouched
    assert "stdout" not in seen[2];
}

test "the dependency preflight captures every pip call it makes" {
    pf = preflight_src({"py": {"pandas": {"pip": "pandas"}}, "bin": {}});
    runs = [ln for ln in pf.split("\n") if "_sp.run(" in ln];
    assert len(runs) >= 3, pf[:400];
    for ln in runs { assert "capture_output=True" in ln, ln; }
}

test "the tuning hooks are default-on with an opt-out, and SIGIL_THINK stays opt-in" {
    rt = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "compiler", "mechanical", "assets", "osp_runtime.py.txt")).read();
    # the Popen patch is global, so it has a switch; the litellm hook only installs when asked
    assert "if _sigil_on(\"SUBPROCESS_FIX\"):" in rt;
    assert "if mode in (\"\", \"off\", \"default\"):" in rt;
    pf = preflight_src({"py": {"pandas": {"pip": "pandas"}}, "bin": {}});
    assert "SIGIL_VERSION_PARITY" in pf, "version parity has no opt-out";
}
