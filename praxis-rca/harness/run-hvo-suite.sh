#!/usr/bin/env bash
# run-hvo-suite.sh — "Haiku+NEAT vs Opus-alone" RESOLVED@k driver (±NEAT bench).
# ─────────────────────────────────────────────────────────────────────────────
# The QUESTION: can a CHEAP, WEAK model with NEAT's fused graph match/beat an
# EXPENSIVE, STRONG model reading source alone, at RCA / debugging / incident
# response? Two arms, the ONLY variables being (model, tooling):
#   neat  = Claude HAIKU  + NEAT's full fused-graph arsenal (run-neat.sh)
#   code  = Claude OPUS    + raw source only, no runtime, no graph (run-code.sh)
# Same scenarios, same budget, same oracle as run-suite.sh. obscode is dropped.
#
# Per scenario: setup-scenario (deploy faulted variant + confirm fault) -> restand
# the live neat daemon (fresh fused graph) -> for each (arm, seed): load-isolated
# agent run -> RCI/RCR grade -> verify-scenario oracle -> RESOLVED = RCR AND fix.
# Writes ~/praxis/runs/hvo-results.tsv + prints per-arm aggregates (incl. $ cost —
# the whole point is Haiku is ~1/15th the token cost of Opus).
#
#   run-hvo-suite.sh                       # scenarios 401 405 410 412, k=2
#   HVO_SCENS="405 410" K=3 run-hvo-suite.sh
#   MODEL_neat=haiku MODEL_code=opus run-hvo-suite.sh   # models are the point; overridable
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GT="$HERE/ground-truth.tsv"; QUAY=quay.io/shengkunrz/it-bench-dev
NS=otel-demo; DEP=recommendation

SCENS="${HVO_SCENS:-401 405 410 412}"
K="${K:-2}"
ARMS="${HVO_ARMS:-code neat}"
OUT="$HOME/praxis/runs/hvo-results.tsv"
mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "scen\tmode\tarm\tmodel\tseed\trci\trcr\tsymptom_cleared\tfix\tresolved\tedited\ttokens\tcost_usd\tneat_hits\tobs_hits" > "$OUT"
SYMPTOM="Users report the storefront intermittently fails to load product recommendations; some product pages time out or respond slowly. Diagnose the failing service and fix the root cause in the recommendation service source."

# ── per-arm model: the independent variable of THIS bench ──────────────────────
arm_model () {
  case "$1" in
    neat) echo "${MODEL_neat:-haiku}" ;;
    code) echo "${MODEL_code:-opus}"  ;;
    *)    echo "${NEAT_BENCH_MODEL:-opus}" ;;
  esac
}

