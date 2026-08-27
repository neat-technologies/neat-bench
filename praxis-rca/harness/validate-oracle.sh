#!/usr/bin/env bash
set -uo pipefail
export KUBECONFIG=$HOME/.kube/config
export PATH=$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH
H=~/praxis/harness; GT=$H/ground-truth.tsv; QUAY=quay.io/shengkunrz/it-bench-dev
SCENS="${1:-401 405 410 412}"
echo "SCEN MODE  GOLD_should_be_YES  FAULTED_should_be_NO  RCR_gold"
for scen in $SCENS; do
  row=$(grep -E "^${scen}\b" "$GT" | grep -vE '^#' | head -1)
  IFS=$'\t' read -r _s REC PDB PENV EP MODE RCI <<<"$row"
  FIMG="$QUAY:$REC"
  echo "[$(date +%H:%M:%S)] ===== validate $scen ($MODE) ====="
  bash $H/setup-scenario.sh "$scen" 2>&1 | grep -E "FAULT_FIRES|confirm:|ceiling|WARNING"
  CEIL=""; [ "$MODE" = LATENCY ] && CEIL=$(cat ~/praxis/seeds/$scen/lat_ceiling_ms.txt 2>/dev/null || echo 4000)
  echo "[$(date +%H:%M:%S)] verify GOLD (expect YES)"
  LAT_MAX_MS="$CEIL" bash $H/verify-scenario.sh "$scen" ~/praxis/gold/$scen.py "$FIMG" "$MODE" 2>&1 | grep -E "verify-$scen:|RESOLVED_|SYMPTOM_"
  echo "[$(date +%H:%M:%S)] verify FAULTED seed (expect NO)"
  LAT_MAX_MS="$CEIL" bash $H/verify-scenario.sh "$scen" ~/praxis/seeds/$scen/faulted/recommendation_server.py "$FIMG" "$MODE" 2>&1 | grep -E "verify-$scen:|RESOLVED_|SYMPTOM_"
  # RCR grade on the gold diff
  diff -u ~/praxis/seeds/$scen/faulted/recommendation_server.py ~/praxis/gold/$scen.py > /tmp/gold-$scen.diff 2>/dev/null
  echo "  grade.sh on gold diff: $(bash $H/grade.sh $scen /dev/null /tmp/gold-$scen.diff)"
done
echo "[$(date +%H:%M:%S)] DONE validate-oracle"
