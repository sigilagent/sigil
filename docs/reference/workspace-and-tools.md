# Workspace and tools

By default, Sigil's file and shell tools work on the **real machine** — the same filesystem
and the same installed programs you have. That default is deliberate: Sigil's job in chat
mode is to drive what is already here (a build, a test suite, `git`, another agent's CLI),
and containment would cut it off from exactly those. What guards the agent then is the
exec-approval gate.

Containment is a switch, not a fact — see [the sandbox](#the-sandbox) below.

## The workspace

The `workspace` (default `~/.sigil/workspace`, set with `configure workspace <path>`) is
where **relative** paths resolve and where shell jobs start. With the sandbox off it is a
default working directory, not a boundary: an absolute path — or a `cd` inside a shell
command — reaches anywhere the operator can.

- `ws_list(subdir)` — one level; `ws_tree(subdir, depth)` — recursive structure survey,
  skipping noise dirs (`.git`, `node_modules`, `__pycache__`, …), bounded in depth/entries.
- `ws_grep(pattern, path)` — regex content search across files, returning `path:line: text`.
- `ws_read(path, offset, limit)` — read a file or a line range; output is line-numbered
  with a `lines X-Y of N` header so large files can be paged and a partial read is never
  mistaken for the whole file.
- `ws_write` / `ws_edit` — create/modify files.

`ws_tree`, `ws_grep`, and `ws_read` are read-only and run without the exec-approval gate;
only `ws_exec` (real shell) is gated.

Check the current workspace, sandbox mode, and any running shell jobs with `/workspace` in
chat, or with `sigil soul`.

## The sandbox

`configure sandbox <mode>` (or `/sandbox <mode>` in chat) picks how much the tools are
contained:

| Mode | File tools | Shell |
|---|---|---|
| `off` **(default)** | any path on the host; relative paths resolve in the workspace | runs directly, starting in the workspace |
| `jail` | confined to the workspace — an escaping path is **refused**, not clamped | runs directly, starting in the workspace |
| `docker` | confined to the workspace | runs in a locked-down container (`--network none --cap-drop ALL --security-opt no-new-privileges --pids-limit 256 --memory 1g`) with only the workspace mounted at `/work`. Requires Docker; set the image with `SIGIL_SANDBOX_IMAGE` (default `python:3.13-slim`) |

Note that `jail` confines *paths*, not the shell — a command can still `cd` elsewhere,
which is why exec is approval-gated in every mode. To stop the agent running commands at
all, set the exec policy to `deny` (`sigil approvals set deny always`) rather than reaching
for a sandbox mode.

No mode imposes a time limit: a container is a boundary, not a clock.

## The exec gate

`ws_exec(command)` never runs a command unconditionally. The effective policy is the
stricter of a security mode (`deny` / `allowlist` / `full`) and an ask mode (`off` /
`on-miss` / `always`), plus a per-agent allowlist. A non-allowlisted command becomes
*pending*; in the chat REPL you are prompted inline to approve it (once), otherwise it is
blocked. Manage this with `sigil approvals …` (`get` / `set` / `allow` / `approve` /
`elevate` / `audit`).

Because the shell is uncontained, this gate is the control that matters — run Sigil under
a policy you would be comfortable giving any agent shell access with.

## Shell jobs are never killed on a timer

A build, a test suite, or another agent CLI routinely outlives any deadline you would
pick, and killing it throws the work away exactly when it was about to pay off. So
`ws_exec` imposes no time limit at all. Every command runs as a **background job**
spooling its merged stdout/stderr to a file; `ws_exec` waits `wait_seconds` (default 30)
and then reports the output *so far*.

If the job is still going, the reply says `STILL RUNNING` and carries a job id. The agent
then decides the way a person would, from the output it can already see:

- `ws_watch(job_id, wait_seconds)` — keep watching. Returns only what is new since the
  last look, so it reads like a tail.
- `ws_kill(job_id)` — stop it, if it is clearly stuck or was the wrong command.
- `ws_jobs()` — what is still running, how long each has been going, and its command.
- …or nothing at all: go do other work and check back. The job keeps running either way.

## Compiling: `sigil_compile`, not the shell

`sigil compile <SKILL.md>` is a many-minute gated lift. Run through `ws_exec` it would be
a *second* sigil process contending with the live one for the same session file, with no
progress visible until it ended — so the agent has `sigil_compile(path)` instead, which
runs in-process, on the same graph, with no time limit and a live stage trace. `ws_exec`
recognises a `sigil compile …` command line and routes it there automatically.

## Web egress

`web_fetch` carries an **SSRF guard**: it refuses non-`http(s)` URLs and any loopback,
private (`10.`, `192.168.`, `172.16–31.`), or link-local (`169.254.`, cloud metadata)
host — so a tool cannot be tricked into reaching internal services.

## Secrets

Secret values are never stored on the graph. A `SecretRef` maps a name to an environment
variable (`sigil secret add <name> <ENV_VAR>`); `secret:<name>` tokens resolve from the
environment only at run time, and any live secret value is redacted from tool output and
logs.
