#!/usr/bin/env bash
# run-suite.sh — the multi-scenario RESOLVED@k DRIVER for the PRAXIS ±NEAT suite.
# ─────────────────────────────────────────────────────────────────────────────
# Generalized from run-pilot-405.sh to loop scenarios × 3 arms × k seeds, sequential
# (only one scenario active at a time). Per scenario:
#   setup-scenario (deploy faulted variant + productdb + confirm fault) -> restand the
#   live neat daemon (fresh fused graph on the current faulted source) -> for each
#   (arm, seed): load-isolated agent run -> RCI/RCR grade (grade.sh) -> verify-scenario
#   in the scenario's oracle mode -> RESOLVED = RCR AND verified-fix. Revert to faulted.
# Writes ~/praxis/runs/suite-results.tsv (per-run detail) + prints per-arm aggregates.
#
#   run-suite.sh                 # default scenarios 401 405 410 412, k=2
#   SUITE_SCENS="405" K=1 run-suite.sh   # override for a targeted run
# Model + budget are control variables (NEAT_BENCH_MODEL=opus, NEAT_BENCH_MAX_TURNS=40).
# Command/tool count is NOT scored (SCORING.md §5); load-isolation keeps verify clean.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GT="$HERE/ground-truth.tsv"; QUAY=quay.io/shengkunrz/it-bench-dev
NS=otel-demo; DEP=recommendation

SCENS="${SUITE_SCENS:-401 405 410 412}"
K="${K:-2}"
OUT="$HOME/praxis/runs/suite-results.tsv"
mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "scen\tmode\tarm\tseed\trci\trcr\tsymptom_cleared\tfix\tresolved\tedited\ttokens\tcost_usd\tneat_hits\tobs_hits" > "$OUT"
SYMPTOM="Users report the storefront intermittently fails to load product recommendations; some product pages time out or respond slowly. Diagnose the failing service and fix the root cause in the recommendation service source."

