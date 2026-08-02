"""Tests — the mechanical back-end (LOWER).

The invariant under test: a synthesized tool must actually RUN its body. LIFT is
free to emit a tool `body` either as bare statements or as a complete `def`; both
shapes have to lower to a wrapper that returns the body's value. The complete-def
shape is the dangerous one — nesting it inside the wrapper is valid Python, so
`jac check` (and therefore the G4 compile oracle) stays green while every tool
call silently returns None.
"""

# A tool whose body is a COMPLETE def — the shape LIFT emits when the skill's
# snippet is itself a function.
glob DEF_BODY_IR: str = """---
name: shout
description: Uppercase some text.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  upcase:
    sig: "(text: str) -> str"
    surface: SENSE
    doc: "Uppercase the text."
    body: |
      def upcase(text):
          return (text or "").upper()
walker:
  name: ShoutAgent
  carries:
    task:
      type: str
      role: input
    loud:
      type: str
      produced_by: shout_it
nodes:
  - id: shout_it
    type: SENSE
    owner: code
    op: upcase
    reads: [task]
    writes: [loud]
  - id: done
    type: TERMINAL
edges:
  - {from: shout_it, to: done, modality: mandatory}
""";

# The same tool written the way the authoring contract asks for: bare statements.
glob STMT_BODY_IR: str = DEF_BODY_IR.replace(
    "      def upcase(text):\n          return (text or \"\").upper()",
    "      return (text or \"\").upper()"
);

test "a complete-def tool body is delegated to, not just nested" {
    src = transpile_ir(DEF_BODY_IR, "shout_def");
    assert "def _upcase(text=None):" in src;
    assert "def upcase(text):" in src;               # the body rode along verbatim
    assert "    return upcase(text)" in src;         # …and is actually CALLED
}

test "a bare-statement tool body is left alone" {
    src = transpile_ir(STMT_BODY_IR, "shout_stmt");
    assert "def _upcase(text=None):" in src;
    assert 'return (text or "").upper()' in src;
    assert "return upcase(" not in src;              # nothing to delegate to
}

# An ACT tool that writes a file: `path` names a destination, and no carry holds
# it. Binding it to None hands the tool a null path and the module raises at run
# time — the failure the delegating-call fix above surfaces.
glob ACT_PATH_IR: str = """---
name: saver
description: Save a note to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  write_note:
    sig: "(content: str, path: str) -> str"
    surface: ACT·artifact
    doc: "Write content to path."
    body: |
      def write_note(content, path):
          with open(path, "w") as f:
              f.write(content)
          return path
walker:
  name: SaveAgent
  carries:
    task:
      type: str
      role: input
    note:
      type: str
      role: input
    saved:
      type: str
      produced_by: save_it
nodes:
  - id: save_it
    type: ACT
    owner: code
    op: write_note
    tool: write_note
    reads: [note]
    writes: [saved]
  - id: done
    type: TERMINAL
edges:
  - {from: save_it, to: done, modality: mandatory}
""";

test "an ACT tool's destination param resolves to a real path, never None" {
    src = transpile_ir(ACT_PATH_IR, "saver");
    assert "_write_note(self.note, _outname(self.task, \"saved.out\"))" in src;
    assert "_write_note(self.note, None)" not in src;
}

# path-FIRST write tool + a single content read: the blind positional fallback
# used to bind the CONTENT carry to `path` and leave `content` None — every
# deliverable became a 0-byte file named after its own content (caught live:
# algorithmic-art wrote an empty file literally called "Organic Fusion").
glob ACT_PATHFIRST_IR: str = """---
name: exporter
description: Export authored philosophy to a file.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  write_file:
    sig: "(path: str, content: str) -> str"
    surface: ACT·artifact
    serves: [export_it]
    doc: "Write content to path."
    body: |
      def write_file(path, content):
          with open(path, "w") as f:
              f.write(content or "")
          return path
walker:
  name: ExportAgent
  carries:
    task:
      type: str
      role: input
    philosophy_md:
      type: str
      role: input
    exported:
      type: str
      produced_by: export_it
nodes:
  - id: export_it
    type: ACT
    owner: code
    reads: [philosophy_md]
    writes: [exported]
  - id: done
    type: TERMINAL
    reads: [exported]
edges:
  - {from: export_it, to: done}
""";

