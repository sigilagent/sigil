# Claude Code

Sigil and Claude Code connect in both directions. The two are independent — set
up either, or both.

| Direction | Command | What it gives you |
|---|---|---|
| Claude Code into Sigil | `sigil --claude …` | every model tier runs on your Claude subscription, no API keys |
| Sigil into Claude Code | `claude mcp add sigil -- sigil mcp-serve` | every compiled skill becomes a tool in your Claude Code session |

## Prerequisites

Both directions need the Claude Code CLI on your `PATH`, signed in.

```bash
claude --version          # e.g. 2.1.175 (Claude Code)
```

Nothing printed? Install Claude Code, then run `claude` once and sign in.

Confirm which account is signed in — in Direction 1 this is the account that
pays for every Sigil call:

```bash
jq -r '.oauthAccount.emailAddress // "not signed in"' ~/.claude.json
```

If it says `not signed in`, run `claude`, sign in, and re-check. A subscription
login is what makes this key-free; without one, `--claude` refuses to start
rather than silently billing something else.

And Sigil itself:

```bash
curl -fsSL https://github.com/sigilagent/sigil/releases/latest/download/install.sh | bash
sigil docs                # prints the reference topic list — the install is good
```

## Direction 1 — run Sigil on your Claude subscription

Every model tier (compiler, executor, router, chat) is answered by a headless
`claude -p` run against your own subscription. No `ANTHROPIC_API_KEY`, no
`OPENAI_API_KEY`, no proxy, no second auth.

### 1. Try it on one command

```bash
sigil --claude models
```

```
✦ claude mode: every tier runs on your local Claude Code CLI (you@example.com)
tiers:
  frontier : claude-cc/opus
  small    : claude-cc/haiku
  router   : claude-cc/haiku
```

Check two things: the email is yours, and every tier reads `claude-cc/…`. This
command binds the tiers without making a model call, so it costs nothing.

