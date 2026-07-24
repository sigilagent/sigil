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
