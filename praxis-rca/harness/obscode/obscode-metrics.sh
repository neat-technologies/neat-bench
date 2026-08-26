#!/usr/bin/env bash
# obscode-metrics.sh — RAW metric access for the obscode arm (Prometheus API).
# ─────────────────────────────────────────────────────────────────────────────
# Runs a PromQL query (or reads active alerts) against the otel-demo Prometheus.
# Raw numbers, no fusion — the agent joins them to traces/source by hand.
#
# Usage:
#   obscode-metrics.sh '<promql>'                 # instant query
#   obscode-metrics.sh '<promql>' --range 15m     # range query, last 15m
#   obscode-metrics.sh '<promql>' --range 15m --step 30s
#   obscode-metrics.sh --alerts                   # active Prometheus alerts (the RED signal)
#   obscode-metrics.sh --raw '<promql>'           # full JSON, no digest
#
# Examples:
#   obscode-metrics.sh 'sum by (job) (rate(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}[1m]))'
#   obscode-metrics.sh 'histogram_quantile(0.95, sum by (le) (rate(duration_milliseconds_bucket[5m])))'
#   obscode-metrics.sh --alerts
#
# HONEST NOTE: Prometheus is healthy (it was OOM-looping at 300Mi; the operator raised
# it to 1Gi). It carries the otel-demo app RED metrics — traces_span_metrics_calls_total
# (by service_name/span_name/status_code) and traces_span_metrics_duration_milliseconds_bucket
# (histogram_quantile p95/p99) — plus k8s/infra. Two honest caveats: (1) no alert RULES
# are loaded, so --alerts always says "no active alerts" (use the raw RED metrics for the
# anomaly signal); (2) app-RED series take a few minutes to repopulate after a Prometheus
# restart, so PromQL may transiently return "empty result set" — reported honestly, never
# a silent empty. If Prometheus is truly unreachable this helper errors loudly (non-zero
# exit). See harness/obscode/README.md "Status of the metrics leg".
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=obscode-env.sh
source "$HERE/obscode-env.sh"

MODE="query"; RANGE=""; STEP="15s"; RAW=0; QUERY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --alerts) MODE="alerts"; shift ;;
    --range)  RANGE="$2"; shift 2 ;;
    --step)   STEP="$2"; shift 2 ;;
    --raw)    RAW=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*)       echo "unknown flag: $1" >&2; exit 2 ;;
    *)        QUERY="$1"; shift ;;
  esac
done

DOWN_MSG='obscode-metrics: Prometheus is not answering right now. It normally runs
1/1 (the operator raised it to 1Gi after an OOM loop) — if this persists, check the
pod (kubectl get pods -n otel-demo -l app.kubernetes.io/name=prometheus). This is
NOT "no anomaly." Rely on obscode-traces.sh + obscode-logs.sh for the runtime signal.'

if ! obscode_ensure_prom; then
  echo "$DOWN_MSG" >&2
  echo '{"status":"error","errorType":"unreachable","error":"prometheus not answering — see harness/obscode/README.md"}'
  exit 1
fi

fetch() { curl -s --max-time 8 "$@"; }

if [ "$MODE" = alerts ]; then
  OUT="$(fetch "${PROM_API}/api/v1/alerts")"
  [ -n "$OUT" ] || { echo "$DOWN_MSG" >&2; exit 1; }
  if [ "$RAW" = 1 ]; then echo "$OUT"; exit 0; fi
  _TMP="$(mktemp)"; printf '%s' "$OUT" > "$_TMP"
  python3 - "$_TMP" <<'PY'
import sys,json
d=json.load(open(sys.argv[1]))
alerts=(d.get("data") or {}).get("alerts") or []
if not alerts:
    print("[obscode-metrics] no active alerts"); sys.exit(0)
for a in alerts:
    lbl=a.get("labels",{})
    extra={k:v for k,v in lbl.items() if k!="alertname"}
    print(f'{a.get("state","?"):8} {lbl.get("alertname","?")}  {extra}  since={a.get("activeAt","?")}')
PY
  rm -f "$_TMP"
  exit 0
fi

[ -n "$QUERY" ] || { echo "usage: obscode-metrics.sh '<promql>' [--range 15m] | --alerts" >&2; exit 2; }
Q="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$QUERY")"

if [ -n "$RANGE" ]; then
  END="$(date +%s)"
  # convert range like 15m/1h/30s to seconds
  START="$(python3 -c '
import sys,re
r=sys.argv[1]; m=re.match(r"(\d+)([smh])$", r); u={"s":1,"m":60,"h":3600}
print(int(sys.argv[2]) - int(m.group(1))*u[m.group(2)]) if m else print(int(sys.argv[2])-900)
' "$RANGE" "$END")"
  OUT="$(fetch "${PROM_API}/api/v1/query_range?query=${Q}&start=${START}&end=${END}&step=${STEP}")"
else
  OUT="$(fetch "${PROM_API}/api/v1/query?query=${Q}")"
fi
[ -n "$OUT" ] || { echo "$DOWN_MSG" >&2; exit 1; }
if [ "$RAW" = 1 ]; then echo "$OUT"; exit 0; fi

_TMP="$(mktemp)"; printf '%s' "$OUT" > "$_TMP"
python3 - "$_TMP" <<'PY'
import sys,json
d=json.load(open(sys.argv[1]))
if d.get("status")!="success":
    print("[obscode-metrics] query error:", json.dumps(d)[:300]); sys.exit(0)
r=d.get("data",{}); rt=r.get("resultType"); res=r.get("result") or []
if not res:
    print("[obscode-metrics] empty result set"); sys.exit(0)
for s in res[:40]:
    m=s.get("metric",{})
    lab=", ".join(f"{k}={v}" for k,v in m.items()) or "(no labels)"
    if rt=="vector":
        val=s.get("value",[None,None])[1]
        print(f"{lab}  ->  {val}")
    elif rt=="matrix":
        vals=s.get("values",[])
        pts=[float(v[1]) for v in vals if v[1] not in (None,"NaN")]
        last=vals[-1][1] if vals else "?"
        mn=min(pts) if pts else "?"; mx=max(pts) if pts else "?"
        print(f"{lab}  ->  last={last}  n={len(vals)}  min={mn}  max={mx}")
    else:
        print(f"{lab}  ->  {s}")
PY
rm -f "$_TMP"
