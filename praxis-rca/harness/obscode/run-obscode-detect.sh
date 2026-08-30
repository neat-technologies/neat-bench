#!/usr/bin/env bash
# run-obscode-detect.sh — obscode DETECT arm (diagnose only, no fix).
# ─────────────────────────────────────────────────────────────────────────────
# The unfused baseline for the full-suite DETECT scenarios (config / deploy /
# runtime faults not fixable in the recommendation source): one fresh headless
# Claude (model = NEAT_BENCH_MODEL, default opus) with raw SOURCE + raw
# OBSERVABILITY (Jaeger traces / Prometheus metrics / pod logs via the obscode-*.sh
# helpers), the two signals NEVER fused. Same two inputs as the neat arm; only
# neat fuses them. No neat, no graph. Diagnose only — end with a DIAGNOSIS block,
# graded by grade-detect.sh identically to run-neat-detect.
#   run-obscode-detect.sh <scenario> [trial] ["symptom"]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/obscode-env.sh"
SCEN="${1:?usage: run-obscode-detect.sh <scenario> [trial] [\"symptom\"]}"
TRIAL="${2:-1}"
SYMPTOM="${3:-Users report intermittent failures across the storefront: product pages, product recommendations, and/or ad banners fail to load or error out. Exactly one service is at fault.}"
SRC_ROOT="${OBSCODE_SRC_ROOT:-$HOME/opentelemetry-demo}"
RUN_DIR="$HOME/praxis/divruns/${SCEN}/obscode$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"; MODEL="${NEAT_BENCH_MODEL:-opus}"; MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"
CLAUDE_BIN="$(command -v claude || true)"; [ -n "$CLAUDE_BIN" ] || { echo "no claude" >&2; exit 42; }

echo "[$(date +%H:%M:%S)] obscode-detect — scenario $SCEN trial $TRIAL (model=$MODEL)"
obscode_ensure_jaeger || echo "run-obscode-detect: WARNING Jaeger not answering" >&2
if obscode_ensure_prom; then PROM_STATE="up"; else PROM_STATE="not answering"; fi
echo "  obs surface: traces=Jaeger($JAEGER_API)  metrics=Prometheus[$PROM_STATE]  logs=kubectl"

rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$SRC_ROOT/src/recommendation/." "$SRC/" 2>/dev/null || true
cp "$SRC/recommendation_server.py" "$SRC/recommendation_server.py.orig" 2>/dev/null || true

PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are diagnosing a live microservice system: the OpenTelemetry Demo storefront.
Something is broken in production right now.

SYMPTOM: $SYMPTOM

You have TWO independent, RAW signals. They are NOT joined for you — correlate
them yourself, by hand.

1) SOURCE CODE of the whole app (read-only) at:
     $SRC_ROOT/src
   Read and grep freely across every service.

2) LIVE OBSERVABILITY (raw traces / metrics / logs) via these helpers (run with Bash):
     obscode-traces.sh <service> --errors        # error spans + exceptions + durations (Jaeger)
     obscode-traces.sh <service> --lookback 30m  # recent traces
     obscode-traces.sh --trace <traceID>         # one full request end-to-end
     obscode-traces.sh --services                # every instrumented service
     obscode-logs.sh   <service> --errors        # raw pod logs
     obscode-metrics.sh '<promql>'               # Prometheus instant query (RED metrics)
     obscode-metrics.sh --alerts                 # (no alert rules loaded — use raw RED metrics)
   Known services: recommendation, product-catalog, frontend, frontend-proxy, cart,
   checkout, ad, currency, shipping, payment, quote, email.
   Traces + logs are your primary signal; metrics give error-rate/latency. There is
   NO graph and NO fusion — a wrong-host / silent-service / bad-deploy fault shows
   only as a runtime failure edge you must trace back yourself.

YOUR TASK — DIAGNOSE ONLY (do NOT write a fix):
  Using BOTH signals, identify the single faulty SERVICE and the precise ROOT CAUSE
  — what is wrong and exactly where (file+line/function, or the specific
  config/field/host/deployment). As soon as you have localized it, STOP and write
  the diagnosis. End with EXACTLY this block:

DIAGNOSIS:
SERVICE: <the one faulty service>
ROOT CAUSE: <the specific defect and its location, tied to the trace/log evidence>
PROMPT

OBSCODE_ARM_PATH="$HERE:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
chmod +x "$HERE"/obscode-*.sh 2>/dev/null || true
APPEND_SYS="You are the obscode arm of a DETECTION benchmark: raw source + raw observability, UNFUSED. Correlate traces/logs to code yourself with the obscode-*.sh helpers. There is no graph. Diagnose, do not fix."

echo "[$(date +%H:%M:%S)] launching headless claude (obscode-detect, restricted PATH) …"
( cd "$SRC" && env -u NODE_OPTIONS PATH="$OBSCODE_ARM_PATH" \
    JAEGER_API="$JAEGER_API" PROM_API="${PROM_API:-}" OBSCODE_NS="${OBSCODE_NS:-otel-demo}" \
    "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" --allowedTools "Read,Grep,Glob,Bash" \
    --append-system-prompt "$APPEND_SYS" --strict-mcp-config --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"
source "$HERE/../_arm-extract.sh" "$RUN_DIR" "obscode" "$SCEN" "$TRIAL" "$MODEL" "$MAX_TURNS"