test "a path-first write tool binds content by ROLE, not position" {
    src = transpile_ir(ACT_PATHFIRST_IR, "exporter");
    # content param gets the content carry; path param falls to the task-derived name
    assert "_write_file(_outname(self.task, \"exported.out\"), self.philosophy_md)" in src;
    # the misbinding this fixes: content carry as path, content None
    assert "_write_file(self.philosophy_md, None)" not in src;
}

# `task` is not always the only input the IR declares. A carry marked
# `role: input` that no node produces can ONLY come from the invocation — bind
# just `task` and that field keeps its "" default, so the first node reading it
# dies on empty input. Same class as #85: the lowering dropping the IR's data on
# the way to the walker.
test "every unproduced input carry is bound at spawn, not just `task`" {
    src = transpile_ir(ACT_PATH_IR, "saver");
    assert "spawn SaveAgent(task=task, note=task)" in src;
    assert "spawn SaveAgent(task=task);" not in src;
}

# The other half of that rule: binding is for inputs the invocation actually
# supplies. A carry a node produces already has a source, and a non-str input
# cannot take the task text — binding either would fabricate data.
glob MIXED_INPUT_IR: str = """---
name: mixed
description: Inputs of several shapes.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  peek:
    sig: "(src_path: str) -> bool"
    surface: SENSE
    doc: "True if the path is non-empty."
    body: |
      def peek(src_path):
          return bool(src_path)
walker:
  name: MixedAgent
  carries:
    task:
      type: str
      role: input
    src_path:
      type: str
      role: input
    retries:
      type: int
      role: input
    seen:
      type: bool
      produced_by: peek_it
nodes:
  - id: peek_it
    type: SENSE
    owner: code
    op: peek
    tool: peek
    reads: [src_path]
    writes: [seen]
  - id: done
    type: TERMINAL
edges:
  - {from: peek_it, to: done, modality: mandatory}
""";

# A fan-out into independent checks that converge on a gate — the shape every
# "verify these N things, then decide" rule lowers to.
glob FANOUT_GATE_IR: str = """---
name: fanchk
description: Fan out two checks, then gate on both.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  check_a:
    sig: "(text: str) -> bool"
    surface: SENSE
    doc: "First check."
    body: |
      def check_a(text):
          return bool(text)
  check_b:
    sig: "(text: str) -> bool"
    surface: SENSE
    doc: "Second check."
    body: |
      def check_b(text):
          return len(text) > 1
  gate_all:
    sig: "(a_ok: bool, b_ok: bool) -> bool"
    surface: SENSE
    doc: "True when both checks hold."
    body: |
      def gate_all(a_ok, b_ok):
          return bool(a_ok) and bool(b_ok)
walker:
  name: FanAgent
  carries:
    task:
      type: str
      role: input
    a_ok:
      type: bool
      produced_by: run_check_a
    b_ok:
      type: bool
      produced_by: run_check_b
    all_ok:
      type: bool
      produced_by: gate
nodes:
  - id: fan
    type: SPAWN
    owner: code
  - id: run_check_a
    type: CODE
    owner: code
    op: check_a
    tool: check_a
    reads: [task]
    writes: [a_ok]
  - id: run_check_b
    type: CODE
    owner: code
    op: check_b
    tool: check_b
    reads: [task]
    writes: [b_ok]
  - id: gate
    type: ROUTE
    owner: code
    op: gate_all
    tool: gate_all
    reads: [a_ok, b_ok]
    writes: [all_ok]
  - id: done
    type: TERMINAL
edges:
  - {from: fan, to: run_check_a, modality: mandatory}
  - {from: fan, to: run_check_b, modality: mandatory}
  - {from: run_check_a, to: gate, modality: mandatory}
  - {from: run_check_b, to: gate, modality: mandatory}
  - {from: gate, to: done, guard: "all_ok == true"}
  - {from: gate, to: fan, guard: "all_ok == false"}
""";

# Taking only the first forward edge left run_check_b unreachable, so `b_ok` kept
# its default and the gate could never pass.
test "a fan-out visits every unguarded forward edge, not just the first" {
    src = transpile_ir(FANOUT_GATE_IR, "fanchk");
    assert "visit [-->][?:RunCheckA];" in src;
    assert "visit [-->][?:RunCheckB];" in src;
}

