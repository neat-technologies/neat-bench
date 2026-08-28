#!/usr/bin/env bash
# run-code-detect.sh — CODE arm for the DETECTION bench (diagnose only, no fix).
# Source-only agent (Read/Grep/Glob/Bash), restricted PATH (no neat, no kubectl).
#   run-code-detect.sh <scenario> [trial] ["symptom"]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN="${1:?scenario}"; TRIAL="${2:-1}"
SYMPTOM="${3:-Users report intermittent failures across the storefront: product pages, product recommendations, and/or ad banners fail to load or error out. Exactly one service is at fault.}"
SRC_ROOT="${CODE_SRC_ROOT:-$HOME/opentelemetry-demo}"
RUN_DIR="$HOME/praxis/divruns/${SCEN}/code$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"; MODEL="${NEAT_BENCH_MODEL:-opus}"; MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"
CLAUDE_BIN="$(command -v claude || true)"; [ -n "$CLAUDE_BIN" ] || { echo "no claude" >&2; exit 42; }

echo "[$(date +%H:%M:%S)] code-detect — scenario $SCEN trial $TRIAL (model=$MODEL)"
rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$SRC_ROOT/src/recommendation/." "$SRC/" 2>/dev/null || true
cp "$SRC/recommendation_server.py" "$SRC/recommendation_server.py.orig" 2>/dev/null || true

PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are diagnosing a live microservice system: the OpenTelemetry Demo storefront.
Something is broken in production right now.

SYMPTOM: $SYMPTOM

You have ONE signal: the SOURCE CODE of the whole app, read-only, at
    $SRC_ROOT/src
Read and grep freely across every service (recommendation, product-catalog, ad,
cart, checkout, frontend, currency, etc.). You have NO runtime signal — no traces,
no metrics, no logs, no cluster/deployment state, no graph. Reason from code alone.

YOUR TASK — DIAGNOSE ONLY (do NOT write a fix):
  Identify the single faulty SERVICE and the precise ROOT CAUSE — what is wrong and
  exactly where (file + line/function, or the specific config/field/dependency). As
  soon as you have localized it, STOP and write the diagnosis. End with EXACTLY this
  block:

DIAGNOSIS:
SERVICE: <the one faulty service>
ROOT CAUSE: <the specific defect and its location>
PROMPT

ARM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
APPEND_SYS="You are the code arm of a DETECTION benchmark: raw source ONLY, no runtime signal, no cluster access, no graph. Diagnose from the code. Do not attempt to run neat, kubectl, or any observability tool — they are unavailable."
echo "[$(date +%H:%M:%S)] launching headless claude (code-detect, restricted PATH) …"
( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" --allowedTools "Read,Grep,Glob,Bash" \
    --append-system-prompt "$APPEND_SYS" --strict-mcp-config --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"
source "$HERE/_arm-extract.sh" "$RUN_DIR" "code" "$SCEN" "$TRIAL" "$MODEL" "$MAX_TURNS"
