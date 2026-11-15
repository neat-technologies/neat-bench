#!/usr/bin/env bash
# bare-sonnet k=3 on all 4 apps: the same model as the NEAT arms, without NEAT. Separates what NEAT does
# from what the cheaper model does. Reported next to the pinned k=3 number.
# security CLI and MCP all run the same build. Reported next to the pinned k=3 number, never merged into it.
set -euo pipefail
cd "$HOME/neat-bench/security-pilot"
export PATH="$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:$PATH"
export BENCH_NEAT_CLI="$HOME/neat-main-1622/packages/core/dist/cli.cjs"
export NEAT_BIN="node $HOME/neat-main-1622/packages/core/dist/cli.cjs"
export NEAT_MCP_ENTRY="$HOME/neat-main-1622/packages/mcp/dist/index.cjs"
export BENCH_TRIAL_COST_CAP=25
export RAM_FLOOR_GI=6
export BENCH_DAEMON_HEALTH_MS=600000
export BENCH_K=3
export BENCH_LABEL=k3-bare-sonnet
export BENCH_ARMS=bare-sonnet
set -a; . "$HOME/.neat-bench-secrets/anthropic.env"; set +a
echo "bare-sonnet start $(date -u +%FT%TZ) NEAT_BIN=$NEAT_BIN node=$(node -v) key_loaded=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo yes || echo NO)"
exec nice -n 19 ./node_modules/.bin/tsx harness/run-k3-suite.ts