# A code ROUTE has to DECIDE before it branches: emitting only the branch left
# `all_ok` at its `False` default forever, so the route looped through its repair
# edge until the step budget blew.
test "a code ROUTE calls the tool that computes its own guard" {
    src = transpile_ir(FANOUT_GATE_IR, "fanchk");
    assert "self.all_ok = " in src;
    assert "_gate_all(self.a_ok, self.b_ok)" in src;
}

glob BUDGET_ROUTE_IR: str = """---
name: budgeted
description: A bounded repair loop — the route's budget guard is the bound.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: BudgetedAgent
  carries:
    task: {type: str, role: input}
    errors: {type: str, produced_by: check_it}
    ok: {type: bool, produced_by: check_it}
    round: {type: int, produced_by: bump}
nodes:
  - id: check_it
    type: ROUTE
    owner: code
    op: check_it
    tool: check_it
    reads: [task]
    writes: [errors, ok]
  - id: bump
    type: CODE
    owner: code
    op: bump
    tool: bump
    reads: [round]
    writes: [round]
  - id: done
    type: TERMINAL
edges:
  - {from: check_it, to: done, guard: "ok == true"}
  - {from: check_it, to: bump, guard: "round < 3"}
  - {from: check_it, to: done, guard: "errors != \\"\\""}
  - {from: bump, to: check_it, modality: mandatory}
tools:
  check_it:
    sig: (task) -> (errors,ok)
    body: |
      def check_it(task):
          return "", True
  bump:
    sig: (round) -> round
    body: |
      def bump(round):
          return int(round or 0) + 1
""";

# A ROUTE guard the enum/equality shapes don't recognize used to fall through to
# a bare `True`, which is an ALWAYS-TAKEN branch: the repair edge lost its round
# budget (unbounded loop) and every edge behind it went unreachable. Numeric and
# string comparisons belong to _guard_expr, which has always handled them for
# non-ROUTE edges.
test "a ROUTE guard outside the enum shapes lowers to its real comparison" {
    src = transpile_ir(BUDGET_ROUTE_IR, "budgeted");
    assert "self.round < 3" in src;
    assert 'self.errors != ""' in src;
    assert "elif True {" not in src;
    assert "if True {" not in src;
}

# ...but ONLY when the guard's subject is a real carry. A bare word naming
# nothing the walker holds is not lowerable: `self.more` reads a field that does
# not exist, so BOTH branches go dead and a loop that should spin falls straight
# through instead (runtime_budget's step-budget scenario is exactly this shape).
# Those keep the permissive default.
test "a ROUTE guard whose subject is no carry stays permissive" {
    ir = BUDGET_ROUTE_IR.replace('guard: "round < 3"', 'guard: "more"')
                        .replace('guard: "errors != \\"\\""', 'guard: "finished"');
    src = transpile_ir(ir, "budgeted");
    assert "self.more" not in src;
    assert "self.finished" not in src;
    assert "if True {" in src;
}

test "spawn binding skips produced and non-string carries" {
    src = transpile_ir(MIXED_INPUT_IR, "mixed");
    assert "spawn MixedAgent(task=task, src_path=task)" in src;
    assert "retries=task" not in src;   # int input: the task text is not an int
    assert "seen=task" not in src;      # produced by peek_it, not by the caller
}

