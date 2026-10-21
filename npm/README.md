# Sigil

**The skill compiler.** Sigil compiles a `SKILL.md` through a typed AG-IR into a
runnable agent harness, so any model (small and local included) follows the skill
by construction. Don't prompt the skill — compile it.

```bash
npm install -g @sigilagent/sigil
```

```bash
sigil compile ./SKILL.md -e agent.jac        # the compiler, end to end
sigil solve "turn report.pdf into clean CSV" # the agent: compile on miss, reuse on hit
sigil library                                # the compiled skills, with run stats
sigil chat                                   # the conversational agent over the same graph
```

Docs: [sigilagent.com](https://sigilagent.com) · [github.com/sigilagent/sigil](https://github.com/sigilagent/sigil)

## What this package installs

Sigil runs on the native [jac](https://www.jac-lang.org) runtime, not on Node. This
package is a thin launcher: the first time you run `sigil` (and after each
`npm update`), it runs the release's own installer, which

1. installs the jac version this release is pinned to into `~/.local/bin`, if you don't have it,
2. fetches the matching Sigil release into `~/.sigil/app`,
3. provisions its runtime dependencies (the LLM backend, the chat REPL).

Your agent's graph lives in `~/.sigil/app`, outside `node_modules`, so upgrading or
reinstalling the npm package never touches it. Nothing needs root.

Requires macOS or Linux with `bash`, `curl` and `git`. The same install is also
available without npm:

```bash
curl -fsSL https://github.com/sigilagent/sigil/releases/latest/download/install.sh | bash
```

## Updating and removing

```bash
npm update -g @sigilagent/sigil   # the next `sigil` run upgrades ~/.sigil/app
npm uninstall -g @sigilagent/sigil
rm -rf ~/.sigil                   # also delete the agent, its graph and compiled skills
```

`SIGIL_HOME` moves Sigil's state directory (default `~/.sigil`; the app is `$SIGIL_HOME/app`).
