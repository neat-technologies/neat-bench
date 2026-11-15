#!/usr/bin/env bash
# Bench smoke launcher. Usage: smoke-launch.sh [apps-csv] [arms-csv]
set -euo pipefail
cd "$HOME/neat-bench/security-pilot"
export PATH="$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:$PATH"
export BENCH_NEAT_CLI="$HOME/neat-src/packages/core/dist-fixed/cli.cjs"
export NEAT_BIN="node $HOME/neat-src/packages/core/dist-fixed/cli.cjs"
export NEAT_MCP_ENTRY="$HOME/neat-src/packages/mcp/dist-fixed/index.cjs"
export BENCH_TRIAL_COST_CAP=25
export RAM_FLOOR_GI=6
export BENCH_DAEMON_HEALTH_MS=600000
[ -n "${1:-}" ] && export SMOKE_APPS="$1"
[ -n "${2:-}" ] && export SMOKE_ARMS="$2"
set -a; . "$HOME/.neat-bench-secrets/anthropic.env"; set +a
echo "smoke start $(date -u +%FT%TZ) apps=${SMOKE_APPS:-all} arms=${SMOKE_ARMS:-neat-sonnet-full} key_loaded=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo yes || echo NO)"
exec nice -n 10 ./node_modules/.bin/tsx harness/run-smoke.ts