# A verify-then-repair skill: a model proposes, code checks six ways, a gate folds
# the verdicts, and a GEN-EDIT repairs on failure. The shape any skill with a
# verification gate lowers to — and where three separate lowering faults met.
glob REPAIR_IR: str = """---
name: fixer
description: Propose names, verify them, repair on failure.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  run_checks:
    sig: "(answer) -> (c1,c2,c3,c4,c5,c6)"
    surface: SENSE
    doc: "Six independent verdicts."
    body: |
      def run_checks(answer):
          n = len(answer or [])
          return (n > 0, n > 1, n > 2, n > 3, n > 4, n > 5)
  gate_all:
    sig: "(c1,c2,c3,c4,c5,c6) -> all_ok"
    surface: SENSE
    doc: "True when every verdict holds."
    body: |
      def gate_all(c1, c2, c3, c4, c5, c6):
          return all([c1, c2, c3, c4, c5, c6])
walker:
  name: FixAgent
  carries:
    task:
      type: str
      role: input
    source:
      type: list[str]
      role: input
    answer:
      type: list[str]
      produced_by: propose
    c1: {type: bool, produced_by: checks}
    c2: {type: bool, produced_by: checks}
    c3: {type: bool, produced_by: checks}
    c4: {type: bool, produced_by: checks}
    c5: {type: bool, produced_by: checks}
    c6: {type: bool, produced_by: checks}
    all_ok:
      type: bool
      produced_by: gate
nodes:
  - id: propose
    type: GEN-FILL
    owner: model
    doc: "Propose one name per source item."
    reads: [source]
    writes: [answer]
  - id: checks
    type: CODE
    owner: code
    op: run_checks
    tool: run_checks
    reads: [answer]
    writes: [c1, c2, c3, c4, c5, c6]
  - id: gate
    type: ROUTE
    owner: code
    op: gate_all
    tool: gate_all
    reads: [c1, c2, c3, c4, c5, c6]
    writes: [all_ok]
  - id: fixit
    type: GEN-EDIT
    owner: model
    doc: "Repair the answer."
    reads: [answer, c1, c2, c3, c4, c5, c6]
    writes: [answer]
  - id: done
    type: TERMINAL
edges:
  - {from: propose, to: checks, modality: mandatory}
  - {from: checks, to: gate, modality: mandatory}
  - {from: gate, to: done, guard: "all_ok == true"}
  - {from: gate, to: fixit, guard: "all_ok == false"}
  - {from: fixit, to: checks, modality: mandatory}
""";

# Wired to read only the REJECTED attempt and the verdicts, a repair is blind: told
# THAT a check failed but never what the input was, it cannot know the answer, and a
# small model fills the gap by inventing. Give it the producer's inputs.
test "a repair slot inherits the reads of the node that produced its carry" {
    src = transpile_ir(REPAIR_IR, "fixer");
    assert "def fixit(source: list[str]" in src;
}

# The arity cap used to be a bare `[:6]` duplicated across seven sites. `fixit`
# declares SEVEN reads, so the tail was dropped with no diagnostic — and raising one
# copy emitted a slot whose call site passed fewer args than it declared.
test "a slot keeps every declared read, and its call site matches its arity" {
    src = transpile_ir(REPAIR_IR, "fixer");
    decl = src.split("def fixit(")[1].split(")")[0];
    call = src.split("fixit(self.")[1].split(");")[0];
    # scope the check to the SIGNATURE — the walker also declares `has c6: bool`,
    # so searching the whole module would pass even with the read truncated away.
    assert "c6: bool" in decl;
    assert len(decl.split(",")) == len(call.split(","));
}

# byLLM leaks JSON structure into list elements ('' or '"},{"'). Downstream that is
# indistinguishable from a real item, so a count check fails and the repair "fixes"
# the blank by NAMING it instead of dropping it.
test "a list-returning slot's result is stripped of contentless elements" {
    src = transpile_ir(REPAIR_IR, "fixer");
    assert "_clean_strlist(propose(" in src;
}

# A code-owned verification step writing a bool verdict — the shape every "check
# that X holds" rule lowers to.
glob GATE_IR: str = """---
name: checker
description: Check a sentence is short enough.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  check_len:
    sig: "(sentence: str) -> bool"
    surface: SENSE
    doc: "True if the sentence is 25 words or fewer."
    body: |
      def check_len(sentence):
          return len((sentence or "").split()) <= 25
walker:
  name: CheckAgent
  carries:
    task:
      type: str
      role: input
    sentence:
      type: str
      role: input
    is_short:
      type: bool
      produced_by: check_it
nodes:
  - id: check_it
    type: SENSE
    owner: code
    op: check_len
    tool: check_len
    reads: [sentence]
    writes: [is_short]
  - id: done
    type: TERMINAL
edges:
  - {from: check_it, to: done, modality: mandatory}
""";

