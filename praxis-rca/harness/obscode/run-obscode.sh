#!/usr/bin/env bash
# run-obscode.sh — the obscode ARM RUNNER for PRAXIS Code-Cloud-RCA (±NEAT bench).
# ─────────────────────────────────────────────────────────────────────────────
# obscode = the STRONG, UNFUSED baseline: one fresh headless Claude Opus with
#   (a) raw SOURCE access to the otel-demo tree (Read/Grep/Glob), and
#   (b) raw OBSERVABILITY — traces (Jaeger) + metrics (Prometheus) + logs —
#       via the obscode-*.sh helpers,
# the two signals NEVER fused. It gets the SAME two inputs as the neat arm; only
# neat fuses them. No MCP server, no neat, no graph. The agent stitches by hand.
#
# It slots into the exact box convention the code/neat arms use: it writes the
# agent's fix to  ~/praxis/runs/<scenario>/obscode[/trial-N]/src/recommendation_server.py
# so grade-fix.sh / verify-generic.sh grade it identically to the other arms.
#
#   run-obscode.sh <scenario> [trial] ["symptom text"]
#     <scenario>  PRAXIS id, e.g. 401, 405, 411   (fault already injected by operator)
#     [trial]     seed index for RESOLVED@k determinism runs (default 1)
#     [symptom]   cause-neutral symptom shown to the agent (default: generic rec/frontend errors)
#
# Model + budget are control variables — identical across all three arms:
#   NEAT_BENCH_MODEL   (default: opus)     NEAT_BENCH_MAX_TURNS (default: 40)
# Override BOTH the same way for every arm or the comparison is invalid.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=obscode-env.sh
source "$HERE/obscode-env.sh"

SCEN="${1:?usage: run-obscode.sh <scenario> [trial] [\"symptom\"]}"
TRIAL="${2:-1}"
SYMPTOM="${3:-Users report errors on the product / recommendation path: the storefront intermittently fails to load recommendations and the frontend returns errors. Diagnose the failing service and fix the root cause in source.}"

SRC_ROOT="${OBSCODE_SRC_ROOT:-$HOME/opentelemetry-demo}"     # full app source (read/grep)
REC_SRC="$SRC_ROOT/src/recommendation"                       # the editable fault locus
RUN_DIR="$HOME/praxis/runs/${SCEN}/obscode$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"
MODEL="${NEAT_BENCH_MODEL:-opus}"
MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"

command -v claude >/dev/null 2>&1 || { echo "run-obscode: claude CLI not found on PATH" >&2; exit 42; }
[ -d "$REC_SRC" ] || { echo "run-obscode: recommendation source not found at $REC_SRC" >&2; exit 1; }

echo "[$(date +%H:%M:%S)] obscode arm — scenario $SCEN trial $TRIAL (model=$MODEL, turns=$MAX_TURNS)"

# ── obs surface up (traces always; metrics best-effort — honest if it's down) ──
obscode_ensure_jaeger || echo "run-obscode: WARNING Jaeger not answering — obs surface degraded" >&2
if obscode_ensure_prom; then PROM_STATE="up (app RED + latency + infra; no alert rules loaded — see README)"; else PROM_STATE="not answering"; fi
echo "  obs surface: traces=Jaeger($JAEGER_API)  metrics=Prometheus[$PROM_STATE]  logs=kubectl"

# ── fresh editable copy of the recommendation service (reset per run) ──────────
rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$REC_SRC/." "$SRC/"
cp "$SRC/recommendation_server.py" "$SRC/recommendation_server.py.orig"

# ── the prompt (symptom-only; both signals offered; explicitly UNFUSED) ───────
PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are debugging a live microservice system: the OpenTelemetry Demo (an online
storefront). Something is broken in production right now.

SYMPTOM: $SYMPTOM

You have TWO independent, RAW signals. They are NOT joined for you — you must
correlate them yourself, by hand.

1) SOURCE CODE (read-only reference to the whole app):
     $SRC_ROOT/src
   Read and grep freely across every service. The service you can EDIT and must
   PATCH is the recommendation service, whose source is your current directory
   (./). Your fix must be an edit to a file in ./ (e.g. ./recommendation_server.py).

2) LIVE OBSERVABILITY (raw traces / metrics / logs from the running system) via
   these helper commands — run them with Bash:
     obscode-traces.sh <service> --errors        # error spans + exception events + durations (Jaeger)
     obscode-traces.sh <service> --lookback 30m  # recent traces for a service
     obscode-traces.sh --trace <traceID>         # one full request end-to-end
     obscode-traces.sh --services                # every instrumented service
     obscode-logs.sh   <service> --errors        # raw pod logs (stdout/stderr)
     obscode-metrics.sh '<promql>'               # Prometheus instant query
     obscode-metrics.sh --alerts                 # active Prometheus alerts
   Known services include: recommendation, product-catalog, frontend, frontend-proxy,
   cart, checkout, ad, currency, shipping, payment, quote, email.
   METRICS NOTE: Prometheus carries the app RED metrics — traces_span_metrics_calls_total
   (by service_name/span_name/status_code) and traces_span_metrics_duration_milliseconds_bucket
   (use histogram_quantile for p95/p99 per service) — plus infra. Two caveats: no alert
   RULES are loaded, so --alerts says "no active alerts" regardless (use the raw RED
   metrics for the anomaly signal, not --alerts); and app-RED series need a few minutes to
   repopulate after a Prometheus restart (a transient "empty result set" is a timing gap,
   NOT "no anomaly"). Traces + logs are your primary signal; metrics give error-rate/latency.

