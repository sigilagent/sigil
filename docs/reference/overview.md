# Overview

Sigil is a self-evolving agent that **is** an object-spatial graph. Its identity,
configuration, skills, and memory are all nodes on one persistent graph rooted at
`root` — there are no `SOUL.md` / `SKILL.md` / config files on disk.

## The two-tier idea

The first time Sigil sees a class of task, a **frontier model** authors a typed
procedure (an AG-IR), a compiler lowers it to a runnable OSP agent, and that procedure
is persisted on the graph. From then on a **cheap/small model** executes it. You pay the
expensive model once to build the harness; the cheap model rides it forever.

## How a request flows

- **Chat mode** (`sigil chat`) — a conversational agent that holds a running
  conversation and uses tools directly: files, shell, web, cron, memory, skills, MCP,
  channels, and parallel sub-agents. This is the primary way to use Sigil. See
  [chat-and-tools](chat-and-tools.md).
- **`solve "<task>"`** — the one-shot crystallize→execute→learn loop: route the task to a
  known skill (HIT), author a new one (MISS), or adapt an existing one (PARTIAL). See
  [memory-and-skills](memory-and-skills.md).

## The graph (the "soul")

```
root ──Embodies──▶ Soul ──Knows──────▶ Spec       the AG-IR contract
  │                 │  ╲──Remembers──▶ Memory     semantic memory (durable facts)
  │                 ╲───Owns─────────▶ Registry
root ──Anchored──▶ Registry ──Crystallized──▶ TaskGraph   procedural memory (skills)
                                    TaskGraph ──Ran──────▶ Attempt   episodic memory (runs)
```

The `Soul` node holds all configuration — persona, model tiers, workspace, sandbox mode,
channels, policies. `awaken()` rebinds the agent's cognition from the graph on every run,
so a `configure` change takes effect on the next turn with no restart.

## Interfaces

- `sigil chat` — the conversational REPL (markdown, live tool trace, inline approvals).
- `sigil <command>` — one-shot CLI (`solve`, `soul`, `configure`, `cron`, `channel`,
  `docs`, `models`, `teach`, `recall`, …). Run `sigil` with no args for the full list.
- `sigil serve` (= `jac start observatory.jac`) — the full-stack server: REST API + the Observatory web UI
  (live agent-graph + token observability), plus the `api_inbound` webhook for channels.