# The writing-plans shape: a GEN node writes an UNTYPED carry, and a tool consumes
# that carry as a dict. Declaring the slot `-> str` makes the tool's `.get()` fail
# on every model — the failure is in the contract, not the cognition.
glob CONSUMER_TYPE_IR: str = """---
name: header
description: Build a plan header.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  render_header:
    sig: "(header_fields) -> str"
    surface: SENSE
    doc: "Render the header from its fields."
    body: |
      def render_header(header_fields: dict) -> str:
          return header_fields.get("feature_name", "[none]")
walker:
  name: HeaderAgent
  carries:
    task:
      type: str
      role: input
    header_fields:
      type: any
      produced_by: fill_fields
    header_md:
      type: str
      produced_by: render_it
nodes:
  - id: fill_fields
    type: GEN-FILL
    owner: model
    reads: [task]
    writes: [header_fields]
    doc: "Fill in the header fields."
  - id: render_it
    type: SENSE
    owner: code
    op: render_header
    tool: render_header
    reads: [header_fields]
    writes: [header_md]
  - id: done
    type: TERMINAL
edges:
  - {from: fill_fields, to: render_it, modality: mandatory}
  - {from: render_it, to: done, modality: mandatory}
""";

test "an untyped carry takes its type from the tool that consumes it" {
    src = transpile_ir(CONSUMER_TYPE_IR, "header_consumer");
    # the slot must produce what the consumer reads, parameterized so byLLM can
    # schematize it (a bare `dict` raises "Untyped dict is not supported").
    assert "def fill_fields(task: str) -> dict[str, str] by llm;" in src;
    assert "-> str by llm;" not in src;
}

test "a bare dict/list slot return is widened so byLLM can schematize it" {
    ir = CONSUMER_TYPE_IR.replace("      type: any\n      produced_by: fill_fields",
                                  "      type: dict\n      produced_by: fill_fields");
    src = transpile_ir(ir, "header_bare_dict");
    assert "-> dict[str, str] by llm;" in src;
    assert "-> dict by llm;" not in src;
}

# A tool LIFT authored as a standalone stdin-script: a def plus a __main__ harness.
# Inlined into the ejected module (itself __main__), the guard fires and reads empty
# stdin — a JSONDecodeError before the real work. It must be stripped, and the def
# delegated to.
glob MAIN_GUARD_IR: str = """---
name: saver
description: Save content to a path.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  save_file:
    sig: "(content, path) -> str"
    surface: ACT·artifact
    doc: "Write content to path."
    body: |
      import sys, json, os
      def tool(content: str, path: str) -> str:
          os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
          with open(path, "w") as f:
              f.write(content)
          return path
      if __name__ == "__main__":
          data = json.load(sys.stdin)
          print(tool(data["content"], data["path"]))
walker:
  name: SaveAgent
  carries:
    task:
      type: str
      role: input
    content:
      type: str
      role: input
    saved:
      type: str
      produced_by: save_it
nodes:
  - id: save_it
    type: ACT
    owner: code
    op: save_file
    tool: save_file
    reads: [content]
    writes: [saved]
  - id: done
    type: TERMINAL
edges:
  - {from: save_it, to: done, modality: mandatory}
""";

test "an inlined tool body's __main__ stdin harness is stripped, not run" {
    src = transpile_ir(MAIN_GUARD_IR, "saver_main");
    assert 'if __name__ == "__main__":' not in src;   # the harness never rides in
    assert "json.load(sys.stdin)" not in src;          # …so it can't fire on empty stdin
    assert "def tool(content: str, path: str) -> str:" in src;   # the real def stays
    assert "return tool(content, path)" in src;        # …and is delegated to
}

test "every tool is emitted as a traced wrapper around its impl" {
    src = transpile_ir(DEF_BODY_IR, "shout_traced");
    assert "def _upcase__impl(text=None):" in src;              # body lives in the impl
    assert "def _upcase(text=None):" in src;                    # callers hit the wrapper
    assert '_tui_tool("upcase", [("text", text)], lambda: _upcase__impl(text))' in src;
}

glob GEN_IR: str = """---
name: noter
description: Write a note.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
walker:
  name: NoteAgent
  carries:
    task:
      type: str
      role: input
    note:
      type: str
      produced_by: draft
nodes:
  - id: draft
    type: GEN-RAW
    owner: model
    reads: [task]
    writes: [note]
    doc: "Write the note the task asks for."
  - id: done
    type: TERMINAL
edges:
  - {from: draft, to: done, modality: mandatory}
""";

test "a by-llm slot is bracketed so its inputs and output are visible" {
    src = transpile_ir(GEN_IR, "noter_traced");
    assert '_tui_llm_in("draft", [("task", self.task)]);' in src;
    assert "_tui_llm_out(self.note);" in src;
}

