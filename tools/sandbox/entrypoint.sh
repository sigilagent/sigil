#!/usr/bin/env bash
# Runs INSIDE the sandbox container (tools/sandbox/run.sh): pick the models, solve
# the task, show what it compiled, and leave whatever it wrote in the mounted /out.
# One container => one graph, so the steps share it.
set -uo pipefail
# One-shot commands: no scheduler, no Observatory left behind.
export SIGIL_NO_DAEMON=1 SIGIL_NO_SERVE=1
mkdir -p /tmp/work && cd /tmp/work
Q() { sigil "$@" 2>&1 | grep -vE "^(Preparing application|  Restoring prepared application|jac run: takeover)"; }

TASK="${1:-write a haiku about the ocean and save it to haiku.txt}"

echo "==> models (frontier=${SIGIL_FRONTIER:-gpt-5} small=${SIGIL_SMALL:-gpt-4o-mini})"
Q models set frontier "${SIGIL_FRONTIER:-gpt-5}"     >/dev/null
Q models set small    "${SIGIL_SMALL:-gpt-4o-mini}"  >/dev/null
Q models set router   "${SIGIL_ROUTER:-gpt-4o-mini}" >/dev/null

echo "==> solve: $TASK"
Q solve "$TASK"

echo; echo "==> library (compiled procedures + run stats)"
Q library

# What the agent wrote lands where it ran (here) or in its workspace.
cp -r /tmp/work/. /out/ 2>/dev/null || true
cp -r "$HOME/.sigil/workspace/." /out/ 2>/dev/null || true
