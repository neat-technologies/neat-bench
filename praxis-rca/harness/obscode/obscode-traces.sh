#!/usr/bin/env bash
# obscode-traces.sh — RAW trace access for the obscode arm (Jaeger query API).
# ─────────────────────────────────────────────────────────────────────────────
# Gives a headless agent the live trace signal — error spans, exception events,
# span durations, the cross-service call structure — as a compact, real digest it
# reads and stitches to source BY HAND. No fusion, no graph, no join to code.
#
# Usage:
#   obscode-traces.sh <service> [--errors] [--lookback 1h] [--limit 20] [--raw]
#   obscode-traces.sh --trace <traceID>          # one full trace, span tree
#   obscode-traces.sh --services                 # list instrumented services
#   obscode-traces.sh --operations <service>     # operations seen for a service
#
#   --errors     only traces Jaeger tagged error=true (fast path to failures)
#   --lookback   time window back from now (Jaeger syntax: 1h, 30m, 2h; default 1h)
#   --limit      max traces (default 20)
#   --raw        dump the full Jaeger JSON instead of the digest
#
# Examples:
#   obscode-traces.sh recommendation --errors        # what's failing + why
#   obscode-traces.sh frontend-proxy --lookback 30m  # edge-service view
#   obscode-traces.sh --trace 60dcdb812d148d6c...     # drill one request end-to-end
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=obscode-env.sh
source "$HERE/obscode-env.sh"

ERRORS=0; LOOKBACK="1h"; LIMIT="20"; RAW=0; MODE="service"; SERVICE=""; TRACEID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --errors)     ERRORS=1; shift ;;
    --lookback)   LOOKBACK="$2"; shift 2 ;;
    --limit)      LIMIT="$2"; shift 2 ;;
    --raw)        RAW=1; shift ;;
    --trace)      MODE="trace"; TRACEID="$2"; shift 2 ;;
    --services)   MODE="services"; shift ;;
    --operations) MODE="operations"; SERVICE="$2"; shift 2 ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    -*)           echo "unknown flag: $1" >&2; exit 2 ;;
    *)            SERVICE="$1"; shift ;;
  esac
done

obscode_ensure_jaeger || { echo "obscode-traces: Jaeger unreachable" >&2; exit 1; }

if [ "$MODE" = services ]; then
  curl -s "${JAEGER_API}/services" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(sorted(d.get("data") or [])))'
  exit 0
fi
if [ "$MODE" = operations ]; then
  [ -n "$SERVICE" ] || { echo "usage: --operations <service>" >&2; exit 2; }
  curl -s "${JAEGER_API}/operations?service=${SERVICE}" | python3 -c 'import sys,json; d=json.load(sys.stdin); print("\n".join(sorted((o.get("name") if isinstance(o,dict) else o) for o in (d.get("data") or []))))'
  exit 0
fi

# tags filter for error-only
TAGS=""
[ "$ERRORS" = 1 ] && TAGS='&tags=%7B%22error%22%3A%22true%22%7D'

if [ "$MODE" = trace ]; then
  [ -n "$TRACEID" ] || { echo "usage: --trace <traceID>" >&2; exit 2; }
  JSON="$(curl -s "${JAEGER_API}/traces/${TRACEID}")"
else
  [ -n "$SERVICE" ] || { echo "usage: obscode-traces.sh <service> [--errors ...]" >&2; exit 2; }
  JSON="$(curl -s "${JAEGER_API}/traces?service=${SERVICE}&limit=${LIMIT}&lookback=${LOOKBACK}${TAGS}")"
fi

if [ "$RAW" = 1 ]; then echo "$JSON"; exit 0; fi