test "a bool verdict is assigned to its carry, not discarded" {
    src = transpile_ir(GATE_IR, "checker");
    assert "self.is_short = bool(_unwrap(_check_len(self.sentence), \"is_short\", 0, True));" in src;
    assert "carry keeps default" not in src;
}

test "the delegating call forwards params by name and Nones the rest" {
    ir = DEF_BODY_IR.replace(
        "      def upcase(text):\n          return (text or \"\").upper()",
        "      def upcase(text, style=None):\n          return (text or \"\").upper()"
    );
    src = transpile_ir(ir, "shout_extra");
    # `text` is a wrapper param, `style` is not — it must not be invented.
    assert "    return upcase(text, None)" in src;
}

test "a body with helper defs delegates to `run`, not to nothing" {
    # LIFT's multi-def convention: helpers above, entry def named `run`. Bailing
    # on nfn != 1 left the wrapper defining functions and returning None.
    ir = DEF_BODY_IR.replace(
        "      def upcase(text):\n          return (text or \"\").upper()",
        "      def clean(s):\n          return (s or \"\").strip()\n\n      def run(text):\n          return clean(text).upper()"
    );
    src = transpile_ir(ir, "shout_helpers");
    assert "    return run(text)" in src;             # the entry def is CALLED
    assert "\n    return clean(" not in src;          # …not the helper (line-anchored:
                                                      # the body's own `return clean(...)`
                                                      # sits deeper inside `def run`)
}

# A verification tool that reports two carries at once — `-> (report, ok)`. The
# old lowering stuffed the stringified whole return into writes[0] and left every
# later write at its default: the verdict never landed, so no guard downstream
# could ever see a failed check.
glob MULTI_WRITE_IR: str = """---
name: checker2
description: Check a sentence and report.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  verify_all:
    sig: "(sentence: str) -> (verdict_report, ok)"
    surface: SENSE
    doc: "Report on the sentence; ok iff it passes."
    body: |
      def run(sentence):
          ok = len((sentence or "").split()) <= 25
          return {"verdict_report": "words ok" if ok else "too long", "ok": ok}
walker:
  name: Check2Agent
  carries:
    task:
      type: str
      role: input
    sentence:
      type: str
      role: input
    verdict_report:
      type: str
      produced_by: check_it
    ok:
      type: bool
      produced_by: check_it
nodes:
  - id: check_it
    type: SENSE
    owner: code
    op: verify_all
    tool: verify_all
    reads: [sentence]
    writes: [verdict_report, ok]
  - id: done
    type: TERMINAL
edges:
  - {from: check_it, to: done, modality: mandatory}
""";

test "a multi-write tool is destructured into EVERY carry it writes" {
    src = transpile_ir(MULTI_WRITE_IR, "checker2");
    assert "_rw = _verify_all(self.sentence);" in src;
    assert "self.verdict_report = str(_unwrap(_rw, \"verdict_report\", 0, False));" in src;
    assert "self.ok = bool(_unwrap(_rw, \"ok\", 1, False));" in src;
}

# A code ROUTE branching on a bool verdict — guards authored `ok == true` /
# `ok == false`. Quoting the RHS compared a bool carry to the string "true":
# both branches dead, the walker stalled at the route with no deliverable.
glob BOOL_ROUTE_IR: str = """---
name: gatekeeper
description: Pass or fix based on a check.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  check_len:
    sig: "(sentence: str) -> bool"
    surface: SENSE
    doc: "True if the sentence is 25 words or fewer."
    body: |
      def run(sentence):
          return len((sentence or "").split()) <= 25
walker:
  name: GateAgent
  carries:
    task:
      type: str
      role: input
    sentence:
      type: str
      role: input
    ok:
      type: bool
      produced_by: check_it
    fixed:
      type: str
      produced_by: fix_it
nodes:
  - id: check_it
    type: SENSE
    owner: code
    op: check_len
    tool: check_len
    reads: [sentence]
    writes: [ok]
  - id: route_it
    type: ROUTE
    owner: code
    reads: [ok]
  - id: fix_it
    type: GEN-EDIT
    owner: model
    reads: [sentence]
    writes: [fixed]
  - id: done
    type: TERMINAL
edges:
  - {from: check_it, to: route_it, modality: mandatory}
  - {from: route_it, to: done, modality: discretionary, guard: "ok == true"}
  - {from: route_it, to: fix_it, modality: discretionary, guard: "ok == false"}
  - {from: fix_it, to: done, modality: mandatory}
""";

