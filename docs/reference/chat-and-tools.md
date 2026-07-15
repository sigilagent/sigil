# Chat mode and the tool-belt

`sigil chat` is a conversational, tool-using agent — one running conversation from which
you can do everything. It renders replies as markdown, streams a **live trace of every
tool call**, and prompts inline to approve any gated shell command.

The agent decides first whether a message even needs a tool. Greetings, questions, and
anything answerable in words get a plain reply — tools are only used for real side
effects (files, code, live data, scheduling, memory, delegation).

## The tools

**Files & shell** (jailed to the workspace — see [workspace-and-sandbox](workspace-and-sandbox.md))
- `ws_list(subdir)` · `ws_read(path)` · `ws_write(path, content)` · `ws_edit(path, old, new)`
- `ws_exec(command)` — runs through the exec-approval gate + sandbox.

**Web**
- `web_search(query)` — open-web search via a provider (needs `BRAVE_API_KEY` or
  `FIRECRAWL_API_KEY`; see [models](models.md)/setup).
- `web_fetch(url)` — read a specific URL, SSRF-guarded. Works on keyless JSON APIs
  (e.g. GitHub's `api.github.com`), so "new PRs/issues in a repo" needs no search key.

**Automation** — `schedule_task` · `list_scheduled` · `cancel_scheduled`.
See [automation-and-cron](automation-and-cron.md).

**Memory & skills** — `remember_fact` · `recall_memory` · `learn_skill` · `list_skills`.
See [memory-and-skills](memory-and-skills.md).

**Sub-agents** — `spawn_parallel(tasks)` runs independent sub-tasks concurrently (via
Jac `flow`/`wait` over `root`-spawned worker walkers); `spawn_subagent(task)` delegates one.

**Channels & external** — `connect_channel(kind)` and `setup_channel(name, kind)` for
messaging setup (see [channels](channels.md)); `send_message(channel, peer, text)`;
`mcp_call(name, args_json)` for registered MCP servers.

**Self-config** — `cfg_set_model` · `cfg_set_persona` · `cfg_set_prompt_mode`.

**Docs** — `list_docs()` and `read_docs(topic)`: the agent reads this reference to answer
questions about itself.

## Slash commands (in the REPL)

`/help` · `/soul` · `/config` · `/tools` · `/workspace` · `/sandbox <mode>` · `/cron` ·
`/channels` · `/connect <kind>` · `/skills` · `/docs [topic]` · `/model <tier> <name>` ·
`/remember <fact>` · `/recall <query>` · `/reset` · `/clear` · `/exit`.

## Tool policy

Which tools are permitted is governed by `tool_allow` / `tool_deny` / `tool_profile`
on the soul (see [configuration](configuration.md)). Deny wins over allow.
