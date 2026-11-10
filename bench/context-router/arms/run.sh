#!/usr/bin/env bash
# bench/context-router/arms/run.sh
# ─────────────────────────────────────────────────────────────────────────────
# Run ONE arm of the context-routing experiment on ONE task (neat-bench#23).
#
#   run.sh <task.json> <bare|full|oracle|jev> <trial-n> [--out DIR] [--dry-run] [--route-json FILE]
#
# The operator provisions the target first (clone at the task's base_commit,
# instrument, start the scoped daemon) exactly as for harness/arms/run-arm.sh;
# this script does not provision. It needs:
#   APP_DIR     the target checkout the agent edits (a git repo at base_commit)
#   REST        the scoped daemon's REST port (default 8090)
#   NEAT_REPO   the local Neat checkout under test (MCP bin + claude-skill)
#   TYPESAFE_API_KEY   for the jev arm only; read by the SDK, never echoed
#   NEAT_ROUTER_PROJECT, NEAT_ROUTER_DAEMON_TOKEN   optional, for the router's daemon reads
#   VERIFY=1    run the task's oracle command in APP_DIR after the agent finishes
#
# Every arm gets the same prompt, model, turn budget, built-in tools and
# permissions. What changes per arm is built by arm-config.mjs (see README).
# --dry-run builds the arm and writes cmd.json (the exact argv) without
# touching APP_DIR or calling the agent; tests use it.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CR="$(cd "$HERE/.." && pwd)"                       # bench/context-router
REPO_ROOT="$(cd "$CR/../.." && pwd)"               # neat-bench
die() { echo "run.sh: $*" >&2; exit 1; }

TASK="${1:?usage: run.sh <task.json> <bare|full|oracle|jev> <trial-n> [--out DIR] [--dry-run] [--route-json FILE]}"
ARM="${2:?missing arm}"
TRIAL="${3:?missing trial-n}"
shift 3
OUT_DIR="" DRY_RUN=0 ROUTE_JSON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --route-json) ROUTE_JSON="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$ARM" in bare|full|oracle|jev) : ;; *) die "arm must be bare, full, oracle or jev, got: $ARM" ;; esac
[ -f "$TASK" ] || die "task not found: $TASK"
TASK="$(cd "$(dirname "$TASK")" && pwd)/$(basename "$TASK")"

TASK_ID="$(jq -r .id "$TASK")"
OUT_DIR="${OUT_DIR:-$REPO_ROOT/results/context-router/$TASK_ID/trial-$TRIAL/$ARM}"
mkdir -p "$OUT_DIR"

NEAT_REPO="${NEAT_REPO:-$HOME/Documents/GitHub/Untitled/Neat}"
SKILL_DIR="${SKILL_DIR:-$NEAT_REPO/packages/claude-skill}"
NEAT_MCP_BIN="${NEAT_MCP_BIN:-$NEAT_REPO/packages/mcp/dist/index.cjs}"
REST="${REST:-8090}"
D="http://127.0.0.1:$REST"
BENCH_MODEL="${NEAT_BENCH_MODEL:-sonnet}"
BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-25}"
[ "$ARM" = bare ] || [ -f "$SKILL_DIR/GRAPH_FIRST.md" ] || die "GRAPH_FIRST.md not found under SKILL_DIR=$SKILL_DIR"

# ── the prompt: identical in every arm ───────────────────────────────────────
jq -r .prompt "$TASK" > "$OUT_DIR/request.txt"      # the developer's request: all the router sees
{
  cat "$OUT_DIR/request.txt"
  printf '\nFix it. Change as little as possible and do not change tests. When you are done, say which file and line you changed and why.\n'
} > "$OUT_DIR/prompt.txt"

# ── reset the tree and inject the bug ────────────────────────────────────────
if [ "$DRY_RUN" = 0 ]; then
  [ -n "${APP_DIR:-}" ] && [ -d "$APP_DIR/.git" ] || die "APP_DIR must be the target's git checkout"
  git -C "$APP_DIR" checkout -- . >/dev/null 2>&1 || true
  git -C "$APP_DIR" clean -fd -e node_modules -e .env >/dev/null 2>&1 || true
  git -C "$APP_DIR" apply "$(dirname "$TASK")/$(jq -r .bug_patch "$TASK")" || die "bug patch did not apply in $APP_DIR"
fi

# ── route (jev arm only) ─────────────────────────────────────────────────────
ROUTE_ARG=()
if [ "$ARM" = jev ]; then
  if [ -n "$ROUTE_JSON" ]; then
    cp "$ROUTE_JSON" "$OUT_DIR/route.json"
  else
    node "$CR/router/cli.mjs" --prompt-file "$OUT_DIR/request.txt" --daemon "$D" \
      ${NEAT_ROUTER_PROJECT:+--project "$NEAT_ROUTER_PROJECT"} --out "$OUT_DIR/route.json"
  fi
  ROUTE_ARG=(--route "$OUT_DIR/route.json")
fi

