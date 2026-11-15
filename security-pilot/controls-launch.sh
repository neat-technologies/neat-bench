#!/usr/bin/env bash
# Grader controls launcher (no model calls). Usage: controls-launch.sh [apps-csv] [controls-csv]
set -euo pipefail
cd "$HOME/neat-bench/security-pilot"
export PATH="$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
export RAM_FLOOR_GI=6
export BENCH_DAEMON_HEALTH_MS=600000
[ -n "${1:-}" ] && export CONTROL_APPS="$1"
[ -n "${2:-}" ] && export CONTROL_NAMES="$2"
while ps -eo args | grep -q "[r]un-smoke.ts"; do sleep 20; done
echo "controls start $(date -u +%FT%TZ) apps=${CONTROL_APPS:-all} controls=${CONTROL_NAMES:-all}"
exec nice -n 10 ./node_modules/.bin/tsx harness/run-controls.ts
