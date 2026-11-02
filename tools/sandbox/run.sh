#!/usr/bin/env bash
# Test the Sigil core loop in a locked-down container. Compiled agents author AND
# RUN arbitrary model-written Python — this keeps that off your host.
#
#   ./tools/sandbox/run.sh                            # default haiku task
#   ./tools/sandbox/run.sh "extract the tables from a.csv and save summary.json"
#   FRONTIER=gpt-5 SMALL=gpt-4o-mini ./tools/sandbox/run.sh "..."
#   FRONTIER=anthropic/claude-haiku-4-5 SMALL=anthropic/claude-haiku-4-5 ./tools/sandbox/run.sh
#
# Requires: docker + a provider key in your env (OPENAI_API_KEY, ANTHROPIC_API_KEY,
# OPENROUTER_API_KEY or GEMINI_API_KEY). Keys are passed in, never baked into the image.
# The image is the same one the Windows pathway runs (docker/Dockerfile), built on
# jaseci's jac image at the version jac.toml pins.
set -euo pipefail
cd "$(dirname "$0")/../.."

TASK="${1:-write a haiku about the ocean and save it to haiku.txt}"
keys=()
for k in OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY GEMINI_API_KEY; do
  [ -n "${!k:-}" ] && keys+=(-e "$k")
done
[ "${#keys[@]}" -gt 0 ] || { echo "set a provider key (e.g. OPENAI_API_KEY) in your env first" >&2; exit 1; }

./docker/build.sh sigil-sandbox >/dev/null
mkdir -p tools/sandbox/out

# One container runs the whole sequence (models -> solve -> library), so every step
# shares one graph. Hardening: no host access except a writable out/, all caps
# dropped, no privilege escalation, capped pids/memory. Network stays ON only for
# the model API — put an egress proxy (allow api.openai.com only) in front for a
# stricter test. The caps are sized for Sigil on jac 0.37: each `jac run` of the
# CLI holds about 1 GB, and the embedded Postgres runs a handful of processes.
docker run --rm \
  "${keys[@]}" \
  -e "SIGIL_FRONTIER=${FRONTIER:-gpt-5}" \
  -e "SIGIL_SMALL=${SMALL:-gpt-4o-mini}" \
  -e "SIGIL_ROUTER=${SMALL:-gpt-4o-mini}" \
  -v "$PWD/tools/sandbox/out:/out" \
  -v "$PWD/tools/sandbox/entrypoint.sh:/opt/sandbox/entrypoint.sh:ro" \
  --pids-limit 512 --memory 6g \
  --cap-drop ALL --security-opt no-new-privileges \
  --entrypoint bash \
  sigil-sandbox /opt/sandbox/entrypoint.sh "$TASK"

echo
echo "==> artifacts the compiled agent produced (host ./tools/sandbox/out/):"
ls -la tools/sandbox/out/ 2>/dev/null | grep -vE '^total' || echo "(none)"
