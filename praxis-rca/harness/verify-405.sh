#!/usr/bin/env bash
# verify-405.sh — the fix ORACLE for PRAXIS scenario 405 (neo4j external-dep hang).
# ─────────────────────────────────────────────────────────────────────────────
# 405's fault is a HANG: recommendation's requests.get(neo4jdb_addr) has no
# timeout, and the neo4j mock holds connections open → gRPC DEADLINE_EXCEEDED →
# frontend-proxy 504. A CORRECT fix (timeout + retry/backoff/graceful-degrade)
# does NOT make neo4j reachable — neo4j stays down — it makes recommendation
# FAIL FAST and still serve (product-catalog recommendations, no neo4j extras).
# So RESOLVED is NOT "no errors": it is "requests COMPLETE (200, well under the
# 15s deadline) with no DEADLINE_EXCEEDED, and no new regression elsewhere."
#
#   verify-405.sh <fixed_recommendation_server.py>
#   → prints RESOLVED_405=YES|NO plus measurements; ALWAYS reverts to faulted.
#
# Requires: docker, kind, kubectl, curl on PATH. VALIDATE with a smoke where the
# "fix" is the unfixed faulted seed — the oracle MUST say NO and revert cleanly.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

FIXED="${1:?usage: verify-405.sh <fixed_recommendation_server.py>}"
[ -f "$FIXED" ] || { echo "verify-405: fixed file not found: $FIXED" >&2; exit 1; }

NS=otel-demo
DEP=recommendation
FAULT_IMG="quay.io/shengkunrz/it-bench-dev:neo4j-serving-recommendation"
TAG="neat-bench/rec-405-fix:$(date +%s)-$$"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
LAT_MAX_MS=12000     # must be well under the 15s client deadline
PF_PORT=18080

echo "[$(date +%H:%M:%S)] verify-405: building fixed image on the faulted base"
cp "$FIXED" "$WORK/recommendation_server.py"
cat > "$WORK/Dockerfile" <<DOCKER
FROM $FAULT_IMG
COPY recommendation_server.py /usr/src/app/recommendation_server.py
DOCKER
docker build -q -t "$TAG" "$WORK" >/dev/null 2>&1 || { echo "verify-405: docker build failed" >&2; echo "RESOLVED_405=NO reason=build_failed"; exit 2; }
kind load docker-image --name kind-dev "$TAG" >/dev/null 2>&1 || { echo "verify-405: kind load failed" >&2; echo "RESOLVED_405=NO reason=kind_load_failed"; exit 2; }

echo "[$(date +%H:%M:%S)] verify-405: deploying fixed image + rollout"
kubectl set image deploy/$DEP -n $NS "$DEP=$TAG" >/dev/null 2>&1
kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
sleep 30   # settle; exclude the rollout transition from the oracle window

# ── drive deterministic load through frontend-proxy ───────────────────────────
pkill -f "port-forward.*frontend-proxy" 2>/dev/null; sleep 1
setsid bash -c "export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:\$PATH; kubectl port-forward svc/frontend-proxy $PF_PORT:8080 -n $NS" >/tmp/verify405-pf.log 2>&1 </dev/null &
sleep 4
SINCE_MARK=$(date +%s)
CODES=""; LATS=""
for i in 1 2 3 4 5 6 7 8; do
  read -r code lat < <(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 18 "http://localhost:$PF_PORT/api/recommendations?productIds=OLJCESPC7Z")
  CODES="$CODES $code"; LATS="$LATS $lat"
done
# p95-ish = max here (n=8); convert seconds→ms
MAX_MS=$(printf '%s\n' $LATS | awk 'BEGIN{m=0}{v=$1*1000; if(v>m)m=v}END{printf "%d", m}')
N200=$(printf '%s\n' $CODES | grep -c '^200$' || true)
N504=$(printf '%s\n' $CODES | grep -cE '^(502|503|504|000)$' || true)

# ── symptom check: DEADLINE_EXCEEDED / hang in recommendation over the window ──
WINDOW=$(( $(date +%s) - SINCE_MARK + 5 ))
DEADLINE=$(kubectl logs deploy/$DEP -n $NS --since=${WINDOW}s 2>/dev/null | grep -icE "DEADLINE_EXCEEDED|Deadline Exceeded|context deadline" || true)
# ── regression: other core flows newly erroring? ──────────────────────────────
OTHER=0
for s in frontend cart checkout product-catalog; do
  c=$(kubectl logs deploy/$s -n $NS --since=${WINDOW}s 2>/dev/null | grep -icE "error|exception|5[0-9][0-9]|UNAVAILABLE|INTERNAL" || true)
  OTHER=$((OTHER+c))
done
# ── anti-cheat: deployed image must be our freshly-built tag, replicas>=1 ──────
CUR_IMG=$(kubectl get deploy/$DEP -n $NS -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
REPLICAS=$(kubectl get deploy/$DEP -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
CHEAT=NO; [ "$CUR_IMG" = "$TAG" ] && [ "${REPLICAS:-0}" -ge 1 ] || CHEAT=YES

# ── verdict ───────────────────────────────────────────────────────────────────
RESOLVED=NO
if [ "$N200" -eq 8 ] && [ "$N504" -eq 0 ] && [ "$DEADLINE" -eq 0 ] && [ "$MAX_MS" -lt "$LAT_MAX_MS" ] && [ "$OTHER" -lt 5 ] && [ "$CHEAT" = NO ]; then
  RESOLVED=YES
fi
echo "verify-405: codes=[$CODES ] max_latency_ms=$MAX_MS n200=$N200 n5xx=$N504 deadline_exceeded=$DEADLINE other_core_errors=$OTHER anticheat_breach=$CHEAT"
echo "RESOLVED_405=$RESOLVED"

# ── ALWAYS revert to faulted so the next run starts clean ─────────────────────
echo "[$(date +%H:%M:%S)] verify-405: reverting recommendation to faulted image"
kubectl set image deploy/$DEP -n $NS "$DEP=$FAULT_IMG" >/dev/null 2>&1
kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
pkill -f "port-forward.*frontend-proxy" 2>/dev/null || true
[ "$RESOLVED" = YES ] && exit 0 || exit 1
