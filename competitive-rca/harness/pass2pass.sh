#!/usr/bin/env bash
# pass2pass.sh — the REGRESSION leg of the robust grade (ROBUST = RESOLVED ∧ 0 regressions).
# Captures the PASS_TO_PASS baseline in a known-good state, then (after an arm's fix is
# deployed) re-checks it; any green-in-baseline → red-now is a regression.
#   pass2pass.sh capture <baseline.json> [target-svc]   # run in a CLEAN (pre-fault) state
#   pass2pass.sh check   <baseline.json> [target-svc]   # run AFTER the fix is applied
# Prints (check): REGRESSIONS=<n>  REGRESSED=<csv|none>  NOW=<json>
set -uo pipefail
export PATH=$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH
export KUBECONFIG=$HOME/.kube/config
NS=otel-demo
MODE="${1:?capture|check}"; BASE="${2:?baseline.json}"; TARGET="${3:-}"

PFPID=""; cleanup(){ [ -n "$PFPID" ] && kill "$PFPID" 2>/dev/null; }
trap cleanup EXIT
pkill -f "port-forward svc/frontend-proxy 18090" 2>/dev/null; sleep 1
setsid bash -c "kubectl -n $NS port-forward svc/frontend-proxy 18090:8080" >/tmp/p2p-pf.log 2>&1 & PFPID=$!; sleep 4
B="http://localhost:18090"
code(){ curl -s -o /dev/null -w "%{http_code}" --max-time 12 "$1" 2>/dev/null || echo 000; }

# ── PASS_TO_PASS probes: storefront behaviours that must survive any correct fix ──
HOME_C=$(code "$B/")
PROD_C=$(code "$B/api/products")
RECO=$(curl -s --max-time 22 "$B/api/recommendations?productIds=OLJCESPC7Z&sessionId=p2p&currencyCode=USD" 2>/dev/null)
RECO_C=$(echo "$RECO" | grep -qE 'productIds|product_ids|"id"' && echo 200 || echo FAIL)
DATA_C=$(code "$B/api/data?contextKeys=telescopes")
# per-service deployment health (each is its own PASS_TO_PASS item, target excluded)
DEPJSON=$(kubectl -n $NS get deploy -o json 2>/dev/null | T="$TARGET" python3 -c "import sys,json,os
d=json.load(sys.stdin); t=os.environ.get('T','')
out={}
for x in d['items']:
    n=x['metadata']['name']
    if n==t: continue
    ready=(x.get('status',{}).get('readyReplicas',0) or 0); want=(x['spec'].get('replicas',1) or 1)
    out['dep_'+n]='OK' if ready>=want else 'BAD'
print(json.dumps(out))")

JSON=$(python3 -c "import json,sys
d=dict(x.split('=',1) for x in sys.argv[1:-1]); d.update(json.loads(sys.argv[-1])); print(json.dumps(d))" \
  "home=$HOME_C" "products=$PROD_C" "recommendations=$RECO_C" "data=$DATA_C" "$DEPJSON")

if [ "$MODE" = capture ]; then echo "$JSON" > "$BASE"; echo "CAPTURED $JSON"; exit 0; fi

python3 - "$BASE" "$JSON" <<'PY'
import sys,json
base=json.load(open(sys.argv[1])); now=json.loads(sys.argv[2])
green=lambda v: str(v) in ("200","OK")
regr=[k for k in base if green(base[k]) and not green(now.get(k,""))]
print("REGRESSIONS=%d"%len(regr))
print("REGRESSED=%s"%(",".join(regr) if regr else "none"))
print("NOW=%s"%json.dumps(now))
PY
