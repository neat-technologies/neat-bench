#!/usr/bin/env bash
# Clean re-run of the CODE arm only: source-only agent, no cluster/daemon needed.
# Syncs the correct FULL recommendation source per scenario (faulted image for
# recimage; healthy for 20/32 deployment faults), removing the stock-bak leak and
# stale-neo4j-file confounds from run1. Grades with the fixed SERVICE-line grader.
set -uo pipefail
export KUBECONFIG=$HOME/.kube/config
export PATH=$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH
H=~/praxis/harness; GT=$H/divergence-ground-truth.tsv; Q=quay.io/shengkunrz/it-bench-dev
HEALTHY_REC=ghcr.io/open-telemetry/demo:2.0.1-recommendation
RECDIR=$HOME/opentelemetry-demo/src/recommendation
OUT=$HOME/praxis/runs/code-clean-results.tsv
echo -e "scen\tstrength\trci_service\tarm\tseed\trci\trcr\tcaught\ttokens\tcost_usd" > "$OUT"
sync_src() { local tmp; tmp=$(mktemp -d); local cid; cid=$(docker create "$1" 2>/dev/null); docker cp "$cid":/usr/src/app/. "$tmp"/ >/dev/null 2>&1; docker rm "$cid" >/dev/null 2>&1; rm -f "$RECDIR"/*.py; cp "$tmp"/*.py "$RECDIR"/ 2>/dev/null; rm -rf "$tmp"; }
for SCEN in 401 405 406 407 408 409 410 413 414 415 416 20 32; do
  row=$(grep -E "^${SCEN}\b" "$GT" | grep -vE "^#" | head -1)
  IFS=$'\t' read -r _s STR DEP TGT REC PDB EP EX RCI BOOT <<<"$row"
  if [ "$DEP" = recimage ]; then sync_src "$Q:$REC"; else sync_src "$HEALTHY_REC"; fi
  echo "[$(date +%H:%M:%S)] scen $SCEN ($STR, rci=$RCI) source synced ($([ "$DEP" = recimage ] && echo "$REC" || echo healthy))"
  for seed in 1 2; do
    NEAT_BENCH_MODEL=opus NEAT_BENCH_MAX_TURNS=40 bash "$H/run-code-detect.sh" "$SCEN" "$seed" >/dev/null 2>&1 || true
    RD=$HOME/praxis/divruns/$SCEN/code$([ "$seed" = 1 ] || echo "/trial-$seed")
    read -r RCIx RCRx CGx <<<"$(bash "$H/grade-detect.sh" "$SCEN" "$RD/answer.txt" | sed "s/RCI=//;s/RCR=//;s/CAUGHT=//")"
    TOK=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('total_tokens',0))" 2>/dev/null || echo 0)
    COST=$(python3 -c "import json;print(json.load(open('$RD/arm.json')).get('cost_usd',0))" 2>/dev/null || echo 0)
    echo -e "$SCEN\t$STR\t$RCI\tcode\t$seed\t$RCIx\t$RCRx\t$CGx\t$TOK\t$COST" >> "$OUT"
    echo "    code seed=$seed -> RCI=$RCIx RCR=$RCRx CAUGHT=$CGx"
  done
done
echo "==== CLEAN CODE CATCH RATE ===="
awk -F'\t' '$4=="code"{n++; if($8=="YES")y++}END{printf "code AGENT (clean): %d/%d (%.0f%%)\n",y+0,n+0,(n?100*y/n:0)}' "$OUT"
column -t "$OUT"
echo DONE_CLEANCODE