# ── digest: real, useful, unfused. Per trace: services touched, error spans with
#    their operation/service/duration/status + exception events; then a summary
#    (n traces, n with errors, top exception messages, duration percentiles). ──
# NB: JSON goes via a temp file (arg), NOT stdin — the digest program itself is fed
# to `python3 -` on stdin via the heredoc, so stdin is already taken.
_TMP="$(mktemp)"; printf '%s' "$JSON" > "$_TMP"
python3 - "$_TMP" "$SERVICE" "$MODE" <<'PY'
import sys, json
raw = open(sys.argv[1]).read()
subject = sys.argv[2] if len(sys.argv) > 2 else ""
mode = sys.argv[3] if len(sys.argv) > 3 else "service"
try:
    d = json.loads(raw)
except Exception as e:
    print(f"[obscode-traces] could not parse Jaeger response: {e}")
    print(raw[:400]); sys.exit(0)
traces = d.get("data") or []
if not traces:
    print(f"[obscode-traces] no traces returned (subject={subject}). Widen --lookback or drop --errors.")
    sys.exit(0)

def tagmap(sp): return {t["key"]: t.get("value") for t in sp.get("tags", [])}

all_durs = []          # root/entry durations, microseconds
exc_counts = {}        # exception.message -> count
err_span_total = 0

for t in traces:
    procs = {pid: p.get("serviceName", "?") for pid, p in (t.get("processes") or {}).items()}
    spans = t.get("spans", [])
    svcs = sorted({procs.get(s.get("processID"), "?") for s in spans})
    # entry span = the one with no CHILD_OF reference (best-effort)
    roots = [s for s in spans if not s.get("references")]
    root = roots[0] if roots else (spans[0] if spans else None)
    root_dur = root.get("duration") if root else None
    if root_dur is not None:
        all_durs.append(root_dur)
    err_spans = []
    for s in spans:
        tm = tagmap(s)
        is_err = str(tm.get("error")).lower() == "true" or str(tm.get("otel.status_code")).upper() == "ERROR"
        excs = []
        for lg in s.get("logs", []):
            f = {x["key"]: x.get("value") for x in lg.get("fields", [])}
            if f.get("event") == "exception" or "exception.type" in f:
                msg = f"{f.get('exception.type','?')}: {f.get('exception.message','')}".strip()
                excs.append((msg, f.get("exception.stacktrace", "")))
                exc_counts[msg] = exc_counts.get(msg, 0) + 1
        if is_err or excs:
            err_span_total += 1
            err_spans.append((procs.get(s.get("processID"), "?"), s.get("operationName", "?"),
                              s.get("duration", 0), tm.get("http.status_code") or tm.get("rpc.grpc.status_code"), excs))
    if err_spans or mode == "trace":
        print(f"trace {t.get('traceID','?')[:16]}  services=[{','.join(svcs)}]  spans={len(spans)}  root_dur={ (root_dur or 0)/1000:.1f}ms")
        for svc, op, dur, st, excs in err_spans:
            line = f"    ERROR  {svc} :: {op}  dur={dur/1000:.1f}ms"
            if st not in (None, "", "0"): line += f"  status={st}"
            print(line)
            for msg, stack in excs:
                print(f"           exception: {msg}")
                if stack:
                    frame = [ln for ln in str(stack).splitlines() if 'File "' in ln or ", line " in ln]
                    if frame: print(f"           at: {frame[-1].strip()[:160]}")

def pct(vals, p):
    if not vals: return 0.0
    v = sorted(vals); k = int(round((p/100.0)*(len(v)-1)))
    return v[k]/1000.0

print("")
print(f"[summary] subject={subject}  traces={len(traces)}  error_spans={err_span_total}")
if all_durs:
    print(f"[summary] entry-span latency ms: p50={pct(all_durs,50):.1f}  p95={pct(all_durs,95):.1f}  max={max(all_durs)/1000:.1f}")
if exc_counts:
    print("[summary] top exceptions:")
    for msg, c in sorted(exc_counts.items(), key=lambda kv: -kv[1])[:6]:
        print(f"    {c:>4}x  {msg[:160]}")
PY
rm -f "$_TMP"
