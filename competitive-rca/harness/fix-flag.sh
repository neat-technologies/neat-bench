#!/usr/bin/env bash
# fix-flag.sh <flagKey> <variant> — remediate a feature-flag fault: set the flag's
# defaultVariant in the flagd ConfigMap back to <variant> (its committed value) and
# reload flagd. The ACT tool a resolve arm calls after diagnosing a flag fault.
#   fix-flag.sh cartFailure off
set -uo pipefail
export PATH=$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH
export KUBECONFIG=$HOME/.kube/config
NS=otel-demo
FLAG="${1:?usage: fix-flag.sh <flagKey> <variant>}"; VARIANT="${2:?variant}"
CUR="$(kubectl -n "$NS" get cm flagd-config -o jsonpath='{.data.demo\.flagd\.json}' 2>/dev/null)"
[ -n "$CUR" ] || { echo "fix-flag: cannot read flagd-config" >&2; exit 1; }
PATCH="$(printf '%s' "$CUR" | FLAG="$FLAG" VARIANT="$VARIANT" python3 -c '
import sys, json, os
d = json.load(sys.stdin)
f = d.get("flags", {})
k = os.environ["FLAG"]
if k in f:
    f[k]["defaultVariant"] = os.environ["VARIANT"]
print(json.dumps({"data": {"demo.flagd.json": json.dumps(d)}}))')"
kubectl -n "$NS" patch cm flagd-config --type merge -p "$PATCH" >/dev/null 2>&1 || { echo "fix-flag: patch failed" >&2; exit 1; }
kubectl -n "$NS" rollout restart deploy/flagd >/dev/null 2>&1
kubectl -n "$NS" rollout status deploy/flagd --timeout=90s >/dev/null 2>&1
sleep 6
echo "fix-flag: set $FLAG -> $VARIANT (flagd reloaded)"
