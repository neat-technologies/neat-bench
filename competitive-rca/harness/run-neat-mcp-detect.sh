#!/usr/bin/env bash
# run-neat-mcp-detect.sh — the REAL-USER neat arm (Deniz's ruling). The agent is a
# real user: installer-written directive (`neat claude install` -> cwd CLAUDE.md) +
# NEAT's MCP server (@neat.is/mcp), no hand-written NEAT menu, no neat-card. PULL:
# the task is the symptom only; the agent queries NEAT on its own via mcp__neat__*.
#   run-neat-mcp-detect.sh <scenario> [trial] ["symptom"]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN="${1:?scenario}"; TRIAL="${2:-1}"
SYMPTOM="${3:-Users report intermittent failures across the storefront: product pages, product recommendations, and/or ad banners fail to load or error out. Exactly one service is at fault.}"
SRC_ROOT="${NEAT_SRC_ROOT:-$HOME/opentelemetry-demo}"
RUN_DIR="$HOME/praxis/divruns/${SCEN}/neat-mcp$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"; MODEL="${NEAT_BENCH_MODEL:-opus}"; MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"
NEAT_PROJECT="${NEAT_BENCH_PROJECT:-default}"
export NEAT_CORE_URL="${NEAT_CORE_URL:-http://localhost:8098}"
export NEAT_AUTH_TOKEN="${NEAT_AUTH_TOKEN:-benchops-neat-token}"
export NEAT_CORE_TOKEN="${NEAT_CORE_TOKEN:-benchops-neat-token}"
CLAUDE_BIN="$(command -v claude || true)"; NEAT_BIN="$(command -v neat || true)"; NVM_BIN="$(dirname "$NEAT_BIN")"
GLOBAL_MCP="$(npm root -g)/@neat.is/mcp"
[ -n "$CLAUDE_BIN" ] || { echo "no claude" >&2; exit 42; }
[ -n "$NEAT_BIN" ] || { echo "no neat" >&2; exit 43; }

echo "[$(date +%H:%M:%S)] neat-mcp-detect — scenario $SCEN trial $TRIAL (model=$MODEL, project=$NEAT_PROJECT, core=$NEAT_CORE_URL)"
rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$SRC_ROOT/src/recommendation/." "$SRC/" 2>/dev/null || true

# 1) installer-written directive in the agent's cwd (the #1387 query-first prose)
( cd "$SRC" && NEAT_CORE_URL="$NEAT_CORE_URL" neat claude install >/dev/null 2>&1 ) || echo "  warn: neat claude install rc=$?"

# 2) MCP config: the NIGHTLY @neat.is/mcp pointed at the bench daemon (:8098) with token
MCP_CFG="$RUN_DIR/mcp-config.json"
cat > "$MCP_CFG" <<JSON
{"mcpServers":{"neat":{"type":"stdio","command":"node","args":["$GLOBAL_MCP/dist/index.cjs"],"env":{"NEAT_CORE_URL":"$NEAT_CORE_URL","NEAT_AUTH_TOKEN":"$NEAT_AUTH_TOKEN","NEAT_CORE_TOKEN":"$NEAT_CORE_TOKEN"}}}}
JSON

# 3) task prompt = symptom only (pull); the directive carries the NEAT order
PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are diagnosing a live microservice system: the OpenTelemetry Demo storefront.
Something is broken in production right now.

SYMPTOM: $SYMPTOM

Find the ONE faulty service and its precise root cause. As soon as you have localized
the faulty service and the nature of the fault, STOP and write the diagnosis. End with
EXACTLY this block:

DIAGNOSIS:
SERVICE: <the one faulty service>
ROOT CAUSE: <the specific defect and where — file/symbol, config/field/host, or the wrong/silent dependency>
PROMPT

ARM_PATH="$NVM_BIN:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
echo "[$(date +%H:%M:%S)] launching headless claude (neat-mcp real-user arm) …"
( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" \
    NEAT_CORE_URL="$NEAT_CORE_URL" NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" NEAT_CORE_TOKEN="$NEAT_CORE_TOKEN" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Grep,Glob,Bash,mcp__neat__*" \
    --mcp-config "$MCP_CFG" --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"
source "$HERE/_arm-extract.sh" "$RUN_DIR" "neat-mcp" "$SCEN" "$TRIAL" "$MODEL" "$MAX_TURNS"
