# AG-IR cookbook

A small library of **gate-clean golden AG-IRs**, one per authoring archetype.
Each was authored by a frontier model against
[`../writing-ag-ir.md`](../writing-ag-ir.md), then driven through the same
compile oracle and gate battery the compiler pipeline uses (G4 + G9), and
hand-reviewed. Every file here lowers and type-checks clean.

Use them three ways:

- **As worked examples** — copy the archetype closest to your task and adapt it.
- **As a starter library** — register one directly, no model call:
  ```bash
  sigil register-skill docs/reference/agir-cookbook/<name>.agir agir
  ```
- **As regression fixtures** — `src/compiler/mechanical/cookbook.test.jac` gates
  every `.agir` here, so a compiler change that breaks a golden IR fails loudly.

## The archetypes

| file | archetype | shows off |
|---|---|---|
| `word_frequency.agir` | pure-code pipeline (no model judgment) | builtin `read_file`/`write_file` bound by name; a custom `CODE` tool; `_inname`/`_outname` task-filename binding |
| `doc_tldr.agir` | model-judgment pipeline | a single `GEN-*` slot between a `SENSE` read and an `ACT` write |
| `md_to_text.agir` | SENSE → transform → ACT read/writer | the read/transform/write shape with the read/write filename fallback |
| `confirm_delete.agir` | human-in-the-loop gate | an `owner: code` `ROUTE` that consumes the human's answer with explicit guards (G6) |
| `contact_to_csv.agir` | typed model → code boundary | a `GEN-FILL` typed extraction feeding a code tool, with the carry typed to match (G9) |
| `bug_report.agir` | knowledge-heavy | a fixed output template embodied in `knowledge`, resident on the filling slot |
| `grep_summary.agir` | SENSE-heavy + model summary | the builtin `grep` tool feeding a model summary and an `ACT` write |

Each maps onto a section of the guide — read the guide first, then reach for the
example that matches the shape you need.

## Provenance

These are committed compiler output, not hand-tuned artifacts: authored by GPT-5
from the guide, repaired only through the bounded compile-oracle loop, and kept
only when they landed `clean` (G4 ok, no residual G9). The generator is
`_golden.jac` at the repo root (not shipped). Regenerate a single archetype with
`GOLDEN_ONLY=<name> jac run _golden.jac`.
