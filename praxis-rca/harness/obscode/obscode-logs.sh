#!/usr/bin/env bash
# obscode-logs.sh — RAW pod logs for the obscode arm (kubectl logs, read-only).
# ─────────────────────────────────────────────────────────────────────────────
# Pod stdout/stderr for a service — the raw application log stream. Part of the
# unfused obs surface: the agent reads exceptions/tracebacks here and stitches
# them to source by hand. Read-only; never mutates the cluster.
#
# Usage:
#   obscode-logs.sh <service> [--since 5m] [--tail 200] [--grep PATTERN] [--errors]
#
#   --since    time window (kubectl syntax: 5m, 1h; default 5m)
#   --tail     max lines (default 200)
#   --grep     keep only lines matching an extended-regex PATTERN
#   --errors   shorthand for a broad error/exception/traceback filter
#
# Examples:
#   obscode-logs.sh recommendation --errors
#   obscode-logs.sh frontend-proxy --since 10m --grep '5[0-9][0-9]|UNAVAILABLE'
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=obscode-env.sh
source "$HERE/obscode-env.sh"

SVC=""; SINCE="5m"; TAIL="200"; PAT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since)  SINCE="$2"; shift 2 ;;
    --tail)   TAIL="$2"; shift 2 ;;
    --grep)   PAT="$2"; shift 2 ;;
    --errors) PAT='error|exception|traceback|abort|no attribute|failed|panic|fatal|UNAVAILABLE|INTERNAL|5[0-9][0-9]'; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*)       echo "unknown flag: $1" >&2; exit 2 ;;
    *)        SVC="$1"; shift ;;
  esac
done
[ -n "$SVC" ] || { echo "usage: obscode-logs.sh <service> [--since 5m] [--tail 200] [--grep PAT] [--errors]" >&2; exit 2; }

OUT="$(kubectl logs "deploy/${SVC}" -n "$OBSCODE_NS" --since="$SINCE" --tail="$TAIL" 2>/dev/null)"
if [ -z "$OUT" ]; then
  # deploy/ name may differ from the app label; fall back to a label selector.
  OUT="$(kubectl logs -n "$OBSCODE_NS" -l "opentelemetry.io/name=${SVC}" --since="$SINCE" --tail="$TAIL" 2>/dev/null)"
fi
[ -n "$OUT" ] || { echo "[obscode-logs] no logs for '${SVC}' in last ${SINCE} (name may differ; try 'kubectl get deploy -n ${OBSCODE_NS}')"; exit 0; }

if [ -n "$PAT" ]; then
  printf '%s\n' "$OUT" | grep -iE --color=never "$PAT" || echo "[obscode-logs] no lines matching /${PAT}/ in last ${SINCE}"
else
  printf '%s\n' "$OUT"
fi
