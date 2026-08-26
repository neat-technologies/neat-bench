#!/usr/bin/env bash
# obscode-env.sh — shared reach layer for the obscode arm's raw-obs helpers.
# ─────────────────────────────────────────────────────────────────────────────
# obscode = raw source + raw observability (traces/metrics/logs), UNFUSED. This
# file is the ONE place that knows WHERE the obs surface lives and HOW to reach
# it, so every helper (traces/metrics/logs) and the arm-runner source it.
#
#   source obscode-env.sh          # sets JAEGER_API / PROM_API, defines helpers
#   obscode_ensure_jaeger          # idempotent port-forward to Jaeger query API
#   obscode_ensure_prom            # idempotent port-forward to Prometheus
#
# The obs surface (otel-demo namespace, verified 2026-08-27):
#   traces   → svc/jaeger-query   :16686  (HTTP query API, base path /jaeger/ui/api)
#   metrics  → svc/prometheus     :9090   (/api/v1/query, /api/v1/alerts)
#   logs     → kubectl logs deploy/<svc>  (pod stdout/stderr, read-only)
# We reach the two HTTP APIs with `kubectl port-forward` to local ports unlikely
# to collide with the neat arm's forwards (8098 neat, 4319 otel, 8080 frontend).
#
# HONEST GAP (see README.md): the otel-demo Prometheus pod is OOMKilled in a loop
# (300Mi limit, exit 137). obscode-metrics.sh degrades LOUDLY when it's down — it
# never returns a silent empty. Traces (Jaeger) + pod logs are healthy and carry
# the baseline. Fixing Prometheus is a cluster memory bump owned by the operator.
# ─────────────────────────────────────────────────────────────────────────────

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
# kubectl lives in ~/.local/bin, node/claude in the nvm dir on the bench box.
case ":$PATH:" in *":$HOME/.local/bin:"*) : ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
for _nvmbin in "$HOME"/.nvm/versions/node/*/bin; do
  [ -d "$_nvmbin" ] && case ":$PATH:" in *":$_nvmbin:"*) : ;; *) export PATH="$_nvmbin:$PATH" ;; esac
done

OBSCODE_NS="${OBSCODE_NS:-otel-demo}"
OBSCODE_JAEGER_PORT="${OBSCODE_JAEGER_PORT:-16699}"   # local port for jaeger-query
OBSCODE_PROM_PORT="${OBSCODE_PROM_PORT:-9099}"        # local port for prometheus

# API bases the helpers hit. Jaeger's query API is under /jaeger/ui/api because
# otel-demo sets QUERY_BASE_PATH=/jaeger/ui (the bare /api/* path serves the SPA).
export JAEGER_API="http://localhost:${OBSCODE_JAEGER_PORT}/jaeger/ui/api"
export PROM_API="http://localhost:${OBSCODE_PROM_PORT}"

# _obscode_pf <svc> <local_port> <remote_port> — start a detached port-forward if
# one isn't already up. Fully detaches (setsid + </dev/null) so it survives the
# ssh channel / the arm-runner exiting.
_obscode_pf() {
  local svc="$1" lp="$2" rp="$3"
  if pgrep -f "port-forward.*${svc}.*${lp}:${rp}" >/dev/null 2>&1; then return 0; fi
  setsid kubectl port-forward -n "$OBSCODE_NS" "svc/${svc}" "${lp}:${rp}" \
      </dev/null >"/tmp/obscode-pf-${svc}.log" 2>&1 &
  disown 2>/dev/null || true
}

# obscode_ensure_jaeger — port-forward Jaeger and block until the query API answers.
obscode_ensure_jaeger() {
  _obscode_pf jaeger-query "$OBSCODE_JAEGER_PORT" 16686
  local i
  for i in $(seq 1 20); do
    if curl -s --max-time 3 "${JAEGER_API}/services" 2>/dev/null | grep -q '"data"'; then return 0; fi
    sleep 1
  done
  echo "obscode-env: WARNING — Jaeger query API not answering at ${JAEGER_API}" >&2
  return 1
}

# obscode_ensure_prom — port-forward Prometheus. Does NOT hard-block: the pod
# OOM-loops, so we start the forward and give it a short chance, then let the
# caller (obscode-metrics.sh) report honestly if it's down.
obscode_ensure_prom() {
  _obscode_pf prometheus "$OBSCODE_PROM_PORT" 9090
  local i
  for i in $(seq 1 6); do
    if curl -s --max-time 2 "${PROM_API}/api/v1/query?query=vector(1)" 2>/dev/null | grep -q '"status"'; then return 0; fi
    sleep 1
  done
  return 1   # caller decides how loud to be
}

obscode_ensure_pf() { obscode_ensure_jaeger; obscode_ensure_prom; }
