# Memory and skills

Sigil has three graph-native memory layers plus the library of **compiled skills**.

## The three memory layers

- **Semantic** (`Memory` nodes) — durable facts. Add with `remember_fact` (chat) or
  `sigil teach "<fact>"`; retrieve with `recall_memory` / `sigil recall "<query>"`. Facts
  are also grown automatically by distilling durable facts from completed tasks, and are
  injected into chat context each turn.
- **Episodic** (`Attempt` nodes) — every run, its outcome, and a summary.
- **Procedural** (`TaskGraph` nodes) — the compiled skills themselves.

Retrieval mode is set by `recall_mode`: `lexical` (deterministic word overlap, no model),
`vector` (litellm embeddings + cosine, needs `embed_model`), or `hybrid`.

## Skills (compiled procedures)

A skill enters the library two ways: explicitly — `sigil compile ./SKILL.md`
runs the full gated pipeline (see [skill-compilation](skill-compilation.md)) —
or at runtime via `solve`, where "crystallizing" is the same compiler applied on
demand: the **frontier model** authors the typed procedure (AG-IR), the
mechanical half lowers it, and the result persists as a `TaskGraph`. Later
requests of the same kind are a **HIT** and run on the cheap model; a near-match
is a **PARTIAL** (the procedure is recompiled to cover it); a new kind is a
**MISS** (compiled fresh).

In chat, `learn_skill(task)` crystallizes a reusable skill on demand; use it only when you
want a durable, repeatable procedure rather than a one-off action.

## Managing the library

```bash
sigil library                 # crystallized skills with run stats
sigil eval <sig> [probe]      # grounded-eval a skill (run + judge the artifact)
sigil relearn <sig> [hint]    # re-crystallize a skill fresh with the frontier
sigil forget <sig>            # remove a skill entirely (all versions + files)
```

The `auto_eval` valve (with `eval_threshold`) judges each skill run and can automatically
relearn a degraded procedure. Isolation: each crystallized module runs in a separate
subprocess, so a run's throwaway task-graph never touches Sigil's own persistent graph.
