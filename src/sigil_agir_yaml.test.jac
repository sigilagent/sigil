"""Tests — reading and writing AG-IR documents.

The round-trip is the contract: whatever load_agir accepts, dump_agir must emit
in a form load_agir reads back to the same mapping. The block-scalar case is the
one worth pinning — a tool body that round-trips as an escaped one-liner is still
*correct*, but it destroys the readability of the artifact a human opens when a
compile goes wrong.
"""

glob MALFORMED_IR: str = """---
name: pdf
description: Extract text from a PDF.
---
agir_version: 0.1
shape: pipeline
tools:
  build_command:
    sig: "(task) -> str"
    body: |
      def build_command(task: str) -> str:
          return "pdftotext " + (task or "")
walker:
  name: PdfAgent
  carries:
    task:             { type: str,  role: input }
    pdftotext_command:{ type: str,  produced_by: build_command }
nodes:
  - id: build_command
    type: CODE
    owner: code
edges:
  - {from: build_command, to: done, modality: mandatory}
""";

test "the column-aligned flow map that loses its space is not strict YAML" {
    # `pdftotext_command:{ ... }` — a real defect from a shipped raise2 IR.
    assert not strict_parses(MALFORMED_IR);
}

test "the relaxer still reads it, so nothing downstream ever noticed" {
    ir = load_agir(MALFORMED_IR);
    assert ir.get("shape") == "pipeline";
    carries = ir.get("walker").get("carries");
    assert "pdftotext_command" in carries;
    assert carries["pdftotext_command"]["produced_by"] == "build_command";
}

test "dump_agir canonicalizes it: the round-trip output IS strict YAML" {
    out = dump_agir(load_agir(MALFORMED_IR));
    assert strict_parses(out);
    # and it still reads back to the same mapping
    again = load_agir(out);
    assert again.get("walker").get("carries")["pdftotext_command"]["produced_by"] == "build_command";
}

test "the frontmatter survives the round-trip as a --- prelude" {
    out = dump_agir(load_agir(MALFORMED_IR));
    assert out.startswith("---\n");
    assert "name: pdf" in out;
    assert load_agir(out).get("_frontmatter").get("name") == "pdf";
}

test "a multi-line tool body is emitted as a | block, not an escaped one-liner" {
    out = dump_agir(load_agir(MALFORMED_IR));
    assert "body: |" in out;
    assert "\\n" not in out.split("body:")[1].split("walker:")[0];
    body = load_agir(out).get("tools").get("build_command").get("body");
    assert "def build_command" in body;
    assert "\n" in body;
}

test "block_scalars=False reproduces the old escaped form" {
    out = dump_agir(load_agir(MALFORMED_IR), False);
    assert "body: |" not in out;
    assert strict_parses(out);
}

test "a non-mapping is an empty document, never a crash" {
    assert dump_agir("not an ir") == "";
    assert dump_agir(None) == "";
}
