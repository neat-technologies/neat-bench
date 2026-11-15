#!/usr/bin/env bash
# Supplement to k3-2026-11-15T00-43-40-620Z: paperless-ngx on both NEAT arms, k=3, on NEAT main
# bf8c29ae (adds #1622, the fix-diff memo that lets a cold paperless scan finish), with each NEAT
# trial reading its own copy of a per-app seeded advisory cache (SCOPE.md 2026-11-15). Daemon,
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
export BENCH_LABEL=supp-paperless-1622
export BENCH_APPS=paperless-ngx
export BENCH_ARMS=neat-sonnet-full,neat-sonnet-lean
set -a; . "$HOME/.neat-bench-secrets/anthropic.env"; set +a
echo "supp start $(date -u +%FT%TZ) NEAT_BIN=$NEAT_BIN node=$(node -v) key_loaded=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo yes || echo NO)"
exec nice -n 19 ./node_modules/.bin/tsx harness/run-k3-suite.ts
