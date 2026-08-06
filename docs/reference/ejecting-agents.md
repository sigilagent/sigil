# Ejecting

A compiled skill can leave Sigil in two shapes. They are for different things.

## One file, one task

```bash
sigil compile ./SKILL.md -e agent.jac
./agent.jac "extract the tables from report.pdf"
SIGIL_MODEL=ollama_chat/qwen3:8b ./agent.jac "…"    # any model can run it
```

The skill's step graph plus the runtime helper library, in a single executable
`.jac`. It runs the task and exits. Nothing persists — no memory of the last run,
no schedule, no way to reach it. That is the point: it is a program, and it goes
anywhere a `jac` binary goes.

## A whole agent

```bash
sigil eject-agent clean_csv ./csvbot          # one skill
sigil eject-agent all ./myagent               # the whole library
```

```
csvbot/
  jac.toml              its own project, its own store
  csvbot                launcher — pins cwd, passes SIGIL_PWD
  main.jac              solve | cron | channel | daemon | chat | soul | tasks
  agent/                the bundled runtime capabilities
  agent/crystallized/   the compiled skill module(s)
  agent/skills.json     installed onto its graph on first run
  docs/reference/       so its `read_docs` tool has something to read
```

This one keeps working when you close the terminal:

```bash
cd csvbot
./csvbot solve "clean yesterday's export"
./csvbot daemon start                                  # its own scheduler
./csvbot cron add nightly cron "0 3 * * *" "clean the export"
./csvbot channel connect telegram telegram
./csvbot teach "the finance export always has a BOM"
./csvbot daemon install                                # start at login
```

It has its own soul, its own memory, its own schedule, its own channels, its own
approvals policy and its own daemon — a graph next to the launcher, and state
under `$SIGIL_HOME` (default `~/.<name>`). It is a peer of the Sigil that made
it, not a client of it.

### It has no compiler

An ejected agent runs the skills it shipped with. It cannot author new ones:

```
$ ./csvbot compile ./NEW-SKILL.md
xx csvbot was ejected without the compiler: it runs the skills it
   shipped with and cannot author new ones. `./csvbot skills` lists them.
```

`solve` routes to a shipped skill, and on a miss it says so rather than
compiling:

```
$ ./csvbot solve "book me a flight"
No skill on this agent covers that. It ships with: clean_csv.
```

That is a deliberate trade — smaller artifact, no compile-time model dependency,
and a much tighter surface for something you deploy. When you want the agent to
learn something new, compile it in Sigil and eject again.

To change what it ships with, add the signatures you want:

```bash
sigil eject-agent all ./myagent            # everything in the library
```

### How it can exist

Sigil is two things wearing one name: a compiler that authors skills and a
runtime that owns an identity and runs them. They lived in one module, which
made the runtime impossible to ship on its own — bundling cron meant bundling the
whole AI front-end, because cron imported the hub and the hub imported the
lowerer.

The hub is split at that seam. `sigil_core.jac` is the runtime — the Soul, memory,
model tiers, the skill library, tool policy, and executing a procedure that
already exists. `sigil.jac` is the compiler — authoring one that does not. An
ejected agent is the first half plus your skills.

Two seams keep one set of capability modules serving both: `solve_task` and the
tool-belt's `sigil_compile` resolve through a registry that the full Sigil fills
in on import and an ejected runtime never does. So the same `cron.jac` runs in
both, and only one of them can compile.

A test asserts the negative property — that no module in the runtime closure
imports the compiler — because that is the kind of thing that silently stops
being true.

## A single binary

The ejected project is an ordinary jac project, so:

```bash
cd csvbot && jac build --as binary
```

## Upgrading an ejected agent

Re-eject over the same directory. The code is replaced; the agent's graph — its
memory, its schedule, its channels, its run history — lives in `.jac/data` and is
left alone.
