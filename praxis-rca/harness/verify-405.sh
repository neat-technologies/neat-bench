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
# faulted base with max_workers bumped 10→100 (the concurrency AMPLIFIER removed
# so we measure the neo4j-timeout fix, not pool exhaustion) — applied equally to
# the faulted baseline and every arm's fix (a control variable). Local image, so
# it must deploy with imagePullPolicy=IfNotPresent (patched below).
FAULT_IMG="${FAULT_IMG_405:-neat-bench/rec-405-faulted-w100:v1}"
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
# CRITICAL: the recommendation deploy ships imagePullPolicy=Always, which makes
# kubelet try to PULL our locally-built tag (not in any registry) → the new pod
# never starts and the OLD faulted pod keeps serving. Patch image AND policy to
# IfNotPresent together so the kind-loaded image is actually used.
kubectl patch deploy/$DEP -n $NS --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$DEP\",\"image\":\"$TAG\",\"imagePullPolicy\":\"IfNotPresent\"}]}}}}" >/dev/null 2>&1
kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
sleep 30   # settle; exclude the rollout transition from the oracle window

# ── drive deterministic load through frontend-proxy ───────────────────────────
pkill -f "port-forward.*frontend-proxy" 2>/dev/null; sleep 1
setsid bash -c "export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:\$PATH; kubectl port-forward svc/frontend-proxy $PF_PORT:8080 -n $NS" >/tmp/verify405-pf.log 2>&1 </dev/null &
sleep 4
# WARM-UP: during the faulted period the frontend-proxy circuit-breaker (Envoy
# outlier detection) ejects recommendation and 503s EVERYTHING regardless of the
# new code. Drive steady traffic ~90s so a WORKING fix lets the breaker re-admit
# recommendation (→ 200s); a non-fix keeps it erroring (→ stays 503/504). Without
# this the oracle measures the breaker, not the fix (the bug that failed all arms).
echo "[$(date +%H:%M:%S)] verify-405: warm-up 90s (let circuit-breaker re-admit a healthy recommendation)"
WEND=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$WEND" ]; do
  curl -s -o /dev/null --max-time 10 "http://localhost:$PF_PORT/api/products" 2>/dev/null
  curl -s -o /dev/null --max-time 10 "http://localhost:$PF_PORT/api/recommendations?productIds=OLJCESPC7Z" 2>/dev/null
  sleep 2
done
# MEASURE steady state
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
# ── regression: probe product-catalog directly (a fix that broke another flow
#    would 5xx here) — robust vs a broad log grep that matches baseline noise. ──
POK=0
for i in 1 2 3 4; do
  pc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://localhost:$PF_PORT/api/products" 2>/dev/null)
  [ "$pc" = 200 ] && POK=$((POK+1))
done
# hard failures in other services over the window (reported note, not the gate)
OTHER=0
for s in cart checkout product-catalog; do
  c=$(kubectl logs deploy/$s -n $NS --since=${WINDOW}s 2>/dev/null | grep -icE "Traceback|CRITICAL|panic|UNAVAILABLE|INTERNAL" || true)
  OTHER=$((OTHER+c))
done
# ── anti-cheat: the RUNNING pod's recommendation_server.py must DIFFER from the
#    faulted seed (a real fix is deployed, not stock/scale-0), replicas>=1. Hash-
#    compare — robust vs containerd image-name normalization (which false-flagged). ──
RUNPOD=$(kubectl get pods -n $NS -o name 2>/dev/null | grep "$DEP" | head -1 | sed 's@pod/@@')
REPLICAS=$(kubectl get deploy/$DEP -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
RUN_HAS_FIX=$(kubectl exec -n $NS "$RUNPOD" -- grep -c 'timeout=' /usr/src/app/recommendation_server.py 2>/dev/null | head -1 || echo 0)
RUN_MD5=$(kubectl exec -n $NS "$RUNPOD" -- md5sum /usr/src/app/recommendation_server.py 2>/dev/null | awk '{print $1}')
FAULT_MD5=$(md5sum "$HOME/praxis/seeds/405/faulted/recommendation_server.py" 2>/dev/null | awk '{print $1}')
CHEAT=NO; { [ -n "$RUN_MD5" ] && [ "$RUN_MD5" != "$FAULT_MD5" ] && [ "${REPLICAS:-0}" -ge 1 ]; } || CHEAT=YES

# ── verdict ───────────────────────────────────────────────────────────────────
# HANG_CLEARED: the actual fault (the 15s indefinite hang) is gone — no request
# rides the deadline and no DEADLINE_EXCEEDED. A timeout-only fix (fast-fail)
# clears the hang but may still error. This is the minimum a real fix achieves.
HANG_CLEARED=NO
[ "$MAX_MS" -lt "$LAT_MAX_MS" ] && [ "$DEADLINE" -eq 0 ] && HANG_CLEARED=YES
# RESOLVED: the app actually RECOVERS — the hang is cleared AND recommendation is
# serving again (breaker re-admitted it → real 200s, not just fast breaker-503s)
# AND no regression AND the freshly-built image is what's deployed. A graceful
# timeout+degrade fix reaches this; a bare fast-fail clears the hang but not this.
RESOLVED=NO
if [ "$HANG_CLEARED" = YES ] && [ "$N200" -ge 6 ] && [ "${POK:-0}" -ge 3 ] && [ "$CHEAT" = NO ]; then
  RESOLVED=YES
fi
echo "verify-405: codes=[$CODES ] max_latency_ms=$MAX_MS n200=$N200 n5xx=$N504 deadline_exceeded=$DEADLINE product_catalog_200=$POK/4 other_hard_errors=$OTHER run_has_timeout=$RUN_HAS_FIX anticheat_breach=$CHEAT"
echo "HANG_CLEARED_405=$HANG_CLEARED  RESOLVED_405=$RESOLVED"

# ── ALWAYS revert to faulted so the next run starts clean ─────────────────────
echo "[$(date +%H:%M:%S)] verify-405: reverting recommendation to faulted image"
kubectl patch deploy/$DEP -n $NS --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$DEP\",\"image\":\"$FAULT_IMG\",\"imagePullPolicy\":\"IfNotPresent\"}]}}}}" >/dev/null 2>&1
kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
pkill -f "port-forward.*frontend-proxy" 2>/dev/null || true
[ "$RESOLVED" = YES ] && exit 0 || exit 1
