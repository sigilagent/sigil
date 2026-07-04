# Prometheus

**A self-evolving agent that *is* an object-spatial graph.** A frontier model
crystallizes each task into a typed procedure; a small model runs it; the
procedures persist as the agent itself. No `SOUL.md`, no `SKILL.md`, no config
files — the agent's identity, skills and memory are all nodes on one graph.

---

## The idea

Most "self-evolving" agents evolve *fuzzily*: they accumulate prompt/memory
snippets and hope a big model reuses them. Prometheus evolves *by construction*.
The first time it sees a class of task, a **frontier model authors an AG-IR** —
a typed graph contract for that task — which a **compiler lowers to a runnable
OSP agent**. That compiled procedure is **persisted on the graph** and, from then
on, executed by a **cheap model**. The expensive model is paid once, to build the
harness; the cheap model rides it forever.

```
        ┌─────────────── the agent's persistent graph ───────────────┐
        │                                                             │
 task ─▶ route ─┬─ HIT ──────▶ run crystallized OSP on the SMALL model │─▶ result
        │       ├─ MISS ─────▶ FRONTIER: task → AG-IR → compile → persist ─┐
        │       └─ PARTIAL ──▶ FRONTIER: mutate an existing procedure ──┐  │
        │                                                     new version ◀┘  │
        │        on small-model failure ─▶ FRONTIER mutate + retry (valve) ◀──┘
        └─────────────────────────────────────────────────────────────┘
```

Why this matters: the crystallized procedure carries **structure a weak model
cannot skip** (step order, embodied tools, grounded verification). So the cheap
model isn't asked to *be* smart — it's asked to *follow* a smart procedure. That
is where capability transfers from the frontier model to the cheap one.

## Everything lives on the graph

Inspired by OpenClaw's config-first *soul*, but with **nothing on disk**. There is
no markdown to author. The agent is a graph rooted at `root`:

```
root ──Embodies──▶ Soul ──Knows──────▶ Spec         the AG-IR contract (seeded onto the graph)
  │                 │  ╲──Remembers──▶ Memory       semantic memory — durable facts
  │                 ╲───Owns─────────▶ Registry
root ──Anchored──▶ Registry ──Crystallized──▶ TaskGraph      procedural memory — the skills
                                    TaskGraph ──Ran────────▶ Attempt     episodic memory — runs
                                    TaskGraph ──MutatedFrom─▶ TaskGraph  evolution lineage
```

- **Soul** — identity + config as *state you mutate in place*: persona, ethos,
  model tiers, channels. `awaken()` rebinds the cognition (which model is
  frontier/small/router, the ethos, the contract) *from the graph* on every run —
  the way a compiled OSP agent rebinds its `llm` in `run()`.
- **Three memory layers, all graph-native:**
  - **procedural** — `TaskGraph` nodes: the crystallized skills themselves.
  - **episodic** — `Attempt` nodes: every run, its outcome, a summary.
  - **semantic** — `Memory` nodes: durable facts, retrieved by deterministic
    lexical recall and injected as run-time context; grown automatically by
    `distill`-ing durable facts from each completed task.

The crystallized procedure is **class-general**; instance-specific memory is
injected only at *execution* time, never baked into the procedure.

## Layout

```
prometheus.jac        the agent: graph model + walkers + the two-tier cognition
main.jac              CLI (solve / library / soul / configure / teach / recall)
prom_runtime.py       disk + OS glue: persist a lowered module, run it isolated
compiler/             vendored AG-IR → OSP compiler (the LOWER engine) + runtime asset
contracts/            the AG-IR authoring contract (seed for the on-graph Spec node)
crystallized/         (runtime) lowered OSP modules — the agent's learned skills
*.session             (runtime) the persistent graph
```

Execution isolation: a compiled OSP agent builds its *own* task-graph off `root`
when it runs, so Prometheus runs each crystallized module in a **separate
subprocess** — the run's throwaway graph never touches Prometheus's own.

## Use

```bash
# the graph persists in a session file across every invocation
JAC="jac run main.jac -s prometheus.session --"

$JAC soul                                        # identity, config, skills & memory (all graph state)
$JAC teach "the user always wants CSV with a header row"
$JAC configure small_model ollama_chat/qwen3:8b  # mutate config on the graph — no file written
$JAC solve "extract the tables from report.pdf as csv"   # crystallize → run → learn
$JAC solve "pull the tables out of invoice.pdf"          # HIT: reuse the crystallized procedure
$JAC library                                     # the crystallized skills, with run stats
```

Cognition is configured on the graph (or seeded from env on first boot):
`PROM_FRONTIER` (default `gpt-5`), `PROM_SMALL` (default `ollama_chat/qwen3:32b`),
`PROM_ROUTER`. The frontier needs its provider key; the small model can be local.

## Status

The graph model, routing, the frontier→AG-IR→compile→persist pipeline, and the
full soul/memory/config lifecycle are built and verified: the compile half lowers
a real AG-IR to a working OSP `run()`; `jac check` is clean; and `teach` /
`configure` / `recall` / `soul` persist across separate processes. The live
`solve` loop needs the configured models (frontier provider key + a small model).