# ── LOAD ISOLATION (run-pilot fix #4): background load runs ONLY during the agent
#    phase (so neat/obscode see a live OBSERVED fault); STOPPED before each verify so
#    the oracle measures the fix under its own controlled sequential load. ──────────
LOAD_PID=""; PF_PID=""
start_load () {
  stop_load
  setsid bash -c "export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:\$PATH; kubectl port-forward svc/frontend-proxy 18080:8080 -n $NS" >/tmp/suite-pf.log 2>&1 </dev/null &
  PF_PID=$!; sleep 4
  setsid bash -c 'while true; do curl -s -o /dev/null --max-time 5 http://localhost:18080/api/products; curl -s -o /dev/null --max-time 16 "http://localhost:18080/api/recommendations?productIds=OLJCESPC7Z" & sleep 2; done' >/tmp/suite-load.log 2>&1 </dev/null &
  LOAD_PID=$!
}
stop_load () {
  [ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null; LOAD_PID=""
  pkill -f 'api/recommendations' 2>/dev/null
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; PF_PID=""
  pkill -f "port-forward.*frontend-proxy" 2>/dev/null
}
trap 'stop_load' EXIT

ensure_faulted () {  # $1=fault_img — re-pin faulted (IfNotPresent; env preserved by strategic merge)
  kubectl patch deploy/$DEP -n $NS --type=strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$DEP\",\"image\":\"$1\",\"imagePullPolicy\":\"IfNotPresent\"}]}}}}" >/dev/null 2>&1
  kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
}

for SCEN in $SCENS; do
  row="$(grep -E "^${SCEN}\b" "$GT" | grep -vE '^#' | head -1)"
  IFS=$'\t' read -r _s REC_TAG PDB_TAG PDB_ENV NEO4J_EP MODE RCI <<<"$row"
  FAULT_IMG="$QUAY:$REC_TAG"
  echo; echo "[$(date +%H:%M:%S)] ################## SCENARIO $SCEN ($MODE) ##################"

  # ── stand up the scenario + confirm the fault fires (honest skip if it can't) ──
  if ! bash "$HERE/setup-scenario.sh" "$SCEN" > "$HOME/praxis/runs/setup-$SCEN.log" 2>&1; then
    echo "[$(date +%H:%M:%S)] setup-$SCEN did NOT confirm the fault — SKIPPING scenario (recorded honestly)."
    grep -E "FAULT_FIRES|confirm:|WARNING" "$HOME/praxis/runs/setup-$SCEN.log" | sed 's/^/    /'
    for arm in code obscode neat; do for seed in $(seq 1 "$K"); do
      echo -e "$SCEN\t$MODE\t$arm\t$seed\tSKIP\tSKIP\tSKIP\tSKIP\tSKIP\tSKIP\t0\t0\t0\t0" >> "$OUT"
    done; done
    continue
  fi
  grep -E "FAULT_FIRES|confirm:|ceiling" "$HOME/praxis/runs/setup-$SCEN.log" | sed 's/^/    /'
  LAT_CEIL=""; [ "$MODE" = LATENCY ] && LAT_CEIL="$(cat "$HOME/praxis/seeds/$SCEN/lat_ceiling_ms.txt" 2>/dev/null || echo 4000)"

  # ── restand the live neat daemon so the fused graph reflects THIS scenario ─────
  echo "[$(date +%H:%M:%S)] restanding neat daemon for scenario $SCEN (fresh fused graph)"
  bash "$HOME/praxis/neat-restand.sh" > "$HOME/praxis/runs/restand-$SCEN.log" 2>&1 || echo "  (restand returned nonzero — continuing; neat arm sanity-checks the daemon)"
  tail -3 "$HOME/praxis/runs/restand-$SCEN.log" | sed 's/^/    /'

  FIRST=1
  for seed in $(seq 1 "$K"); do
    # light order de-bias: even seeds flip the arm order
    if [ $(( seed % 2 )) -eq 1 ]; then order="code obscode neat"; else order="neat obscode code"; fi
    for arm in $order; do
      echo "[$(date +%H:%M:%S)] ===== scen=$SCEN arm=$arm seed=$seed ====="
      ensure_faulted "$FAULT_IMG"
      start_load
      WARM=35; [ "$FIRST" = 1 ] && WARM=90   # first arm of a scenario: longer OBSERVED warm after restand
      echo "  [suite] load on — warming OBSERVED ${WARM}s"; sleep "$WARM"; FIRST=0
      RD="$HOME/praxis/runs/$SCEN/$arm$([ "$seed" = 1 ] || echo "/trial-$seed")"
      RUNNER="$HERE/run-$arm.sh"; [ "$arm" = obscode ] && RUNNER="$HERE/obscode/run-obscode.sh"
      NEAT_BENCH_MODEL="${NEAT_BENCH_MODEL:-opus}" NEAT_BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}" \
        bash "$RUNNER" "$SCEN" "$seed" "$SYMPTOM" || echo "  [suite] run-$arm returned nonzero (continuing)"
      stop_load; sleep 3   # load OFF → verify measures the fix in isolation

      PATCH="$RD/src/recommendation_server.py"
      read -r RCI_R RCR_R <<<"$(bash "$HERE/grade.sh" "$SCEN" "$RD/answer.txt" "$RD/patch.diff" | sed 's/RCI=//;s/RCR=//')"
      EDITED=$(python3 -c "import json;print(json.load(open('$RD/arm.json'))['edited_recommendation'])" 2>/dev/null || echo false)
      NEAT_HITS=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('neat_tool_hits',0))" 2>/dev/null || echo 0)
      OBS_HITS=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('obs_helper_hits',0))" 2>/dev/null || echo 0)
      TOKENS=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('total_tokens',0))" 2>/dev/null || echo 0)
      COST=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('cost_usd',0))" 2>/dev/null || echo 0)

      FIX=NO; SYMP=NO
      if [ "$EDITED" = "True" ] || [ "$EDITED" = "true" ]; then
        LAT_MAX_MS="$LAT_CEIL" bash "$HERE/verify-scenario.sh" "$SCEN" "$PATCH" "$FAULT_IMG" "$MODE" > "$RD/verify.log" 2>&1 || true
        grep -E "verify-$SCEN:|SYMPTOM_CLEARED_|RESOLVED_" "$RD/verify.log" | sed 's/^/    /'
        grep -q "RESOLVED_${SCEN}=YES" "$RD/verify.log" && FIX=YES
        grep -q "SYMPTOM_CLEARED_${SCEN}=YES" "$RD/verify.log" && SYMP=YES
      else
        echo "    [suite] no edit → skipping fix-verify (FIX=NO)"
      fi
      RESOLVED=NO; { [ "$RCR_R" = YES ] && [ "$FIX" = YES ]; } && RESOLVED=YES
      echo -e "$SCEN\t$MODE\t$arm\t$seed\t$RCI_R\t$RCR_R\t$SYMP\t$FIX\t$RESOLVED\t$EDITED\t$TOKENS\t$COST\t$NEAT_HITS\t$OBS_HITS" >> "$OUT"
      echo "  [suite] scen=$SCEN arm=$arm seed=$seed RCI=$RCI_R RCR=$RCR_R SYMPTOM=$SYMP FIX=$FIX RESOLVED=$RESOLVED tok=$TOKENS cost=\$$COST"
    done
  done
  ensure_faulted "$FAULT_IMG"   # leave the scenario faulted for the next loop
done

echo; echo "======== SUITE RESULTS ($OUT) ========"
column -t "$OUT"
echo; echo "---- per-arm aggregates (across all scored runs) ----"
for arm in code obscode neat; do
  tot=$(awk -F'\t' -v a="$arm" '$3==a && $9!="SKIP"{n++}END{print n+0}' "$OUT")
  rci=$(awk -F'\t' -v a="$arm" '$3==a && $5=="YES"{n++}END{print n+0}' "$OUT")
  rcr=$(awk -F'\t' -v a="$arm" '$3==a && $6=="YES"{n++}END{print n+0}' "$OUT")
  res=$(awk -F'\t' -v a="$arm" '$3==a && $9=="YES"{n++}END{print n+0}' "$OUT")
  mtok=$(awk -F'\t' -v a="$arm" '$3==a && $9!="SKIP"{s+=$11;n++}END{if(n)printf "%d",s/n; else print 0}' "$OUT")
  mcost=$(awk -F'\t' -v a="$arm" '$3==a && $9!="SKIP"{s+=$12;n++}END{if(n)printf "%.3f",s/n; else print 0}' "$OUT")
  printf "  %-8s RCI=%s/%s  RCR=%s/%s  RESOLVED=%s/%s  ~%s tok  ~\$%s/run\n" "$arm" "$rci" "$tot" "$rcr" "$tot" "$res" "$tot" "$mtok" "$mcost"
done
echo "results: $OUT"
