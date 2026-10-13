#!/usr/bin/env bash
# run-full81.sh — the whole bench: PRAXIS-14 (detect 10 + resolve 4) then
# ITBench-67 (detect), all 8 arms, both models. Detached, writes one rundir.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
set -a; . "$HOME/.bench-key" 2>/dev/null; . "$HOME/.bench-creds/creds.env" 2>/dev/null; set +a
export DD_SITE="${DD_SITE:-us5.datadoghq.com}"
H="$HOME/praxis/harness"; NS=otel-demo
RUNDIR="${FULL_RUNDIR:-$HOME/praxis/runs/full81-$(date +%Y%m%d-%H%M)}"; mkdir -p "$RUNDIR"
LOG="$RUNDIR/run.log"
ARMS="${FULL_ARMS:-code graphify obscode neat sentry datadog qodo greptile}"
MODELS="${FULL_MODELS:-opus sonnet}"
say(){ echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say "FULL-81 START  rundir=$RUNDIR"
say "arms=[$ARMS]  models=[$MODELS]"

say "===== PHASE 1: PRAXIS-14 (detect 10 + resolve 4, both models) ====="
PRX_RUNDIR="$RUNDIR/praxis" PRX_MODELS="$MODELS" bash "$H/run-praxis-matrix.sh" >>"$LOG" 2>&1 || say "  praxis rc=$?"
say "  PRAXIS rows=$(( $(wc -l < "$RUNDIR/praxis/results.tsv" 2>/dev/null || echo 1) - 1 ))"

say "===== PHASE 2: ITBench-67 (detect, both models) ====="
FS_ARMS="$ARMS" FS_MODELS="$MODELS" ITB_OUT="$RUNDIR/itbench-results.tsv" bash "$H/run-itbench.sh" >>"$LOG" 2>&1 || say "  itbench rc=$?"
say "  ITBench detect rows=$(( $(wc -l < "$RUNDIR/itbench-results.tsv" 2>/dev/null || echo 1) - 1 ))"

say "===== PHASE 3: ITBench flag-RESOLVE (neat vs code, 14 flag scenarios, both models) ====="
ITBRES_ARMS="${FULL_RES_ARMS:-neat code}" ITBRES_MODELS="$MODELS" ITBRES_OUT="$RUNDIR/itbench-resolve.tsv" \
  bash "$H/run-itbench-resolve.sh" >>"$LOG" 2>&1 || say "  itbench-resolve rc=$?"
say "  ITBench resolve rows=$(( $(wc -l < "$RUNDIR/itbench-resolve.tsv" 2>/dev/null || echo 1) - 1 ))"

say "FULL-81 COMPLETE"
say "--- PRAXIS summary ---"
bash "$H/summarize-overnight.sh" "$RUNDIR/praxis/results.tsv" 2>/dev/null | tee -a "$LOG" || true
say "--- ITBench CAUGHT per arm x model (non-VOID) ---"
awk -F'\t' 'NR>1 && $9!="VOID"{n[$4"|"$5]++; if($9=="YES")c[$4"|"$5]++} END{for(k in n){split(k,a,"|"); printf "  %-10s %-7s %d/%d\n",a[1],a[2],c[k]+0,n[k]}}' "$RUNDIR/itbench-results.tsv" 2>/dev/null | sort | tee -a "$LOG" || true
say "--- ITBench flag-RESOLVE per arm x model ---"
awk -F'\t' 'NR>1{n[$4"|"$5]++; if($6=="YES")r[$4"|"$5]++} END{for(k in n){split(k,a,"|"); printf "  %-6s %-7s RESOLVED %d/%d\n",a[1],a[2],r[k]+0,n[k]}}' "$RUNDIR/itbench-resolve.tsv" 2>/dev/null | sort | tee -a "$LOG" || true
say "=== DONE — results in $RUNDIR ==="
