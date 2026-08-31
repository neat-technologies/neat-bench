#!/usr/bin/env bash
# run-fullsuite.sh — the FULL-SUITE ±NEAT driver.
# ─────────────────────────────────────────────────────────────────────────────
# Arms (2, full independence): neat+HAIKU vs obscode+OPUS. The thesis: a cheap
# model reading NEAT's fused live daemon (arsenal + incident cards) matches/beats
# an expensive model with raw, UNFUSED source + Jaeger/Prometheus.
# Every scenario is boxed (fullsuite-catalog.tsv): strict-code / strict-runtime /
# both / fusion / misc, each with a metric mode (resolve | detect). We grade
# everything we've ever graded — RCI, RCR, CAUGHT (detect), RESOLVED (resolve) —
# and report per box + overall + $ cost.
#
# CONTRACT.md is binding. preflight.sh (O1-O3) gates every scored window; a breach
# VOIDS the run. Both arms read a pristine tree (O2); clean-state restand per
# scenario (O3); real live telemetry only (O1).
#
#   run-fullsuite.sh                 # whole catalog, k=3
#   FS_SCENS="401 405 32" K=5 run-fullsuite.sh
#   MODEL_neat=haiku MODEL_obscode=opus run-fullsuite.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NEAT_AUTH_TOKEN=benchops-neat-token
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAT="$HERE/fullsuite-catalog.tsv"; GT="$HERE/divergence-ground-truth.tsv"
QUAY=quay.io/shengkunrz/it-bench-dev; NS=otel-demo; PROJ=default
K="${K:-3}"
ARMS="${FS_ARMS:-obscode neat}"
PRISTINE="${FS_PRISTINE:-$HOME/otel-pristine}"
export NEAT_SRC_ROOT="$PRISTINE" CODE_SRC_ROOT="$PRISTINE" OBSCODE_SRC_ROOT="$PRISTINE"
STOCK_REC="${FS_STOCK_REC:-$HOME/praxis/seeds/healthy-recserver-bak.py}"
OUT="$HOME/praxis/runs/fullsuite-results.tsv"; mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "scen\tbox\tmode\tarm\tmodel\tseed\trci\trcr\tcaught\tresolved\ttokens\tcost_usd\tneat_hits\tobs_hits" > "$OUT"
SYMPTOM="Users report the storefront intermittently fails: product pages, recommendations, and/or ad banners error out or time out. Diagnose the single faulty service and its root cause; fix it in the recommendation source if the fault lives there."

arm_model(){ case "$1" in neat) echo "${MODEL_neat:-haiku}";; obscode) echo "${MODEL_obscode:-opus}";; *) echo opus;; esac; }
SCENS="${FS_SCENS:-$(grep -vE '^#' "$CAT" | awk -F'\t' 'NF>=3{print $1}' | tr '\n' ' ')}"

# ── baseline capture for cross-service targets (assume healthy at start) ───────
PC_STOCK="$(kubectl -n $NS get deploy/product-catalog -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
reset_cross_service(){   # revert 20 (product-catalog image) + 32 (ad scale) bleed
  kubectl -n $NS scale deploy/ad --replicas=1 >/dev/null 2>&1 || true
  [ -n "$PC_STOCK" ] && kubectl -n $NS set image deploy/product-catalog "product-catalog=$PC_STOCK" >/dev/null 2>&1 || true
  kubectl -n $NS rollout status deploy/ad --timeout=90s >/dev/null 2>&1 || true
  kubectl -n $NS rollout status deploy/product-catalog --timeout=90s >/dev/null 2>&1 || true
}

