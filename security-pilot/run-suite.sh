#!/usr/bin/env bash
# Launch a suite run against one NEAT build. The general form of the launch scripts that produced
# the 2026-11-15 runs (k3-launch.sh, supp-launch.sh, bare-sonnet-launch.sh, kept as they ran).
#
#   NEAT_COMMIT=b1e6654 BENCH_LABEL=k3 BENCH_K=3 ./run-suite.sh
#   NEAT_COMMIT=b1e6654 BENCH_LABEL=gitea-rerun BENCH_K=3 BENCH_APPS=gitea ./run-suite.sh
#   NEAT_COMMIT=bf8c29a BENCH_LABEL=supp BENCH_K=3 BENCH_APPS=paperless-ngx \
#     BENCH_ARMS=neat-sonnet-full,neat-sonnet-lean ./run-suite.sh
#
# NEAT_COMMIT   a build made by bootstrap-box.sh under $HOME/neat-builds/<commit> (required)
# BENCH_LABEL   prefix of the run directory under runs/ (default: suite)
# BENCH_K       trials per (arm, app) cell (default: 3)
# BENCH_APPS    comma list; default all four (uptime-kuma,nodegoat,paperless-ngx,gitea)
# BENCH_ARMS    comma list; default every arm in harness/arms.ts
#
# Runs serially, in the foreground. For a long run start it detached:
#   nohup ./run-suite.sh > runs/<label>.out 2>&1 < /dev/null &
set -euo pipefail
cd "$HOME/neat-bench/security-pilot"
: "${NEAT_COMMIT:?set NEAT_COMMIT to a build under \$HOME/neat-builds (see bootstrap-box.sh)}"
BUILD="$HOME/neat-builds/$NEAT_COMMIT"
[ -f "$BUILD/packages/core/dist/cli.cjs" ] && [ -f "$BUILD/packages/mcp/dist/index.cjs" ] || {
  echo "no NEAT build at $BUILD; run: NEAT_COMMITS=$NEAT_COMMIT ./bootstrap-box.sh" >&2
  exit 1
}
export PATH="$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:/usr/local/go/bin:$HOME/.local/bin:$PATH"
# The daemon, the security CLI and the MCP server must all be the same build; the runner refuses
# to start otherwise.
export BENCH_NEAT_CLI="$BUILD/packages/core/dist/cli.cjs"
export NEAT_BIN="node $BUILD/packages/core/dist/cli.cjs"
export NEAT_MCP_ENTRY="$BUILD/packages/mcp/dist/index.cjs"
# Recorded in every trial's run.json as the NEAT commit the build came from.
export BENCH_NEAT_SHA="$(git -C "$BUILD" rev-parse HEAD)"
export BENCH_TRIAL_COST_CAP="${BENCH_TRIAL_COST_CAP:-25}"
export RAM_FLOOR_GI="${RAM_FLOOR_GI:-6}"
export BENCH_DAEMON_HEALTH_MS="${BENCH_DAEMON_HEALTH_MS:-600000}"
export BENCH_K="${BENCH_K:-3}"
export BENCH_LABEL="${BENCH_LABEL:-suite}"
set -a; . "$HOME/.neat-bench-secrets/anthropic.env"; set +a
[ -n "${ANTHROPIC_API_KEY:-}" ] || { echo "ANTHROPIC_API_KEY is empty in ~/.neat-bench-secrets/anthropic.env" >&2; exit 1; }
echo "suite start $(date -u +%FT%TZ) label=$BENCH_LABEL k=$BENCH_K apps=${BENCH_APPS:-all} arms=${BENCH_ARMS:-all}"
echo "NEAT $BENCH_NEAT_SHA  cli sha256 $(sha256sum "$BENCH_NEAT_CLI" | cut -c1-16)  mcp sha256 $(sha256sum "$NEAT_MCP_ENTRY" | cut -c1-16)  node $(node -v)"
exec nice -n 19 ./node_modules/.bin/tsx harness/run-k3-suite.ts
