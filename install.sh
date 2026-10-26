#!/usr/bin/env bash
#
# Sigil installer — https://sigilagent.com
#
#   curl -fsSL https://github.com/sigilagent/sigil/releases/latest/download/install.sh | bash
#
# What it does:
#   1. fetches the Sigil source into  ~/.sigil/app   (override with $SIGIL_HOME)
#   2. makes sure the jac it runs on is the version it pins (jac.toml `jac-version`),
#      installing that native `jac` binary into ~/.local/bin if yours differs
#   3. provisions the runtime deps (PyYAML + the LLM runtime) into the project
#   4. drops a `sigil` launcher onto your PATH  (~/.local/bin, override $SIGIL_BIN_DIR)
#   5. compiles Sigil once, where it will run, so the first command starts warm
#   6. on a fresh install at a terminal: connects a model (`sigil setup`) and asks
#      whether Sigil should start when you log in
#   7. starts Sigil (the scheduler and the Observatory); an update restarts
#      whichever of them was already running, so they pick up the new code
#
# Nothing here needs root. Re-running is safe: it updates an existing install.
#
# Env knobs:
#   SIGIL_HOME     where the source lives      (default: ~/.sigil/app)
#   SIGIL_BIN_DIR  where the launcher goes     (default: ~/.local/bin)
#   SIGIL_PATH_CHECK=0  don't ask for SIGIL_BIN_DIR on PATH (the npm package
#                  puts its own `sigil` there and keeps this shim private)
#   SIGIL_REF      branch / tag / commit       (default: main in the repo copy;
#                  a release asset is rewritten to pin its own tag — see below)
#   JAC_VERSION    the jac to install          (default: the fetched tree's pin)
#   SIGIL_PRECOMPILE=0  skip step 5 (the first command compiles instead)
#   SIGIL_WIZARD=0      skip step 6's questions (also skipped with no terminal)
#   SIGIL_AUTOSTART=1|0 answer "start at login?" in advance, with or without a terminal
#   SIGIL_START=1|0     start Sigil at the end (default: 1 at a terminal, 0 otherwise)
#   SIGIL_STATE_HOME    Sigil's state dir, when it is not ~/.sigil (the npm launcher sets it)

set -euo pipefail

REPO="sigilagent/sigil"
SIGIL_HOME="${SIGIL_HOME:-$HOME/.sigil/app}"
BIN_DIR="${SIGIL_BIN_DIR:-$HOME/.local/bin}"
# Self-pinning releases: the release workflow rewrites DEFAULT_REF to the tag in
# the copy it attaches to a GitHub Release, so `releases/latest/download/install.sh`
# installs exactly the released commit — not whatever main happens to be. The repo
# copy stays on main. SIGIL_REF always overrides either.
DEFAULT_REF="main"
REF="${SIGIL_REF:-$DEFAULT_REF}"
# The PATH you came in with: installing jac below prepends ~/.local/bin for this
# script only, and the closing PATH advice has to describe your shell, not ours.
ORIG_PATH="$PATH"

# ---- pretty output -----------------------------------------------------------
if [ -t 1 ]; then
  P=$'\033[1;35m'; Y=$'\033[1;33m'; R=$'\033[1;31m'; G=$'\033[1;32m'; D=$'\033[0m'
else
  P=""; Y=""; R=""; G=""; D=""
