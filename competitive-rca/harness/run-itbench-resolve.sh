#!/usr/bin/env bash
# run-itbench-resolve.sh — flag-fault RESOLVE leg. For each app-flag scenario, for
# each arm x model: clean -> inject the fault -> run the arm (diagnose + call fix-flag)
# -> verify the fault cleared. Sequential (mutating flag state; re-inject per arm).
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
set -a; . "$HOME/.bench-key" 2>/dev/null; . "$HOME/.bench-creds/creds.env" 2>/dev/null; set +a
H="$HOME/praxis/harness"; NS=otel-demo; CAT="$H/itbench-catalog.tsv"
OUT="${ITBRES_OUT:-$HOME/praxis/runs/itbench-resolve.tsv}"; mkdir -p "$(dirname "$OUT")"
SCENS="${ITBRES_SCENS:-$(grep -vE '^#|^scen' "$CAT" | awk -F'\t' '$5=="app-flag"{print $1}' | tr '\n' ' ')}"
ARMS="${ITBRES_ARMS:-neat code}"
MODELS="${ITBRES_MODELS:-opus sonnet}"
[ -f "$OUT" ] || echo -e "scen\tservice\tflag\tarm\tmodel\tresolved\tacted\ttokens\tcost_usd" > "$OUT"
say(){ echo "[$(date +%H:%M:%S)] $*"; }

inject(){ ( cd "$HOME/ITBench/scenarios/sre" && timeout 180 make inject-scenario-faults SCENARIO_NUMBER="$1" ) >"/tmp/itbres-inject-$1.log" 2>&1; }
cleanflags(){ bash "$HOME/bench-reset.sh" none >/dev/null 2>&1 || true; }

say "ITBench-RESOLVE START  scens=[$SCENS]  arms=[$ARMS]  models=[$MODELS]"
for SCEN in $SCENS; do
  ROW="$(grep -E "^${SCEN}	" "$CAT" | head -1)"; [ -n "$ROW" ] || continue
  IFS=$'\t' read -r _s SVC _fid FLAG _cls _re <<<"$ROW"; SVC="${SVC%\?}"
  say "===== itbench-resolve $SCEN ($SVC / $FLAG) ====="
  for ARM in $ARMS; do for M in $MODELS; do
    cleanflags; sleep 3
    say "  [$ARM/$M] inject $SCEN"; inject "$SCEN"; sleep 18   # flagd reload + neat poll fold
    rd="$HOME/praxis/divruns/itbres-$SCEN/$ARM-$M"
    NEAT_BENCH_MODEL="$M" NEAT_BENCH_MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}" ARM_RUN_DIR="$rd" \
      bash "$H/run-flagfix.sh" "$ARM" "$SCEN" "$FLAG" "$M" >"/tmp/itbres-$SCEN-$ARM-$M.log" 2>&1 || true
    ACTED="$(grep -oE 'CALLED_FIXFLAG=[A-Z]+' "$rd/acted" 2>/dev/null | cut -d= -f2)"
    RES="$(bash "$H/verify-flag.sh" "$FLAG" off 2>/dev/null | grep -oE 'RESOLVED_FLAG=[A-Z]+' | cut -d= -f2)"
    TOK="$(python3 -c "import json;print(json.load(open('$rd/usage.json')).get('total_tokens',0))" 2>/dev/null || echo 0)"
    COST="$(python3 -c "import json;print(json.load(open('$rd/usage.json')).get('cost_usd',0))" 2>/dev/null || echo 0)"
    echo -e "$SCEN\t$SVC\t$FLAG\t$ARM\t$M\t${RES:-NO}\t${ACTED:-NO}\t${TOK:-0}\t${COST:-0}" >> "$OUT"
    say "    $ARM/$M RESOLVED=${RES:-NO} acted=${ACTED:-NO} tok=${TOK:-0}"
  done; done
done
cleanflags
say "ITBench-RESOLVE COMPLETE"
awk -F'\t' 'NR>1{n[$4"|"$5]++; if($6=="YES")r[$4"|"$5]++} END{for(k in n){split(k,a,"|");printf "  %-6s %-7s RESOLVED %d/%d\n",a[1],a[2],r[k]+0,n[k]}}' "$OUT" | sort
