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
#   SIGIL_REF      branch / tag / commit       (default: main)

set -euo pipefail

REPO="sigilagent/sigil"
SIGIL_HOME="${SIGIL_HOME:-$HOME/.sigil/app}"
BIN_DIR="${SIGIL_BIN_DIR:-$HOME/.local/bin}"
REF="${SIGIL_REF:-main}"

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
    git -C "$SIGIL_HOME" fetch --depth 1 origin "$REF" \
      && git -C "$SIGIL_HOME" checkout -q FETCH_HEAD 2>/dev/null \
      || git -C "$SIGIL_HOME" reset --hard "origin/$REF" 2>/dev/null || true
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
# PyYAML (the compiler parses the crystallizer's YAML output) + the byLLM 'llm'
# runtime the model calls need (litellm/httpx/loguru/pillow). byLLM itself is
# bundled in the native jac binary, but that runtime closure is not — without it
# the very first `solve` fails with "'litellm' is required for this feature".
info "Provisioning dependencies (PyYAML + the LLM runtime)…"
( cd "$SIGIL_HOME" && jac install pyyaml litellm httpx loguru pillow >/dev/null 2>&1 ) \
  || warn "dependency install failed — run \`jac install pyyaml litellm httpx loguru pillow\` in $SIGIL_HOME before your first solve."

# ---- 4. launcher on PATH -----------------------------------------------------
mkdir -p "$BIN_DIR"
cat > "$BIN_DIR/sigil" <<EOF
#!/usr/bin/env bash
# Sigil launcher shim — installed by install.sh
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

  Next — set up your models, then compile your first skill:

    sigil setup                        # pick your models (any command also prompts on first run)
    export OPENAI_API_KEY=sk-...       # your model key (skip it for a local model)

    sigil examples                     # starter SKILL.md files to compile
    sigil compile <SKILL.md> -e agent.jac    # SKILL.md  ->  a runnable agent
    ./agent.jac "…"                    # run it — on any model (SIGIL_MODEL=…)

    sigil examples fetch superpowers   # pull a community skill library to compile
    sigil chat                         # the whole agent, from one conversation

  Docs: https://sigilagent.com   ·   https://github.com/sigilagent/sigil
EOF
