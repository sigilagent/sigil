#!/usr/bin/env bash
# Test the Sigil core loop in a locked-down container. The crystallized agents
# author AND RUN arbitrary model-written Python — this keeps that off your host.
#
#   ./tools/sandbox/run.sh                            # default haiku task
#   ./tools/sandbox/run.sh "extract the tables from a.csv and save summary.json"
#   FRONTIER=gpt-5 SMALL=gpt-4o-mini ./tools/sandbox/run.sh "..."
#
# Requires: docker + OPENAI_API_KEY in your env (never baked into the image).
set -euo pipefail
cd "$(dirname "$0")/../.."

TASK="${1:-write a haiku about the ocean and save it to haiku.txt}"
: "${OPENAI_API_KEY:?set OPENAI_API_KEY in your env first}"

echo "==> building sigil-core (first run only)"
# The build context is the repo root (the image needs src/ and jac.toml), but the
# exclude list lives next to the Dockerfile rather than cluttering the repo root.
# BuildKit reads `<dockerfile>.dockerignore` in preference to the context's — force
# it on, or the legacy builder silently ships the whole tree into the context.
DOCKER_BUILDKIT=1 docker build -f tools/sandbox/Dockerfile -t sigil-core . >/dev/null
mkdir -p tools/sandbox/out

# One container runs the whole sequence (configure -> solve -> library), so the graph
# session persists across the steps. Hardening: no host access except a writable out/,
# all caps dropped, no privilege escalation, capped pids/memory. Network stays ON only
# for the model API — put an egress proxy (allow api.openai.com only) in front for a
# stricter test.
docker run --rm \
  -e "OPENAI_API_KEY=$OPENAI_API_KEY" \
  -e "SIGIL_FRONTIER=${FRONTIER:-gpt-5}" \
  -e "SIGIL_SMALL=${SMALL:-gpt-4o-mini}" \
  -e "SIGIL_ROUTER=${SMALL:-gpt-4o-mini}" \
  -v "$PWD/tools/sandbox/out:/app/out" \
  --pids-limit 256 --memory 2g \
  --cap-drop ALL --security-opt no-new-privileges \
  sigil-core "$TASK"

echo
echo "==> artifacts the crystallized agent produced (host ./tools/sandbox/out/):"
ls -la tools/sandbox/out/ 2>/dev/null | grep -vE '^total|\.session' || echo "(none)"
