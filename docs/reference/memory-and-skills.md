# Memory and skills

Sigil has three graph-native memory layers plus the library of compiled skills.

## The three memory layers

- **Semantic** (`Memory` nodes) — durable facts. Add with `remember_fact` (chat)
  or `sigil teach "<fact>"`, retrieve with `recall_memory` /
  `sigil recall "<query>"`. Facts also grow automatically, distilled from
  completed tasks, and are injected into chat context each turn.
- **Episodic** (`Attempt` nodes) — every run, its outcome, and a summary.
- **Procedural** (`TaskGraph` nodes) — the compiled skills themselves.

Retrieval mode is set by `recall_mode`: `lexical` (deterministic word overlap, no model),
`vector` (litellm embeddings + cosine, needs `embed_model`), or `hybrid`.

## Skills (compiled procedures)

A skill enters the library two ways. Explicitly, with `sigil compile ./SKILL.md`,
which runs the full gated pipeline (see
[skill-compilation](skill-compilation.md)). Or at runtime via `solve`, where
compiling is the same compiler applied on demand: the frontier model authors the
typed procedure (AG-IR), the mechanical half lowers it, and the result persists
as a `TaskGraph`.

Later requests of the same kind are a **HIT** and run on the cheap model. A
near-match is a **PARTIAL**, and the procedure is recompiled to cover it. A new
kind is a **MISS**, compiled fresh.

In chat, `learn_skill(task)` compiles a reusable skill on demand; use it only when you
want a durable, repeatable procedure rather than a one-off action.

### A compiled skill is a tool

The moment a skill compiles it joins the agent's own tool-belt as
`skill_<signature>`, described by its `intent`. The chat agent and its sub-agents
call it the way they call any other tool — the description is the trigger, so
nobody has to say "use the csv-clean skill" — under the tool policy and the skill
gate ([chat-and-tools](chat-and-tools.md#the-skill-gate)). `use_skill(signature,
task)` remains the by-name door.

A compiled skill can also call *another* compiled skill. A run is handed the rest
of the library (this skill excluded, policy already applied) through
`SIGIL_SKILL_TOOLS`, and the emitted prelude turns it into tools on the slots
that already carry an autonomy tool-belt. Each sibling runs in its own
subprocess, and the shelf is not passed down again, so composition is one level
deep by construction. An ejected artifact gets no such environment and stays
exactly as standalone as it was ([ejecting-agents](ejecting-agents.md)).

## Managing the library

```bash
sigil library                 # compiled skills with run stats
sigil tools skills            # …as tools: the name each answers to, and its gate
sigil eval <sig> [probe]      # grounded-eval a skill (run + judge the artifact)
sigil relearn <sig> [hint]    # recompile a skill fresh with the frontier
sigil forget <sig>            # remove a skill entirely (all versions + files)
```

The `auto_eval` valve (with `eval_threshold`) judges each skill run and can automatically
relearn a degraded procedure. Isolation: each compiled module runs in a separate
subprocess, so a run's throwaway task-graph never touches Sigil's own persistent graph.
