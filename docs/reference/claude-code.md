# Claude Code

Sigil and Claude Code connect in both directions, and the two are independent —
run either, or both:

| Direction | Command | What it gives you |
|---|---|---|
| Claude Code **into** Sigil | `sigil --claude …` | every model tier runs on your Claude subscription — no API keys |
| Sigil **into** Claude Code | `claude mcp add sigil -- sigil mcp-serve` | every compiled skill becomes a tool in your Claude Code session |

On top of the first, a failed compile can escalate to a tool-using Claude Code
session that runs the compile oracle itself — see [when a compile
fails](#when-a-compile-fails).

Setting this up for the first time? [claude-code-setup](claude-code-setup.md)
is the step-by-step version — prerequisites, verification at each step, and a
troubleshooting table. This page is the explanation behind it.

## Claude Code as the model

Sigil can run its cognition on the **Claude Code CLI you already have installed**,
instead of on a provider API key. Every model tier — the compiler, the executor, the
router, chat — is answered by a headless `claude -p` run against your own Claude
subscription.

```bash
sigil --claude compile ./SKILL.md     # compile a skill on Claude Code
sigil --claude chat                   # chat, sub-agents, tools — all on Claude Code
sigil --claude solve "turn report.pdf into clean CSV"
```

`--claude` is global: put it anywhere in the command line, before or after the
subcommand. `SIGIL_CLAUDE=1` does the same thing for a whole shell.

No `ANTHROPIC_API_KEY`, no `OPENAI_API_KEY`, no proxy, no second auth. If
`claude` runs in your terminal, Sigil can compile with it.

## What the tiers become

| Tier | Becomes | Override |
|---|---|---|
| `frontier`, `chat` | `claude-cc/opus` | `SIGIL_CLAUDE_FRONTIER` |
| `small`, `router` | `claude-cc/haiku` | `SIGIL_CLAUDE_SMALL` |

`sigil --claude models` reports the effective names, not the graph config they
shadow. A tier already set to a `claude-cc/…` name is left alone.

You can also name one directly, with no flag, and leave the other tiers on their
usual providers:

```bash
sigil models set frontier claude-cc/opus     # compile on Claude Code…
sigil models set small ollama_chat/qwen3:8b  # …execute locally, for free
```

The model after the slash is a Claude Code model alias — `opus`, `sonnet`,
`haiku`, `fable` — or a full model id. `claude-cc/default` omits `--model` and
takes whatever your CLI is configured for.

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
protocol it recovers from plain text. So these tiers bind with
`native_tools = false` and a prose reply is a complete answer.

Each call runs as a **toolless** one-off Claude Code agent (`tools: []`). That
detail is load-bearing, not hygiene: a default `claude -p` session has
Read/Bash/Task, and when byLLM hands it a tool list the model reaches for *its*
tools instead of emitting the tool-call text byLLM parses — the run then dies on
`error_max_turns`. With no tools available, prose is the only move it has.

## Requirements

- Claude Code on `PATH` (`claude --version`), signed in.
- A recent enough CLI to support `--agents` / `--agent` (custom agent definitions).

### Which account pays

**Your Claude subscription — by construction.** `--claude` names the account it
is using when it starts:

```
✦ claude mode: every tier runs on your local Claude Code CLI (you@example.com)
```

Left to itself, Claude Code would prefer an `ANTHROPIC_API_KEY` you had once
approved (it asks the first time it sees one and records the answer in
`~/.claude.json` under `customApiKeyResponses`). That would quietly turn "runs on
your subscription" into console billing. So Sigil **withholds the variable from
the CLI subprocess** — your own environment is never modified, the child simply
does not receive it — and the subscription login is what answers.

If there is no login to use, `--claude` **stops before binding a single tier**
rather than failing on the first model call:

```
xx --claude needs a Claude Code subscription login, and this machine has none.
   Run `claude` once and sign in, then re-run.
   To bill an approved ANTHROPIC_API_KEY instead: SIGIL_CLAUDE_ALLOW_API_KEY=1
```

`SIGIL_CLAUDE_ALLOW_API_KEY=1` is the opt-out for anyone who *wants* API-key
billing: the key is passed through, and the startup line says `(api key)` so the
choice stays visible.

To see what the CLI itself would do:

```bash
jq '.customApiKeyResponses, .oauthAccount.emailAddress' ~/.claude.json
```

## Environment

| Variable | Default | What it does |
|---|---|---|
| `SIGIL_CLAUDE` | unset | `1` turns on claude mode, same as `--claude` |
| `SIGIL_CLAUDE_FRONTIER` | `claude-cc/opus` | model for the `frontier` / `chat` tiers |
| `SIGIL_CLAUDE_SMALL` | `claude-cc/haiku` | model for the `small` / `router` tiers |
| `SIGIL_CLAUDE_BIN` | `claude` | path to the Claude Code binary |
| `SIGIL_CLAUDE_CC_TIMEOUT` | unset | seconds before one slot call is killed; **unset means no limit** |
| `SIGIL_CLAUDE_AGENT_TIMEOUT` | unset | seconds before an agent session (authoring, repair) is killed; unset means no limit |
| `SIGIL_CLAUDE_ALLOW_API_KEY` | unset | pass `ANTHROPIC_API_KEY` through, billing it instead of the subscription |
| `SIGIL_CLAUDE_CC_CWD` | temp dir | working directory for the subprocess |
| `SIGIL_CLAUDE_SEARCH_MODEL` | `haiku` | model that answers a `web_search` (see below) |
| `SIGIL_CLAUDE_SEARCH_TIMEOUT` | `180` | seconds before one web search is killed |

The subprocess deliberately runs outside your project, with MCP servers and
skills disabled, so a repo `CLAUDE.md` can't leak into a compile.

## Nothing is killed on a timer

A slot call has no time limit by default, and neither does an agent session.

`SIGIL_CLAUDE_CC_TIMEOUT` used to default to 600s, and it demonstrably killed real
work: one spec-loop call on a document-sized `SKILL.md` ran past ten minutes, was killed
with everything it had produced thrown away, then retried into the same wall twice more —
half an hour of subscription spend for an error message. Unlike a shell job there is no
partial output to salvage from a slot call, so a deadline buys nothing at all; it only
decides whether the work is lost. `--max-turns` is the real bound on an agent session.

Set either variable for an **unattended** deployment — cron, a server — where a genuinely
hung CLI would block forever with nobody at the keyboard to interrupt it. Interactively,
Ctrl-C is the timeout.

The one exception is `web_search` (below), which keeps a 180s ceiling: a search that has
not answered in three minutes is stuck, and there is nothing to salvage there either way.

## Web search without a key

`web_search` normally needs a Brave or Firecrawl key, because keyless engines serve bot
challenges rather than results. In claude mode it doesn't: the machine already has a
search-capable agent you are paying for, so the same seam that answers a byLLM slot
answers a search.

The order is Brave → Firecrawl → Claude. A direct search API is faster and cheaper than a
model turn, so a key still wins when you have one; the Claude route is what makes
`sigil --claude` work with no search signup at all.

This is the one place a `claude -p` run is handed a tool on purpose. The slot agent above
is deliberately toolless; the search agent has exactly `WebSearch`, a JSON-only reply
contract, and nothing else it could reach for. It runs on `haiku` by default
(`SIGIL_CLAUDE_SEARCH_MODEL`) — a search is retrieval, not judgment.

It is gated on claude mode specifically. Spending your subscription on a search you never
asked to spend it on would be a surprise; in claude mode you have already said every model
call goes through that CLI, and a search is one more of those.

## What it costs, honestly

A `claude -p` run always ships Claude Code's own preamble — roughly **9k input
tokens per call**, even with every tool disabled. Sigil keeps the flags and the
system prompt a fixed string so that prefix stays byte-identical between calls
and is served from the prompt cache, but it never goes away.

So this mode buys **subscription reuse, not cheapness**. It is a good fit for
compiling — expensive, rare, judgment-heavy — and a poor one for a hot execution
tier doing thousands of calls, where a local model or a direct API key is far
cheaper per token. Expect ~1.5–4s of latency per slot.

If you want Claude *and* the cheapest tokens, skip this mode and use the normal
Anthropic provider with a key: `sigil models set frontier claude-sonnet-4-6`.

## Limits

- **Text only.** Images and video in a slot are dropped with a marker in the prompt.
- **Streaming arrives in one chunk.** The reply is complete and correct, but in
  chat mode it lands all at once instead of token by token.
- **One completion per call.** Slots are bounded to a single turn, so Claude Code
  never runs an agent loop of its own inside one of Sigil's slots.
- **Ejected runnables can't use it.** `sigil compile -e agent.jac` produces a
  standalone file with no Sigil imports, so `SIGIL_MODEL=claude-cc/…` has nothing
  to register the provider. Give an ejected program a normal provider name.

## Serving compiled skills to Claude Code

The other direction. `sigil mcp-serve` speaks MCP over stdio and publishes **one
tool per compiled skill**:

```bash
claude mcp add sigil -- sigil mcp-serve     # then start a fresh Claude Code session
```

Claude Code then sees `skill_clean_csv`, `skill_writing_plans`, and so on. Each
tool's description is the skill's own `description:` frontmatter — the "use
when…" line you already wrote — so the trigger is the same mechanism a subagent
uses: Claude reaches for the skill when the task looks like that skill's job.

Two tools cover the rest:

| Tool | What it does |
|---|---|
| `skill_<signature>` | run that compiled skill on a task, pinned — no routing |
| `sigil_solve` | let Sigil route the task, compiling a new skill on a miss |
| `sigil_library` | list the compiled skills with their run statistics |

The division of labour is the point: **Claude Code decides *when*, the compiled
harness decides *how*.** Inside the tool call there is no prompt to drift from —
the skill's steps are nodes the run must visit, so what comes back followed the
skill by construction.

Server details: JSON-RPC 2.0 over stdio, no MCP SDK dependency. The server takes
the same graph as the CLI (`~/.sigil/agent.session`), so a skill you compile in
the terminal shows up in Claude Code after a session restart. New skills need a
fresh session — MCP tool lists are read at startup.

This is the mirror of `sigil add-mcp`, which points the *other* way: there Sigil
consumes a tool server so the compiler can bind its tools into new skills.

## Letting an agent author the AG-IR

`--agent` swaps the compiler's front-end: instead of authoring the AG-IR through
a staged pipeline of byLLM slots, a Claude Code session writes it directly,
verifying each draft against the compile oracle.

```bash
sigil --claude compile ./SKILL.md --agent
```

It is **opt-in**, and the reason is worth being precise about. What it keeps:

- the **spec loop**, unchanged — every rule must quote your skill verbatim, so a
  hallucinated obligation is still dropped mechanically before authoring starts;
- the **gate battery** — G1 (embodiment), G4 (compile oracle, with the same
  bounded repair loop), G5 (every mandatory rule realized by a node).

What it drops: LIFT's staged authoring — the workflow spine, the annotator flows,
the assemble step, and the view repair that routes each issue back to the flow
that owns it, plus the coverage critics that hunt for dropped obligations across
several rounds.

So it is faster, and it runs on a subscription instead of a frontier key. It is
**not** more trustworthy. The honest framing is *agent-authored, gate-verified* —
not *verified the way LIFT verifies*. Use the default pipeline when faithfulness
is the priority.

The session gets a workspace with four files and nothing else on its path:

| File | What it is |
|---|---|
| `writing-agir/SKILL.md` | the meta-skill: how to write an AG-IR, and what the gates check |
| `SKILL.md` | the skill being compiled |
| `rules.md` | the frozen rule set, with ids — the contract the IR is audited against |
| `agir-template.md` | the compiler-exact YAML shape (plus the full reference files) |

It writes `agent.ir` and runs `sigil gate agent.ir <name>` after every edit. Each
node carries `traces_to: [r3, r7]` naming the rules it realizes, which is what G5
audits — so "it compiles" is never mistaken for "it covers the skill".

`SIGIL_CLAUDE_AUTHOR_TURNS` (default `80`) bounds the session.

`--agent` only needs the `claude` binary — the authoring session always runs on
it. Combining it with `--claude` additionally puts the spec loop on Claude Code;
without `--claude` the spec loop runs on your configured `frontier` tier as usual.

## When a compile fails

The compiler's repair loop is a bounded byLLM slot: it sees `(ir, diagnostic)`
and proposes a fix, and the G4 compile oracle re-gates every attempt. When those
attempts are spent, `--claude` (or `SIGIL_CLAUDE_REPAIR=1`) escalates instead of
giving up.

The escalation is a *tool-using* Claude Code session in a scratch workspace
holding the failing `agent.ir` and the AG-IR authoring contract. It gets one
verification command:

```bash
sigil gate agent.ir <name>      # G4, exit nonzero while the IR is broken
```

so it can edit, re-run the oracle, and iterate — the loop a single slot call
can't do. When it finishes, Sigil re-gates the file itself and only accepts a
result that passes. **The oracle stays the authority; the agent only proposes.**

`sigil gate` is a first-class command, useful on its own for a hand-written IR
or a CI check.

| Variable | Default | What it does |
|---|---|---|
| `SIGIL_CLAUDE_REPAIR` | unset (set by `--claude`) | `1` arms the escalation |
| `SIGIL_CLAUDE_REPAIR_TURNS` | `40` | turn budget for the repair session |

Escalation costs a full agent session, not one slot call, so it is never the
silent default.

## See also

- [claude-code-setup](claude-code-setup.md) — the step-by-step setup guide
- [models](models.md) — the tier system, aliases, and fallback chains
- [skill-compilation](skill-compilation.md) — what the frontier tier is actually doing
