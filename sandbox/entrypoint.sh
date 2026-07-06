#!/usr/bin/env bash
# Runs INSIDE the sandbox container: configure models on the graph, solve the task,
# show what it crystallized, and copy any artifacts out to the mounted /app/out.
# One container => one persistent session, so configure + solve share the graph.
set -uo pipefail
cd /app
S=/tmp/prom.session
Q() { jac run main.jac -s "$S" -- "$@" 2>&1 | grep -vE "plugin 'jac-desktop|^ *[Ww]arning|W0064|Builtins module"; }

TASK="${1:-write a haiku about the ocean and save it to haiku.txt}"

echo "==> configuring models (frontier=${SIGIL_FRONTIER:-gpt-5} small=${SIGIL_SMALL:-gpt-4o-mini})"
Q configure frontier_model "${SIGIL_FRONTIER:-gpt-5}"   >/dev/null
Q configure small_model    "${SIGIL_SMALL:-gpt-4o-mini}" >/dev/null
Q configure router_model   "${SIGIL_ROUTER:-gpt-4o-mini}" >/dev/null

echo "==> solve: $TASK"
Q solve "$TASK"

echo; echo "==> library (crystallized skills + run stats)"
Q library

# lift any artifacts the crystallized script wrote into the mounted out/ dir
mkdir -p /app/out
find /app -maxdepth 1 -type f -newer /app/main.jac \
  \( -name '*.txt' -o -name '*.md' -o -name '*.pdf' -o -name '*.png' -o -name '*.csv' -o -name '*.json' -o -name '*.html' \) \
  -exec cp -f {} /app/out/ \; 2>/dev/null || true