# ── LOAD ISOLATION: background load ONLY during the agent phase (neat sees a live
#    OBSERVED fault); STOPPED before each verify so the oracle measures the fix. ──
LOAD_PID=""; PF_PID=""
start_load () {
  stop_load
  setsid bash -c "export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:\$PATH; kubectl port-forward svc/frontend-proxy 18080:8080 -n $NS" >/tmp/hvo-pf.log 2>&1 </dev/null &
  PF_PID=$!; sleep 4
  setsid bash -c 'while true; do curl -s -o /dev/null --max-time 5 http://localhost:18080/api/products; curl -s -o /dev/null --max-time 16 "http://localhost:18080/api/recommendations?productIds=OLJCESPC7Z" & sleep 2; done' >/tmp/hvo-load.log 2>&1 </dev/null &
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

  if ! bash "$HERE/setup-scenario.sh" "$SCEN" > "$HOME/praxis/runs/setup-$SCEN.log" 2>&1; then
    echo "[$(date +%H:%M:%S)] setup-$SCEN did NOT confirm the fault — SKIPPING scenario (recorded honestly)."
    grep -E "FAULT_FIRES|confirm:|WARNING" "$HOME/praxis/runs/setup-$SCEN.log" | sed 's/^/    /'
    for arm in $ARMS; do for seed in $(seq 1 "$K"); do
      echo -e "$SCEN\t$MODE\t$arm\t$(arm_model "$arm")\t$seed\tSKIP\tSKIP\tSKIP\tSKIP\tSKIP\tSKIP\t0\t0\t0\t0" >> "$OUT"
    done; done
    continue
  fi
  grep -E "FAULT_FIRES|confirm:|ceiling" "$HOME/praxis/runs/setup-$SCEN.log" | sed 's/^/    /'
  LAT_CEIL=""; [ "$MODE" = LATENCY ] && LAT_CEIL="$(cat "$HOME/praxis/seeds/$SCEN/lat_ceiling_ms.txt" 2>/dev/null || echo 4000)"

  echo "[$(date +%H:%M:%S)] restanding neat daemon for scenario $SCEN (fresh fused graph)"
  bash "$HOME/praxis/neat-restand.sh" > "$HOME/praxis/runs/restand-$SCEN.log" 2>&1 || echo "  (restand returned nonzero — continuing; neat arm sanity-checks the daemon)"
  tail -3 "$HOME/praxis/runs/restand-$SCEN.log" | sed 's/^/    /'

  # ── keep the code arm truly source-only: restand regenerates NEAT's own byproducts
  #    (neat.patch install-plan + neat-out/ daemon state) into the repo the arms read.
  #    They carry no fault diagnosis, but a "source-only" arm shouldn't see NEAT tooling
  #    output at all — strip them so the read scope is pure app source. The neat arm uses
  #    the live daemon, not these files, so removing them is safe for both arms. ────────
  rm -f  "$HOME/opentelemetry-demo/neat.patch" 2>/dev/null || true
  rm -rf "$HOME/opentelemetry-demo/neat-out"   2>/dev/null || true

  ARMS_REV="$(echo $ARMS | awk '{for(i=NF;i>=1;i--) printf "%s ", $i}')"
  FIRST=1
  for seed in $(seq 1 "$K"); do
    # order de-bias: odd seeds run ARMS as given, even seeds reversed
    if [ $(( seed % 2 )) -eq 1 ]; then order="$ARMS"; else order="$ARMS_REV"; fi
    for arm in $order; do
      MODEL="$(arm_model "$arm")"
      echo "[$(date +%H:%M:%S)] ===== scen=$SCEN arm=$arm model=$MODEL seed=$seed ====="
      ensure_faulted "$FAULT_IMG"
      start_load
      WARM=35; [ "$FIRST" = 1 ] && WARM=90
      echo "  [hvo] load on — warming OBSERVED ${WARM}s"; sleep "$WARM"; FIRST=0
      RD="$HOME/praxis/runs/$SCEN/$arm$([ "$seed" = 1 ] || echo "/trial-$seed")"
      RUNNER="$HERE/run-$arm.sh"
      # decontaminate: reset the SHARED recommendation source to the faulted seed so
      # this arm's private copy starts from faulted source, even if a prior arm's agent
      # mistakenly edited the shared tree (belt to the absolute-path prompt's braces).
      FSEED="$HOME/praxis/seeds/$SCEN/faulted/recommendation_server.py"
      [ -f "$FSEED" ] && cp "$FSEED" "$HOME/opentelemetry-demo/src/recommendation/recommendation_server.py" 2>/dev/null || true
      NEAT_BENCH_MODEL="$MODEL" NEAT_BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}" \
        bash "$RUNNER" "$SCEN" "$seed" "$SYMPTOM" || echo "  [hvo] run-$arm returned nonzero (continuing)"
      stop_load; sleep 3

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
        echo "    [hvo] no edit → skipping fix-verify (FIX=NO)"
      fi
      RESOLVED=NO; { [ "$RCR_R" = YES ] && [ "$FIX" = YES ]; } && RESOLVED=YES
      echo -e "$SCEN\t$MODE\t$arm\t$MODEL\t$seed\t$RCI_R\t$RCR_R\t$SYMP\t$FIX\t$RESOLVED\t$EDITED\t$TOKENS\t$COST\t$NEAT_HITS\t$OBS_HITS" >> "$OUT"
      echo "  [hvo] scen=$SCEN arm=$arm($MODEL) seed=$seed RCI=$RCI_R RCR=$RCR_R SYMPTOM=$SYMP FIX=$FIX RESOLVED=$RESOLVED tok=$TOKENS cost=\$$COST neat_hits=$NEAT_HITS"
    done
  done
  ensure_faulted "$FAULT_IMG"
done

echo; echo "======== HVO SUITE RESULTS ($OUT) ========"
column -t "$OUT"
echo; echo "---- per-arm aggregates (across all scored runs) ----"
for arm in $ARMS; do
  m="$(arm_model "$arm")"
  tot=$(awk -F'\t' -v a="$arm" '$3==a && $10!="SKIP"{n++}END{print n+0}' "$OUT")
  rci=$(awk -F'\t' -v a="$arm" '$3==a && $6=="YES"{n++}END{print n+0}' "$OUT")
  rcr=$(awk -F'\t' -v a="$arm" '$3==a && $7=="YES"{n++}END{print n+0}' "$OUT")
  res=$(awk -F'\t' -v a="$arm" '$3==a && $10=="YES"{n++}END{print n+0}' "$OUT")
  mtok=$(awk -F'\t' -v a="$arm" '$3==a && $10!="SKIP"{s+=$12;n++}END{if(n)printf "%d",s/n; else print 0}' "$OUT")
  mcost=$(awk -F'\t' -v a="$arm" '$3==a && $10!="SKIP"{s+=$13;n++}END{if(n)printf "%.3f",s/n; else print 0}' "$OUT")
  printf "  %-5s(%-6s) RCI=%s/%s  RCR=%s/%s  RESOLVED=%s/%s  ~%s tok  ~\$%s/run\n" "$arm" "$m" "$rci" "$tot" "$rcr" "$tot" "$res" "$tot" "$mtok" "$mcost"
done
echo "results: $OUT"
