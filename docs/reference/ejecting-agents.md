# Ejecting

A compiled skill can leave Sigil in two shapes. They are for different things.

## One file, one task

```bash
sigil compile ./SKILL.md -e agent.jac
./agent.jac "extract the tables from report.pdf"
SIGIL_MODEL=ollama_chat/qwen3:8b ./agent.jac "…"    # any model can run it
```

The skill's step graph plus the runtime helper library, in a single executable
`.jac`. It runs the task and exits. Nothing persists: no memory of the last run,
no schedule, no way to reach it. It is a program, and it goes anywhere a `jac`
binary goes.

### Binding typed inputs directly

A task sentence is one way in. The artifact also takes each of its typed inputs
as a flag, which is what you want when a caller already knows the values:

```bash
./agent.jac --src_csv=export.csv --out=clean.csv
./agent.jac --src_csv=export.csv "and drop the trailing blank rows"
```

Each `--<input>=<value>` binds that input carry by name; the task text fills in
any input a flag didn't cover. A call that passes flags and no sentence gets a
default task rather than stopping to ask for one, so it works unattended.

### Serving itself as an MCP tool

```bash
./agent.jac --mcp
```

The artifact becomes a stdio JSON-RPC server exposing itself as one tool. The
tool schema comes from its own typed inputs and the description from the skill's
imperative surface, so a calling agent sees a typed tool rather than a shell
command. `tools/call` runs the skill in-process — warm calls land in
~0.04–0.1s, against seconds for a fresh subprocess per call. The artifact's own
prints go to stderr to keep the protocol channel clean.

This is the same idea as `sigil mcp-serve` ([claude-code](claude-code.md)), minus
Sigil: one file, one tool, no graph behind it.

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

## A single binary

The ejected project is an ordinary jac project, so:

```bash
cd csvbot && jac build --as binary
```

## Upgrading an ejected agent

Re-eject over the same directory. The code is replaced; the agent's graph — its
memory, its schedule, its channels, its run history — lives in `.jac/data` and is
left alone.
