#!/usr/bin/env bash
# Validate the card verify-after-apply lever on kuma (neat-sonnet-full), dist-fixed + real test.
set -euo pipefail
cd "$HOME/neat-bench/security-pilot"
export PATH="$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:$PATH"
export BENCH_NEAT_CLI="$HOME/neat-src/packages/core/dist-fixed/cli.cjs"
export NEAT_BIN="node $HOME/neat-src/packages/core/dist-fixed/cli.cjs"
export BENCH_TRIAL_COST_CAP=25
export RAM_FLOOR_GI=6
export BENCH_DAEMON_HEALTH_MS=600000
set -a; . "$HOME/.neat-bench-secrets/anthropic.env"; set +a
echo "kuma-check start $(date -u +%FT%TZ) NEAT_BIN=$NEAT_BIN node=$(node -v) key_loaded=$([ -n "${ANTHROPIC_API_KEY:-}" ] && echo yes || echo NO)"
exec nice -n 19 ./node_modules/.bin/tsx harness/run-kuma-check.ts
