# Sigil

**A self-evolving agent that *is* an object-spatial graph.** A frontier model
crystallizes each task into a typed procedure; a small model runs it; the
procedures persist as the agent itself. No `SOUL.md`, no `SKILL.md`, no config
files — the agent's identity, skills and memory are all nodes on one graph.

---

## The idea

Most "self-evolving" agents evolve *fuzzily*: they accumulate prompt/memory
snippets and hope a big model reuses them. Sigil evolves *by construction*.
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

## Bring your own tools & skills — at runtime, no restart

Because config and skills are graph state, adding either is just a graph mutation that
takes effect on the **next** `solve` (more dynamic than editing files + restarting):

```bash
# BYO MCP server (drop-in tools) — via byLLM's native McpClient (stdio / sse / http)
$JAC add-mcp github stdio gh-mcp                 # or: add-mcp search http http://localhost:9000/mcp
$JAC mcp                                          # list registered servers + their discovered tools
# its tools are now available to the crystallizer (bound by name) and to live runs (_live_tool)

# BYO skills — three ingress forms, cheapest-effort to most-control
$JAC register-skill ./my-skill/SKILL.md          # frontier lifts SKILL.md -> AG-IR -> compile
$JAC register-skill ./procedure.agir  agir        # compile a hand-authored AG-IR (no model call)
$JAC register-skill ./crystallized/foo_v1.jac osp # drop in a precompiled OSP module
```

MCP servers are `McpServer` nodes on the `Soul`; skills are `TaskGraph`s in the `Registry`.
A crystallized agent's live-tool calls (`_live_tool`) dispatch to whichever registered
server exposes the tool; the frontier binds those tool names when it crystallizes. A *new*
capability an *old* skill should use = a `mutate`. In server mode (`jac start`), the same
operations are `walker:pub` endpoints — swap to `:priv` and each user gets an isolated graph
(their own soul, skills, and MCP servers) with auth, for free.

## Chat mode — run the whole agent from one conversation

`chat` is not a thin wrapper over `solve`; it's a **conversational, tool-using ReAct
agent** (`chat_agent.jac`) that can do everything from a single conversation — the
way you'd use OpenClaw, but graph-native.

```bash
JAC="jac run main.jac -s sigil.session --"
$JAC chat            # a Claude-style REPL: markdown replies, a LIVE trace of every
                     # tool call, and inline approval prompts for gated shell commands
```

One agent, one running conversation, the full tool-belt:

- **Sandboxed workspace** — `ws_read/ws_write/ws_edit/ws_list` are **jailed** to one
  directory (an escaping path is refused, not clamped); `ws_exec` runs only through the
  **exec-approval gate** and, per `sandbox_mode`, in a cwd-confined subprocess (`jail`,
  default) or a locked-down Docker container (`docker`, `--network none --cap-drop ALL`).
- **Web** — `web_search` (keyless) + `web_fetch` with an **SSRF guard** (loopback /
  private / link-local hosts refused).
- **Its own cron** — `schedule_task` / `list_scheduled` / `cancel_scheduled`. "every
  morning", "in 2 hours", "on a cron" all schedule real `CronJob` nodes from chat.
- **Memory & skills** — `remember_fact` / `recall_memory`, and `learn_skill` to
  crystallize a durable, reusable procedure (the frontier→AG-IR→OSP loop) mid-chat.
- **Parallel sub-agents** — `spawn_parallel` fans independent sub-tasks out to
  concurrent workers via Jac's **`flow`/`wait`** over `root spawn` (a `SubAgent` walker
  per task); `spawn_subagent` delegates one. They finish in ~1× wall-clock, not N×.
- **External** — `mcp_call` (any registered MCP tool) and `send_message` (any channel).

Everything drives the **same persistent graph** as the one-shot commands, so a fact
remembered or a job scheduled in chat is there for `solve`, cron, and the Observatory.

### Connect a messaging channel

Sigil's messaging contract is one webhook: an adapter forwards each inbound message to
`POST /walker/api_inbound` as `{channel, peer, text}` and delivers the reply. Ask in
chat ("how do I connect Discord?") or use the guided commands:

