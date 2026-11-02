# Overview

Sigil is a skill compiler. You write a skill as plain markdown, and Sigil
compiles it into a typed agent harness: a program the model runs *inside*, so
every step, rule, and check in the skill is enforced by structure rather than
hoped for in a prompt. See [skill-compilation](skill-compilation.md) for the
pipeline.

Everything the compiler produces and needs lives on one persistent
object-spatial graph: compiled skills, configuration, memory. There are no
config files on disk.

## The two-tier economics

A frontier model is paid once, at compile time, to author the typed procedure
(the AG-IR) that the compiler lowers and gate-checks. From then on a cheap,
small, even fully-local model executes the compiled harness: the structure a weak
model would skip is no longer skippable.

## How a request flows

- **`sigil compile ./SKILL.md [-e out.jac]`** — the explicit path: compile a
  skill onto the graph; `-e` also ejects one self-contained runnable program.
- **`sigil solve "<task>"`** — the compiler applied at runtime: route the task
  against the compiled-skill library (**HIT** — run it on the cheap model),
  compile a new skill for a new class of task (**MISS**), or recompile an
  existing one to cover a near-match (**PARTIAL**). See
  [memory-and-skills](memory-and-skills.md).
- **Chat mode** (`sigil chat`) — a conversational agent over the same graph:
  files, shell, web, cron, memory, skills, MCP, channels, parallel sub-agents.
  See [chat-and-tools](chat-and-tools.md).

## The graph (the compiler's persistent memory)

```mermaid
graph LR
    root((root)) -->|Embodies| Soul
    root -->|Anchored| Registry
    Soul -->|Knows| Spec["Spec — the AG-IR contract"]
    Soul -->|Remembers| Memory["Memory — durable facts"]
    Soul -->|Owns| Registry
    Registry -->|Crystallized| TaskGraph["TaskGraph — a compiled skill"]
    TaskGraph -->|Ran| Attempt["Attempt — one run"]
    TaskGraph -->|MutatedFrom| TaskGraph
```

The `Soul` node holds all configuration — persona, model tiers, workspace, sandbox,
channels, policies. `awaken()` rebinds the agent's cognition from the graph on every run,
so a `configure` change takes effect on the next turn with no restart.

## Interfaces

- `sigil chat`, or just `sigil` — the conversational agent, full-screen (markdown,
  live tool trace, inline approvals); `sigil chat --classic` for the inline REPL.
- `sigil <command>` — one-shot CLI (`solve`, `soul`, `configure`, `cron`, `channel`,
  `docs`, `models`, `teach`, `recall`, …). Run `sigil` with no args for the full list.
- `sigil serve` (= `jac start observatory.jac`) — the full-stack server: REST API + the Observatory web UI
  (see below), plus the `api_inbound` webhook for channels.

## The Observatory

The web console has three places, in its top bar:

- **Studio** (the home page) — a chat with Sigil beside the shelf of compiled
  agents and a viewer that draws the selected agent's AG-IR as a graph. The chat is
  a general one. Ask for an agent and Sigil scopes it with you; once it is confident,
  it proposes the agent with a **Build** button, which compiles the SKILL.md it wrote
  and shows every compile stage in the conversation. The paperclip compiles a skill
  folder you already have. Each shelf entry shows its steps as marks: diamonds are
  steps the model decides, squares run as code, dots route or return. In the viewer,
  click a step to inspect it, and **Ask Sigil about this step** frames your next
  message around it. Set `SIGIL_CHAT_PROPOSE=0` to turn the Build proposal off.
- **Dashboard** — what needs you (approvals, failing skills or schedules, unfaithful
  compiles) and a tile for every other page: runs, usage, memory, automations,
  approvals, model providers, channels, MCP & tools, compile reports, the full skill
  library, settings and docs.
- **Settings** — model providers, models, keys and secrets, the agent's persona,
  behaviour, tool policy, workspace and sandbox, and the system.

⌘K searches all of it, and asks Sigil whatever you type.
