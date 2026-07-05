#!/usr/bin/env bash
# Test the Prometheus core loop in a locked-down container. The crystallized agents
# author AND RUN arbitrary model-written Python — this keeps that off your host.
#
#   ./sandbox/run.sh                                  # default haiku task
#   ./sandbox/run.sh "extract the tables from a.csv and save summary.json"
#   FRONTIER=gpt-5 SMALL=gpt-4o-mini ./sandbox/run.sh "..."
#
# Requires: docker + OPENAI_API_KEY in your env (never baked into the image).
set -euo pipefail
cd "$(dirname "$0")/.."

TASK="${1:-write a haiku about the ocean and save it to haiku.txt}"
: "${OPENAI_API_KEY:?set OPENAI_API_KEY in your env first}"

echo "==> building prometheus-core (first run only)"
docker build -f sandbox/Dockerfile -t prometheus-core . >/dev/null
mkdir -p sandbox/out

# One container runs the whole sequence (configure -> solve -> library), so the graph
# session persists across the steps. Hardening: no host access except a writable out/,
# all caps dropped, no privilege escalation, capped pids/memory. Network stays ON only
# for the model API — put an egress proxy (allow api.openai.com only) in front for a
# stricter test.
docker run --rm \
  -e "OPENAI_API_KEY=$OPENAI_API_KEY" \
  -e "PROM_FRONTIER=${FRONTIER:-gpt-5}" \
  -e "PROM_SMALL=${SMALL:-gpt-4o-mini}" \
  -e "PROM_ROUTER=${SMALL:-gpt-4o-mini}" \
  -v "$PWD/sandbox/out:/app/out" \
  --pids-limit 256 --memory 2g \
  --cap-drop ALL --security-opt no-new-privileges \
  prometheus-core "$TASK"

echo
echo "==> artifacts the crystallized agent produced (host ./sandbox/out/):"
ls -la sandbox/out/ 2>/dev/null | grep -vE '^total|\.session' || echo "(none)"