fi
info() { printf '%s::%s %s\n' "$P" "$D" "$*"; }
warn() { printf '%s!!%s %s\n' "$Y" "$D" "$*" >&2; }
die()  { printf '%sxx%s %s\n' "$R" "$D" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

printf '\n%s  ◆ Sigil installer%s\n\n' "$P" "$D"

# A fresh install gets the wizard; an update (`sigil update` re-runs this script)
# gets none of it, and restarts what was running instead. Both facts have to be
# read before step 1 replaces the tree.
FRESH=1
[ -f "$SIGIL_HOME/src/main.jac" ] && FRESH=0
STATE_DIR="${SIGIL_STATE_HOME:-$HOME/.sigil}"
pid_live() { local p; p="$(cat "$STATE_DIR/run/$1.pid" 2>/dev/null || true)"; [ -n "$p" ] && kill -0 "$p" 2>/dev/null; }
WAS_DAEMON=0; WAS_SERVE=0
if [ "$FRESH" = 0 ]; then
  if pid_live daemon; then WAS_DAEMON=1; fi
  if pid_live observatory; then WAS_SERVE=1; fi
fi

# ---- 1. fetch Sigil source ---------------------------------------------------
info "Fetching Sigil ($REF) → $SIGIL_HOME"
mkdir -p "$(dirname "$SIGIL_HOME")"
if have git; then
  if [ -d "$SIGIL_HOME/.git" ]; then
    # Upgrade in place. Two traps, both of which used to fail SILENTLY and leave
    # the previous version installed under a "✓ Sigil installed" banner:
    #   * `checkout FETCH_HEAD` refuses whenever a tracked file has drifted, and
    #     a long-lived install drifts (a half-applied earlier upgrade is enough);
    #   * the fallback reset to `origin/$REF` names a ref that a tag fetch never
    #     creates — `fetch --depth 1 origin <tag>` writes FETCH_HEAD and nothing
    #     else, so `origin/v0.3.0` does not resolve.
    # Reset to the commit we actually fetched, and let a failure be loud. This
    # rewrites TRACKED files only: the graph in .jac/data, compiled skills and
    # every other untracked/ignored file are left exactly where they are.
    git -C "$SIGIL_HOME" fetch --depth 1 origin "$REF" \
      || die "could not fetch '$REF' into $SIGIL_HOME."
    git -C "$SIGIL_HOME" reset --hard -q FETCH_HEAD \
      || die "could not update $SIGIL_HOME to '$REF' (local changes to tracked files?)."
    # An install that reports success while running last month's code is the one
    # outcome worth an explicit check.
    at="$(git -C "$SIGIL_HOME" rev-parse HEAD 2>/dev/null || echo unknown)"
    want="$(git -C "$SIGIL_HOME" rev-parse FETCH_HEAD 2>/dev/null || echo unknown)"
    [ "$at" = "$want" ] || die "update did not take: $SIGIL_HOME is at $at, expected $want."
  else
    rm -rf "$SIGIL_HOME"
    git clone --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$SIGIL_HOME" 2>/dev/null \
      || git clone --depth 1 "https://github.com/$REPO.git" "$SIGIL_HOME"
  fi
else
  warn "git not found — downloading a source tarball instead."
  tmp="$(mktemp -d)"
  curl -fsSL "https://github.com/$REPO/archive/refs/heads/$REF.tar.gz" -o "$tmp/src.tgz" \
    || curl -fsSL "https://github.com/$REPO/archive/refs/tags/$REF.tar.gz" -o "$tmp/src.tgz" \
    || die "could not download Sigil source for '$REF'."
  tar -xzf "$tmp/src.tgz" -C "$tmp"
  src="$(find "$tmp" -maxdepth 1 -type d -name 'sigil-*' | head -1)"
  [ -n "$src" ] || die "unexpected tarball layout."
  rm -rf "$SIGIL_HOME"; mv "$src" "$SIGIL_HOME"; rm -rf "$tmp"
fi
[ -f "$SIGIL_HOME/src/main.jac" ] || die "Sigil source looks incomplete (no src/main.jac in $SIGIL_HOME)."

# ---- 2. the jac this Sigil pins ----------------------------------------------
# PINNED: jac ships breaking changes as clean breaks, so Sigil runs on exactly the
# jac it was tested against. The pin is jac.toml's `jac-version` in the tree just
# fetched, so a release's installer and the tree it installs cannot disagree.
# Unpinned, this installed whatever jac was newest — v0.37 made a jac.toml table
# a hard error and every fresh install broke. Worse, an existing jac was kept
# whatever its version, so `sigil update` left every earlier install (jac 0.36.1)
# on a jac whose `jac run` rejects the flags this tree passes.
DEFAULT_JAC_VERSION="0.37.25"   # for a tree from before jac.toml carried the pin
pinned="$(sed -n 's/^jac-version *= *"=*\([0-9][0-9.]*\)".*/\1/p' "$SIGIL_HOME/jac.toml" 2>/dev/null | head -1 || true)"
JAC_VERSION="${JAC_VERSION:-${pinned:-$DEFAULT_JAC_VERSION}}"
jac_ver() { "$1" --version 2>/dev/null | sed -n 's/^jac \([0-9][0-9.]*\).*/\1/p' | head -1 || true; }

JAC_BIN="$(command -v jac 2>/dev/null || true)"
found="${JAC_BIN:+$(jac_ver "$JAC_BIN")}"
if [ -n "$JAC_BIN" ] && [ "$found" = "$JAC_VERSION" ]; then
  info "Found jac $JAC_VERSION: $JAC_BIN"
else
  if [ -n "$JAC_BIN" ]; then
    info "Found jac ${found:-of unknown version} at $JAC_BIN; this Sigil runs on jac $JAC_VERSION — installing it to ~/.local/bin…"
  else
    info "Installing the native jac runtime (v${JAC_VERSION})…"
  fi
  curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh \
    | bash -s -- --version "$JAC_VERSION" \
    || die "jac $JAC_VERSION install failed. See https://www.jac-lang.org for manual instructions."
  export PATH="$HOME/.local/bin:$PATH"
  JAC_BIN="$HOME/.local/bin/jac"
  got="$(jac_ver "$JAC_BIN")"
  [ "$got" = "$JAC_VERSION" ] || die "installed jac reports '${got:-nothing}', expected $JAC_VERSION ($JAC_BIN)."
  # An older jac EARLIER on your PATH (a venv, conda, /usr/local) still answers to
  # `jac` in your shell. Sigil does not care — the launcher below is pinned to
  # this binary — but you should know which one you get when you type `jac`.
  shadow="$(PATH="$ORIG_PATH" command -v jac 2>/dev/null || true)"
  if [ -n "$shadow" ] && [ "$shadow" != "$JAC_BIN" ]; then
    warn "your PATH finds another jac first ($shadow, $(jac_ver "$shadow")). Sigil uses $JAC_BIN."
  fi
fi

# ---- 3. runtime dependencies -------------------------------------------------
# Bare `jac install` provisions two things at once: jac.toml's [dependencies] (pyyaml
# for the AG-IR compiler, rich + prompt_toolkit for the `chat` REPL) AND the capability
# closures jac derives from the config — among them `llm`, which is what puts the
# litellm/pillow/loguru model backend on disk.
#
# That second half is why jac.toml carries a top-level [byllm] section. Through jac 0.34
# the runtime closure shipped litellm itself and the section did nothing; 0.36 dropped it
# from the closure, leaving it an optional dep of byLLM that jac resolves only for a
# project whose config asks for the `llm` capability. Miss the opt-in and the install
# still reports success — byLLM just falls back to its stub and every model call dies
# later with an unreadable AttributeError.
# Do NOT re-list packages here: an explicit list silently drifts from jac.toml, and
# a dependency added there but missed here breaks that feature on a fresh install
# (this is exactly how `sigil chat` shipped broken with "No module named 'rich'").
info "Provisioning dependencies (LLM runtime, chat REPL, everything jac.toml declares)…"
# Keep the output: this is the first place an incompatible jac shows itself, and
# discarding stderr turned "your runtime cannot parse jac.toml" into a one-line
# warning nobody could act on. Same reasoning as the byLLM probe below — an
# install that reports success while being unusable is the failure worth catching.
if ! dep_log="$( cd "$SIGIL_HOME" && "$JAC_BIN" install 2>&1 )"; then
  warn "dependency install failed — Sigil will not run until this is fixed:"
  printf '%s\n' "$dep_log" | sed 's/^/    /' >&2
  case "$dep_log" in
    *"jac.toml is invalid"*)
      warn "  this jac ($("$JAC_BIN" --version 2>/dev/null | head -1)) cannot parse Sigil's jac.toml"
      warn "  (JAC_VERSION=$JAC_VERSION; the tree pins ${pinned:-nothing})."
      ;;
    *) warn "  re-run \`$JAC_BIN install\` in $SIGIL_HOME before your first solve." ;;
  esac
