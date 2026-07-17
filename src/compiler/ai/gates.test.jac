"""Tests — the G4 compile oracle. The happy path is a LIVE round-trip: a minimal
AG-IR through mechanical.transpile_ir + a real `jac check` subprocess. The
failure paths must return routed verdicts, never raise."""

glob GOOD_IR: str = """---
name: note-writer
description: Write a short note to a file.
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
    report:
      type: str
      produced_by: done
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

test "a valid AG-IR round-trips through transpile + jac check" {
    v = compile_gate(GOOD_IR, "note_writer");
    assert v.ok;
    assert "def run(" in v.module_src;
    assert v.errors == "";
}

test "garbage input yields a routed failure, not an exception" {
    v = compile_gate("::: not yaml {{{", "junk");
    assert not v.ok;
    assert v.errors != "";
}

test "transpile without check still requires a run() entrypoint" {
    v = compile_gate(GOOD_IR, "note_writer_nocheck", check=False);
    assert v.ok;
    assert "def run(" in v.module_src;
}
