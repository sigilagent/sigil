#!/usr/bin/env bash
#
# Sigil installer — https://sigilagent.com
#
#   curl -fsSL https://github.com/sigilagent/sigil/releases/latest/download/install.sh | bash
#
# What it does:
#   1. installs the native `jac` runtime (self-contained binary) if it's missing
#   2. fetches the Sigil source into  ~/.sigil/app   (override with $SIGIL_HOME)
#   3. provisions the runtime deps (PyYAML + the LLM runtime) into the project
#   4. drops a `sigil` launcher onto your PATH  (~/.local/bin, override $SIGIL_BIN_DIR)
#
# Nothing here needs root. Re-running is safe: it updates an existing install.
#
# Env knobs:
#   SIGIL_HOME     where the source lives      (default: ~/.sigil/app)
#   SIGIL_BIN_DIR  where the launcher goes     (default: ~/.local/bin)
#   SIGIL_REF      branch / tag / commit       (default: main in the repo copy;
#                  a release asset is rewritten to pin its own tag — see below)

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

# ---- 1. native jac runtime ---------------------------------------------------
if have jac; then
  info "Found jac: $(jac --version 2>/dev/null | head -1)"
else
  info "Installing the native jac runtime…"
  curl -fsSL https://raw.githubusercontent.com/jaseci-labs/jaseci/main/scripts/install.sh | bash \
    || die "jac install failed. See https://www.jac-lang.org for manual instructions."
  export PATH="$HOME/.local/bin:$PATH"
fi
have jac || die "jac is not on your PATH. Add \$HOME/.local/bin to PATH and re-run this script."

# ---- 2. fetch Sigil source ---------------------------------------------------
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
[ -f "$SIGIL_HOME/main.jac" ] || die "Sigil source looks incomplete (no main.jac in $SIGIL_HOME)."

# ---- 3. runtime dependencies -------------------------------------------------
# Bare `jac install` provisions everything in jac.toml's [dependencies] — notably
# rich + prompt_toolkit, which the `chat` REPL imports. The byLLM 'llm' runtime
# (litellm/loguru/pillow) and pyyaml/httpx ship inside the native jac runtime
# closure, so they are NOT listed in jac.toml — litellm in particular has no wheel
# for the bundled Python and would make this step fail outright.
# Do NOT re-list packages here: an explicit list silently drifts from jac.toml, and
# a dependency added there but missed here breaks that feature on a fresh install
# (this is exactly how `sigil chat` shipped broken with "No module named 'rich'").
info "Provisioning dependencies (the chat REPL + anything else jac.toml declares)…"
( cd "$SIGIL_HOME" && jac install >/dev/null 2>&1 ) \
  || warn "dependency install failed — run \`jac install\` in $SIGIL_HOME before your first solve."

# ---- 4. launcher on PATH -----------------------------------------------------
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/sigil" <<EOF
#!/usr/bin/env bash
# Sigil launcher shim — installed by install.sh
# Capture the invocation directory BEFORE cd-ing, or the wrapper's
# SIGIL_PWD default records the app dir and every relative path the
# user typed (e.g. \`sigil compile ./SKILL.md\`) resolves wrong.
export SIGIL_PWD="\${SIGIL_PWD:-\$PWD}"
cd "$SIGIL_HOME" && exec ./sigil "\$@"
EOF
chmod +x "$BIN_DIR/sigil"
chmod +x "$SIGIL_HOME/sigil" 2>/dev/null || true

# ---- done --------------------------------------------------------------------
printf '\n%s  ✓ Sigil installed%s\n\n' "$G" "$D"
printf '    source     %s\n' "$SIGIL_HOME"
printf '    launcher   %s\n\n' "$BIN_DIR/sigil"

case ":$PATH:" in
  *":$BIN_DIR:"*) : ;;
  *) warn "add the launcher to your PATH:  export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

cat <<'EOF'

  Next:
    export OPENAI_API_KEY=sk-...       # a model key (or point it at a local model)

    # just use it — runs locally, no server needed:
    sigil solve "turn report.pdf into a clean CSV"
    sigil soul | sigil tasks list | sigil chat

    # optional — a live web dashboard to watch it work:
    sigil serve                        # Observatory web UI + HTTP API

  Docs: https://sigilagent.com   ·   https://github.com/sigilagent/sigil
EOF
