#!/usr/bin/env bash
# No-API check of the NEAT arms with NEAT's own MCP security tools: stand each app up, call every
# tool once with canned arguments, record each answer's size. Run once per NEAT build.
set -uo pipefail
cd "$HOME/neat-bench/security-pilot"
export PATH="$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:/usr/local/go/bin:$HOME/.local/bin:$PATH"
export SMOKE_APPS=uptime-kuma,paperless-ngx
export SKIP_CONFIGS=bare-opus/uptime-kuma,bare-opus/paperless-ngx,neat-sonnet-lean/uptime-kuma,neat-sonnet-lean/paperless-ngx
export RAM_FLOOR_GI=6 BENCH_DAEMON_HEALTH_MS=600000 BENCH_NEAT_SECURITY=mcp
for c in "$@"; do
  B="$HOME/neat-builds/$c"
  export BENCH_NEAT_CLI="$B/packages/core/dist/cli.cjs" NEAT_BIN="node $B/packages/core/dist/cli.cjs" NEAT_MCP_ENTRY="$B/packages/mcp/dist/index.cjs" BENCH_NEAT_SHA="$c"
  echo "=== build $c start $(date -u +%FT%TZ)"
  rm -rf runs/_advisory-seed
  nice -n 10 ./node_modules/.bin/tsx harness/smoke-matrix.ts 2>&1 | tail -40
  echo "=== build $c done $(date -u +%FT%TZ)"
done
echo "=== EVAL SMOKE COMPLETE"