fi

# An install that "succeeds" with no model backend is the one failure worth catching
# here, because nothing else notices until the user's first solve. Ask byLLM directly
# whether its litellm backend resolved rather than trusting the exit code above.
probe_dir="$(mktemp -d)"
cat > "$probe_dir/probe.jac" <<'PROBE'
with entry {
    import from jaclang.byllm._optdeps.litellm { HAS_LITELLM }
    print("sigil-llm-ok" if HAS_LITELLM else "sigil-llm-missing");
}
PROBE
probe_out="$( cd "$SIGIL_HOME" && "$JAC_BIN" run --no-serve "$probe_dir/probe.jac" 2>/dev/null || true )"
case "$probe_out" in
  *sigil-llm-ok*)
    info "LLM runtime ready (byLLM + litellm)."
    ;;
  *)
    warn "byLLM resolved no litellm backend — model calls will fail on the first solve."
    warn "  fix: cd $SIGIL_HOME && $JAC_BIN install   (jac.toml must keep its top-level [byllm] section)"
    ;;
esac
rm -rf "$probe_dir"

# ---- 4. launcher on PATH -----------------------------------------------------
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/sigil" <<EOF
#!/usr/bin/env bash
# Sigil launcher shim — installed by install.sh
# Capture the invocation directory BEFORE cd-ing, or the wrapper's
# SIGIL_PWD default records the app dir and every relative path the
# user typed (e.g. \`sigil compile ./SKILL.md\`) resolves wrong.
export SIGIL_PWD="\${SIGIL_PWD:-\$PWD}"
# The jac this install verified (jac.toml's pin) — not whichever \`jac\` a
# later shell finds first. SIGIL_JAC set by the caller still wins.
export SIGIL_JAC="\${SIGIL_JAC:-$JAC_BIN}"
cd "$SIGIL_HOME" && exec ./sigil "\$@"
EOF
chmod +x "$BIN_DIR/sigil"
chmod +x "$SIGIL_HOME/sigil" 2>/dev/null || true

