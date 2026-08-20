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
          return {"bundle": {"n": 1}, "rounds": 1}
walker:
  name: CarryAgent
  carries:
    task:     { type: str,  role: input }
    bundle:   { type: dict, produced_by: collect }
    rounds:   { type: int,  produced_by: collect }
nodes:
  - id: collect
    type: SENSE
    owner: code
    op: gather
    tool: gather
    reads: [task]
    writes: [bundle, rounds]
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
    assert "def think(task: str) -> str by llm(tools=[read_rows, *_skill_tools()]);" in src, src[-2000:];
    assert "def wrap(notes: str) -> str by llm;" in src, src[-2000:];
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
    assert len(tools) == 1, str(tools);
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
