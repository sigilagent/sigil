# Chat mode and the tool-belt

`sigil chat` is a conversational, tool-using agent — one running conversation you
can do everything from. It renders replies as markdown, streams a live trace of
every tool call, and prompts inline to approve any gated shell command.

The agent decides first whether a message needs a tool at all. Greetings,
questions, and anything answerable in words get a plain reply. Tools are for real
side effects: files, code, live data, scheduling, memory, delegation.

## The tools

### Files and code

Relative paths resolve in the workspace. Absolute paths reach the real host
unless `sandbox` is on — see [workspace-and-tools](workspace-and-tools.md).

- `ws_list(subdir)` — one directory level. `ws_tree(subdir, depth)` — recursive
  survey, skipping noise dirs like `.git` and `node_modules`, for getting the
  shape of a repo.
- `ws_grep(pattern, path)` — regex search across files, returns `path:line: text`.
- `ws_read(path, offset, limit)` — read a file. Large files are paged
  (line-numbered, with a `lines X-Y of N` header), so read on rather than
  concluding from the first page.
- `ws_write(path, content)` and `ws_edit(path, old, new)`.
- `ws_exec(command, wait_seconds)` — real shell, uncontained by default, through
  the exec-approval gate. Nothing is killed on a timer: it reports the output so
  far and, if the command is still going, a job id. `ws_watch(job_id)` keeps
  watching (new output only), `ws_kill(job_id)` stops it, `ws_jobs()` lists them.
  The agent reads what actually happened and decides whether to wait — see
  [workspace-and-tools](workspace-and-tools.md).

`ws_tree`, `ws_grep` and `ws_read` are read-only and need no approval.

When analyzing a codebase the agent surveys with `ws_tree`, locates with
`ws_grep`, and reads several files before drawing conclusions, fanning out with
`spawn_parallel` for a repo-scale review.

### Web

- `web_search(query)` — open-web search. Uses `BRAVE_API_KEY` /
  `FIRECRAWL_API_KEY` if set, and otherwise Claude Code's own WebSearch in claude
  mode, so `sigil --claude` needs no search key at all. See
  [models](models.md#web-search-providers).
- `web_fetch(url)` — read a specific URL, SSRF-guarded. Works on keyless JSON
  APIs such as `api.github.com`, so "new PRs/issues in a repo" needs no search key.

### Automation

`schedule_task`, `list_scheduled`, `cancel_scheduled`. See
[automation-and-cron](automation-and-cron.md).

### Memory and skills

`remember_fact`, `recall_memory`, `learn_skill`, `list_skills`, plus
`sigil_compile(path)`, which compiles a SKILL.md in-process — never shell out to
`sigil compile`, see [workspace-and-tools](workspace-and-tools.md). More in
[memory-and-skills](memory-and-skills.md).

### Sub-agents

`spawn_parallel(tasks)` runs independent sub-tasks concurrently, via Jac
`flow`/`wait` over `root`-spawned worker walkers. `spawn_subagent(task)`
delegates one.

### Channels and external

`connect_channel(kind)` and `setup_channel(name, kind)` for messaging setup (see
[channels](channels.md)), `send_message(channel, peer, text)`, and
`mcp_call(name, args_json)` for registered MCP servers.

### Self-config and docs

`cfg_set_model`, `cfg_set_persona`, `cfg_set_prompt_mode`. `list_docs()` and
`read_docs(topic)` let the agent read this reference to answer questions about
itself.

## Slash commands (in the REPL)

`/help` · `/soul` · `/config` · `/tools` · `/workspace` · `/sandbox <mode>` ·
`/cron` · `/channels` · `/connect <kind>` · `/skills` · `/docs [topic]` ·
`/model <tier> <name>` · `/remember <fact>` · `/recall <query>` · `/reset` ·
`/clear` · `/exit`.

## Tool policy

Which tools are permitted is governed by `tool_allow` / `tool_deny` /
`tool_profile` on the soul (see [configuration](configuration.md)). Deny wins
over allow.
