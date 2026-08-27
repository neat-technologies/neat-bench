#!/usr/bin/env bash
# run-divergence-suite.sh — DETECTION driver for the divergence bench.
# ─────────────────────────────────────────────────────────────────────────────
# Per scenario (only one active at a time):
#   setup-divergence -> restand the neat daemon fresh (clean incident store) ->
#   drive load to populate OBSERVED -> run `neat divergences` RAW (headline: does it
#   surface the fault?) -> neat-detect agent x2 + code-detect agent x2 -> grade each
#   (RCI service + RCR nature from the diagnosis text). No fix, no verify.
# Writes ~/praxis/runs/divergence-results.tsv (one row per divergences-query + per
# agent run) and prints the per-scenario table + the three catch RATES.
#
#   run-divergence-suite.sh                      # default: all 13 scenarios, k=2
#   SUITE_SCENS="401 32" K=1 run-divergence-suite.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export NEAT_AUTH_TOKEN=benchops-neat-token
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GT="$HERE/divergence-ground-truth.tsv"; NS=otel-demo; PROJ=default
SCENS="${SUITE_SCENS:-401 405 406 407 408 409 410 413 414 415 416 20 32}"
K="${K:-2}"
OUT="$HOME/praxis/runs/divergence-results.tsv"; mkdir -p "$(dirname "$OUT")"
[ -f "$OUT" ] || echo -e "scen\tstrength\trci_service\tarm\tseed\trci\trcr\tcaught\ttokens\tcost_usd\tneat_hits" > "$OUT"

# ── load: broad storefront traffic so OBSERVED covers rec / product-catalog / ad ─
LOAD_PID=""; PF_PID=""
start_load () {
  stop_load
  setsid bash -c "kubectl port-forward svc/frontend-proxy 18080:8080 -n $NS" >/tmp/div-pf.log 2>&1 </dev/null &
  PF_PID=$!; sleep 4
  setsid bash -c 'while true; do
    curl -s -o /dev/null --max-time 8 http://localhost:18080/ ;
    curl -s -o /dev/null --max-time 6 http://localhost:18080/api/products ;
    curl -s -o /dev/null --max-time 16 "http://localhost:18080/api/recommendations?productIds=OLJCESPC7Z" &
    curl -s -o /dev/null --max-time 6 "http://localhost:18080/api/data?contextKeys=telescopes" ;
    sleep 2; done' >/tmp/div-load.log 2>&1 </dev/null &
  LOAD_PID=$!
}
stop_load () {
  [ -n "$LOAD_PID" ] && kill "$LOAD_PID" 2>/dev/null; LOAD_PID=""
  pkill -f 'api/recommendations' 2>/dev/null
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; PF_PID=""
  pkill -f "port-forward.*frontend-proxy" 2>/dev/null
}
trap 'stop_load' EXIT

