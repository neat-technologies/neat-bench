#!/usr/bin/env bash
# run-hvo-detect.sh — "Haiku+NEAT vs Opus-alone" DETECTION driver (diagnose only).
# ─────────────────────────────────────────────────────────────────────────────
# The QUESTION the user actually wants answered: on RUNTIME-DECISIVE incidents —
# the ones whose root cause is NOT in any source file (wrong DB host, bad image,
# a service scaled to zero) — can a CHEAP model with NEAT's fused graph DIAGNOSE
# what an EXPENSIVE model reading source alone is structurally BLIND to? Arms:
#   neat = Claude HAIKU + NEAT's full fused-graph arsenal (run-neat-detect.sh)
#   code = Claude OPUS   + raw source only, no runtime, no graph (run-code-detect.sh)
# Metric = CAUGHT (right faulty service AND right fault nature), model-free grader.
# NO fix, NO verify — diagnosis is the deliverable (config/deploy faults have no
# source edit). Also records whether raw `neat divergences` fires (0.9.7 #1100).
#
#   run-hvo-detect.sh                      # runtime-weighted default set, k=2
#   HVO_SCENS="413 414 20 32" K=3 run-hvo-detect.sh
#   MODEL_neat=haiku MODEL_code=opus run-hvo-detect.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NEAT_AUTH_TOKEN=benchops-neat-token
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GT="$HERE/divergence-ground-truth.tsv"; NS=otel-demo; PROJ=default
# runtime-weighted: 413/414 wrong-host + 20 bad-image + 32 scaled-to-0 are the
# code-BLIND headline; 405/410 neo4j runtime middle-ground; 401 static control.
SCENS="${HVO_SCENS:-401 405 410 413 414 20 32}"
K="${K:-2}"
ARMS="${HVO_ARMS:-code neat}"

# ── ISOLATION: both arms read a PRISTINE source tree the NEAT daemon never writes
#    into (the daemon keeps its 2.6MB neat-out/graph.json + neat.patch in
#    ~/opentelemetry-demo; a "source-only" arm must never be able to read the fused
#    graph off disk). The daemon still runs on ~/opentelemetry-demo. Per scenario we
#    sync pristine's recommendation_server.py to the faulted-seed-or-stock so the disk
#    source matches deployed reality (faulted for source-visible scenarios; stock for
#    runtime-decisive ones, where the code arm is correctly blind). ─────────────────
PRISTINE="${HVO_PRISTINE:-$HOME/otel-pristine}"
export NEAT_SRC_ROOT="$PRISTINE" CODE_SRC_ROOT="$PRISTINE"
STOCK_REC="${HVO_STOCK_REC:-$HOME/praxis/seeds/healthy-recserver-bak.py}"
sync_pristine_rec () {  # $1 = scenario
  local fseed="$HOME/praxis/seeds/$1/faulted/recommendation_server.py"
  local dst="$PRISTINE/src/recommendation/recommendation_server.py"
  if   [ -f "$fseed" ];     then cp "$fseed" "$dst" 2>/dev/null || true
  elif [ -f "$STOCK_REC" ]; then cp "$STOCK_REC" "$dst" 2>/dev/null || true
  fi
}
OUT="$HOME/praxis/runs/hvo-detect-results.tsv"; mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "scen\tstrength\trci_service\tarm\tmodel\tseed\trci\trcr\tcaught\ttokens\tcost_usd\tneat_hits" > "$OUT"

arm_model () {
  case "$1" in
    neat) echo "${MODEL_neat:-haiku}" ;;
    code) echo "${MODEL_code:-opus}"  ;;
    *)    echo "-" ;;
  esac
}