test "a bool-carry guard lowers to its truthy form, never a string compare" {
    src = transpile_ir(BOOL_ROUTE_IR, "gatekeeper");
    assert "if self.ok { visit" in src;
    assert "elif not self.ok { visit" in src;
    assert '== "true"' not in src;                    # the dead-stall shape
}

# A param-less tool whose IR carries a FIXED command — the whole invocation is in
# the command string, there are no params to thread. Truncating to the executable
# ran `git` bare (usage text, exit 1) and the graph chewed on the error output.
glob FIXED_CMD_IR: str = """---
name: logger
description: Read recent git history.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  git_log_10:
    sig: "() -> text"
    surface: SENSE
    doc: "The last ten commits, one line each."
    command: git log --oneline -10
walker:
  name: LogAgent
  carries:
    task:
      type: str
      role: input
    log_text:
      type: str
      produced_by: read_log
nodes:
  - id: read_log
    type: SENSE
    owner: code
    op: git_log_10
    tool: git_log_10
    reads: []
    writes: [log_text]
  - id: done
    type: TERMINAL
edges:
  - {from: read_log, to: done, modality: mandatory}
""";

test "a fixed command keeps every token, not just the executable" {
    src = transpile_ir(FIXED_CMD_IR, "logger");
    assert '_run_cmd(["git", "log", "--oneline", "-10"], [])' in src;
    assert '_run_cmd(["git"], [])' not in src;        # the bare-binary bug
}

# --- mapping sections written as sequences ----------------------------------
# The contract asks for `tools: {upcase: {...}}`, but YAML makes a sequence of
# dicts just as natural and the authoring model reaches for it. It used to die in
# `_items` with `list indices must be integers or slices, not dict` — a TypeError
# naming no section, so the repair pass re-authored the same shape three times.

glob TOOLS_AS_SEQ_IR: str = DEF_BODY_IR.replace(
    "tools:\n  upcase:\n",
    "tools:\n  - name: upcase\n"
);

glob TOOLS_AS_NESTED_SEQ_IR: str = DEF_BODY_IR.replace(
    "tools:\n  upcase:\n    sig:",
    "tools:\n  - upcase:\n      sig:"
).replace(
    "    surface: SENSE\n    doc: \"Uppercase the text.\"\n    body: |\n      def upcase(text):\n          return (text or \"\").upper()",
    "      surface: SENSE\n      doc: \"Uppercase the text.\"\n      body: |\n        def upcase(text):\n            return (text or \"\").upper()"
);

glob CARRIES_AS_SEQ_IR: str = DEF_BODY_IR.replace(
    "  carries:\n    task:\n      type: str\n      role: input\n    loud:\n      type: str\n      produced_by: shout_it",
    "  carries:\n    - name: task\n      type: str\n      role: input\n    - name: loud\n      type: str\n      produced_by: shout_it"
);

test "tools written as a sequence of named dicts lower like the mapping form" {
    assert TOOLS_AS_SEQ_IR != DEF_BODY_IR, "fixture did not substitute";
    seq = transpile_ir(TOOLS_AS_SEQ_IR, "shout_seq");
    ref = transpile_ir(DEF_BODY_IR, "shout_seq");
    assert seq == ref, "sequence form lowered differently than the mapping form";
}

test "tools written as a sequence of single-entry mappings also lower" {
    assert TOOLS_AS_NESTED_SEQ_IR != DEF_BODY_IR, "fixture did not substitute";
    src = transpile_ir(TOOLS_AS_NESTED_SEQ_IR, "shout_nested");
    assert "def _upcase(text=None):" in src, src[:400];
    assert "def upcase(text):" in src, src[:400];      # the body still rides along
}

test "walker carries written as a sequence lower like the mapping form" {
    assert CARRIES_AS_SEQ_IR != DEF_BODY_IR, "fixture did not substitute";
    seq = transpile_ir(CARRIES_AS_SEQ_IR, "shout_car");
    ref = transpile_ir(DEF_BODY_IR, "shout_car");
    assert seq == ref, "sequence carries lowered differently than the mapping form";
}