If you get `--claude needs a Claude Code subscription login` instead, there is no
login for Sigil to use — go back to [prerequisites](#prerequisites).

### 2. Compile something on it

```bash
sigil --claude compile ./examples/csv-clean/SKILL.md
sigil --claude chat                                    # chat, sub-agents, tools
sigil --claude solve "turn report.pdf into clean CSV"  # route + run
```

`--claude` is global: put it anywhere on the line, before or after the
subcommand. `SIGIL_CLAUDE=1` does the same for a whole shell.

### 3. Make it stick

**A. Everything on Claude Code**, for a shell or permanently:

```bash
export SIGIL_CLAUDE=1        # add to ~/.zshrc or ~/.bashrc
```

**B. Only the expensive tier on Claude Code**, execution somewhere cheap. No flag
needed, and this is the better default for anything that runs often:

```bash
sigil models set frontier claude-cc/opus       # compile on your subscription…
sigil models set small ollama_chat/qwen3:8b    # …execute locally, for free
```

Why B: every `claude -p` call ships Claude Code's own preamble, roughly 9k input
tokens per call even with all tools disabled. That is fine for compiling (rare,
expensive, judgment-heavy) and wasteful for a hot execution tier doing thousands
of calls. See [what it costs](#what-it-costs-honestly).

### The tier mapping

| Tier | Becomes | Override |
|---|---|---|
| `frontier`, `chat` | `claude-cc/opus` | `SIGIL_CLAUDE_FRONTIER` |
| `small`, `router` | `claude-cc/haiku` | `SIGIL_CLAUDE_SMALL` |

`sigil --claude models` reports the effective names, not the graph config they
shadow. A tier already set to a `claude-cc/…` name is left alone.

Model names after the slash are Claude Code aliases:

| Name | Binds to |
|---|---|
| `claude-cc/opus` | Opus — the default for `frontier` / `chat` |
| `claude-cc/sonnet` | Sonnet |
| `claude-cc/haiku` | Haiku — the default for `small` / `router` |
| `claude-cc/fable` | Fable |
| `claude-cc/default` | whatever your CLI is configured for (no `--model` passed) |

A full model id works too.

### Which account pays

Your Claude subscription, by construction. `--claude` names the account it is
using when it starts:

```
✦ claude mode: every tier runs on your local Claude Code CLI (you@example.com)
```

Left to itself, Claude Code would prefer an `ANTHROPIC_API_KEY` you had once
approved (it asks the first time it sees one and records the answer in
`~/.claude.json` under `customApiKeyResponses`), which would quietly turn "runs
on your subscription" into console billing. Sigil withholds the variable from the
CLI subprocess — your own environment is never modified, the child simply does
not receive it — so the subscription login is what answers.

If there is no login to use, `--claude` stops before binding a single tier rather
than failing on the first model call:

```
xx --claude needs a Claude Code subscription login, and this machine has none.
   Run `claude` once and sign in, then re-run.
   To bill an approved ANTHROPIC_API_KEY instead: SIGIL_CLAUDE_ALLOW_API_KEY=1
```

`SIGIL_CLAUDE_ALLOW_API_KEY=1` is the opt-out for anyone who wants API-key
billing: the key is passed through, and the startup line says `(api key)` so the
choice stays visible.

To see what the CLI itself would do:

```bash
jq '.customApiKeyResponses, .oauthAccount.emailAddress' ~/.claude.json
```

## Direction 2 — serve compiled skills into Claude Code

`sigil mcp-serve` speaks MCP over stdio and publishes one tool per compiled
skill, so Claude Code can call your compiled harnesses directly.

Sigil's own agents see the same shelf the same way — each compiled skill is a
tool on the chat agent's belt, under the same names
([chat-and-tools](chat-and-tools.md#compiled-skills--one-tool-each)). What is
served here is filtered by the same tool policy: a skill you
`configure tool_deny skill_<sig>` is not listed to Claude Code and cannot be
called by name. The approval gate is deliberately *not* applied over the wire —
there is no operator at the far end of a stdio pipe to answer it.

### 1. Compile at least one skill, with a `description:`

The frontmatter description becomes the MCP tool description, which is the only
thing Claude Code routes on. Write it as a "use when…" line:

```markdown
---
name: clean-csv
description: Use when a messy CSV file needs its headers normalized to clean snake_case names and blank rows removed, saved to a verified output file.
---
```

Omit it and the tool falls back to `compiled from SKILL.md (AI compiler)`, which
is valid and useless as a trigger. Then:

```bash
sigil compile ./examples/csv-clean/SKILL.md
sigil library
```

```
compiled procedures (1):
  clean_csv  v1  [compiled-skill]  runs=0 ok=0
```

### 2. Register the server

```bash
claude mcp add sigil -- sigil mcp-serve            # this project
claude mcp add sigil -s user -- sigil mcp-serve    # every project
```

If `sigil` may not be on the `PATH` of whatever launches Claude Code, give the
absolute path:

```bash
claude mcp add sigil -- "$HOME/.local/bin/sigil" mcp-serve
```

### 3. Start a fresh session and verify

```bash
claude mcp list           # sigil: sigil mcp-serve - ✔ Connected
```

Inside a session, `/mcp` shows the same thing. MCP tool lists are read at
startup, so a skill you compile in the terminal appears only after you restart
the Claude Code session.

### 4. If it will not connect, test the wire directly

The server is JSON-RPC 2.0 on stdio, so you can drive it by hand:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | sigil mcp-serve
```

```json
{"jsonrpc": "2.0", "id": 1, "result": {"protocolVersion": "2024-11-05", "serverInfo": {"name": "sigil", …}}}
{"jsonrpc": "2.0", "id": 2, "result": {"tools": [{"name": "skill_clean_csv", …}]}}
```

If that prints JSON and Claude Code still reports a failure, the problem is
registration or `PATH`, not the server.

### What Claude Code ends up seeing

| Tool | What it does |
|---|---|
| `skill_<signature>` | run that compiled skill on a task, pinned — no routing |
| `sigil_solve` | let Sigil route the task, compiling a new skill on a miss |
| `sigil_library` | list the compiled skills with their run statistics |

Each `skill_` tool's description is the skill's own frontmatter, so the trigger
is the same mechanism a subagent uses: Claude reaches for the skill when the task
looks like that skill's job. Claude Code decides *when*; the compiled harness
decides *how*. Inside the tool call there is no prompt to drift from, so what
comes back followed the skill by construction.

The server takes the same graph as the CLI (`~/.sigil/agent.session`), so a skill
you compile in the terminal shows up in Claude Code after a session restart.

This is the mirror of `sigil add-mcp`, which points the other way: there Sigil
consumes a tool server so the compiler can bind its tools into new skills.

## Running both directions at once

They are separate mechanisms, so there is nothing to reconcile. If you want the
skills served to Claude Code to also run their cognition on it, register the
server in claude mode:

```bash
claude mcp add sigil -- sigil --claude mcp-serve
```

The startup banner goes to stderr precisely so this works: `mcp-serve` keeps
stdout clean for the JSON-RPC wire. Be aware of what this builds, though — each
tool call is then a Claude Code session spawning `claude -p` subprocesses of its
own, paying the ~9k-token preamble on every slot. Pinning `small` to a local
model (Direction 1, option B) keeps that in check.

## How it works

byLLM routes every `by llm()` point through litellm, and litellm lets a handler
claim a provider prefix. Sigil registers one for `claude-cc`
([`src/sigil_claude_cc.jac`](../../src/sigil_claude_cc.jac)), so a Claude Code
subprocess is just another model — no byLLM change, no fork, no gateway.

```
by llm()  →  litellm.completion  →  claude-cc handler  →  claude -p  →  your subscription
```

Text in, text out is enough for every slot shape, including typed returns and
tool use, because byLLM already carries both as prose for models with no native
tool support: it appends the output JSON schema to the prompt and parses the
reply back, and it renders the tool list into a `<tool_call>{…}</tool_call>`
protocol it recovers from plain text. These tiers bind with
`native_tools = false`, and a prose reply is a complete answer.

Each call runs as a toolless one-off Claude Code agent (`tools: []`). That detail
is load-bearing rather than hygiene: a default `claude -p` session has
Read/Bash/Task, and when byLLM hands it a tool list the model reaches for *its*
tools instead of emitting the tool-call text byLLM parses, and the run dies on
`error_max_turns`. With no tools available, prose is the only move it has.

The subprocess also runs outside your project, with MCP servers and skills
disabled, so a repo `CLAUDE.md` cannot leak into a compile.

## What it costs, honestly

A `claude -p` run always ships Claude Code's own preamble — roughly 9k input
tokens per call, even with every tool disabled. Sigil keeps the flags and the
system prompt a fixed string so that prefix stays byte-identical between calls
and is served from the prompt cache, but it never goes away.

This mode buys subscription reuse, not cheapness. It fits compiling, which is
expensive, rare and judgment-heavy, and fits a hot execution tier badly, where a
local model or a direct API key is far cheaper per token. Expect ~1.5–4s of
latency per slot.

If you want Claude *and* the cheapest tokens, skip this mode and use the normal
Anthropic provider with a key: `sigil models set frontier claude-sonnet-4-6`.

## Nothing is killed on a timer

A slot call has no time limit by default, and neither does an agent session.

`SIGIL_CLAUDE_CC_TIMEOUT` used to default to 600s, and it killed real work: one
spec-loop call on a document-sized `SKILL.md` ran past ten minutes, was killed
with everything it had produced thrown away, then retried into the same wall
twice more — half an hour of subscription spend for an error message. Unlike a
shell job there is no partial output to salvage from a slot call, so a deadline
buys nothing; it only decides whether the work is lost. `--max-turns` is the real
bound on an agent session.

Set either variable for an unattended deployment (cron, a server) where a
genuinely hung CLI would block forever with nobody at the keyboard to interrupt
it. Interactively, Ctrl-C is the timeout.

The one exception is `web_search`, which keeps a 180s ceiling: a search that has
not answered in three minutes is stuck, and there is nothing to salvage there
either.

## Watching the model write

Every `claude -p` call runs with `--output-format stream-json
--include-partial-messages`, so the reply arrives as deltas rather than in one
lump. Sigil taps those on the way past and prints them: during a compile you
watch the AG-IR being written, thinking included, under the stage that asked for
it.

The stream ends with the same `result` object the non-streaming form returns, so
token accounting, cost and `sigil_observe` are unchanged — the only difference is
that you can see it happen.

Turn it off with `--quiet`, `SIGIL_VERBOSE=0`, or `sigil configure verbose off`.

Streaming is claude-mode only. It is the provider Sigil owns; making an arbitrary
litellm provider stream would mean declaring the compiler's byLLM slots
`stream=True`, which changes every slot's return type. Other providers still get
the staged build view.

## Web search without a key

`web_search` normally needs a Brave or Firecrawl key, because keyless engines
serve bot challenges rather than results. In claude mode it doesn't: the machine
already has a search-capable agent you are paying for, so the same seam that
answers a byLLM slot answers a search.

The order is Brave → Firecrawl → Claude. A direct search API is faster and
cheaper than a model turn, so a key still wins when you have one; the Claude
route is what makes `sigil --claude` work with no search signup at all.

This is the one place a `claude -p` run is handed a tool on purpose. The slot
agent above is deliberately toolless; the search agent has exactly `WebSearch`, a
JSON-only reply contract, and nothing else it could reach for. It runs on `haiku`
by default (`SIGIL_CLAUDE_SEARCH_MODEL`), since a search is retrieval rather than
judgment.

It is gated on claude mode specifically. Spending your subscription on a search
you never asked to spend it on would be a surprise; in claude mode you have
already said every model call goes through that CLI.

## Limits

- **Text only.** Images and video in a slot are dropped with a marker in the prompt.
- **Streaming arrives in one chunk.** The reply is complete and correct, but in
  chat mode it lands all at once instead of token by token.
- **One completion per call.** Slots are bounded to a single turn, so Claude Code
  never runs an agent loop of its own inside one of Sigil's slots.
- **Ejected runnables can't use it.** `sigil compile -e agent.jac` produces a
  standalone file with no Sigil imports, so `SIGIL_MODEL=claude-cc/…` has nothing
  to register the provider. Give an ejected program a normal provider name.

## Optional: letting an agent author the AG-IR

`--agent` swaps the compiler's front-end: instead of authoring the AG-IR through
a staged pipeline of byLLM slots, a Claude Code session writes it directly,
verifying each draft against the compile oracle.

```bash
sigil --claude compile ./SKILL.md --agent
```

It is opt-in, and the reason is worth being precise about. What it keeps:

- the spec loop, unchanged — every rule must quote your skill verbatim, so a
  hallucinated obligation is still dropped mechanically before authoring starts;
- the gate battery — G1 (embodiment), G4 (compile oracle, with the same bounded
  repair loop), G5 (every mandatory rule realized by a node).

What it drops: LIFT's staged authoring — the workflow spine, the annotator flows,
the assemble step, the view repair that routes each issue back to the flow that
owns it, and the coverage critics that hunt for dropped obligations across
several rounds.

So it is faster, and it runs on a subscription instead of a frontier key. It is
not more trustworthy. The honest framing is *agent-authored, gate-verified*,
which is not *verified the way LIFT verifies*. Use the default pipeline when
faithfulness is the priority.

The session gets a workspace with four files and nothing else on its path:

| File | What it is |
|---|---|
| `writing-agir/SKILL.md` | the meta-skill: how to write an AG-IR, and what the gates check |
| `SKILL.md` | the skill being compiled |
| `rules.md` | the frozen rule set, with ids — the contract the IR is audited against |
| `agir-template.md` | the compiler-exact YAML shape (plus the full reference files) |

It writes `agent.ir` and runs `sigil gate agent.ir <name>` after every edit. Each
node carries `traces_to: [r3, r7]` naming the rules it realizes, which is what G5
audits, so "it compiles" is never mistaken for "it covers the skill".

`SIGIL_CLAUDE_AUTHOR_TURNS` (default `80`) bounds the session.

`--agent` only needs the `claude` binary — the authoring session always runs on
it. Combining it with `--claude` additionally puts the spec loop on Claude Code;
without `--claude` the spec loop runs on your configured `frontier` tier. Needs a
CLI recent enough to support `--agents` / `--agent`.

## Optional: when a compile fails

The compiler's repair loop is a bounded byLLM slot: it sees `(ir, diagnostic)`
and proposes a fix, and the G4 compile oracle re-gates every attempt. When those
attempts are spent, `--claude` (or `SIGIL_CLAUDE_REPAIR=1`) escalates instead of
giving up.

The escalation is a tool-using Claude Code session in a scratch workspace holding
the failing `agent.ir` and the AG-IR authoring contract. It gets one verification
command:

```bash
sigil gate agent.ir <name>      # G4, exit nonzero while the IR is broken
```

so it can edit, re-run the oracle, and iterate — the loop a single slot call
can't do. When it finishes, Sigil re-gates the file itself and accepts only a
result that passes. The oracle stays the authority; the agent only proposes.

`sigil gate` is a first-class command, useful on its own for a hand-written IR or
a CI check.

| Variable | Default | What it does |
|---|---|---|
| `SIGIL_CLAUDE_REPAIR` | unset (set by `--claude`) | `1` arms the escalation |
| `SIGIL_CLAUDE_REPAIR_TURNS` | `40` | turn budget for the repair session |

Escalation costs a full agent session rather than one slot call, so it is never
the silent default.

## Environment

| Variable | Default | What it does |
|---|---|---|
| `SIGIL_CLAUDE` | unset | `1` turns on claude mode, same as `--claude` |
| `SIGIL_CLAUDE_FRONTIER` | `claude-cc/opus` | model for the `frontier` / `chat` tiers |
| `SIGIL_CLAUDE_SMALL` | `claude-cc/haiku` | model for the `small` / `router` tiers |
| `SIGIL_CLAUDE_BIN` | `claude` | path to the Claude Code binary |
| `SIGIL_CLAUDE_CC_TIMEOUT` | unset | seconds before one slot call is killed; unset means no limit |
| `SIGIL_CLAUDE_AGENT_TIMEOUT` | unset | seconds before an agent session (authoring, repair) is killed; unset means no limit |
| `SIGIL_CLAUDE_ALLOW_API_KEY` | unset | pass `ANTHROPIC_API_KEY` through, billing it instead of the subscription |
| `SIGIL_CLAUDE_CC_CWD` | temp dir | working directory for the subprocess |
| `SIGIL_CLAUDE_SEARCH_MODEL` | `haiku` | model that answers a `web_search` |
| `SIGIL_CLAUDE_SEARCH_TIMEOUT` | `180` | seconds before one web search is killed |
| `SIGIL_CLAUDE_AUTHOR_TURNS` | `80` | turn budget for an `--agent` authoring session |
| `SIGIL_CLAUDE_REPAIR` | unset | `1` arms repair escalation |
| `SIGIL_CLAUDE_REPAIR_TURNS` | `40` | turn budget for the repair session |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `--claude needs a Claude Code subscription login` | no `oauthAccount` in `~/.claude.json` | run `claude`, sign in, re-run |
| `` `claude` not found on PATH `` | CLI not on the `PATH` Sigil sees | install it, or `export SIGIL_CLAUDE_BIN=/full/path/to/claude` |
| `the claude CLI is not logged in` | login expired or never happened | run `claude`, sign in |
| `the Anthropic account backing the claude CLI is out of credit` | the CLI is billing an API key, not a subscription | `jq '.customApiKeyResponses' ~/.claude.json`; or move the tier: `sigil models set <tier> <model>` |
| banner says `(api key)` instead of your email | `SIGIL_CLAUDE_ALLOW_API_KEY` is set | unset it — Sigil then withholds `ANTHROPIC_API_KEY` from the subprocess |
| a call is killed on a deadline | `SIGIL_CLAUDE_CC_TIMEOUT` / `SIGIL_CLAUDE_AGENT_TIMEOUT` is set in your environment | unset it; both default to no limit |
| new skill missing in Claude Code | tool lists are read at session start | restart the Claude Code session |
| a skill tool has a generic description | no `description:` in the SKILL.md frontmatter | add one, recompile, restart the session |
| chat replies land all at once | streaming arrives in one chunk in this mode | expected — see [limits](#limits) |
| an ejected `agent.jac` rejects `claude-cc/…` | ejected runnables have no Sigil imports to register the provider | give the ejected program a normal provider name |

## See also

- [models](models.md) — the tier system, aliases, and fallback chains
- [skill-compilation](skill-compilation.md) — what the frontier tier is doing
