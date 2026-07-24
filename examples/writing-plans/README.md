# writing-plans — a real skill, compiled, running on a local 8B

This bundle takes a real community skill — [`writing-plans`](https://github.com/obra/superpowers-skills/tree/main/skills/collaboration/writing-plans)
from the [superpowers](https://github.com/obra/superpowers-skills) library — through
Sigil's middle, the **AG-IR**, and out the other side as a standalone runnable that
executes faithfully on a **fully-local 8B model** (`gemma4`, Q4_K_M, via Ollama —
no API key, nothing in the cloud).

```bash
# runs on a local 8B; the produced plan lands in ./plan_file.out
SIGIL_MODEL=ollama_chat/gemma4 ./writing-plans.jac \
  "Add per-API-key rate limiting to our public FastAPI endpoints using Redis"
```

[`run-trace.txt`](run-trace.txt) is a real run — every node, timed. The plan it
wrote is checked in as [`sample-output.md`](sample-output.md): a 12 KB
implementation plan, three test-driven tasks with exact file paths, complete code,
and per-task commit steps — written by an 8B because the structure the model would
otherwise skip is baked into the graph.

## The three files, and the pipeline they trace

| file | what it is |
|---|---|
| [`SKILL.md`](SKILL.md) | the source skill — plain-markdown instructions |
| [`writing-plans.agir`](writing-plans.agir) | the **AG-IR**: the skill as a typed graph |
| [`writing-plans.jac`](writing-plans.jac) | the ejected runnable — the mechanical lowering of the AG-IR |

The AG-IR is six nodes — two model slots and four code nodes — no more:

```
draft_header ─▶ write_tasks ─▶ assemble ─▶ verify ─▶ save ─▶ done
  (by llm)       (by llm)      (code)     (gate)    (write)
```

- **`draft_header`, `write_tasks`** are typed `by llm` slots — the two points where
  the skill genuinely calls for judgment. Each `reads: [task]`, so the model always
  sees what it is planning; the skill's header and task formats ride each slot as
  resident knowledge.
- **`assemble`** joins them deterministically (code, no model).
- **`verify`** is a gate: a code check that the plan actually contains task sections
  with code — a typed `bool` verdict, not a vibe.
- **`save`** is the embodied artifact write — the deliverable reaches disk.

That is the whole point of compiling a skill: on a weak model a prompt's steps are
optional, but a node the walker must visit is not.

## Honest note on how this AG-IR was authored

This AG-IR is **hand-authored** — it is the `agir` ingress path
(`sigil register-skill ./writing-plans.agir agir`), not the output of
`sigil compile ./SKILL.md`. It demonstrates the **AG-IR → runnable → local-8B** half
of the pipeline end to end, faithfully.

The **automatic** `SKILL.md → AG-IR` compile of *this* skill — a judgment-heavy,
conversational planning skill — is still work in progress: the frontier compiler
tends to over-determinize its presentational prose into ceremony nodes, and does
not yet reliably produce a graph a small model runs clean. That gap, and the
closed-loop (compile → run → repair) architecture proposed to close it, is written
up in **[issue #83](https://github.com/sigilagent/sigil/issues/83)**. The lean AG-IR
here is exactly the target such a compiler should converge on.

For the fully-automatic path working end to end today, see the smaller
[`one-line-tldr`](../compiled) example, which compiles from `SKILL.md` with no model
for the run.

## Rebuild the runnable from the AG-IR

The `.jac` is the deterministic mechanical lowering of the `.agir` — regenerate it
any time:

```bash
sigil register-skill ./writing-plans.agir agir      # onto Sigil's graph
# or lower it directly with the mechanical back-end (no model, no graph)
```
