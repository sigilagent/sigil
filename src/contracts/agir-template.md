# AG-IR authoring contract (compiler-exact)

Produce an AG-IR in EXACTLY this YAML shape. It is lowered by a compiler to a runnable
OSP agent; deviating from these keys makes it fail to compile.

## Required top-level structure
- `--- ... ---` frontmatter with `name` and `description`.
- `types:` — typed data. Each is `{kind: object, fields: {...}}` or `{kind: enum, members: [...]}`.
- `walker:` — `name` + `carries:` (the typed slots that flow through the run; each slot
  `{type, role?/produced_by?, doc}`).
- `nodes:` — the pipeline steps. Each `{id, type, owner, reads:[...], writes:[...], doc, ...}`.
  Node `type` ∈ {ROUTE, GEN-ENUM, GEN-FILL, GEN-RAW, SENSE, ACT (with `surface: artifact`),
  TERMINAL}. `owner` ∈ {model, code}. GEN-* = a model slot; ACT/SENSE = a code tool.
- `tools:` — only for deterministic code tools. Each `{surface: SENSE|ACT·artifact,
  sig: "(a, b) -> t", serves: [OP_ENUM], body: | <python> }`. For "author code then run it"
  tasks you do NOT need tools — use a GEN-RAW `write_code` node + an ACT `execute` node
  (the compiler emits the author→run→repair envelope automatically).
- `edges:` — REQUIRED. The node chain, in order: `- { from: <id>, to: <id> }`. Without
  edges the walker stops after the first node.

## Rules
- Output MUST be valid YAML. Put code/snippets in `body: |` block scalars or quoted strings.
  Never emit a raw `::py::` block or an unescaped `:` in an unquoted value.
- Prefer an embodied `command:`/`body:` code tool for deterministic steps; use a GEN-RAW
  `write_code` + ACT `execute` pair for open-ended "produce an artifact" tasks.
- Bind any REGISTERED TOOLS (MCP) by their EXACT name as SENSE/ACT nodes — do not re-script them.

## COMPLETE WORKING EXAMPLE — mimic this shape exactly

```yaml
---
name: file-writer
description: Author and run a Python script to produce a requested text/file artifact.
---
agir_version: 0.1
types:
  Args:
    kind: object
    fields:
      out: { type: str, doc: output file path parsed from the task }
walker:
  name: FileWriterAgent
  carries:
    task:     { type: str,  role: input, doc: user task verbatim }
    args:     { type: Args, produced_by: extract_args }
    script:   { type: str,  produced_by: write_code }
    artifact: { type: str,  produced_by: execute }
nodes:
  - id: activate
    type: ROUTE
    owner: model
    doc: Activation gate.
  - id: extract_args
    type: GEN-FILL
    owner: model
    output: Args
    reads: [task]
    writes: [args]
    doc: Parse the output file path from the task.
  - id: write_code
    type: GEN-RAW
    owner: model
    output: "python source"
    reads: [task, args]
    writes: [script]
    doc: Emit a self-contained Python script that produces the requested artifact and writes it to args.out.
  - id: execute
    type: ACT
    surface: artifact
    owner: code
    reads: [script]
    writes: [artifact]
    doc: Run the generated script to produce the artifact at args.out.
  - id: finish
    type: TERMINAL
    owner: code
    reads: [artifact]
    doc: Report the artifact path.
edges:
  - { from: activate,     to: extract_args }
  - { from: extract_args, to: write_code }
  - { from: write_code,   to: execute }
  - { from: execute,      to: finish }
```

Return ONLY the AG-IR text for the requested task, in this exact structure.