YOUR TASK — diagnose AND fix:
  a) Use BOTH signals together — read the traces/logs to see WHAT fails and WHERE
     (which service, which operation, which exception), then read the SOURCE to
     find the exact faulty line and understand WHY.
  b) Edit the recommendation source in ./ to fix the root cause. Change as little
     as possible. Do not change tests. Do not add artificial workarounds — fix the
     actual defect so the service behaves like a correct implementation would.
  c) State plainly: the faulty SERVICE, the FILE and LINE you changed, and WHY
     (tie it to the trace/log evidence you saw).
  d) End your answer with a fenced block of the runtime→code facts you relied on,
     neutral terms only (file paths + coarse targets), one object per line:

\`\`\`neat-evidence
[{"from":"recommendation_server.py","to":"product-catalog","kind":"calls"}]
\`\`\`
PROMPT

# ── run ONE fresh headless Claude Opus. obscode = NO MCP server (‑‑strict-mcp-config
#    with no ‑‑mcp-config guarantees no neat / no ambient servers leak in). Same
#    built-in toolset as the other arms; the ONLY difference vs neat is fusion. ──
export PATH="$HERE:$PATH"                          # so Bash calls resolve obscode-*.sh
export JAEGER_API PROM_API OBSCODE_NS               # helpers read these
chmod +x "$HERE"/obscode-*.sh 2>/dev/null || true

APPEND_SYS="You are the obscode arm of an RCA benchmark: raw source + raw observability, UNFUSED. Correlate traces/logs to code yourself. Prefer the obscode-*.sh helpers for runtime signal. Do not assume a graph exists — there is none."

echo "[$(date +%H:%M:%S)] launching headless claude (obscode) …"
( cd "$SRC" && claude -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Grep,Glob,Edit,Bash" \
    --append-system-prompt "$APPEND_SYS" \
    --strict-mcp-config \
    --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"

# ── capture outputs the graders / report reader expect ────────────────────────
# final assistant answer (stream-json emits a terminal {"type":"result","result":...})
python3 - "$RUN_DIR/claude-stream.jsonl" > "$RUN_DIR/answer.txt" 2>/dev/null <<'PY' || true
import sys,json
ans=""; last_asst=""
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except: continue
    if o.get("type")=="result" and isinstance(o.get("result"),str): ans=o["result"]
    if o.get("type")=="assistant":
        for c in (o.get("message",{}).get("content") or []):
            if isinstance(c,dict) and c.get("type")=="text" and c.get("text","").strip():
                last_asst=c["text"]
# on a completed run use the terminal result; on a truncated/max-turns run fall
# back to the agent's last text so the reasoning is still captured.
print(ans if ans else last_asst)
PY
# tool-call tally (neutral note; NOT a metric per SCORING.md §5)
python3 - "$RUN_DIR/claude-stream.jsonl" > "$RUN_DIR/tool-calls.log" 2>/dev/null <<'PY' || true
import sys,json
for line in open(sys.argv[1]):
    try: o=json.loads(line)
    except: continue
    if o.get("type")=="assistant":
        for c in (o.get("message",{}).get("content") or []):
            if isinstance(c,dict) and c.get("type")=="tool_use":
                inp=c.get("input",{})
                hint=inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                print(f'{c.get("name")}\t{str(hint)[:120]}')
PY
NCALLS=$(wc -l < "$RUN_DIR/tool-calls.log" 2>/dev/null | tr -d ' ')
OBS_CALLS=$(grep -cE 'obscode-(traces|metrics|logs)' "$RUN_DIR/tool-calls.log" 2>/dev/null || echo 0)

# patch record + whether the agent actually edited the file
diff -u "$SRC/recommendation_server.py.orig" "$SRC/recommendation_server.py" > "$RUN_DIR/patch.diff" 2>/dev/null
EDITED=$([ -s "$RUN_DIR/patch.diff" ] && echo true || echo false)

cat > "$RUN_DIR/arm.json" <<JSON
{
  "arm": "obscode",
  "scenario": "$SCEN",
  "trial": $TRIAL,
  "model": "$MODEL",
  "max_turns": $MAX_TURNS,
  "prom_state_at_run": "$PROM_STATE",
  "edited_recommendation": $EDITED,
  "tool_calls_total": ${NCALLS:-0},
  "obs_helper_calls": ${OBS_CALLS:-0},
  "graded_file": "$SRC/recommendation_server.py",
  "verify": "grade-fix.sh $SRC/recommendation_server.py <faultfree_ref.py>  |  verify-generic.sh $SRC <tag> <base_image> <oracle>"
}
JSON

echo "[$(date +%H:%M:%S)] obscode done → $RUN_DIR"
echo "  edited=$EDITED  tool_calls=$NCALLS  obs_helper_calls=$OBS_CALLS  prom=$PROM_STATE"
echo "  grade with:  bash ~/praxis/grade-fix.sh $SRC/recommendation_server.py <faultfree_ref.py>"
echo "  or verify :  bash ~/praxis/verify-generic.sh $SRC obscode$SCEN <fault_base_image> ~/praxis/oracle-rec.sh"
[ "$EDITED" = true ] || echo "  NOTE: agent produced no source edit — inspect answer.txt / claude.err"
