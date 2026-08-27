#!/usr/bin/env bash
# run-pilot-405.sh — the RESOLVED@k DRIVER for the 405 pilot (3 arms × k=2).
# ─────────────────────────────────────────────────────────────────────────────
# For each (arm ∈ {code,obscode,neat}, seed ∈ {1,2}): ensure 405 is faulted, run
# the arm's headless agent (Load Scenario → Load Tools → Load Headless Agent),
# RCR-grade the emitted patch (did it add a timeout/retry to the neo4j call at
# ~line 129 in get_additional_product_from_database), then fix-grade via
# verify-405.sh (app recovers, regression-free). RESOLVED = RCR AND fix.
# Headline = RESOLVED@2 per arm; the load-bearing comparison is neat vs obscode.
# Command/tool count is NOT scored (SCORING.md §5).
#
#   run-pilot-405.sh            # runs the full 6-run pilot; writes pilot-results.tsv
#
# Model + budget are control variables — identical across arms
#   NEAT_BENCH_MODEL (opus)  NEAT_BENCH_MAX_TURNS (40)
# A steady background load keeps the OBSERVED layer live for the neat/obscode arms.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NS=otel-demo; DEP=recommendation
FAULT_IMG="quay.io/shengkunrz/it-bench-dev:neo4j-serving-recommendation"
SCEN=405
OUT="$HOME/praxis/runs/$SCEN/pilot-results.tsv"
mkdir -p "$(dirname "$OUT")"
echo -e "arm\tseed\trcr\tfix\tresolved\tedited\tneat_hits\tobs_hits" > "$OUT"
SYMPTOM="Users report the storefront intermittently fails to load product recommendations; some product pages time out. Diagnose the failing service and fix the root cause in the recommendation service source."

ensure_faulted () {
  local img; img=$(kubectl get deploy/$DEP -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  if [ "$img" != "$FAULT_IMG" ]; then
    echo "  [pilot] restoring faulted image"; kubectl set image deploy/$DEP -n $NS "$DEP=$FAULT_IMG" >/dev/null 2>&1
    kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
  fi
}

# steady background load so neat/obscode see a live OBSERVED hang (products fast + recs hang)
pkill -f "port-forward.*frontend-proxy" 2>/dev/null; sleep 1
setsid bash -c "export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:\$PATH; kubectl port-forward svc/frontend-proxy 18080:8080 -n $NS" >/tmp/pilot-pf.log 2>&1 </dev/null &
sleep 4
setsid bash -c 'while true; do curl -s -o /dev/null --max-time 5 http://localhost:18080/api/products; curl -s -o /dev/null --max-time 16 "http://localhost:18080/api/recommendations?productIds=OLJCESPC7Z" & sleep 2; done' >/tmp/pilot-load.log 2>&1 </dev/null &
LOAD_PID=$!
trap 'kill $LOAD_PID 2>/dev/null; pkill -f "port-forward.*frontend-proxy" 2>/dev/null' EXIT
echo "[$(date +%H:%M:%S)] steady load started (pid $LOAD_PID); warming OBSERVED layer 40s"; sleep 40

rcr_grade () {   # $1=patch.diff → echo YES/NO
  local p="$1"; [ -s "$p" ] || { echo NO; return; }
  # localized to the neo4j resilience defect: added a timeout/retry/backoff, in the neo4j-call vicinity
  local added_resilience added_area
  added_resilience=$(grep -E '^\+' "$p" | grep -icE 'timeout *=|Timeout|retr(y|ies)|backoff|max_retries|Session\(\)|HTTPAdapter' || true)
  added_area=$(grep -icE 'get_additional_product_from_database|neo4jdb_addr|neo4j|requests\.get' "$p" || true)
  { [ "$added_resilience" -gt 0 ] && [ "$added_area" -gt 0 ]; } && echo YES || echo NO
}

# seed 1: code,obscode,neat ; seed 2: neat,obscode,code  (light order de-bias)
for seed in 1 2; do
  if [ "$seed" = 1 ]; then order="code obscode neat"; else order="neat obscode code"; fi
  for arm in $order; do
    echo "[$(date +%H:%M:%S)] ===== arm=$arm seed=$seed ====="
    ensure_faulted
    RD="$HOME/praxis/runs/$SCEN/$arm$([ "$seed" = 1 ] || echo "/trial-$seed")"
    RUNNER="$HERE/run-$arm.sh"; [ "$arm" = obscode ] && RUNNER="$HERE/obscode/run-obscode.sh"
    NEAT_BENCH_MODEL="${NEAT_BENCH_MODEL:-opus}" NEAT_BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}" \
      bash "$RUNNER" "$SCEN" "$seed" "$SYMPTOM" || echo "  [pilot] run-$arm returned nonzero (agent may have errored; continuing)"
    PATCH="$RD/src/recommendation_server.py"
    RCR=$(rcr_grade "$RD/patch.diff")
    EDITED=$(python3 -c "import json;print(json.load(open('$RD/arm.json'))['edited_recommendation'])" 2>/dev/null || echo false)
    NEAT_HITS=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('neat_tool_hits',0))" 2>/dev/null || echo 0)
    OBS_HITS=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('obs_helper_hits',0))" 2>/dev/null || echo 0)
    FIX=NO
    if [ "$EDITED" = "True" ] || [ "$EDITED" = "true" ]; then
      if bash "$HERE/verify-405.sh" "$PATCH" > "$RD/verify.log" 2>&1; then FIX=YES; fi
      grep -E 'verify-405:|RESOLVED_405' "$RD/verify.log" | sed 's/^/    /'
    else
      echo "    [pilot] no edit → skipping fix-verify (FIX=NO)"
    fi
    RESOLVED=NO; { [ "$RCR" = YES ] && [ "$FIX" = YES ]; } && RESOLVED=YES
    echo -e "$arm\t$seed\t$RCR\t$FIX\t$RESOLVED\t$EDITED\t$NEAT_HITS\t$OBS_HITS" >> "$OUT"
    echo "  [pilot] arm=$arm seed=$seed RCR=$RCR FIX=$FIX RESOLVED=$RESOLVED"
  done
done

echo; echo "======== 405 PILOT RESULTS (RESOLVED@2) ========"
column -t "$OUT"
echo "---- per-arm RESOLVED@2 ----"
for arm in code obscode neat; do
  tot=$(awk -F'\t' -v a="$arm" '$1==a{n++}END{print n+0}' "$OUT")
  res=$(awk -F'\t' -v a="$arm" '$1==a && $5=="YES"{n++}END{print n+0}' "$OUT")
  echo "  $arm: RESOLVED@2 = $res/$tot"
done
echo "results: $OUT"
