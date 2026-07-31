# Claude Code setup

Zero to working, in both directions — Sigil running on your Claude subscription,
and your compiled skills showing up as tools inside Claude Code.

The two directions are independent. Set up either, or both:

| You want | Go to | Time |
|---|---|---|
| Sigil to run with no API key at all | [Direction 1](#direction-1--run-sigil-on-your-claude-subscription) | ~2 min |
| Your compiled skills usable inside Claude Code | [Direction 2](#direction-2--serve-compiled-skills-into-claude-code) | ~5 min |

This page is only the steps. For *why* it works — the provider shim, the token
math, the limits — read [claude-code](claude-code.md).

## Prerequisites

Both directions need the Claude Code CLI on your `PATH`, signed in.

```bash
claude --version          # e.g. 2.1.175 (Claude Code)
```

Nothing printed? Install Claude Code first, then run `claude` once and sign in.

Now confirm **which account is signed in** — this is the account that will pay
for every Sigil call in Direction 1:

```bash
jq -r '.oauthAccount.emailAddress // "not signed in"' ~/.claude.json
```

If it says `not signed in`, run `claude`, sign in, and re-check. A subscription
login is what makes the whole thing key-free; without one, `--claude` refuses to
start rather than silently billing something else.

And Sigil itself:

```bash
curl -fsSL https://github.com/sigilagent/sigil/releases/latest/download/install.sh | bash
sigil docs                # prints the reference topic list — the install is good
```

## Direction 1 — run Sigil on your Claude subscription

Every model tier (compiler, executor, router, chat) is answered by a headless
`claude -p` run against your own subscription. No `ANTHROPIC_API_KEY`, no
`OPENAI_API_KEY`, no proxy.

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

Check two things in that output: the email is **yours**, and every tier reads
`claude-cc/…`. This command binds the tiers but makes no model call, so it is
free — it is the right smoke test.

If instead you get:

```
xx --claude needs a Claude Code subscription login, and this machine has none.
```

go back to [prerequisites](#prerequisites) — there is no login for Sigil to use.

### 2. Compile something on it

```bash
sigil --claude compile ./examples/csv-clean/SKILL.md
```

`--claude` is global: it can go anywhere on the line, before or after the
subcommand. `SIGIL_CLAUDE=1` does the same for a whole shell.

```bash
sigil --claude chat                                    # chat, sub-agents, tools
sigil --claude solve "turn report.pdf into clean CSV"  # route + run
```

### 3. Make it stick — pick one of two

**A. Everything on Claude Code**, for a shell or permanently:

```bash
export SIGIL_CLAUDE=1        # add to ~/.zshrc or ~/.bashrc
```

**B. Only the expensive tier on Claude Code**, execution somewhere cheap — no
flag needed, and this is the better default for anything that runs often:

```bash
sigil models set frontier claude-cc/opus       # compile on your subscription…
sigil models set small ollama_chat/qwen3:8b    # …execute locally, for free
```

Why B: every `claude -p` call ships Claude Code's own preamble — roughly **9k
input tokens per call**, even with all tools disabled. That is fine for
compiling (rare, expensive, judgment-heavy) and wasteful for a hot execution
tier doing thousands of calls. This mode buys *subscription reuse, not
cheapness*.

Model names after the slash are Claude Code aliases:

| Name | Binds to |
|---|---|
| `claude-cc/opus` | Opus — the default for `frontier` / `chat` |
| `claude-cc/sonnet` | Sonnet |
| `claude-cc/haiku` | Haiku — the default for `small` / `router` |
| `claude-cc/fable` | Fable |
| `claude-cc/default` | whatever your CLI is configured for (no `--model` passed) |

Override the two `--claude` defaults with `SIGIL_CLAUDE_FRONTIER` and
`SIGIL_CLAUDE_SMALL`.

## Direction 2 — serve compiled skills into Claude Code

`sigil mcp-serve` speaks MCP over stdio and publishes **one tool per compiled
skill**, so Claude Code can call your compiled harnesses directly.

### 1. Compile at least one skill — with a `description:`

The frontmatter description becomes the MCP tool description, which is the only
thing Claude Code routes on. Write it as a "use when…" line:

```markdown
---
name: clean-csv
description: Use when a messy CSV file needs its headers normalized to clean snake_case names and blank rows removed, saved to a verified output file.
---
```

Omit it and the tool falls back to `compiled from SKILL.md (AI compiler)` —
technically valid, and useless as a trigger. Then:

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
claude mcp add sigil -- sigil mcp-serve
```

That registers it for the current project. Add `-s user` to make it available in
every project:

```bash
claude mcp add sigil -s user -- sigil mcp-serve
```

If `sigil` may not be on the `PATH` of whatever launches Claude Code, give the
absolute path instead:

```bash
claude mcp add sigil -- "$HOME/.local/bin/sigil" mcp-serve
```

### 3. Start a fresh session and verify

```bash
claude mcp list           # sigil: sigil mcp-serve - ✔ Connected
```

Inside a session, `/mcp` shows the same thing. **MCP tool lists are read at
startup**, so a skill you compile in the terminal appears only after you restart
the Claude Code session.

### 4. If it will not connect, test the wire directly

The server is just JSON-RPC 2.0 on stdio, so you can drive it by hand:

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
registration or `PATH` — not the server.

### What Claude Code ends up seeing

| Tool | What it does |
|---|---|
| `skill_<signature>` | run that compiled skill on a task, pinned — no routing |
| `sigil_solve` | let Sigil route the task, compiling a new skill on a miss |
| `sigil_library` | list the compiled skills with their run statistics |

**Claude Code decides *when*; the compiled harness decides *how*.** Inside the
tool call there is no prompt to drift from — the skill's steps are nodes the run
must visit.

## Running both directions at once

Nothing to reconcile — they are separate mechanisms. If you want the skills
*served* to Claude Code to also *run* their cognition on it, register the server
in claude mode:

```bash
claude mcp add sigil -- sigil --claude mcp-serve
```

The startup banner goes to stderr precisely so this works: `mcp-serve` keeps
stdout clean for the JSON-RPC wire. Be aware of what you have built, though —
each tool call is then a Claude Code session spawning `claude -p` subprocesses
of its own, paying the ~9k-token preamble on every slot. Pinning `small` to a
local model (Direction 1, option B) keeps that in check.

## Optional extras

Both are opt-in and documented in full in [claude-code](claude-code.md):

- **Agent-authored IR** — `sigil --claude compile ./SKILL.md --agent` lets a
  Claude Code session write the AG-IR directly against the compile oracle.
  Faster; keeps the grounded spec loop and the gate battery; drops LIFT's staged
  authoring. *Agent-authored, gate-verified* — the default pipeline stays the
  default when faithfulness matters. Needs a CLI recent enough for `--agents` /
  `--agent`.
- **Repair escalation** — with `--claude` (or `SIGIL_CLAUDE_REPAIR=1`), a
  compile whose bounded repair slots are spent escalates to a tool-using Claude
  Code session that can edit the IR and re-run `sigil gate` itself. Sigil
  re-gates the result and accepts only a passing one.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `--claude needs a Claude Code subscription login` | no `oauthAccount` in `~/.claude.json` | run `claude`, sign in, re-run |
| `` `claude` not found on PATH `` | CLI not on the `PATH` Sigil sees | install it, or `export SIGIL_CLAUDE_BIN=/full/path/to/claude` |
| `the claude CLI is not logged in — run claude once and sign in` | login expired or never happened | run `claude`, sign in |
| `the Anthropic account backing the claude CLI is out of credit` | the CLI is billing an API key, not a subscription | `jq '.customApiKeyResponses' ~/.claude.json`; or move the tier: `sigil models set <tier> <model>` |
| banner says `(api key)` instead of your email | `SIGIL_CLAUDE_ALLOW_API_KEY` is set | unset it — Sigil then withholds `ANTHROPIC_API_KEY` from the subprocess and the subscription answers |
| `claude timed out after 600s` | one slot call exceeded the cap | raise `SIGIL_CLAUDE_CC_TIMEOUT` (seconds) |
| authoring/repair session times out | `--agent` sessions are long-running | raise `SIGIL_CLAUDE_AGENT_TIMEOUT` (default `3600`) |
| new skill missing in Claude Code | tool lists are read at session start | restart the Claude Code session |
| a skill tool has a generic description | no `description:` in the SKILL.md frontmatter | add one, recompile, restart the session |
| chat replies land all at once | streaming arrives in one chunk in this mode | expected — see [limits](claude-code.md#limits) |
| an ejected `agent.jac` rejects `claude-cc/…` | ejected runnables have no Sigil imports to register the provider | give the ejected program a normal provider name |

Full variable list: [claude-code § environment](claude-code.md#environment).

## See also

- [claude-code](claude-code.md) — how this works, what it costs, and the limits
- [models](models.md) — the tier system, aliases, and fallback chains
- [skill-compilation](skill-compilation.md) — what the frontier tier is doing
