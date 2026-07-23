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

test "a bool verdict is assigned to its carry, not discarded" {
    src = transpile_ir(GATE_IR, "checker");
    assert "self.is_short = bool(_check_len(self.sentence));" in src;
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
