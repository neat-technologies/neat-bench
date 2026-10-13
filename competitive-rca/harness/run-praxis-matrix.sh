#!/usr/bin/env bash
# run-praxis-matrix.sh — PRAXIS-14 both-model matrix: detect (parallel arms, both
# models) + resolve (sequential, RESOLVED + ROBUST regression). Clean baseline +
# collector flush at start and before resolve. Honest, unconfounded (image/env/code
# faults — not flag faults, so neat's flag-grain gap doesn't apply here).
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
set -a; . "$HOME/.bench-key" 2>/dev/null; . "$HOME/.bench-creds/creds.env" 2>/dev/null; set +a
export DD_SITE="${DD_SITE:-us5.datadoghq.com}"
H="$HOME/praxis/harness"; NS=otel-demo
RUNDIR="${PRX_RUNDIR:-$HOME/praxis/runs/praxis-$(date +%Y%m%d-%H%M)}"; mkdir -p "$RUNDIR"
OUT="$RUNDIR/results.tsv"; LOG="$RUNDIR/run.log"; BASE="$RUNDIR/p2p-baseline.json"
DET="${PRX_DET:-413 407 406 408 409 415 416 20 32 414}"   # 414 (crash-loop) last
RES="${PRX_RES:-401 412 405 410}"
MODELS="${PRX_MODELS:-opus sonnet}"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

clean(){ say "clean: flush collector + reset flags + rec->stock"
  kubectl -n $NS rollout restart deploy/otel-collector >/dev/null 2>&1
  kubectl -n $NS rollout status deploy/otel-collector --timeout=120s >/dev/null 2>&1
  bash "$HOME/bench-reset.sh" none >/dev/null 2>&1 || true
  kubectl -n $NS set image deploy/recommendation recommendation=ghcr.io/open-telemetry/demo:2.2.0-recommendation >/dev/null 2>&1
  kubectl -n $NS set env deploy/recommendation NEO4J_PRODUCT_DATABASE_ENDPOINT- >/dev/null 2>&1 || true
  kubectl -n $NS rollout status deploy/recommendation --timeout=150s >/dev/null 2>&1
}

say "PRAXIS matrix START  rundir=$RUNDIR  models=[$MODELS]"
say "detect=[$DET]  resolve=[$RES]"
clean
say "warm storefront 25s so the PASS_TO_PASS baseline records healthy 200s"
( kubectl -n $NS port-forward svc/frontend-proxy 18091:8080 >/tmp/warm-pf.log 2>&1 & WP=$!; sleep 4
  for _w in $(seq 1 12); do
    curl -s -o /dev/null --max-time 12 "http://localhost:18091/api/recommendations?productIds=OLJCESPC7Z&currencyCode=USD" 2>/dev/null
    curl -s -o /dev/null --max-time 8 "http://localhost:18091/" 2>/dev/null
    curl -s -o /dev/null --max-time 8 "http://localhost:18091/api/products" 2>/dev/null
    sleep 2
  done
  kill "$WP" 2>/dev/null ) || true
pkill -f "port-forward.*18091" 2>/dev/null || true
say "capture pass2pass (PASS_TO_PASS) baseline in the healthy state"
bash "$H/pass2pass.sh" capture "$BASE" recommendation 2>&1 | tee -a "$LOG"

say "===== DETECT phase (both models, parallel arms, all 8 arms) ====="
FS_ARMS="code graphify obscode neat sentry datadog qodo greptile" \
  FS_MODELS="$MODELS" FS_SCENS="$DET" FS_OUT="$OUT" K=1 \
  bash "$H/run-fullsuite.sh" >>"$LOG" 2>&1 || say "  detect phase rc=$?"
bash "$H/summarize-overnight.sh" "$OUT" > "$RUNDIR/summary.txt" 2>/dev/null || true

clean   # flush before resolve: clears 414 crash-loop pollution (the resolve-VOID cause)
say "===== RESOLVE phase (both models, RESOLVED + ROBUST, code-capable arms) ====="
FS_ARMS="code graphify obscode neat" \
  FS_MODELS="$MODELS" FS_SCENS="$RES" FS_OUT="$OUT" FS_P2P_BASELINE="$BASE" K=1 \
  bash "$H/run-fullsuite.sh" >>"$LOG" 2>&1 || say "  resolve phase rc=$?"

say "PRAXIS matrix COMPLETE"
bash "$H/summarize-overnight.sh" "$OUT" | tee -a "$LOG" > "$RUNDIR/summary.txt"
