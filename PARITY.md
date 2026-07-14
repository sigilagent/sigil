# Sigil ↔ OpenClaw feature parity

OpenClaw is a ~14,000-file, ~125-plugin TypeScript product built over years. This maps
every OpenClaw **feature category** to its Sigil status. The guiding principle is
OpenClaw's own: *"core stays lean; capability ships as plugins."* So parity means
implementing the **core categories** as graph-native Jac + the **extension mechanisms**,
and letting the long tail (52 providers, 27 channel adapters, native apps) ride those
mechanisms — exactly as OpenClaw ships them as plugins rather than core.

Legend: ✅ implemented (graph-native Jac, tested) · 🔶 mechanism present (rides byLLM /
MCP / the extension API — concrete adapters are the plug-in long tail) · 📋 gap (design
noted, not built).

---

## Core runtime & agent loop

| OpenClaw | Sigil | Status |
|---|---|---|
| Agent turn (intake→context→infer→tools→reply→persist) | `solve` walker: awaken→recall→route→execute→learn | ✅ |
| Config model: `SOUL.md`/persona/rules (file-based) | **`Soul` node** — persona, ethos, model tiers, channels, all on the graph (no files) | ✅ |
| System prompt assembly (`full`/`minimal`/`none` modes) | **`Soul.prompt_mode`** — full (ethos+memory) / minimal (contract only) / none (bare task); `configure prompt_mode` | ✅ |
| Sessions (dm scope, daily reset, transcripts) | `Attempt` episodic records; `Channel.dm_scope` (main/per-peer) | 🔶 |
| Compaction / pruning (prompt-cache economics) | byLLM history primitive; memory injected at run-time not baked in | 🔶 |
| Command queue (steer/queue/followup), streaming | single serialized `solve`; token stream via Observatory | 🔶 |
| Multi-agent / bindings / sub-agents | `walker:priv` per-user root; crystallized sub-procedures | 🔶 |
| Standing orders / commitments | cron `task` = the standing order; `Memory` = commitments | 🔶 |

## Automation / Cron  ✅ (explicit ask — fully built)

| OpenClaw | Sigil | Status |
|---|---|---|
| `cron add --at/--every/--cron --tz` | `cron add <name> <at\|every\|cron> <spec> "<task>" [tz] [channel]` | ✅ |
| One-shot `at` auto-deletes after success | `delete_after_run` (default true for `at`) | ✅ |
| Persisted jobs (`jobs.json`) | **`CronJob` nodes on the graph** (no file) | ✅ |
| Run history (`cron runs`) | **`CronRun` nodes** per fire (`cron runs <name>`) | ✅ |
| `cron list/show/rm/enable/disable` | same commands | ✅ |
| Scheduler fires the agent | `cron_tick` → `solve()`; driven by jac-scale scheduler / daemon / external cron | ✅ |
| — | **native LLVM binary** `cron_native.na.jac`→`jac nacompile`→`bin/cron_native` for the due-time math | ✅ |
| Webhook / Gmail-PubSub triggers | `api_inbound` webhook endpoint (channels) | 🔶 |
| Hooks (`/new`, `/reset`, lifecycle) | **`hooks.jac`** — Hook nodes + `fire_hooks(event)` | ✅ |
| Background task ledger (`tasks list/show`) | `CronRun` + `Attempt` records | 🔶 |

## Channels  ✅ mechanism + loop built

| OpenClaw | Sigil | Status |
|---|---|---|
| Channel plugin registration (`registerChannel`) | **`Channel` node** + `channel_add/list/rm` | ✅ |
| Inbound message → agent → reply | **`inbound(channel, peer, text)`** → `solve` → outbound record | ✅ |
| `message send/broadcast` | `message_send(channel, peer, text)` | ✅ |
| Webhook channel | **`api_inbound` HTTP endpoint** (ready webhook) | ✅ |
| dm scope routing (main/per-peer) | `Channel.dm_scope` | ✅ |
| 27 concrete adapters (discord/slack/telegram/whatsapp/matrix/imessage/…) | any adapter POSTs to `inbound()` / delivers `outbound` | 🔶 (the plug-in long tail) |
| Reactions / threads / polls / edits | 📋 | 📋 |

## Tools / "superpowers"

| OpenClaw | Sigil | Status |
|---|---|---|
| Tool registration (`registerTool`) | AG-IR tool nodes + byLLM `tools=[…]` slots | ✅ |
| MCP tools (bundle plugins) | **byLLM `McpClient`** + `add-mcp` + rung-0 dispatch | ✅ |
| `exec`/`bash` + approval gate | `check_exec` gate (`approvals.jac`) + embodied command tools | ✅ (gate) / 🔶 (runner) |
| web_search / web_fetch | embodiment rung-0 `_live_tool` (real HTTP) + MCP search servers | 🔶 |
| Tool groups + `allow`/`deny`/`profile` | 📋 (policy fields on Soul) | 📋 |
| browser, image/video/music gen, pdf, tts | via MCP servers or a provider plugin | 🔶 |
| ACP harnesses (Claude Code/Codex/Cursor) | crystallized OSP agents are the harness; ACP bridge 📋 | 🔶 |

## Security