# ── light restand: fresh EXTRACTED (current faulted source) + fresh OBSERVED, no
#    hard wait-for-all-pods (bootstrap/20 faults keep a pod un-Ready by design). The
#    collector already forwards to 172.18.0.1:4319 across restarts (patched once). ──
restand_light () {
  pkill -f 'neat watch' 2>/dev/null; sleep 3
  rm -f $HOME/opentelemetry-demo/neat-out/graph.json $HOME/opentelemetry-demo/neat-out/*.ndjson 2>/dev/null
  ( cd $HOME/opentelemetry-demo && neat init $HOME/opentelemetry-demo >/dev/null 2>&1 )
  NEAT_AUTH_TOKEN=benchops-neat-token NEAT_OTEL_TOKEN=benchops-neat-token HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 \
    setsid neat watch $HOME/opentelemetry-demo >$HOME/neat-watch.log 2>&1 &
  sleep 10
  # safety: ensure the collector still exports to neat; if missing, patch+restart once
  if ! kubectl get cm otel-collector -n $NS -o jsonpath='{.data.relay}' 2>/dev/null | grep -q 'otlphttp/neat'; then
    kubectl get cm otel-collector -n $NS -o yaml > /tmp/cm-div.yaml 2>/dev/null
    yq -i '.data.relay |= (from_yaml | .exporters."otlphttp/neat".endpoint="http://172.18.0.1:4319" | .exporters."otlphttp/neat".headers.authorization="Bearer benchops-neat-token" | .exporters."otlphttp/neat".tls.insecure=true | .service.pipelines.traces.exporters += ["otlphttp/neat"] | to_yaml)' /tmp/cm-div.yaml 2>/dev/null
    kubectl apply -f /tmp/cm-div.yaml >/dev/null 2>&1; kubectl rollout restart deploy/otel-collector -n $NS >/dev/null 2>&1; sleep 20
  fi
}

grade_row () {  # $1=scen $2=arm $3=seed $4=answer_file  -> echoes "RCI RCR CAUGHT"
  bash "$HERE/grade-detect.sh" "$1" "$4" | sed 's/RCI=//;s/RCR=//;s/CAUGHT=//'
}

for SCEN in $SCENS; do
  row="$(grep -E "^${SCEN}\b" "$GT" | grep -vE '^#' | head -1)"
  IFS=$'\t' read -r _s STRENGTH DEPLOY TARGET REC_TAG PDB_TAG NEO4J_EP EXTRA_ENV RCI BOOT <<<"$row"
  echo; echo "[$(date +%H:%M:%S)] ############ SCENARIO $SCEN ($STRENGTH, rci=$RCI, boot=$BOOT) ############"

  if ! bash "$HERE/setup-divergence.sh" "$SCEN" > "$HOME/praxis/runs/setup-div-$SCEN.log" 2>&1; then
    echo "  setup did NOT confirm the fault — recording SKIP."
    grep -E "FAULT_FIRES|confirm:" "$HOME/praxis/runs/setup-div-$SCEN.log" | sed 's/^/    /'
    echo -e "$SCEN\t$STRENGTH\t$RCI\tdivergences\t0\tSKIP\tSKIP\tSKIP\t0\t0\t0" >> "$OUT"
    for arm in neat code; do for seed in $(seq 1 "$K"); do
      echo -e "$SCEN\t$STRENGTH\t$RCI\t$arm\t$seed\tSKIP\tSKIP\tSKIP\t0\t0\t0" >> "$OUT"; done; done
    continue
  fi
  grep -E "FAULT_FIRES|confirm:" "$HOME/praxis/runs/setup-div-$SCEN.log" | sed 's/^/    /'

  echo "[$(date +%H:%M:%S)] restanding neat daemon (fresh graph)"; restand_light
  start_load; echo "  load on — populating OBSERVED 80s"; sleep 80

  # ── HEADLINE: raw `neat divergences` + the rest of the raw query layer ────────
  DD="$HOME/praxis/divruns/$SCEN"; mkdir -p "$DD"
  neat divergences --project $PROJ                > "$DD/divergences.txt" 2>&1 || true
  neat root-cause "service:$RCI" --project $PROJ   > "$DD/rootcause.txt"   2>&1 || true
  neat incidents "service:$RCI" --project $PROJ    > "$DD/incidents.txt"   2>&1 || true
  neat stale-edges --project $PROJ                 > "$DD/stale.txt"       2>&1 || true
  # DIV_FIRED: strict — does `divergences` specifically surface the fault (not coverage noise)
  DIV_FIRED=$(bash "$HERE/grade-div-fired.sh" "$SCEN" "$DD/divergences.txt" | sed 's/FIRED=//')
  # QUERY_FIRED: does ANY raw neat query (divergences/root-cause/incidents/stale) name the fault
  cat "$DD/divergences.txt" "$DD/rootcause.txt" "$DD/incidents.txt" "$DD/stale.txt" > "$DD/allqueries.txt" 2>/dev/null
  read -r q_rci q_rcr QUERY_FIRED <<<"$(grade_row "$SCEN" neatquery 0 "$DD/allqueries.txt")"
  echo "  neat divergences -> FIRED=$DIV_FIRED   |   any-neat-query -> FIRED=$QUERY_FIRED"
  head -4 "$DD/divergences.txt" | sed 's/^/      div| /'
  head -2 "$DD/rootcause.txt"   | sed 's/^/      rc | /'
  echo -e "$SCEN\t$STRENGTH\t$RCI\tdivergences\t0\t-\t-\t$DIV_FIRED\t0\t0\t0" >> "$OUT"
  echo -e "$SCEN\t$STRENGTH\t$RCI\tneatquery\t0\t$q_rci\t$q_rcr\t$QUERY_FIRED\t0\t0\t0" >> "$OUT"

  # ── agents: neat-detect + code-detect, k seeds ───────────────────────────────
  for seed in $(seq 1 "$K"); do
    for arm in neat code; do
      RUNNER="$HERE/run-$arm-detect.sh"
      NEAT_BENCH_MODEL=opus NEAT_BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-25}" \
        bash "$RUNNER" "$SCEN" "$seed" >/dev/null 2>&1 || echo "    run-$arm-detect nonzero (continuing)"
      RD="$HOME/praxis/divruns/$SCEN/$arm$([ "$seed" = 1 ] || echo "/trial-$seed")"
      read -r RCIx RCRx CAUGHTx <<<"$(grade_row "$SCEN" "$arm" "$seed" "$RD/answer.txt")"
      TOK=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('total_tokens',0))" 2>/dev/null || echo 0)
      COST=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('cost_usd',0))" 2>/dev/null || echo 0)
      NH=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('neat_tool_hits',0))" 2>/dev/null || echo 0)
      echo -e "$SCEN\t$STRENGTH\t$RCI\t$arm\t$seed\t$RCIx\t$RCRx\t$CAUGHTx\t$TOK\t$COST\t$NH" >> "$OUT"
      echo "    $arm seed=$seed -> RCI=$RCIx RCR=$RCRx CAUGHT=$CAUGHTx tok=$TOK"
    done
  done
  stop_load; sleep 2
done

echo; echo "======== DIVERGENCE (DETECTION) RESULTS ========"
column -t "$OUT"
echo; echo "---- per-scenario table ----"
printf "%-5s %-7s %-15s %-9s %-9s %-11s %-11s\n" scen strength rci div_fired anyq_fired neat_caught code_caught
for SCEN in $SCENS; do
  st=$(awk -F'\t' -v s="$SCEN" '$1==s{print $2; exit}' "$OUT")
  rci=$(awk -F'\t' -v s="$SCEN" '$1==s{print $3; exit}' "$OUT")
  df=$(awk -F'\t' -v s="$SCEN" '$1==s && $4=="divergences"{print $8; exit}' "$OUT")
  qf=$(awk -F'\t' -v s="$SCEN" '$1==s && $4=="neatquery"{print $8; exit}' "$OUT")
  nc=$(awk -F'\t' -v s="$SCEN" '$1==s && $4=="neat"{if($8=="YES")c++; n++}END{printf "%d/%d",c+0,n+0}' "$OUT")
  cc=$(awk -F'\t' -v s="$SCEN" '$1==s && $4=="code"{if($8=="YES")c++; n++}END{printf "%d/%d",c+0,n+0}' "$OUT")
  printf "%-5s %-7s %-15s %-9s %-9s %-11s %-11s\n" "$SCEN" "$st" "$rci" "$df" "$qf" "$nc" "$cc"
done
echo; echo "---- CATCH RATES ----"
awk -F'\t' '$4=="divergences" && $8!="SKIP"{n++; if($8=="YES")y++}END{printf "  neat DIVERGENCES fired:  %d/%d (%.0f%%)\n", y+0,n+0,(n?100*y/n:0)}' "$OUT"
awk -F'\t' '$4=="neatquery" && $8!="SKIP"{n++; if($8=="YES")y++}END{printf "  any-neat-query surfaced: %d/%d (%.0f%%)\n", y+0,n+0,(n?100*y/n:0)}' "$OUT"
for arm in neat code; do
  awk -F'\t' -v a="$arm" '$4==a && $8!="SKIP"{n++; if($8=="YES")y++}END{printf "  %-4s AGENT caught:       %d/%d (%.0f%%)\n", a, y+0,n+0,(n?100*y/n:0)}' "$OUT"
done
echo "results: $OUT"