test "a nameless entry in a sequence section says what to fix, not 'list indices'" {
    bad = DEF_BODY_IR.replace("tools:\n  upcase:\n", "tools:\n  - notaname: upcase\n");
    assert bad != DEF_BODY_IR, "fixture did not substitute";
    msg = "";
    try { transpile_ir(bad, "shout_bad"); }
    except Exception as e { msg = str(e); }
    assert "list indices" not in msg, msg;
    assert "no name" in msg, msg;
    assert "notaname" in msg, msg;          # names the offending entry's keys
}

test "a bare string in a sequence section becomes a name with an empty spec" {
    assert _items(["alpha", "beta"]) == [["alpha", {}], ["beta", {}]];
    # the mapping form is untouched
    assert _items({"a": 1, "b": 2}) == [["a", 1], ["b", 2]];
    assert _items(None) == [];
}

# --- the common tool library ------------------------------------------------
# A code-owned node lowers through a tool, and a tool needs a body. Without a
# standard library the author had to hand-write Python for `read this file`, and
# when it didn't the node lowered to a marker comment and the gate killed the
# compile. Binding by name now supplies the body.

glob TOOLIB_IR: str = """---
name: reader
description: Read a file and report it.
---
agir_version: 0.1
standalone: true
shape: pipeline
types: {}
tools:
  read_file:
    surface: SENSE
    serves: [load]
walker:
  name: ReaderAgent
  carries:
    task:
      type: str
      role: input
    body:
      type: str
      produced_by: load
nodes:
  - id: load
    type: SENSE
    owner: code
    op: read_file
    reads: [task]
    writes: [body]
  - id: done
    type: TERMINAL
edges:
  - {from: load, to: done, modality: mandatory}
""";

test "a tool named after a builtin gets the library's body, no author Python" {
    src = transpile_ir(TOOLIB_IR, "reader");
    assert "def _read_file(" in src, src[:400];
    # the library's implementation rode in, not a marker comment or a stub
    assert "no such file" in src, "the builtin body was not inlined";
    assert "os.path.expanduser" in src;
    assert ("_live_tool(" + chr(34) + "read_file" + chr(34)) not in src, "fell through to the live-tool rung instead";
}

test "the library's canonical sig wins, so body and wrapper always agree" {
    # the author wrote no sig at all here; a mismatched one must not strand the
    # body's parameter names either
    q2 = chr(34);
    bad = TOOLIB_IR.replace("  read_file:" + chr(10) + "    surface: SENSE",
                            "  read_file:" + chr(10) + "    sig: " + q2 + "(wrong_name: str) -> str" + q2
                            + chr(10) + "    surface: SENSE");
    src = transpile_ir(bad, "reader2");
    assert "def _read_file(path=None):" in src, src[:400];
    assert "wrong_name" not in src, "the author's sig overrode the builtin's body params";
}

test "an author-written body still wins over the library" {
    q = chr(34);
    mine = TOOLIB_IR.replace("  read_file:" + chr(10) + "    surface: SENSE",
                            "  read_file:" + chr(10) + "    surface: SENSE" + chr(10)
                            + "    body: |" + chr(10) + "      return " + q + "MY OWN BODY" + q);
    src = transpile_ir(mine, "reader3");
    assert "MY OWN BODY" in src;
    assert "no such file" not in src, "the library overrode an explicit body";
}

test "the catalogue names every builtin, with its surface" {
    cat = builtin_catalogue();
    for n in builtin_names() { assert n in cat, n + " missing from the catalogue"; }
    assert "read_file" in cat and "run_command" in cat and "grep" in cat;
    assert "EXACT name" in cat, "must tell the author how to bind one";
    assert builtin("read_file") is not None;
    assert builtin("not_a_builtin") is None;
}

test "every builtin body is self-contained: no sigil import at run time" {
    # the whole point of inlining. `import sigil_mcp` in the live-tool path has
    # always raised ModuleNotFoundError in the run subprocess; a library that had
    # to be imported would reproduce exactly that bug.
    for n in builtin_names() {
        b = str(dict(builtin(n))["body"]);
        assert "import sigil" not in b, n + " imports sigil at run time";
        assert "from src" not in b, n + " imports the repo at run time";
        assert "return" in b, n + " never returns anything";
    }
}
