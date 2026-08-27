#!/usr/bin/env bash
# verify-scenario.sh — the generalized fix ORACLE for the PRAXIS ±NEAT suite.
# ─────────────────────────────────────────────────────────────────────────────
# Generalized from the proven verify-405.sh. Same hard-won fixes, per-mode verdict:
#   ERROR   (401)  faulted = 500/AttributeError. RESOLVED = 200s + NO AttributeError
#                  / "has no attribute" / products_list in rec logs over the window.
#   HANG    (405/410) faulted = 504 riding the client deadline. RESOLVED = no request
#                  rides the deadline (max_latency < LAT_MAX_MS) + NO DEADLINE_EXCEEDED
#                  + real 200s (circuit-breaker re-admits a healthy recommendation).
#   LATENCY (412)  faulted returns 200 but SLOW. RESOLVED = 200s AND max_latency below
#                  LAT_MAX_MS (set from the faulted baseline in setup — pass via env).
# Every mode also requires: no product-catalog regression + a freshly-built image is
# actually deployed (anti-cheat by md5 vs the scenario's faulted seed).
#
#   verify-scenario.sh <scenario> <fixed_recommendation_server.py> <fault_img> <mode>
#     <fault_img>  full quay path of the faulted image (build base + revert target)
#     <mode>       ERROR | HANG | LATENCY
#   env: LAT_MAX_MS  latency ceiling in ms (HANG default 12000; LATENCY REQUIRED from setup)
#
#   → prints RESOLVED_<scen>=YES|NO plus measurements; ALWAYS reverts to <fault_img>.
# Requires: docker, kind, kubectl, curl on PATH.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

SCEN="${1:?usage: verify-scenario.sh <scen> <fixed_file> <fault_img> <mode>}"
FIXED="${2:?fixed_recommendation_server.py}"
FAULT_IMG="${3:?fault_img (full quay path)}"
MODE="${4:?mode ERROR|HANG|LATENCY}"
[ -f "$FIXED" ] || { echo "verify-$SCEN: fixed file not found: $FIXED" >&2; echo "RESOLVED_${SCEN}=NO reason=no_fixed_file"; exit 1; }

NS=otel-demo; DEP=recommendation
TAG="neat-bench/rec-${SCEN}-fix:$(date +%s)-$$"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
PF_PORT=18080
FAULT_SEED="$HOME/praxis/seeds/${SCEN}/faulted/recommendation_server.py"
# latency ceiling: HANG must be well under the 15s deadline; LATENCY set from baseline.
case "$MODE" in
  HANG)    LAT_MAX_MS="${LAT_MAX_MS:-12000}" ;;
  LATENCY) LAT_MAX_MS="${LAT_MAX_MS:?LATENCY mode needs LAT_MAX_MS (from faulted baseline)}" ;;
  ERROR)   LAT_MAX_MS="${LAT_MAX_MS:-15000}" ;;   # sanity cap only; ERROR gates on logs
  *) echo "verify-$SCEN: unknown mode $MODE" >&2; exit 2 ;;
esac

echo "[$(date +%H:%M:%S)] verify-$SCEN ($MODE): building fixed image on faulted base $FAULT_IMG"
cp "$FIXED" "$WORK/recommendation_server.py"
cat > "$WORK/Dockerfile" <<DOCKER
FROM $FAULT_IMG
COPY recommendation_server.py /usr/src/app/recommendation_server.py
DOCKER
docker build -q -t "$TAG" "$WORK" >/dev/null 2>&1 || { echo "RESOLVED_${SCEN}=NO reason=build_failed"; exit 2; }
kind load docker-image --name kind-dev "$TAG" >/dev/null 2>&1 || { echo "RESOLVED_${SCEN}=NO reason=kind_load_failed"; exit 2; }

echo "[$(date +%H:%M:%S)] verify-$SCEN: deploying fixed image (IfNotPresent) + rollout"
# CRITICAL (verify-405 fix #1): local tag + the deploy's imagePullPolicy=Always would
# make kubelet try to PULL our tag (not in any registry) and keep the old pod. Patch
# image AND policy=IfNotPresent together. env is preserved by strategic merge.
kubectl patch deploy/$DEP -n $NS --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$DEP\",\"image\":\"$TAG\",\"imagePullPolicy\":\"IfNotPresent\"}]}}}}" >/dev/null 2>&1
kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
sleep 30   # settle; exclude the rollout transition from the oracle window

# ── drive deterministic load through frontend-proxy ───────────────────────────
pkill -f "port-forward.*frontend-proxy" 2>/dev/null; sleep 1
setsid bash -c "export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:\$PATH; kubectl port-forward svc/frontend-proxy $PF_PORT:8080 -n $NS" >/tmp/verify-pf.log 2>&1 </dev/null &
sleep 4
# WARM-UP (verify-405 fix #3): during the faulted period Envoy outlier-detection ejects
# recommendation and 503s everything. Drive ~90s so a WORKING fix lets the breaker
# re-admit recommendation (real 200s); a non-fix keeps erroring. Without this the oracle
# measures the breaker, not the fix.
echo "[$(date +%H:%M:%S)] verify-$SCEN: warm-up 90s (circuit-breaker re-admit)"
CURL_MAX=18; [ "$MODE" = LATENCY ] && CURL_MAX=35   # a slow-but-correct baseline may be long
WEND=$(( $(date +%s) + 90 ))
while [ "$(date +%s)" -lt "$WEND" ]; do
  curl -s -o /dev/null --max-time 10 "http://localhost:$PF_PORT/api/products" 2>/dev/null
  curl -s -o /dev/null --max-time "$CURL_MAX" "http://localhost:$PF_PORT/api/recommendations?productIds=OLJCESPC7Z" 2>/dev/null
  sleep 2