```bash
$JAC channel setup telegram          # step-by-step: token → env var → webhook wiring
$JAC channel connect tg telegram     # registers the Channel node + a token SecretRef
```

Supported guides: **discord · telegram · whatsapp · slack** (each rides the same
`api_inbound` contract; the per-provider adapter is the only glue).

## Layout

The two entrypoints live at the repo root; the agent itself is the `src/` package.

```
main.jac                 CLI entrypoint (chat / solve / config / soul / channel / tasks / … )
observatory.jac          full-stack server entrypoint (`jac start`) — API + web UI
jac.toml                 project + dependency manifest
src/                     the agent package
  sigil.jac                graph model + walkers + the two-tier cognition (crystallize/execute)
  chat_agent.jac           the conversational ReAct agent — the full chat-mode tool-belt
  sigil_workspace.jac      the sandbox: jailed file tools, gated exec, SSRF-guarded web
  sigil_subagents.jac      parallel sub-agents (flow/wait over root-spawned SubAgent walkers)
  sigil_channels_setup.jac channel connection guides + one-call graph bootstrap
  sigil_runtime.jac        disk + OS glue: persist a lowered module, run it isolated
  sigil_mcp.jac            adapter over byLLM's native McpClient — discovery + rung-0 dispatch
  agent.jac                run_task hook bus + the OpenAI-compatible walkers (api_*)
  channels.jac             messaging surface + inbound→reply loop + reactions/threads/edits
  cron.jac / sigil_cron.jac  scheduling (graph CronJob/CronRun; native due-time math)
  hooks.jac                lifecycle hook bus (before/after_solve, message_received, …)
  approvals.jac            exec-approval gate + allowlist + break-glass elevation
  sigil_secrets.jac        SecretRef indirection (env-backed, redacted)
  sigil_sessions.jac       per-dm_scope transcripts with daily reset
  sigil_tasks.jac          background task ledger (Attempt + CronRun projection)
  sigil_plugins.jac        openclaw.plugin.json manifest install
  sigil_migrate.jac        OpenClaw export → graph migration
  sigil_chat.jac           chat REPL (markdown, live tool trace, inline approvals) + setup/config
  views.jac / sigil_observe.jac  Observatory graph + token-observability projections
  compiler/                vendored AG-IR → OSP compiler (the LOWER engine) + runtime asset
  contracts/               the AG-IR authoring contract (seed for the on-graph Spec node)
  *.test.jac               unit-test annexes (run with `jac test src/<module>.jac`)
  crystallized/            (runtime) lowered OSP modules — the agent's learned skills
web/                     the Observatory browser client (cl)
*.session                (runtime) the persistent graph
```

Execution isolation: a compiled OSP agent builds its *own* task-graph off `root`
when it runs, so Sigil runs each crystallized module in a **separate
subprocess** — the run's throwaway graph never touches Sigil's own.

## Use

```bash
# the graph persists in a session file across every invocation
JAC="jac run main.jac -s sigil.session --"

$JAC soul                                        # identity, config, skills & memory (all graph state)
$JAC teach "the user always wants CSV with a header row"
$JAC configure small_model ollama_chat/qwen3:8b  # mutate config on the graph — no file written
$JAC solve "extract the tables from report.pdf as csv"   # crystallize → run → learn
$JAC solve "pull the tables out of invoice.pdf"          # HIT: reuse the crystallized procedure
$JAC library                                     # the crystallized skills, with run stats
```

Cognition is configured on the graph (or seeded from env on first boot):
`SIGIL_FRONTIER` (default `gpt-5`), `SIGIL_SMALL` (default `ollama_chat/qwen3:32b`),
`SIGIL_ROUTER`. The frontier needs its provider key; the small model can be local.

## Status

The graph model, routing, the frontier→AG-IR→compile→persist pipeline, and the
full soul/memory/config lifecycle are built and verified: the compile half lowers
a real AG-IR to a working OSP `run()`; `jac check` is clean; and `teach` /
`configure` / `recall` / `soul` persist across separate processes. The live
`solve` loop needs the configured models (frontier provider key + a small model).