LOAD_PID=""; PF_PID=""
start_load () {
  stop_load
  setsid bash -c "kubectl port-forward svc/frontend-proxy 18080:8080 -n $NS" >/tmp/hvod-pf.log 2>&1 </dev/null &
  PF_PID=$!; sleep 4
  setsid bash -c 'while true; do
    curl -s -o /dev/null --max-time 8 http://localhost:18080/ ;
    curl -s -o /dev/null --max-time 6 http://localhost:18080/api/products ;
    curl -s -o /dev/null --max-time 16 "http://localhost:18080/api/recommendations?productIds=OLJCESPC7Z" &
    curl -s -o /dev/null --max-time 6 "http://localhost:18080/api/data?contextKeys=telescopes" ;
    sleep 2; done' >/tmp/hvod-load.log 2>&1 </dev/null &
  LOAD_PID=$!
}
stop_load () {
  [ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null; LOAD_PID=""
  pkill -f 'api/recommendations' 2>/dev/null
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; PF_PID=""
  pkill -f "port-forward.*frontend-proxy" 2>/dev/null
}
trap 'stop_load' EXIT

restand_light () {
  pkill -f 'neat watch' 2>/dev/null; sleep 3
  rm -f $HOME/opentelemetry-demo/neat-out/graph.json $HOME/opentelemetry-demo/neat-out/*.ndjson 2>/dev/null
  ( cd $HOME/opentelemetry-demo && neat init $HOME/opentelemetry-demo >/dev/null 2>&1 )
  NEAT_AUTH_TOKEN=benchops-neat-token NEAT_OTEL_TOKEN=benchops-neat-token HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 \
    setsid neat watch $HOME/opentelemetry-demo >$HOME/neat-watch.log 2>&1 &
  sleep 10
  if ! kubectl get cm otel-collector -n $NS -o jsonpath='{.data.relay}' 2>/dev/null | grep -q 'otlphttp/neat'; then
    kubectl get cm otel-collector -n $NS -o yaml > /tmp/cm-hvod.yaml 2>/dev/null
    yq -i '.data.relay |= (from_yaml | .exporters."otlphttp/neat".endpoint="http://172.18.0.1:4319" | .exporters."otlphttp/neat".headers.authorization="Bearer benchops-neat-token" | .exporters."otlphttp/neat".tls.insecure=true | .service.pipelines.traces.exporters += ["otlphttp/neat"] | to_yaml)' /tmp/cm-hvod.yaml 2>/dev/null
    kubectl apply -f /tmp/cm-hvod.yaml >/dev/null 2>&1; kubectl rollout restart deploy/otel-collector -n $NS >/dev/null 2>&1; sleep 20
  fi
}

grade_row () { bash "$HERE/grade-detect.sh" "$1" "$4" | sed 's/RCI=//;s/RCR=//;s/CAUGHT=//'; }

for SCEN in $SCENS; do
  row="$(grep -E "^${SCEN}\b" "$GT" | grep -vE '^#' | head -1)"
  IFS=$'\t' read -r _s STRENGTH DEPLOY TARGET REC_TAG PDB_TAG NEO4J_EP EXTRA_ENV RCI BOOT <<<"$row"
  echo; echo "[$(date +%H:%M:%S)] ############ SCENARIO $SCEN ($STRENGTH, rci=$RCI, boot=$BOOT) ############"

  if ! bash "$HERE/setup-divergence.sh" "$SCEN" > "$HOME/praxis/runs/setup-div-$SCEN.log" 2>&1; then
    echo "  setup did NOT confirm the fault — recording SKIP."
    grep -E "FAULT_FIRES|confirm:" "$HOME/praxis/runs/setup-div-$SCEN.log" | sed 's/^/    /'
    echo -e "$SCEN\t$STRENGTH\t$RCI\tdivergences\t-\t0\tSKIP\tSKIP\tSKIP\t0\t0\t0" >> "$OUT"
    for arm in $ARMS; do for seed in $(seq 1 "$K"); do
      echo -e "$SCEN\t$STRENGTH\t$RCI\t$arm\t$(arm_model "$arm")\t$seed\tSKIP\tSKIP\tSKIP\t0\t0\t0" >> "$OUT"; done; done
    continue
  fi
  grep -E "FAULT_FIRES|confirm:" "$HOME/praxis/runs/setup-div-$SCEN.log" | sed 's/^/    /'
  sync_pristine_rec "$SCEN"   # match pristine disk source to this scenario's deployed reality

  echo "[$(date +%H:%M:%S)] restanding neat daemon (fresh graph)"; restand_light
  start_load; echo "  load on — populating OBSERVED 80s"; sleep 80

  # HEADLINE raw layer: does `neat divergences` (0.9.7 #1100) fire on this fault?
  DD="$HOME/praxis/divruns/$SCEN"; mkdir -p "$DD"
  neat divergences --project $PROJ                > "$DD/divergences.txt" 2>&1 || true
  neat root-cause "service:$RCI" --project $PROJ   > "$DD/rootcause.txt"   2>&1 || true
  neat incidents "service:$RCI" --project $PROJ    > "$DD/incidents.txt"   2>&1 || true
  neat stale-edges --project $PROJ                 > "$DD/stale.txt"       2>&1 || true
  DIV_FIRED=$(bash "$HERE/grade-div-fired.sh" "$SCEN" "$DD/divergences.txt" | sed 's/FIRED=//')
  cat "$DD/divergences.txt" "$DD/rootcause.txt" "$DD/incidents.txt" "$DD/stale.txt" > "$DD/allqueries.txt" 2>/dev/null
  read -r q_rci q_rcr QUERY_FIRED <<<"$(grade_row "$SCEN" neatquery 0 "$DD/allqueries.txt")"
  echo "  neat divergences -> FIRED=$DIV_FIRED   |   any-neat-query -> FIRED=$QUERY_FIRED"
  head -4 "$DD/divergences.txt" | sed 's/^/      div| /'
  echo -e "$SCEN\t$STRENGTH\t$RCI\tdivergences\t-\t0\t-\t-\t$DIV_FIRED\t0\t0\t0" >> "$OUT"
  echo -e "$SCEN\t$STRENGTH\t$RCI\tneatquery\t-\t0\t$q_rci\t$q_rcr\t$QUERY_FIRED\t0\t0\t0" >> "$OUT"

  ARMS_REV="$(echo $ARMS | awk '{for(i=NF;i>=1;i--) printf "%s ", $i}')"
  for seed in $(seq 1 "$K"); do
    if [ $(( seed % 2 )) -eq 1 ]; then order="$ARMS"; else order="$ARMS_REV"; fi
    for arm in $order; do
      MODEL="$(arm_model "$arm")"
      RUNNER="$HERE/run-$arm-detect.sh"
      NEAT_BENCH_MODEL="$MODEL" NEAT_BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}" \
        bash "$RUNNER" "$SCEN" "$seed" >/dev/null 2>&1 || echo "    run-$arm-detect nonzero (continuing)"
      RD="$HOME/praxis/divruns/$SCEN/$arm$([ "$seed" = 1 ] || echo "/trial-$seed")"
      read -r RCIx RCRx CAUGHTx <<<"$(grade_row "$SCEN" "$arm" "$seed" "$RD/answer.txt")"
      TOK=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('total_tokens',0))" 2>/dev/null || echo 0)
      COST=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('cost_usd',0))" 2>/dev/null || echo 0)
      NH=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('neat_tool_hits',0))" 2>/dev/null || echo 0)
      echo -e "$SCEN\t$STRENGTH\t$RCI\t$arm\t$MODEL\t$seed\t$RCIx\t$RCRx\t$CAUGHTx\t$TOK\t$COST\t$NH" >> "$OUT"
      echo "    $arm($MODEL) seed=$seed -> RCI=$RCIx RCR=$RCRx CAUGHT=$CAUGHTx tok=$TOK cost=\$$COST neat_hits=$NH"
    done
  done
  stop_load; sleep 2
done

echo; echo "======== HVO DETECTION RESULTS ========"
column -t "$OUT"
echo; echo "---- per-scenario ----"
printf "%-5s %-7s %-15s %-10s %-11s %-11s\n" scen strength rci div_fired neat_caught code_caught
for SCEN in $SCENS; do
  st=$(awk -F'\t' -v s="$SCEN" '$1==s{print $2; exit}' "$OUT")
  rci=$(awk -F'\t' -v s="$SCEN" '$1==s{print $3; exit}' "$OUT")
  df=$(awk -F'\t' -v s="$SCEN" '$1==s && $4=="divergences"{print $9; exit}' "$OUT")
  nc=$(awk -F'\t' -v s="$SCEN" '$1==s && $4=="neat"{if($9=="YES")c++; n++}END{printf "%d/%d",c+0,n+0}' "$OUT")
  cc=$(awk -F'\t' -v s="$SCEN" '$1==s && $4=="code"{if($9=="YES")c++; n++}END{printf "%d/%d",c+0,n+0}' "$OUT")
  printf "%-5s %-7s %-15s %-10s %-11s %-11s\n" "$SCEN" "$st" "$rci" "$df" "$nc" "$cc"
done
echo; echo "---- CATCH RATES + COST ----"
awk -F'\t' '$4=="divergences" && $9!="SKIP"{n++; if($9=="YES")y++}END{printf "  neat DIVERGENCES fired:   %d/%d (%.0f%%)\n", y+0,n+0,(n?100*y/n:0)}' "$OUT"
for arm in $ARMS; do
  m="$(arm_model "$arm")"
  awk -F'\t' -v a="$arm" -v m="$m" '$4==a && $9!="SKIP"{n++; if($9=="YES")y++; s+=$11; ct++}END{printf "  %-4s(%-6s) AGENT caught: %d/%d (%.0f%%)  ~$%.3f/run\n", a, m, y+0,n+0,(n?100*y/n:0), (ct?s/ct:0)}' "$OUT"
done
echo "results: $OUT"
