#!/usr/bin/env bash
# verify-flag.sh <flagKey> <committedVariant> — did the flag fault clear?
# Prints RESOLVED_FLAG=YES|NO. YES iff flagd now SERVES the committed value AND the
# storefront is healthy (home + products + cart path return 2xx).
set -uo pipefail
export PATH=$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH
export KUBECONFIG=$HOME/.kube/config
NS=otel-demo
FLAG="${1:?usage: verify-flag.sh <flagKey> <committedVariant>}"; WANT="${2:?committed variant}"
SERVED="$(node $HOME/flagd-probe.js localhost:18015 2>/dev/null | grep -oE "$FLAG: [^|]*defaultVariant=[A-Za-z0-9%]+" | grep -oE 'defaultVariant=[A-Za-z0-9%]+' | cut -d= -f2 | head -1)"
# storefront health: warm port-forward, probe home/products/cart
PF_LOG=/tmp/vf-pf.log
( kubectl -n "$NS" port-forward svc/frontend-proxy 18093:8080 >"$PF_LOG" 2>&1 & echo $! > /tmp/vf-pf.pid )
sleep 4
ok=0; tot=0
for path in "/" "/api/products" "/api/cart"; do
  tot=$((tot+1))
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost:18093$path" 2>/dev/null)"
  [ "${code:0:1}" = "2" ] && ok=$((ok+1))
done
kill "$(cat /tmp/vf-pf.pid 2>/dev/null)" 2>/dev/null || true; pkill -f "port-forward.*18093" 2>/dev/null || true
HEALTHY=NO; [ "$ok" -ge 2 ] && HEALTHY=YES
if [ "$SERVED" = "$WANT" ] && [ "$HEALTHY" = YES ]; then
  echo "RESOLVED_FLAG=YES  (served=$SERVED==$WANT, storefront $ok/$tot ok)"
else
  echo "RESOLVED_FLAG=NO  (served=$SERVED want=$WANT, storefront $ok/$tot ok, healthy=$HEALTHY)"
fi
