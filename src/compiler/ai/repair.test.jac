"""Tests — the compile-repair loop. A scripted MockLLM plays the repairer; the
compile gate runs LIVE on both the broken input and the repaired output."""

import from jaclang.byllm.lib { MockLLM }

glob FIXED_IR: str = """---
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

test "a failing IR is repaired and re-gated to green" {
    pin_repair_llm(MockLLM(model_name="mockllm", config={"outputs": [FIXED_IR]}));
    out = repair_compile_loop("::: not yaml {{{", "note_writer_r");
    assert out.verdict.ok;
    assert "def run(" in out.verdict.module_src;
    assert len(out.attempts) == 1;
    assert "fixed" in out.attempts[0];
}

test "an accidental markdown fence from the repairer is stripped" {
    fenced = "```yaml\n" + FIXED_IR + "\n```";
    pin_repair_llm(MockLLM(model_name="mockllm", config={"outputs": [fenced]}));
    out = repair_compile_loop("::: not yaml {{{", "note_writer_f");
    assert out.verdict.ok;
}

test "exhaustion returns the last verdict honestly, never a silent success" {
    pin_repair_llm(MockLLM(model_name="mockllm", config={"outputs": ["still garbage", "more garbage"]}));
    out = repair_compile_loop("::: not yaml {{{", "note_writer_x", max_attempts=2);
    assert not out.verdict.ok;
    assert len(out.attempts) == 2;
    assert "still failing" in out.attempts[1];
}