# ── build the arm ────────────────────────────────────────────────────────────
node "$HERE/arm-config.mjs" "$TASK" "$ARM" --skill-dir "$SKILL_DIR" "${ROUTE_ARG[@]}" > "$OUT_DIR/arm-config.json"
CFG="$OUT_DIR/arm-config.json"

ARGS=(-p "$(cat "$OUT_DIR/prompt.txt")" --model "$BENCH_MODEL" --max-turns "$BENCH_MAX_TURNS"
      --allowedTools "$(jq -r .allowedTools "$CFG")")
if [ "$(jq -r .mcp "$CFG")" = true ]; then
  sed -e "s#<NEAT_MCP_BIN>#$NEAT_MCP_BIN#g" -e "s#<REST>#$REST#g" \
      "$REPO_ROOT/harness/arms/with-neat.mcp.json" > "$OUT_DIR/with-neat.mcp.json"
  ARGS+=(--mcp-config "$OUT_DIR/with-neat.mcp.json")
fi
if [ "$(jq -r '.appendSystemPrompt != null' "$CFG")" = true ]; then
  ARGS+=(--append-system-prompt "$(jq -r .appendSystemPrompt "$CFG")")
fi
if [ "$(jq -r '.settings != null' "$CFG")" = true ]; then
  ARGS+=(--settings "$(jq -r .settings "$CFG")")
fi
ARGS+=(--strict-mcp-config --dangerously-skip-permissions
       --output-format stream-json --verbose --include-partial-messages)

node -e 'process.stdout.write(JSON.stringify({ argv: process.argv.slice(1) }, null, 2) + "\n")' -- "${ARGS[@]}" > "$OUT_DIR/cmd.json"
if [ "$DRY_RUN" = 1 ]; then
  echo "[dry-run] $TASK_ID $ARM → $OUT_DIR (cmd.json, arm-config.json)"
  exit 0
fi

# ── run the agent ────────────────────────────────────────────────────────────
command -v claude >/dev/null 2>&1 || die "claude CLI not found"
T0=$(date +%s)
( cd "$APP_DIR" && claude "${ARGS[@]}" ) > "$OUT_DIR/claude-stream.jsonl" 2> "$OUT_DIR/claude.err" || true
WALL_S=$(( $(date +%s) - T0 ))

git -C "$APP_DIR" add -A >/dev/null 2>&1 || true
git -C "$APP_DIR" diff --cached -- . ':(exclude)node_modules' > "$OUT_DIR/edit.diff" 2>/dev/null || true
git -C "$APP_DIR" reset -q >/dev/null 2>&1 || true

node "$REPO_ROOT/harness/arms/parse-claude-stream.mjs" "$OUT_DIR/claude-stream.jsonl" \
  --neat-tools "$(jq -r '.allowedTools | split(",")[5:] | join(",")' "$CFG")" > "$OUT_DIR/metrics.json" 2>/dev/null || echo '{}' > "$OUT_DIR/metrics.json"
node "$HERE/neat-bytes.mjs" "$OUT_DIR/claude-stream.jsonl" > "$OUT_DIR/neat-bytes.json" 2>/dev/null || echo '{}' > "$OUT_DIR/neat-bytes.json"

# ── the task's own oracle ────────────────────────────────────────────────────
ORACLE=null
ORACLE_CMD="$(jq -r '.oracle.cmd // empty' "$TASK")"
if [ "${VERIFY:-0}" = 1 ] && [ -n "$ORACLE_CMD" ]; then
  if ( cd "$APP_DIR" && bash -c "$ORACLE_CMD" ) > "$OUT_DIR/verify.txt" 2>&1; then ORACLE=true; else ORACLE=false; fi
fi

jq -n --slurpfile cfg "$CFG" --slurpfile m "$OUT_DIR/metrics.json" --slurpfile nb "$OUT_DIR/neat-bytes.json" \
  --argjson trial "$TRIAL" --argjson wall "$WALL_S" --argjson oracle "$ORACLE" \
  --argjson diff_lines "$(wc -l < "$OUT_DIR/edit.diff" | tr -d ' ')" \
  --slurpfile route <( [ -f "$OUT_DIR/route.json" ] && jq '{tier,reason,confidence,needsRuntime,files,latencyMs,jevLatencyMs,jevError}' "$OUT_DIR/route.json" || echo null ) \
  '{task: $cfg[0].task, size: $cfg[0].size, arm: $cfg[0].arm, trial: $trial,
    route: $route[0], oracle_pass: $oracle, wall_s: $wall,
    injected_bytes: $cfg[0].injectedBytes, neat_runtime_bytes: $nb[0],
    model: $m[0].model, success: $m[0].success, tokens: $m[0].tokens,
    cost_usd: $m[0].total_cost_usd, turns: $m[0].num_turns, files_opened: $m[0].files_opened,
    tool_calls: {neat: ($m[0].neat_calls // 0), other: ($m[0].other_calls // 0)},
    edit_diff_lines: $diff_lines}' > "$OUT_DIR/arm.json"
echo "[$ARM] $TASK_ID trial $TRIAL done → $OUT_DIR/arm.json (oracle_pass=$ORACLE, wall ${WALL_S}s)"