LOAD_PID=""; PF_PID=""
start_load(){ stop_load
  setsid bash -c "kubectl port-forward svc/frontend-proxy 18080:8080 -n $NS" >/tmp/fs-pf.log 2>&1 </dev/null & PF_PID=$!; sleep 4
  setsid bash -c 'while true; do
    curl -s -o /dev/null --max-time 8 http://localhost:18080/ ;
    curl -s -o /dev/null --max-time 6 http://localhost:18080/api/products ;
    curl -s -o /dev/null --max-time 22 "http://localhost:18080/api/recommendations?productIds=OLJCESPC7Z" &
    curl -s -o /dev/null --max-time 8 "http://localhost:18080/api/data?contextKeys=telescopes" ;
    sleep 2; done' >/tmp/fs-load.log 2>&1 </dev/null & LOAD_PID=$!; }
stop_load(){ [ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null; LOAD_PID=""; pkill -f 'api/recommendations' 2>/dev/null
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; PF_PID=""; pkill -f 'port-forward.*frontend-proxy' 2>/dev/null; }
trap 'stop_load' EXIT

restand(){ pkill -f 'neat watch' 2>/dev/null; sleep 3
  rm -f $HOME/opentelemetry-demo/neat-out/graph.json $HOME/opentelemetry-demo/neat-out/*.ndjson 2>/dev/null
  ( cd $HOME/opentelemetry-demo && neat init $HOME/opentelemetry-demo >/tmp/fs-init.log 2>&1 )
  NEAT_AUTH_TOKEN=benchops-neat-token NEAT_OTEL_TOKEN=benchops-neat-token HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 \
    setsid neat watch $HOME/opentelemetry-demo >$HOME/neat-watch.log 2>&1 & sleep 12
  if ! kubectl get cm otel-collector -n $NS -o jsonpath='{.data.relay}' 2>/dev/null | grep -q 'otlphttp/neat'; then
    kubectl get cm otel-collector -n $NS -o yaml > /tmp/fs-cm.yaml 2>/dev/null
    yq -i '.data.relay |= (from_yaml | .exporters."otlphttp/neat".endpoint="http://172.18.0.1:4319" | .exporters."otlphttp/neat".headers.authorization="Bearer benchops-neat-token" | .exporters."otlphttp/neat".tls.insecure=true | .service.pipelines.traces.exporters += ["otlphttp/neat"] | to_yaml)' /tmp/fs-cm.yaml 2>/dev/null
    kubectl apply -f /tmp/fs-cm.yaml >/dev/null 2>&1; kubectl rollout restart deploy/otel-collector -n $NS >/dev/null 2>&1; sleep 20; fi; }

sync_pristine_rec(){ local fseed="$HOME/praxis/seeds/$1/faulted/recommendation_server.py"; local dst="$PRISTINE/src/recommendation/recommendation_server.py"
  if [ -f "$fseed" ]; then cp "$fseed" "$dst" 2>/dev/null || true; elif [ -f "$STOCK_REC" ]; then cp "$STOCK_REC" "$dst" 2>/dev/null || true; fi; }

void_scenario(){ local scen="$1" box="$2" mode="$3" why="$4"; echo "  [fullsuite] VOID $scen ($why)"
  for arm in $ARMS; do for s in $(seq 1 "$K"); do
    echo -e "$scen\t$box\t$mode\t$arm\t$(arm_model "$arm")\t$s\tVOID\tVOID\tVOID\tVOID\t0\t0\t0\t0" >> "$OUT"; done; done; }

for SCEN in $SCENS; do
  crow="$(grep -E "^${SCEN}\b" "$CAT" | grep -vE '^#' | head -1)"; [ -n "$crow" ] || { echo "no catalog row for $SCEN"; continue; }
  IFS=$'\t' read -r _s BOX MODE RCI _note <<<"$crow"
  grow="$(grep -E "^${SCEN}\b" "$GT" | grep -vE '^#' | head -1)"
  IFS=$'\t' read -r _g STRENGTH DEPLOY TARGET REC_TAG PDB_TAG NEO4J_EP EXTRA_ENV _rci BOOT <<<"$grow"
  echo; echo "[$(date +%H:%M:%S)] ########## $SCEN  box=$BOX mode=$MODE target=$RCI ##########"

  reset_cross_service
  if ! bash "$HERE/setup-divergence.sh" "$SCEN" > "$HOME/praxis/runs/fs-setup-$SCEN.log" 2>&1; then
    grep -E "FAULT_FIRES|confirm" "$HOME/praxis/runs/fs-setup-$SCEN.log" | sed 's/^/    /'
    void_scenario "$SCEN" "$BOX" "$MODE" "fault did not confirm"; continue; fi
  grep -E "FAULT_FIRES|confirm" "$HOME/praxis/runs/fs-setup-$SCEN.log" | sed 's/^/    /'
  # ADAPTIVE drain (O3): wait until the setup confirm-load's error spans have all
  # reached the daemon (its incident count for the target stops growing) BEFORE we
  # restand — so restand kills a daemon whose collector queue is drained and the new
  # daemon starts truly clean. A fixed sleep under-drains heavy-error faults (401's
  # 54 AttributeErrors bled past a 20s wait and voided the scenario).
  echo "  adaptive drain: waiting for confirm-load spans to finish arriving at the daemon"
  _prev=-1; _stable=0; _t=0
  while [ $_t -lt 96 ]; do
    _cnt=$(neat incidents "service:$RCI" --project "$PROJ" 2>/dev/null | grep -oE '[0-9]+ recorded incident' | grep -oE '^[0-9]+' | head -1); _cnt=${_cnt:-0}
    if [ "$_cnt" = "$_prev" ]; then _stable=$((_stable+1)); else _stable=0; fi
    [ "$_stable" -ge 2 ] && break
    _prev="$_cnt"; sleep 6; _t=$((_t+6))
  done
  echo "  drained: target incident count stable at ${_prev} after ${_t}s"
  echo "[$(date +%H:%M:%S)] restand (clear incidents, fresh graph)"; restand
  sync_pristine_rec "$SCEN"

  # ── preflight gate (O1-O3). image arg only for image-based faults. ───────────
  PF_IMG=(); case "$DEPLOY" in recimage|setimage) PF_IMG=(--image "$REC_TAG");; esac
  if ! bash "$HERE/preflight.sh" --target "$RCI" "${PF_IMG[@]}" --pristine "$PRISTINE" --arm "$(echo $ARMS | awk '{print $1}')"; then
    void_scenario "$SCEN" "$BOX" "$MODE" "preflight breach"; continue; fi

  start_load; echo "  load on — warming OBSERVED 80s"; sleep 80
  ARMS_REV="$(echo $ARMS | awk '{for(i=NF;i>=1;i--) printf "%s ",$i}')"
  for seed in $(seq 1 "$K"); do
    if [ $((seed % 2)) -eq 1 ]; then order="$ARMS"; else order="$ARMS_REV"; fi
    for arm in $order; do
      MODEL="$(arm_model "$arm")"
      echo "[$(date +%H:%M:%S)] ---- $SCEN arm=$arm($MODEL) mode=$MODE seed=$seed ----"
      if [ "$MODE" = resolve ]; then
        RD="$HOME/praxis/runs/$SCEN/$arm$([ "$seed" = 1 ] || echo "/trial-$seed")"
        RUNNER="$HERE/run-$arm.sh"; [ "$arm" = obscode ] && RUNNER="$HERE/obscode/run-obscode.sh"
      else
        RD="$HOME/praxis/divruns/$SCEN/$arm$([ "$seed" = 1 ] || echo "/trial-$seed")"
        RUNNER="$HERE/run-$arm-detect.sh"; [ "$arm" = obscode ] && RUNNER="$HERE/obscode/run-obscode-detect.sh"
      fi
      NEAT_BENCH_MODEL="$MODEL" NEAT_BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}" \
        bash "$RUNNER" "$SCEN" "$seed" "$SYMPTOM" >/dev/null 2>&1 || echo "    run-$arm nonzero (continuing)"
      # ── grade ────────────────────────────────────────────────────────────────
      RCI_R=NO; RCR_R=NO; CAUGHT=-; RESOLVED=-
      if [ "$MODE" = resolve ]; then
        read -r RCI_R RCR_R <<<"$(bash "$HERE/grade.sh" "$SCEN" "$RD/answer.txt" "$RD/patch.diff" | sed 's/RCI=//;s/RCR=//')"
        EDITED=$(python3 -c "import json;print(json.load(open('$RD/arm.json'))['edited_recommendation'])" 2>/dev/null || echo false)
        RESOLVED=NO; FIX=NO
        if [ "$EDITED" = True ] || [ "$EDITED" = true ]; then
          MODEO=$(grep -E "^${SCEN}\b" "$HERE/ground-truth.tsv" 2>/dev/null | grep -vE '^#' | head -1 | cut -f6)
          FAULT_IMG="$QUAY:$REC_TAG"
          LAT="$(cat "$HOME/praxis/seeds/$SCEN/lat_ceiling_ms.txt" 2>/dev/null || echo 4000)"
          LAT_MAX_MS="$LAT" bash "$HERE/verify-scenario.sh" "$SCEN" "$RD/src/recommendation_server.py" "$FAULT_IMG" "${MODEO:-HANG}" > "$RD/verify.log" 2>&1 || true
          grep -q "RESOLVED_${SCEN}=YES" "$RD/verify.log" && FIX=YES
        fi
        # CONTRACT rule 4: RESOLVED = correct localization (RCR) AND verified recovery.
        # Oracle-recover alone credits a lazy amputation (clear the symptom, wrong locus).
        { [ "$RCR_R" = YES ] && [ "$FIX" = YES ]; } && RESOLVED=YES
      else
        read -r RCI_R RCR_R CAUGHT <<<"$(bash "$HERE/grade-detect.sh" "$SCEN" "$RD/answer.txt" | sed 's/RCI=//;s/RCR=//;s/CAUGHT=//')"
      fi
      TOK=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('total_tokens',0))" 2>/dev/null || echo 0)
      COST=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('cost_usd',0))" 2>/dev/null || echo 0)
      NH=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('neat_tool_hits',0))" 2>/dev/null || echo 0)
      OH=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('obs_helper_hits',0))" 2>/dev/null || echo 0)
      echo -e "$SCEN\t$BOX\t$MODE\t$arm\t$MODEL\t$seed\t$RCI_R\t$RCR_R\t$CAUGHT\t$RESOLVED\t$TOK\t$COST\t$NH\t$OH" >> "$OUT"
      echo "    $arm($MODEL) seed=$seed RCI=$RCI_R RCR=$RCR_R CAUGHT=$CAUGHT RESOLVED=$RESOLVED tok=$TOK cost=\$$COST"
    done
  done
  stop_load; sleep 2
done

echo; echo "======== FULL-SUITE RESULTS ($OUT) ========"; column -t "$OUT" 2>/dev/null | tail -60
echo; echo "---- per box × arm (CAUGHT for detect, RESOLVED for resolve) ----"
for BOX in strict-code strict-runtime both fusion misc; do
  for arm in $ARMS; do
    awk -F'\t' -v b="$BOX" -v a="$arm" '$2==b && $4==a && $7!="VOID"{n++; if($3=="detect"&&$9=="YES")y++; if($3=="resolve"&&$10=="YES")y++}END{if(n)printf "  %-14s %-8s %d/%d (%.0f%%)\n", b, a, y+0, n, 100*y/n}' "$OUT"
  done
done
echo; echo "---- overall × arm ----"
for arm in $ARMS; do
  awk -F'\t' -v a="$arm" '$4==a && $7!="VOID"{n++; if(($3=="detect"&&$9=="YES")||($3=="resolve"&&$10=="YES"))y++; s+=$12; c++}END{if(n)printf "  %-8s solved %d/%d (%.0f%%)  ~$%.3f/run\n", a, y+0, n, 100*y/n, (c?s/c:0)}' "$OUT"
done
echo "results: $OUT"