# Run the launcher just installed. In this script SIGIL_HOME is the APP dir; to
# Sigil itself SIGIL_HOME is the STATE dir (~/.sigil). Hand Sigil the second
# meaning, never the first, or its graph and logs would land inside the app.
run_sigil() {
  if [ -n "${SIGIL_STATE_HOME:-}" ]; then
    env SIGIL_HOME="$SIGIL_STATE_HOME" "$BIN_DIR/sigil" "$@"
  else
    env -u SIGIL_HOME "$BIN_DIR/sigil" "$@"
  fi
}

# ---- 5. compile once, where it will run ---------------------------------------
# jac compiles a program the first time it runs it, and caches the result keyed
# to the program's absolute path, so this is the one place it can happen ahead
# of time: the path is final now. Without it, the user's first command printed
# a page of "Compiling server modules…" and took a minute or more.
if [ "${SIGIL_PRECOMPILE:-1}" != 0 ]; then
  mkdir -p "$STATE_DIR/log"
  clog="$STATE_DIR/log/install-compile.log"
  info "Compiling Sigil (once; a minute or two)…"
  t0="$(date +%s)"
  # `local help`, not `help`: the launcher answers a bare `help` itself, in bash,
  # without ever starting jac — and starting jac on main.jac is the whole point.
  ( SIGIL_NO_DAEMON=1 SIGIL_NO_SERVE=1 run_sigil local help ) >"$clog" 2>&1 &
  cpid=$!
  if [ -t 1 ]; then
    while kill -0 "$cpid" 2>/dev/null; do
      printf '\r   %ss ' "$(( $(date +%s) - t0 ))"
      sleep 1
    done
    printf '\r'
  fi
  if wait "$cpid" && grep -q "the skill compiler" "$clog"; then
    info "Compiled in $(( $(date +%s) - t0 ))s; later runs start from the cache."
  else
    warn "the precompile did not finish; Sigil will compile on its first run instead."
    warn "  log: $clog"
    tail -5 "$clog" | sed 's/^/    /' >&2
  fi
fi