done
# MEASURE steady state (n=8)
SINCE_MARK=$(date +%s)
CODES=""; LATS=""
for i in 1 2 3 4 5 6 7 8; do
  read -r code lat < <(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time "$CURL_MAX" "http://localhost:$PF_PORT/api/recommendations?productIds=OLJCESPC7Z")
  CODES="$CODES $code"; LATS="$LATS $lat"
done
MAX_MS=$(printf '%s\n' $LATS | awk 'BEGIN{m=0}{v=$1*1000; if(v>m)m=v}END{printf "%d", m}')
N200=$(printf '%s\n' $CODES | grep -c '^200$' || true)
N5XX=$(printf '%s\n' $CODES | grep -cE '^(500|502|503|504|000)$' || true)
WINDOW=$(( $(date +%s) - SINCE_MARK + 5 ))

# ── per-mode symptom check ─────────────────────────────────────────────────────
DEADLINE=$(kubectl logs deploy/$DEP -n $NS --since=${WINDOW}s 2>/dev/null | grep -icE "DEADLINE_EXCEEDED|Deadline Exceeded|context deadline" || true)
ATTRERR=$(kubectl logs deploy/$DEP -n $NS --since=${WINDOW}s 2>/dev/null | grep -icE "has no attribute|AttributeError|products_list" || true)

# ── regression: probe product-catalog directly (verify-405 fix #5) ─────────────
POK=0
for i in 1 2 3 4; do
  pc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://localhost:$PF_PORT/api/products" 2>/dev/null)
  [ "$pc" = 200 ] && POK=$((POK+1))
done
OTHER=0
for s in cart checkout product-catalog; do
  c=$(kubectl logs deploy/$s -n $NS --since=${WINDOW}s 2>/dev/null | grep -icE "Traceback|CRITICAL|panic|UNAVAILABLE|INTERNAL" || true)
  OTHER=$((OTHER+c))
done

# ── anti-cheat (verify-405 fix #2): the RUNNING pod's recommendation_server.py must
#    DIFFER (md5) from the scenario's faulted seed → a real fix is deployed, not
#    stock/scale-0. Hash-compare is robust vs containerd image-name normalization. ──
RUNPOD=$(kubectl get pods -n $NS -o name 2>/dev/null | grep "$DEP" | head -1 | sed 's@pod/@@')
REPLICAS=$(kubectl get deploy/$DEP -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
RUN_MD5=$(kubectl exec -n $NS "$RUNPOD" -- md5sum /usr/src/app/recommendation_server.py 2>/dev/null | awk '{print $1}')
FAULT_MD5=$(md5sum "$FAULT_SEED" 2>/dev/null | awk '{print $1}')
CHEAT=NO; { [ -n "$RUN_MD5" ] && [ "$RUN_MD5" != "$FAULT_MD5" ] && [ "${REPLICAS:-0}" -ge 1 ]; } || CHEAT=YES

# ── verdict per mode ───────────────────────────────────────────────────────────
SYMPTOM_CLEARED=NO; RESOLVED=NO
case "$MODE" in
  HANG)
    [ "$MAX_MS" -lt "$LAT_MAX_MS" ] && [ "$DEADLINE" -eq 0 ] && SYMPTOM_CLEARED=YES
    { [ "$SYMPTOM_CLEARED" = YES ] && [ "$N200" -ge 6 ] && [ "${POK:-0}" -ge 3 ] && [ "$CHEAT" = NO ]; } && RESOLVED=YES ;;
  ERROR)
    [ "$ATTRERR" -eq 0 ] && [ "$N200" -ge 6 ] && SYMPTOM_CLEARED=YES
    { [ "$SYMPTOM_CLEARED" = YES ] && [ "${POK:-0}" -ge 3 ] && [ "$CHEAT" = NO ]; } && RESOLVED=YES ;;
  LATENCY)
    [ "$MAX_MS" -lt "$LAT_MAX_MS" ] && [ "$N200" -ge 6 ] && SYMPTOM_CLEARED=YES
    { [ "$SYMPTOM_CLEARED" = YES ] && [ "${POK:-0}" -ge 3 ] && [ "$CHEAT" = NO ]; } && RESOLVED=YES ;;
esac
echo "verify-$SCEN: mode=$MODE codes=[$CODES ] max_latency_ms=$MAX_MS lat_ceiling_ms=$LAT_MAX_MS n200=$N200 n5xx=$N5XX deadline_exceeded=$DEADLINE attr_errors=$ATTRERR product_catalog_200=$POK/4 other_hard_errors=$OTHER anticheat_breach=$CHEAT run_md5=$RUN_MD5 fault_md5=$FAULT_MD5"
echo "SYMPTOM_CLEARED_${SCEN}=$SYMPTOM_CLEARED  RESOLVED_${SCEN}=$RESOLVED"

# ── ALWAYS revert to the faulted image so the next run starts clean ────────────
echo "[$(date +%H:%M:%S)] verify-$SCEN: reverting recommendation to faulted image"
kubectl patch deploy/$DEP -n $NS --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$DEP\",\"image\":\"$FAULT_IMG\",\"imagePullPolicy\":\"IfNotPresent\"}]}}}}" >/dev/null 2>&1
kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
pkill -f "port-forward.*frontend-proxy" 2>/dev/null || true
[ "$RESOLVED" = YES ] && exit 0 || exit 1
