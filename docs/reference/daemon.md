# The daemon — Sigil with the terminal closed

Sigil's scheduler needs a process that outlives a command. The daemon is that
process: start it once and your schedule runs whether or not the TUI is open.

```bash
sigil daemon start          # background, ticks every 30s
sigil daemon start 5        # tick every 5 seconds instead
sigil daemon status
sigil daemon logs 50
sigil daemon stop
sigil daemon install        # start at login (launchd on macOS, systemd on Linux)
sigil daemon uninstall
```

`sigil daemon run [interval]` is the supervisor loop in the foreground — what
`start` spawns, and what the service unit executes. Run it directly when you want
to watch it work.

## Status

```
$ sigil daemon status
sigil daemon: running — pid 86668, up 14s, tick 5s
  graph   : /Users/you/.sigil/app/.jac/data/sigil.db
  log     : /Users/you/.sigil/log/daemon.log
  jobs    : 3 scheduled, 3 armed
  next due: 2026-08-07 09:00:00 (in 17h22m)
  at login: installed   (sigil daemon install)
```

Each log line is a heartbeat:

```
2026-08-06 11:53:33  sigil daemon up — pid 86668, tick 5s, graph …/sigil.db
2026-08-06 11:53:36  tick: fired 0 job(s), 3 armed
2026-08-06 11:54:15  tick: fired 1 job(s), 3 armed
2026-08-06 11:54:15    morning_digest -> ok
```

`fired 0, 0 armed` and `fired 0, 3 armed` are different diagnoses — the first says
the scheduler cannot see your jobs, the second says nothing is due yet.

## One agent, wherever you run it

Sigil's whole state — soul, memory, skills, schedule — is one graph, and jac
resolves that graph's store **relative to the working directory**. Run `sigil`
from two directories and you had two agents that had never met.

Every entry point now pins its working directory to the project, so the CLI, the
TUI, the daemon, and every job the daemon fires are the same agent. `sigil where`
answers the question directly:

```
$ sigil where
graph     : /Users/you/.sigil/app/.jac/data/sigil.db
project   : /Users/you/.sigil/app
invoked in: /Users/you/code/some-project
daemon    : running
```

Paths you type still resolve against the directory you typed them in — `sigil
compile ./SKILL.md` reads the `SKILL.md` next to *you*, not next to the project.
(That is also a fix: the installed launcher already changed directory, so relative
paths could not be found at all.)

## What the daemon runs

Every tick runs in a fresh subprocess. That is deliberate: a long-lived jac
process serves the graph it loaded at startup, so a supervisor doing the work
in-process would never see a job added after it booted — the daemon would be up
and nothing would fire. The loop supervises; the subprocesses do the work and see
the current graph.

One job runs at a time. A long solve delays the next tick rather than stacking
runs on top of it.

## Approvals in the background

The exec gate (`sigil approvals`) still applies to a job the daemon fires, and
nothing headless can answer a prompt. A command that needs approval is **blocked
and reported** — the job continues and says what was refused; it does not hang
and it does not silently run.

Blocked commands queue up for you:

```bash
sigil approvals pending                                   # what is waiting, and for how long
sigil approvals approve "rsync" allow-always              # answer one
sigil approvals allow "rsync *"                           # or allowlist it ahead of time
sigil approvals clear                                     # drop the queue
```

The queue deduplicates by command, so a job that retries the same blocked command
every hour asks once rather than filling the graph with copies of one question.

To let background work run unattended, allowlist what it needs
(`sigil approvals allow`) rather than loosening the policy globally.

## Service files

`sigil daemon install` writes and loads:

| OS | Unit |
|---|---|
| macOS | `~/Library/LaunchAgents/com.sigilagent.sigil.plist` (`RunAtLoad`, `KeepAlive`) |
| Linux | `~/.config/systemd/user/sigil.service` (`Restart=always`) |

Both pin the working directory to the project and append to
`$SIGIL_HOME/log/daemon.log`. `sigil daemon uninstall` unloads and removes them.

State lives under `$SIGIL_HOME` (default `~/.sigil`): `run/daemon.pid`,
`run/daemon.json`, `log/daemon.log`.

## Stopping

`sigil daemon stop` sends `SIGTERM` and waits up to 30 seconds. A tick that is
mid-solve can legitimately outlast that; the command says so and hands you the
pid rather than escalating to `SIGKILL` behind your back.

## The Observatory

`sigil serve` runs the web UI and the HTTP API against **the same graph as
everything else** — the CLI, the TUI, the daemon, and every job it fires.

That had never been true. Measured three ways: the CLI reported 9 skills while
`POST /walker/api_soul` on the running server reported `skills: 0`; a `teach`
through the server answered "remembered" and the fact landed in no anchor in the
store, so anything done in the web UI was thrown away; and `sigil serve` exec'd
`jac start` directly, skipping the guest-root alignment `src/main.jac` performs.

Root alignment alone does not fix it — a server booted with `__guest__` already
pointing at the superroot still reads an empty Soul. So the endpoints stop owning
a graph. Each one runs its request in a fresh `jac run` process, the execution
mode that demonstrably reads and writes the real store, and returns its result.
The same seam the scheduler and the channel bridges use.

```bash
sigil serve                   # Observatory + API, on the real graph
sigil api soul '{}'           # the same seam, from the shell (JSON out)
```

A request therefore costs one process start. For a local dashboard that is the
right trade against showing a confident, empty agent.

## Lifecycle hooks

`sigil hook add <name> <event> <action-kind> <action>` — four documented events
had no call site anywhere in the codebase, so registering for them registered for
something that never happened. All of them fire now:

| Event | When |
|---|---|
| `gateway_start` | the daemon comes up |
| `session_start` | a transcript begins — a new peer, or the daily reset |
| `before_tool` | ahead of a tool call (the exec gate included) |
| `after_tool` / `tool_failed` | after one, split by outcome |

alongside the four that already worked: `before_solve`, `after_solve`,
`solve_failed`, `message_received`, `cron_fired`. A hook that raises is contained
— it cannot take down the solve, tool call or reply it was observing.

## Shell jobs outlive the turn that started them

`ws_exec` never kills on a timer, but its job registry used to be in-memory: a
build started in one turn was invisible from the next CLI invocation, from the
daemon, and from a restarted TUI — still running, still spooling, with no way to
watch or stop it. Jobs are recorded under `$SIGIL_HOME/run/jobs/` now, so
`ws_jobs` lists them, `ws_watch` reads their output, and `ws_kill` stops them
across process boundaries. Records for finished jobs are pruned as they are seen.