# ---- 6. first-run wizard -------------------------------------------------------
# `curl … | bash` gives this script the pipe as stdin, so questions are read from
# the terminal itself. No terminal (CI, a provisioning script): no questions.
#
# The terminal's own device, not /dev/tty: on macOS, kqueue cannot watch the
# /dev/tty alias, so `sigil setup` (a prompt_toolkit prompt) reading it sees
# end-of-input at once and quits before its first question. The device it
# stands for (/dev/ttys003, /dev/pts/0) works everywhere.
term_dev() {
  local t
  t="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ' || true)"
  case "$t" in
    ""|"?"|"??") echo /dev/tty ;;
    /*) echo "$t" ;;
    *) echo "/dev/$t" ;;
  esac
}
TTYDEV="$(term_dev)"
TTY=""
if [ "$FRESH" = 1 ] && [ "${SIGIL_WIZARD:-1}" != 0 ] && { : <"$TTYDEV"; } 2>/dev/null; then
  TTY=1
fi
ask() {  # ask "question" Y|N  -> 0 for yes
  local a hint="[y/N]"
  [ "$2" = Y ] && hint="[Y/n]"
  printf '%s??%s %s %s ' "$P" "$D" "$1" "$hint" >"$TTYDEV"
  read -r a <"$TTYDEV" || a=""
  case "${a:-$2}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}
if [ -n "$TTY" ]; then
  # Setup requires a connection and does not finish without one; ^C leaves it
  # for later (`sigil setup`, or the first `sigil` asks again).
  SIGIL_NO_DAEMON=1 SIGIL_NO_SERVE=1 run_sigil setup <"$TTYDEV" >"$TTYDEV" 2>&1 \
    || warn "setup did not finish — run \`sigil setup\` when you are ready."
fi
AUTOSTART="${SIGIL_AUTOSTART:-}"
if [ -z "$AUTOSTART" ] && [ -n "$TTY" ]; then
  if ask "Start Sigil automatically when you log in?" Y; then AUTOSTART=1; else AUTOSTART=0; fi
fi
SERVICE=""
if [ "$AUTOSTART" = 1 ]; then
  if out="$(SIGIL_NO_DAEMON=1 SIGIL_NO_SERVE=1 run_sigil daemon install 2>&1)"; then
    SERVICE=1
    info "Sigil starts at login (the scheduler and the Observatory). Undo: sigil daemon uninstall"
  else
    warn "could not add Sigil to login items:"
    printf '%s\n' "$out" | sed 's/^/    /' >&2
  fi
fi

# ---- 7. start it ---------------------------------------------------------------
STARTED=""
if [ "$FRESH" = 1 ]; then
  START="${SIGIL_START:-}"
  if [ -z "$START" ]; then
    if [ -n "$TTY" ]; then START=1; else START=0; fi
  fi
  if [ -n "$SERVICE" ]; then
    # Installing the login service started it already (launchd RunAtLoad,
    # systemd --now). A `sigil start` now would race it: neither has written its
    # pidfile yet, so each would start a second scheduler and Observatory.
    info "Starting Sigil through its login service…"
    for _ in $(seq 1 60); do pid_live daemon && break; sleep 1; done
    if pid_live daemon; then
      printf '    scheduler   : running (login service)\n    observatory : http://localhost:8199   (still building the web client, ~25s)\n'
    else
      warn "the login service has not come up yet; \`sigil daemon status\` and \`sigil daemon logs\` say why."
    fi
    STARTED=1
  elif [ "$START" = 1 ]; then
    info "Starting Sigil…"
    run_sigil start 2>&1 | grep -E '^(scheduler|observatory) +:' | sed 's/^/    /' || true
    STARTED=1
  fi
else
  # An update replaced the code under whatever was running: restart exactly
  # those, so nothing keeps serving the previous version.
  if [ "$WAS_DAEMON" = 1 ]; then
    info "Restarting the scheduler on the new version…"
    run_sigil daemon restart >/dev/null 2>&1 || true
  fi
  if [ "$WAS_SERVE" = 1 ]; then
    info "Restarting the Observatory on the new version…"
    { run_sigil serve stop && run_sigil serve start; } >/dev/null 2>&1 || true
  fi
fi

# ---- done --------------------------------------------------------------------
printf '\n%s  ✓ Sigil installed%s\n\n' "$G" "$D"
printf '    source     %s\n' "$SIGIL_HOME"
printf '    launcher   %s\n\n' "$BIN_DIR/sigil"

case "${SIGIL_PATH_CHECK:-1}:$ORIG_PATH:" in
  0:*|false:*|no:*|off:*) : ;;
  *":$BIN_DIR:"*) : ;;
  *) warn "add the launcher to your PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

if [ "$FRESH" = 0 ]; then
  printf '  Updated to %s. Your graph, skills and settings are where they were.\n\n' "$REF"
elif [ -n "$STARTED" ]; then
  cat <<'EOF'
  Sigil is running.
    sigil                              # chat with your agent
    sigil compile ./SKILL.md           # compile a skill
    http://localhost:8199              # the Observatory (sigil observatory)

  Docs: https://sigilagent.com   ·   https://github.com/sigilagent/sigil
EOF
else
  cat <<'EOF'
  Next:
    sigil setup                        # connect a model: sign in with ChatGPT, Claude Code,
                                       # OpenRouter, a local Ollama, or paste a key
    sigil start                        # the scheduler + the Observatory (http://localhost:8199)
    sigil daemon install               # …and start them at login

    sigil                              # chat with your agent
    sigil solve "turn report.pdf into a clean CSV"

  Docs: https://sigilagent.com   ·   https://github.com/sigilagent/sigil
EOF
fi