| OpenClaw | Sigil | Status |
|---|---|---|
| exec-approvals (`deny`/`allowlist`/`full` × `off`/`on-miss`/`always`) | **`approvals.jac`** — `ExecPolicy` + allowlist + pending-approval flow | ✅ |
| `/approve id allow-once\|allow-always\|deny` | **`approve(cmd, decision)`** | ✅ |
| Elevated / break-glass | 📋 (an elevated flag on the gate) | 📋 |
| Sandbox (docker/ssh/openshell) | crystallized runs isolated in a **subprocess** (graph-state isolation, not a security sandbox) | 🔶 |
| Secrets / SecretRefs | env + graph config; SecretRef indirection 📋 | 🔶 |
| Gateway auth (token/password/trusted-proxy) | jac-cloud `walker:priv` + JWT; token/proxy modes 📋 | 🔶 |
| SSRF / egress proxy | 📋 | 📋 |

## Memory

| OpenClaw | Sigil | Status |
|---|---|---|
| `memory-core` (SQLite FTS+vector, per-agent) | **three-layer graph memory** — procedural (`TaskGraph`), episodic (`Attempt`), semantic (`Memory`) | ✅ |
| `memory_search` / `memory_get` | `recall()` (lexical) + `teach()`; `recall` endpoint | ✅ |
| Exclusive "one active memory plugin" slot | the graph IS the memory; slot is `plugins.slots.memory` analog | 🔶 |
| LanceDB vector recall | swap `recall()` for embedding search (byLLM embeddings available) | 📋 |
| memory-wiki / active-memory / dreaming | dreaming = a cron sweep that `distill`s; wiki 📋 | 🔶 |

## Providers  🔶 (byLLM/litellm already covers all 52)

| OpenClaw | Sigil | Status |
|---|---|---|
| ~52 provider plugins (anthropic/openai/google/deepseek/groq/mistral/…) | **byLLM→litellm** covers every one of them out of the box | 🔶 |
| Local models (ollama/lmstudio/vllm/sglang) | byLLM `Model("ollama_chat/…")` etc. — already the default small tier | ✅ |
| `models list/set/aliases/fallbacks` | model tiers on `Soul` (`configure *_model`); `ModelPool` for fallback | 🔶 |
| Auth-profile rotation + model failover | byLLM `ModelPool(strategy="fallback")` | 🔶 |
| `registerProvider` extension point | byLLM model-name string = the provider selector | 🔶 |

## Plugins / Extensions

| OpenClaw | Sigil | Status |
|---|---|---|
| Bundle plugins = skills + MCP + config | **`register_skill`** (SKILL.md/AG-IR/OSP) + **`add-mcp`** | ✅ |
| Code plugins (`register*` API, ~40 slots) | Jac modules imported by the entry (cron/channels/hooks/approvals are exactly this) | 🔶 |
| `openclaw.plugin.json` manifest | AG-IR frontmatter + a `Plugin` manifest node 📋 | 🔶 |
| ClawHub registry / marketplace | 📋 | 📋 |
| Migration providers (migrate-claude/hermes) | 📋 (a trace→AG-IR crystallizer is the natural fit) | 📋 |

## Gateway / frontends

| OpenClaw | Sigil | Status |
|---|---|---|
| Gateway process (one per host, WS + HTTP) | `jac start observatory.jac` (jac-cloud) — API + client on one port | ✅ |
| CLI (~50 commands) | `main.jac` (solve/library/soul/configure/teach/recall/mcp/register-skill/cron/…) | 🔶 |
| Web Control UI | **Observatory** — live agent-graph + 100% token observability | ✅ |
| OpenAI-compatible `/v1/chat/completions`, `/tools/invoke` | `walker:pub api_*` endpoints; OpenAI-shape adapter 📋 | 🔶 |
| Bonjour/mDNS discovery, tailscale, multiple gateways | jac-cloud deploy features; discovery 📋 | 🔶 |
| Native companion apps (macOS/iOS/Android) | 📋 (jac-mobile/jac-desktop can package the client) | 📋 |
| Devices / node pairing / capabilities | 📋 | 📋 |

---

## What "parity" means here, honestly

- **Built graph-native + tested (✅):** the agent loop, Soul/config, three-layer memory,
  crystallized skills, MCP tools, **cron** (with a native binary), **channels** (the
  inbound→reply loop), **hooks**, **exec-approvals**, the Observatory Control-UI.
- **Rides an existing mechanism (🔶):** all 52 providers + local models (byLLM/litellm),
  tools (MCP + embodiment), the 27 channel adapters (each just calls `inbound()`), plugins
  (skills + MCP + Jac modules). These are *plugins* in OpenClaw too — not core.
- **Documented gaps (📋):** reactions/threads, elevated/sandbox hardening, SecretRefs,
  SSRF proxy, ClawHub, native companion apps, device pairing, OpenAI-compat HTTP shape.
  None are architectural blockers — each is a bounded addition on the existing graph model.

The Sigil difference throughout: OpenClaw keeps this state in `~/.openclaw/*.json`
files; Sigil keeps **all of it on one persistent object-spatial graph** — soul,
skills, memory, channels, cron jobs, hooks, approvals — visible live in the Observatory.
