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
    # (pass 11: the slot returns a typed object — one field per carry — and every
    # carry, the first included, is read from it; the positional _unwrap is gone)
    assert "_rw = choose(" in src, "multi-write slot must bind its typed return";
    assert '_field(_rw, "choice")' in src, "first carry not read from the object";
    assert '_field(_rw, "chosen_file")' in src;
    assert '_field(_rw, "note")' in src;
    assert "obj ChooseOut {" in src and "-> ChooseOut by llm" in src;
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
    # would be a type error and COMPILE (the compile oracle runs jac's checker) would fail.
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

# An xlsx-shaped pipeline: a GEN writes script source, an ACT saves it, a third
# node RUNS it. `script_file` is read downstream, so it is scratch — and the task
# names exactly one file, the deliverable.
glob SCRATCH_IR: str = """---
name: scratch
description: Build a workbook via a generated script.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  write_file:
    sig: "(path, content) -> str"
    surface: ACT
    doc: "Write content to path."
    body: |
      def write_file(path, content):
          open(path, "w").write(content or "")
          return path
  run_script:
    sig: "(script_path) -> str"
    surface: ACT
    doc: "Run the build script."
    body: |
      def run_script(script_path):
          return "ran " + str(script_path)
walker:
  name: ScratchAgent
  carries:
    task:          { type: str, role: input }
    script_source: { type: str, produced_by: author }
    script_file:   { type: str, produced_by: save }
    build_log:     { type: str, produced_by: run }
nodes:
  - id: author
    type: GEN-RAW
    owner: model
    op: author
    reads: [task]
    writes: [script_source]
  - id: save
    type: ACT
    owner: code
    op: write_file
    tool: write_file
    reads: [script_source]
    writes: [script_file]
  - id: run
    type: ACT
    owner: code
    op: run_script
    tool: run_script
    reads: [script_file]
    writes: [build_log]
  - id: done
    type: TERMINAL
edges:
  - {from: author, to: save, modality: mandatory}
  - {from: save, to: run, modality: mandatory}
  - {from: run, to: done, modality: mandatory}
""";

test "an INTERMEDIATE write never takes a filename mined from the task" {
    # `script_file` is read by `run`, so it is scratch. Binding it through
    # _outname gave it the only filename the task mentioned — the deliverable —
    # and the xlsx skill wrote its own Python source over gdp_modified.xlsx,
    # failing every check in load_workbook.
    src = transpile_ir(SCRATCH_IR, "scratch_out");
    assert "_write_file(\"script_file.out\"" in src;
    assert "_outname(self.task, \"script_file.out\")" not in src;
}

# xlsx's real shape: a GEN writes repair_code, an ACT saves it, and NOTHING runs
# it — the IR never wires the execution node. `repair_file` is therefore read by
# no one, so the reads-based intermediate rule cannot see it is scratch.
glob CODEWRITE_IR: str = """---
name: codewrite
description: Save a generated repair script; nothing reads it back.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  write_file:
    sig: "(path, content) -> str"
    surface: ACT
    doc: "Write content to path."
    body: |
      def write_file(path, content):
          open(path, "w").write(content or "")
          return path
walker:
  name: CodeWriteAgent
  carries:
    task:        { type: str, role: input }
    repair_code: { type: str, produced_by: author }
    repair_file: { type: str, produced_by: save }
nodes:
  - id: author
    type: GEN-RAW
    owner: model
    op: author
    reads: [task]
    writes: [repair_code]
  - id: save
    type: ACT
    owner: code
    op: write_file
    tool: write_file
    reads: [repair_code]
    writes: [repair_file]
  - id: done
    type: TERMINAL
edges:
  - {from: author, to: save, modality: mandatory}
  - {from: save, to: done, modality: mandatory}
""";

test "a write fed by GENERATED CODE never takes the task's filename" {
    # `repair_file` is read by no node, so the reads-based rule is blind to it;
    # its CONTENT carry (`repair_code`) is what says it is a script. Before this,
    # _outname gave it gdp_modified.xlsx — the only filename the task named — and
    # the xlsx skill wrote its own Python over the deliverable.
    src = transpile_ir(CODEWRITE_IR, "codewrite_out");
    assert "_outname(self.task" not in src;
    assert "repair_file.out" in src;
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

test "a model-extracted collection gets an OPTIONAL seed-file input" {
    # flood-risk-analysis: the task said "stations are in /root/data/x.txt" but
    # usgs-data-download advertised ['output_path'] only — the extractor could
    # see nothing but the caller's task string. The lowering now mints
    # `<carry>_path` for every list/dict carry a model slot extracts from `task`
    # and splices the file's text into the task that slot reads.
    src = transpile_ir(SEED_IR, "seeds");
    assert "'station_ids_path'" in src;
    assert "_seed_file_text(params.get('station_ids_path', '') or _task_file_path_for('station_ids', task)) or _seed_file_text(_task_input_file(task, params.get('output_path', '')), 8000)" in src;
    assert "if _seed_txt { task = str(task) + _seed_txt; }" in src;
    # every run registers the files the task names as inputs before any write
    assert "_note_task_files(task, params.get('output_path', ''));" in src;
    # a CODE parser of the task that produces a collection gets one too (a regex
    # over the task string cannot see the file the task points at: usgs-data-download)
    src2 = transpile_ir(CARRY_IR, "carries_seed");
    assert "'bundle_path'" in src2;
}

glob WHEN_IR: str = """---
name: whenroute
description: A route whose edges say `when:` instead of `guard:`.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  probe:
    sig: "(task) -> bool"
    surface: SENSE
    doc: "Decide."
    body: |
      def probe(task):
          return "yes" in task
  left:
    sig: "(task) -> str"
    surface: ACT
    doc: "Left."
    body: |
      def left(task):
          return "L"
  right:
    sig: "(task) -> str"
    surface: ACT
    doc: "Right."
    body: |
      def right(task):
          return "R"
walker:
  name: WhenAgent
  carries:
    task: { type: str,  role: input }
    flag: { type: bool, produced_by: decide }
    out:  { type: str,  produced_by: go_left }
    out2: { type: str,  produced_by: go_right }
nodes:
  - id: decide
    type: SENSE
    owner: code
    op: probe
    tool: probe
    reads: [task]
    writes: [flag]
  - id: route
    type: DECIDE
    owner: code
    reads: [flag]
    writes: []
  - id: go_left
    type: ACT
    owner: code
    op: left
    tool: left
    reads: [task]
    writes: [out]
  - id: go_right
    type: ACT
    owner: code
    op: right
    tool: right
    reads: [task]
    writes: [out2]
  - id: done
    type: TERMINAL
edges:
  - {from: decide, to: route, modality: mandatory}
  - {from: route, to: go_left,  modality: conditional, when: "flag"}
  - {from: route, to: go_right, modality: conditional, when: "not flag"}
  - {from: go_left, to: done, modality: mandatory}
  - {from: go_right, to: done, modality: mandatory}
""";

test "an edge condition written as `when:` lowers as a real branch" {
    # 6 of the 8 conditional edges across the SkillsBench IRs said `when:`;
    # every reader keyed on `guard`, so the route visited only its LAST target
    # (pdf/route_fillability: every fillable form went down the flat-form path).
    src = transpile_ir(WHEN_IR, "whenroute");
    assert "if self.flag { visit [-->][?:GoLeft]; }" in src;
    assert "GoRight" in src;
    assert "visit [-->][?:GoRight];" in src;
}

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

test "a task-only extractor is seeded with the ONE input document the task names" {
    # citation-check: `identifiers` was drafted by a model slot from the task text while
    # the entries lived in /root/test.bib -> "zero entries" -> answer.json empty (5/9, both runtimes)
    import os;
    import tempfile;
    ns = _runtime_ns();
    d = tempfile.mkdtemp(prefix="sigil_seed_");
    bib = os.path.join(d, "test.bib");
    open(bib, "w").write("@article{smith2020ai, title={Advances in AI}}\n");
    task = "Validate the citations in " + bib + " and write /root/answer.json";
    ns["_note_task_files"](task, "/root/answer.json");
    assert ns["_task_input_file"](task, "/root/answer.json") == bib;
    assert "smith2020ai" in ns["_seed_file_text"](ns["_task_input_file"](task), 8000);
    # two candidates = ambiguous = no default
    other = os.path.join(d, "notes.txt");
    open(other, "w").write("x");
    task2 = task + " using " + other;
    ns["_note_task_files"](task2, "/root/answer.json");
    assert ns["_task_input_file"](task2, "/root/answer.json") == "";
    # the registry runs BEFORE the seed block in the emitted entry
    src = transpile_ir(SEED_IR, "seedskill");
    assert src.index("_note_task_files(task") < src.index("_seed_txt: str"), "input registry must precede the seed block";
}

test "the program advertises what it IMPLEMENTS (purpose + steps) for the tool contract" {
    src = transpile_ir(SEED_IR, "seedskill");
    assert "glob _EJ_PURPOSE: str = " in src, "purpose global missing";
    # the LIFT's description lives in the AGIR front matter (`_frontmatter`), not the body
    assert "A model slot extracts a list from the task." in src.split("glob _EJ_PURPOSE")[1].split("\n")[0], src.split("glob _EJ_PURPOSE")[1].split("\n")[0];
    assert "glob _EJ_STEPS: list[any] = [" in src, "steps global missing";
    # the MCP server source composes the description from them
    import from .compiler.ai.eject { _MCP_SERVE_SRC }
    assert "COMPILED PROCEDURE: " in _MCP_SERVE_SRC and "Steps it executes" in _MCP_SERVE_SRC;
    assert "def _mcp_serve(run_fn, model_cls, keys, name, model_name, docs=None, purpose=\"\", steps=None)" in _MCP_SERVE_SRC;
    ns: dict[str, any] = {"__builtins__": __builtins__};
    exec(_MCP_SERVE_SRC, ns);
    d = ns["_mcp_description"]("pdf", "Fill PDF forms following forms.md.", ["detect_fillable", "extract_field_info", "fill_fields"]);
    assert d.startswith("COMPILED PROCEDURE: Fill PDF forms"), d[:80];
    assert "detect_fillable -> extract_field_info -> fill_fields" in d, d;
    assert "DIFFERENT operation" in d;
}

glob DIAMOND_IR: str = """---
name: diamond
description: Two branches that rejoin.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools: {}
walker:
  name: DiamondAgent
  carries:
    task: { type: str, role: input }
    x:    { type: str, produced_by: a }
    y:    { type: str, produced_by: b }
    z:    { type: str, produced_by: c }
    w:    { type: str, produced_by: d }
nodes:
  - id: a
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [x]
    doc: "Draft x."
  - id: b
    type: GEN-RAW
    owner: model
    reads: [x]
    writes: [y]
    doc: "Draft y from x."
  - id: c
    type: GEN-RAW
    owner: model
    reads: [x]
    writes: [z]
    doc: "Draft z from x."
  - id: d
    type: GEN-RAW
    owner: model
    reads: [y, z]
    writes: [w]
    doc: "Combine y and z."
  - id: done
    type: TERMINAL
edges:
  - {from: a, to: b, modality: mandatory}
  - {from: a, to: c, modality: mandatory}
  - {from: b, to: d, modality: mandatory}
  - {from: c, to: d, modality: mandatory}
  - {from: d, to: done, modality: mandatory}
""";

test "a DAG join executes once, on its last arrival (not once per incoming path)" {
    # citation-management: 42 nodes / 48 edges -> 122 node visits, every report empty
    src = transpile_ir(DIAMOND_IR, "diamond");
    assert 'if not _join_arrive("d", 2) { return; }' in src, "join gate missing on d";
    assert '_join_arrive("b"' not in src and '_join_arrive("a"' not in src and '_join_arrive("done"' not in src, "gate on a non-join";
    assert "_join_reset();" in src, "per-run reset missing";
    # the gate precedes the node's progress mark, so early arrivals leave no trace
    assert src.index('_join_arrive("d", 2)') < src.index('_progress("d")');
    ns = _runtime_ns();
    ja = ns["_join_arrive"];
    ns["_join_reset"]();
    assert ja("d", 2) == False;
    assert ja("d", 2) == True;
    assert ja("d", 2) == False;      # a fresh round counts again
    ns["_join_reset"]();
    assert ja("d", 2) == False;
    # a route alternative into the node is NOT a pure join: no gate
    # a conditional in-edge makes the arrival count a RUNTIME expression: the
    # unconditional branch counts 1, the guarded one counts only when its guard holds
    routed = DIAMOND_IR.replace("  - {from: c, to: d, modality: mandatory}", "  - {from: c, to: d, modality: conditional, when: \"x\"}");
    src2 = transpile_ir(routed, "diamond2");
    assert re.search(r'_join_arrive\("d", max\(1, 1 \+ \(1 if \(.*self\.x.*\) else 0\)\)\)', src2), "guarded in-edge should count conditionally: " + str([l for l in src2.split("\n") if "_join_arrive(" in l]);
}

glob ROUTE_MERGE_IR: str = """---
name: merge
description: Two route arms that merge at the terminal.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools: {}
walker:
  name: MergeAgent
  carries:
    task:  { type: str, role: input }
    wants: { type: bool, produced_by: classify }
    a_out: { type: str, produced_by: a }
    b_out: { type: str, produced_by: b }
    c_out: { type: str, produced_by: c }
nodes:
  - id: classify
    type: GEN-ENUM
    owner: model
    reads: [task]
    writes: [wants]
    doc: "true when the task wants arm a."
  - id: route
    type: ROUTE
    owner: code
    reads: [wants]
    writes: []
    doc: "Pick the arm."
  - id: a
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [a_out]
    doc: "Arm a."
  - id: b
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [b_out]
    doc: "Arm b, step 1."
  - id: c
    type: GEN-RAW
    owner: model
    reads: [b_out]
    writes: [c_out]
    doc: "Arm b, step 2."
  - id: done
    type: TERMINAL
edges:
  - {from: classify, to: route, modality: mandatory}
  - {from: route, to: a, modality: conditional, when: "wants"}
  - {from: route, to: b, modality: conditional, when: "not wants"}
  - {from: a, to: done, modality: mandatory}
  - {from: b, to: c, modality: mandatory}
  - {from: c, to: done, modality: mandatory}
""";

test "a TERMINAL reached from ALTERNATIVE route arms waits only for the arm that ran" {
    # citation-management: the validation arm reached `done` once, the static gate
    # wanted 4 (one per in-edge), the tool reported INCOMPLETE over a written report
    src = transpile_ir(ROUTE_MERGE_IR, "merge");
    gates = [l for l in src.split("\n") if "_join_arrive(" in l and "def " not in l];
    assert len(gates) == 1, "exactly one gate expected: " + str(gates);
    g = gates[0];
    assert '_join_arrive("done", max(1, ' in g, "arrival count must be a runtime expression: " + g;
    assert '_join_arrive("done", 2)' not in src, "static count over alternative arms";
    assert re.search(r'\(1 if \(.*wants.*\) else 0\) \+ \(1 if \(.*wants.*\) else 0\)', g), "one guarded term per arm: " + g;
    # the runtime: an arrival count of 1 passes on the first arrival
    ns = _runtime_ns();
    ns["_join_reset"]();
    assert ns["_join_arrive"]("done", max(1, 1 + 0)) == True;
    # a route's unguarded (else) edge counts when NONE of its guarded siblings holds
    dflt = ROUTE_MERGE_IR.replace('  - {from: route, to: b, modality: conditional, when: "not wants"}', "  - {from: route, to: b, modality: mandatory}");
    src3 = transpile_ir(dflt, "merge3");
    g3 = [l for l in src3.split("\n") if '_join_arrive("done"' in l][0];
    assert "not (" in g3, "default arm should be the negation of the guarded arms: " + g3;
    # a plain fork-join (DIAMOND) keeps its static count
    assert 'if not _join_arrive("d", 2) { return; }' in transpile_ir(DIAMOND_IR, "diamond");
}

glob TWO_WRITES_IR: str = """---
name: nws
description: A model node fills two carries.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  http_get:
    sig: "(url) -> str"
    surface: SENSE
    doc: "GET a url."
    body: |
      def http_get(url):
          return "csv"
walker:
  name: NwsAgent
  carries:
    task:       { type: str, role: input }
    nws_url:    { type: str, produced_by: pick_state }
    state_code: { type: str, produced_by: pick_state }
    csv_text:   { type: str, produced_by: download }
nodes:
  - id: pick_state
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [nws_url, state_code]
    doc: "From the task, fill two fields: state_code (two letters) and nws_url (the bulk CSV)."
  - id: download
    type: SENSE
    owner: code
    op: http_get
    tool: http_get
    reads: [nws_url]
    writes: [csv_text]
  - id: done
    type: TERMINAL
edges:
  - {from: pick_state, to: download, modality: mandatory}
  - {from: download, to: done, modality: mandatory}
""";

test "a model node that writes several carries returns a typed object, one field per carry" {
    # nws-flood-thresholds: `pick_state` writes nws_url AND state_code; the str-slot lowering put the
    # model's whole "two fields" reply into nws_url (http_get: not a url) and left state_code "" ->
    # header-only table, flood-risk-analysis 1/2 on both runtimes (prose 2/2). 46 artifacts / 34 tasks.
    src = transpile_ir(TWO_WRITES_IR, "nws");
    assert "obj PickStateOut {" in src, "typed return object missing";
    assert "    has nws_url: str = \"\";" in src and "    has state_code: str = \"\";" in src, src[src.index("obj PickStateOut"):src.index("obj PickStateOut") + 200];
    assert "-> PickStateOut by llm" in src, "slot must return the object";
    assert "_rw = pick_state(" in src;
    assert 'self.nws_url = str(_strip_fences(_field(_rw, "nws_url")));' in src, "first carry not read from the object";
    assert 'self.state_code = str(_strip_fences(_field(_rw, "state_code")));' in src, "second carry not read from the object";
    assert "_unwrap(self.nws_url" not in src, "legacy positional unwrap still emitted";
    ns = _runtime_ns();
    fld = ns["_field"];
    import types;
    o = types.SimpleNamespace(nws_url="https://x");
    assert fld(o, "nws_url") == "https://x" and fld(o, "missing") == "" and fld({"a": 1}, "a") == 1 and fld(None, "a") == "";
    # a single-write model node keeps the plain typed slot
    single = transpile_ir(SEED_IR, "seedskill");
    assert "Out {" not in single.split("COGNITIVE SLOTS")[-1][:400], "single-write slot must not grow an object";
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

test "the terminal report surfaces the run's assessment carries, not only delivered files" {
    # citation-management: the report listed five empty *_file paths while report_json and
    # review_notes (which records failed to resolve) sat one field away, unread by the caller
    ir = SEED_IR.replace("    data:        { type: str,  produced_by: pull }",
                         "    data:        { type: str,  produced_by: pull }\n    review_notes: { type: str, produced_by: review }");
    ir = ir.replace("  - id: done\n    type: TERMINAL",
                    "  - id: review\n    type: GEN-RAW\n    owner: model\n    reads: [data]\n    writes: [review_notes]\n    doc: \"Assess the download.\"\n  - id: done\n    type: TERMINAL");
    ir = ir.replace("  - {from: pull, to: done, modality: mandatory}",
                    "  - {from: pull, to: review, modality: mandatory}\n  - {from: review, to: done, modality: mandatory}");
    # with a real deliverable the report used to list ONLY that file: the notes must ride along
    ir = ir.replace("    review_notes: { type: str, produced_by: review }",
                    "    review_notes: { type: str, produced_by: review }\n    saved: { type: str, produced_by: save }");
    ir = ir.replace("  - id: done\n    type: TERMINAL",
                    "  - id: save\n    type: ACT\n    owner: code\n    surface: ACT·artifact\n    op: fetch\n    tool: fetch\n    reads: [station_ids]\n    writes: [saved]\n  - id: done\n    type: TERMINAL");
    ir = ir.replace("  - {from: review, to: done, modality: mandatory}",
                    "  - {from: review, to: save, modality: mandatory}\n  - {from: save, to: done, modality: mandatory}");
    src = transpile_ir(ir, "seedskill");
    assert "saved={_artifact_text(self.saved, 1200)}" in src, "deliverable missing from the terminal report";
    assert "review_notes={str(self.review_notes)[:3000]}" in src, "assessment carry missing from the terminal report";
    # a plain data carry is not an assessment: never dumped into the report
    assert "data={str(self.data)[:3000]}" not in src;
}

test "assessment carries lead the fallback report too, and an empty str slot retries without thinking" {
    # no deliverable: the report used to list only the latest sinks (file carries) at 300 chars
    ir = SEED_IR.replace("    data:        { type: str,  produced_by: pull }",
                         "    data:        { type: str,  produced_by: pull }\n    review_notes: { type: str, produced_by: review }");
    ir = ir.replace("  - id: done\n    type: TERMINAL",
                    "  - id: review\n    type: GEN-RAW\n    owner: model\n    reads: [data]\n    writes: [review_notes]\n    doc: \"Assess the download.\"\n  - id: done\n    type: TERMINAL");
    ir = ir.replace("  - {from: pull, to: done, modality: mandatory}",
                    "  - {from: pull, to: review, modality: mandatory}\n  - {from: review, to: done, modality: mandatory}");
    src = transpile_ir(ir, "seedskill");
    rep = [l for l in src.splitlines() if "self.report = f" in l][0];
    assert "review_notes={str(self.review_notes)[:3000]}" in rep, rep;
    # the retry: a str GEN slot that came back empty runs once more under _nothink_push
    d = transpile_ir(DIAMOND_IR, "diamond");
    assert "if not str(self.x).strip() { _nothink_push(); self.x = str(_strip_fences(a(" in d, "no-think retry missing";
    ns = _runtime_ns();
    import os;
    os.environ["SIGIL_THINK"] = "low";
    ns["_nothink_push"]();
    assert os.environ["SIGIL_THINK"] == "false";
    ns["_nothink_pop"]();
    assert os.environ["SIGIL_THINK"] == "low";
    del os.environ["SIGIL_THINK"];
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

test "a code carry's write destination is a derived script name, never the caller's path input" {
    # xlsx: `_write_file((self.path or ...), self.repair_code)` wrote the repair script INTO the workbook
    ir = SEED_IR.replace("    data:        { type: str,  produced_by: pull }",
                         "    data:        { type: str,  produced_by: pull }\n    repair_code: { type: str, produced_by: plan }\n    repair_file: { type: str, produced_by: save }\n    path: { type: path, role: input }");
    ir = ir.replace("    writes: [station_ids]", "    writes: [station_ids, repair_code]");
    ir = ir.replace("tools:\n  fetch:", "tools:\n  write_file:\n    sig: \"(path, content) -> str\"\n    surface: ACT\n    doc: \"Write text.\"\n    body: |\n      def write_file(path, content):\n          return path\n  fetch:");
    ir = ir.replace("  - id: done\n    type: TERMINAL", "  - id: save\n    type: ACT\n    owner: code\n    op: write_file\n    tool: write_file\n    reads: [repair_code]\n    writes: [repair_file]\n  - id: done\n    type: TERMINAL");
    ir = ir.replace("  - {from: pull, to: done, modality: mandatory}", "  - {from: pull, to: save, modality: mandatory}\n  - {from: save, to: done, modality: mandatory}");
    src = transpile_ir(ir, "seedskill");
    line = [l for l in src.splitlines() if "self.repair_file = " in l][0];
    assert "self.path or" not in line, line;
    assert '"repair_file.py"' in line, line;
    ns = _runtime_ns();
    import tempfile;
    d = tempfile.mkdtemp(prefix="sigil_wab_");
    open(d + "/b.xlsx", "wb").write(b"PK\x03\x04x");
    r = ns["_write_artifact"]("import x", d + "/b.xlsx");
    assert "binary document format" in r and open(d + "/b.xlsx", "rb").read() == b"PK\x03\x04x";
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

test "a code carry never targets the caller's path even when that path is also a read; string-wrapped scripts unwrap" {
    ir = SEED_IR.replace("    data:        { type: str,  produced_by: pull }",
                         "    data:        { type: str,  produced_by: pull }\n    build_code_final: { type: str, produced_by: plan }\n    script_file: { type: str, produced_by: save }\n    path: { type: path, role: input }");
    ir = ir.replace("    writes: [station_ids]", "    writes: [station_ids, build_code_final]");
    ir = ir.replace("tools:\n  fetch:", "tools:\n  write_file:\n    sig: \"(path, content) -> str\"\n    surface: ACT\n    doc: \"Write text.\"\n    body: |\n      def write_file(path, content):\n          return path\n  fetch:");
    ir = ir.replace("  - id: done\n    type: TERMINAL", "  - id: save\n    type: ACT\n    owner: code\n    op: write_file\n    tool: write_file\n    reads: [path, build_code_final]\n    writes: [script_file]\n  - id: done\n    type: TERMINAL");
    ir = ir.replace("  - {from: pull, to: done, modality: mandatory}", "  - {from: pull, to: save, modality: mandatory}\n  - {from: save, to: done, modality: mandatory}");
    src = transpile_ir(ir, "seedskill");
    line = [l for l in src.splitlines() if "self.script_file = " in l][0];
    assert "self.path" not in line and '"script_file.py"' in line, line;
    ns = _runtime_ns();
    sf = ns["_strip_fences"];
    assert sf("build_code = ('from openpyxl import load_workbook\\n' 'wb = load_workbook(\"x.xlsx\")\\n' 'wb.save(\"x.xlsx\")\\n')") == "from openpyxl import load_workbook\nwb = load_workbook(\"x.xlsx\")\nwb.save(\"x.xlsx\")";
    assert sf("x = 1\ny = x + 1") == "x = 1\ny = x + 1";
}

glob OUTPATH_IR: str = """---
name: outpath
description: A report writer whose destination is the caller's output_path.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  write_file:
    surface: ACT·artifact
    serves: [write_report]
    doc: "The builtin writer, bound to the report node the way the LIFT declares it."
walker:
  name: OutpathAgent
  carries:
    task:        { type: str, role: input }
    output_path: { type: path, role: input, doc: "Path where this run should WRITE the report." }
    report_md:   { type: str, produced_by: draft }
    report_file: { type: str, produced_by: write_report }
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [report_md]
    doc: "Draft the report."
  - id: write_report
    type: ACT
    owner: code
    op: write_file
    tool: write_file
    reads: [report_md, output_path]
    writes: [report_file]
    doc: "Write the report to the file named in the task."
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: write_report, modality: mandatory}
  - {from: write_report, to: done, modality: mandatory}
""";

test "a write that reads the caller's output_path writes THERE, with the task filename only as fallback" {
    # react-best-practices: write_report read [report_md, output_path] and still
    # lowered to _outname(self.task, "report_file.out"): the declared-input skip
    # (meant for docx's template_file) swallowed the destination, so --output_path=
    # was echoed as bound and ignored. glm's cell only "worked" because the agent's
    # sentence happened to contain the filename.
    src = transpile_ir(OUTPATH_IR, "outpath");
    cands = [l for l in src.split("\n") if ("report_md" in l) and ("write" in l.lower()) and ("has " not in l)];
    assert cands, "no write line found; write-ish lines: " + str([l.strip()[:160] for l in src.split("\n") if ("_write_" in l) or ("n_write_report" in l)][:8]);
    line = cands[0];
    assert '(self.output_path or _outname(self.task, "report_file.out"))' in line, "destination must be the caller's output_path: " + line;
    assert "_inname(self.task)" not in line, "output_path is a destination, not a source: " + line;
    # the docx case is unchanged: a declared INPUT that is a source never becomes the destination
    tmpl = OUTPATH_IR.replace("output_path: { type: path, role: input, doc: \"Path where this run should WRITE the report.\" }", "template_file: { type: path, role: input, doc: \"The .docx template this run reads.\" }").replace("reads: [report_md, output_path]", "reads: [report_md, template_file]");
    src2 = transpile_ir(tmpl, "outpath2");
    line2 = [l for l in src2.split("\n") if ("report_md" in l) and ("write" in l.lower()) and ("has " not in l)][0];
    assert "self.template_file" not in line2.split(", self.report_md")[0] if ", self.report_md" in line2 else "self.template_file or" not in line2, "a source input must not become the destination: " + line2;
    assert '_outname(self.task, "report_file.out")' in line2, line2;
    # the NO-TOOL fallback (an ACT with no resolvable tool writes its content carry)
    # honours the caller's output_path the same way
    notool = OUTPATH_IR.replace("    op: write_file\n    tool: write_file\n", "").replace("  write_file:\n    surface: ACT·artifact\n    serves: [write_report]\n", "  noop:\n    surface: SENSE\n    serves: []\n");
    src3 = transpile_ir(notool, "outpath3");
    line3 = [l for l in src3.split("\n") if ("report_md" in l) and ("_write_artifact(" in l)][0];
    assert "(self.output_path or _outname(self.task," in line3, "no-tool write must honour output_path: " + line3;
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

# EXTRACTOR VALUES / GUARD. A GEN-FILL step that reads nothing but the task
# sentence re-derives values a caller often already holds — travel-planning spent
# 15 of 21 slot calls asking the model for "Cleveland" out of "... in Cleveland".
# Each value it produces becomes an OPTIONAL flag, and the step is skipped only
# when every value it would produce was supplied; unsupplied binds "" (never the
# task text), so the extraction still runs as authored.
glob EXTRACTOR_IR: str = """---
name: city_search
description: Find rows for the requested city.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  search_rows:
    sig: "(city: str) -> str"
    surface: SENSE
    doc: "Rows for the city."
    body: |
      def search_rows(city):
          return "rows for " + (city or "")
walker:
  name: CitySearch
  carries:
    task:
      type: str
      role: input
    city:
      type: str
      produced_by: extract_city
      doc: "The city to search."
    rows:
      type: str
      produced_by: search
nodes:
  - id: extract_city
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [city]
  - id: search
    type: SENSE
    owner: code
    op: search_rows
    tool: search_rows
    reads: [city]
    writes: [rows]
  - id: done
    type: TERMINAL
edges:
  - {from: extract_city, to: search, modality: mandatory}
  - {from: search, to: done, modality: mandatory}
""";

test "a task-only extraction step's value is an optional flag that skips the model call" {
    src = transpile_ir(EXTRACTOR_IR, "city_search");
    assert "_EJ_PARAM_KEYS: list[any] = ['city']" in src;
    # bound from the caller, defaulting to "" — never to the task text
    assert "city=str(params.get('city', ''))" in src;
    assert "params.get('city', (_task_file_for" not in src;
    # the model call sits behind the supplied-value guard ...
    assert "if not (str(self.city).strip()) {" in src;
    assert "extract_city(" in src;
    # ... and the walk continues to the next step either way (flow stays outside)
    guard_at = src.index("if not (str(self.city).strip()) {");
    visit_at = src.index("visit [-->][?:Search]", guard_at);
    assert src.index("extract_city(", guard_at) < visit_at;
    # the flag documents itself for the MCP schema / tool card
    assert "OPTIONAL: pass the value itself when you already know it" in src;
}

glob EXTRACTOR_MULTI_IR: str = """---
name: route_lookup
description: Look up a route.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  lookup:
    sig: "(origin_city: str, destination_city: str) -> str"
    surface: SENSE
    doc: "Distance between two cities."
    body: |
      def lookup(origin_city, destination_city):
          return origin_city + "->" + destination_city
walker:
  name: RouteLookup
  carries:
    task:
      type: str
      role: input
    origin_city:
      type: str
      produced_by: extract_query
    destination_city:
      type: str
      produced_by: extract_query
    info:
      type: str
      produced_by: look
nodes:
  - id: extract_query
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [origin_city, destination_city]
  - id: look
    type: SENSE
    owner: code
    op: lookup
    tool: lookup
    reads: [origin_city, destination_city]
    writes: [info]
  - id: done
    type: TERMINAL
edges:
  - {from: extract_query, to: look, modality: mandatory}
  - {from: look, to: done, modality: mandatory}
""";

test "a multi-value extraction is skipped only when every value is supplied" {
    src = transpile_ir(EXTRACTOR_MULTI_IR, "route_lookup");
    assert "_EJ_PARAM_KEYS: list[any] = ['origin_city', 'destination_city']" in src;
    assert "if not (str(self.origin_city).strip() and str(self.destination_city).strip()) {" in src;
}

# The boundary: drafting CONTENT from the task (GEN-RAW) is the skill's work and
# is never bypassable, and a step that reads anything besides the task is not a
# pure extraction.
glob NOT_EXTRACTOR_IR: str = """---
name: drafter
description: Draft a note, then classify it.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: Drafter
  carries:
    task:
      type: str
      role: input
    draft:
      type: str
      produced_by: write_draft
    tone:
      type: str
      produced_by: classify_tone
nodes:
  - id: write_draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [draft]
  - id: classify_tone
    type: GEN-ENUM
    owner: model
    reads: [task, draft]
    writes: [tone]
  - id: done
    type: TERMINAL
edges:
  - {from: write_draft, to: classify_tone, modality: mandatory}
  - {from: classify_tone, to: done, modality: mandatory}
""";

test "drafting steps and steps that read more than the task are never bypassable" {
    src = transpile_ir(NOT_EXTRACTOR_IR, "drafter");
    assert "'draft'" not in src.split("_EJ_PARAM_KEYS: list[any] = ")[1].split("\n")[0];
    assert "'tone'" not in src.split("_EJ_PARAM_KEYS: list[any] = ")[1].split("\n")[0];
    assert "str(self.draft).strip()) {" not in src;
    assert "str(self.tone).strip()) {" not in src;
}

# EDIT MODE. A GEN-EDIT step revises a document it already holds; lowered as a
# whole-text slot its output scales with the FILE — restclient-migration's
# rewrite_calls re-emitted a whole Java class and hit its 2500-token cap. It now
# asks a companion slot for SEARCH/REPLACE blocks, applies them in code, and falls
# back to the whole-text slot when any block fails, so a revision is never partial.
glob EDIT_MODE_IR: str = """---
name: rest_migrate
description: Migrate RestTemplate calls.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: RestMigrate
  carries:
    task:
      type: str
      role: input
    source_java:
      type: str
      role: input
    migration_plan:
      type: str
      role: input
    migrated_java:
      type: str
      produced_by: rewrite_calls
nodes:
  - id: rewrite_calls
    type: GEN-EDIT
    owner: model
    reads: [source_java, migration_plan]
    writes: [migrated_java]
  - id: done
    type: TERMINAL
edges:
  - {from: rewrite_calls, to: done, modality: mandatory}
""";

test "a GEN-EDIT revision asks for edits, applies them, and falls back to the whole text" {
    src = transpile_ir(EDIT_MODE_IR, "rest_migrate");
    assert "def rewrite_calls_edits(" in src;
    assert "EDIT MODE: `source_java` is the current text" in src;
    assert "<<<<<<< SEARCH" in src;                     # the block format survives quoting
    assert "_ed = str(rewrite_calls_edits(" in src;
    assert "_ap = str(_apply_edits(str(self.source_java), _ed));" in src;
    assert "if _ap { self.migrated_java = _ap; } else { self.migrated_java = str(_strip_fences(rewrite_calls(" in src;
    # the whole-text slot is still declared: it IS the fallback
    assert "def rewrite_calls(" in src;
    # SIZE GATE: edits only for a large document; a small one is rewritten directly
    # (edit blocks repeat old + new text, so on a small class they cost MORE)
    assert "if len(str(self.source_java)) >= 6000 {" in src;
    assert "} else { self.migrated_java = str(_strip_fences(rewrite_calls(" in src;
}

glob EDIT_INPLACE_IR: str = """---
name: fixer
debuild_pyion: Repair a build script in place.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: Fixer
  carries:
    task:
      type: str
      role: input
    error_log:
      type: str
      role: input
    build_py:
      type: str
      role: input
      produced_by: fix_errors
nodes:
  - id: fix_errors
    type: GEN-EDIT
    owner: model
    reads: [build_py, error_log]
    writes: [build_py]
  - id: done
    type: TERMINAL
edges:
  - {from: fix_errors, to: done, modality: mandatory}
""";

test "an in-place GEN-EDIT repair edits the carry it rewrites" {
    src = transpile_ir(EDIT_INPLACE_IR, "fixer");
    assert "_ap = str(_apply_edits(str(self.build_py), _ed));" in src;
}

glob EDIT_NOSOURCE_IR: str = """---
name: summarizer
description: Revise findings into a summary.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: Summarizer
  carries:
    task:
      type: str
      role: input
    findings_md:
      type: str
      role: input
    summary:
      type: str
      produced_by: revise
nodes:
  - id: revise
    type: GEN-EDIT
    owner: model
    reads: [findings_md]
    writes: [summary]
  - id: done
    type: TERMINAL
edges:
  - {from: revise, to: done, modality: mandatory}
""";

test "a GEN-EDIT with no same-kind source keeps the whole-text lowering" {
    src = transpile_ir(EDIT_NOSOURCE_IR, "summarizer");
    # (the runtime's own `def _apply_edits(` ships in every program, so match the
    # step's slot and the call site, not the bare helper name)
    assert "def revise_edits(" not in src;
    assert "= str(_apply_edits(" not in src;
    assert "self.summary = str(_strip_fences(revise(" in src;
}

test "edit blocks apply exactly, and any unmatched or ambiguous block rejects the whole set" {
    ns = _runtime_ns();
    ap = ns["_apply_edits"];
    src = "import a\nx = RestTemplate()\ny = x.get(u)\n";
    edits = "<<<<<<< SEARCH\nx = RestTemplate()\n=======\nx = RestClient.create()\n>>>>>>> REPLACE\n<<<<<<< SEARCH\ny = x.get(u)\n=======\ny = x.get().uri(u).retrieve()\n>>>>>>> REPLACE";
    assert ap(src, edits) == "import a\nx = RestClient.create()\ny = x.get().uri(u).retrieve()\n";
    # fenced, the way models often wrap it
    assert ap(src, "```\n" + edits + "\n```") == ap(src, edits);
    # a SEARCH that is not in the source -> nothing applied, caller falls back
    assert ap(src, "<<<<<<< SEARCH\nz = 1\n=======\nz = 2\n>>>>>>> REPLACE") == "";
    # a SEARCH that occurs twice is ambiguous -> rejected, never a guess
    assert ap("a\na\n", "<<<<<<< SEARCH\na\n=======\nb\n>>>>>>> REPLACE") == "";
    # a partially valid set is rejected whole: the first block must not leak through
    assert ap(src, edits + "\n<<<<<<< SEARCH\nnope\n=======\nx\n>>>>>>> REPLACE") == "";
    # deletions (empty replacement) apply
    assert ap(src, "<<<<<<< SEARCH\nimport a\n=======\n>>>>>>> REPLACE") == "\nx = RestTemplate()\ny = x.get(u)\n";
    # explicit no-op, and prose with no blocks
    assert ap(src, "NO CHANGES") == src;
    assert ap(src, "here is the rewritten class: ...") == "";
}

# The edit source is found by NAME OVERLAP with the output or the step, not by an
# identical suffix: spring-boot's revisions are pom_xml -> edited_pom and, for
# refactor_adapter_class, adapter_source -> refactored_config. A path input is
# never an edit source (the model cannot SEARCH text it was never shown).
glob EDIT_OVERLAP_IR: str = """---
name: boot_migrate
description: Revise the build and the security adapter.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: BootMigrate
  carries:
    task:
      type: str
      role: input
    pom_xml:
      type: str
      role: input
    legacy_report:
      type: str
      role: input
    adapter_source:
      type: str
      role: input
    test_target_file:
      type: path
      role: input
    edited_pom:
      type: str
      produced_by: plan_dependency_edits
    refactored_config:
      type: str
      produced_by: refactor_adapter_class
    updated_tests:
      type: str
      produced_by: update_security_tests
nodes:
  - id: plan_dependency_edits
    type: GEN-EDIT
    owner: model
    reads: [task, pom_xml, legacy_report]
    writes: [edited_pom]
  - id: refactor_adapter_class
    type: GEN-EDIT
    owner: model
    reads: [task, adapter_source]
    writes: [refactored_config]
  - id: update_security_tests
    type: GEN-EDIT
    owner: model
    reads: [task, test_target_file]
    writes: [updated_tests]
  - id: done
    type: TERMINAL
edges:
  - {from: plan_dependency_edits, to: refactor_adapter_class, modality: mandatory}
  - {from: refactor_adapter_class, to: update_security_tests, modality: mandatory}
  - {from: update_security_tests, to: done, modality: mandatory}
""";

test "an edit source is matched by name overlap, and a path is never one" {
    src = transpile_ir(EDIT_OVERLAP_IR, "boot_migrate");
    assert "_ap = str(_apply_edits(str(self.pom_xml), _ed));" in src;
    assert "_ap = str(_apply_edits(str(self.adapter_source), _ed));" in src;
    assert "def update_security_tests_edits(" not in src;
    assert "_apply_edits(str(self.test_target_file)" not in src;
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
