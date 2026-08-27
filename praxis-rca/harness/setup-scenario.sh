#!/usr/bin/env bash
# setup-scenario.sh — stand up ONE PRAXIS scenario's faulted state (PER-SCENARIO SETUP).
# ─────────────────────────────────────────────────────────────────────────────
# Reads ground-truth.tsv. For <scen>:
#  (a) deploy the matching neo4j-productdb variant (IfNotPresent; 401 has none)
#  (b) strategic-patch recommendation -> the quay faulted image (IfNotPresent) + the
#      right NEO4J_PRODUCT_DATABASE_ENDPOINT env (405 http:// ; 410/412 host:port)
#  (c) copy the faulted recommendation_server.py into ~/opentelemetry-demo/src (so the
#      arms copy the correct faulted source) — the live neat daemon watches this tree
#  (d) CONFIRM the fault fires (drive /api/recommendations): 401->500, 405/410->504,
#      412->200-but-slow. For LATENCY, measure the faulted baseline and write the
#      oracle ceiling to seeds/<scen>/lat_ceiling_ms.txt (fixed must be several× faster).
# Prints FAULT_FIRES=YES|NO. STOCK quay images (workers=10); load-isolation (not a
# max_workers bump) gives clean sequential measurement (task fix #7).
#
#   setup-scenario.sh <scenario>
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GT="$HERE/ground-truth.tsv"
NS=otel-demo; DEP=recommendation; PF_PORT=18081
QUAY=quay.io/shengkunrz/it-bench-dev

SCEN="${1:?usage: setup-scenario.sh <scenario>}"
row="$(grep -E "^${SCEN}\b" "$GT" | grep -vE '^#' | head -1)"
[ -n "$row" ] || { echo "setup-$SCEN: no ground-truth row" >&2; exit 1; }
IFS=$'\t' read -r _s REC_TAG PDB_TAG PDB_ENV NEO4J_EP MODE RCI <<<"$row"
FAULT_IMG="$QUAY:$REC_TAG"
echo "[$(date +%H:%M:%S)] setup-$SCEN: rec=$REC_TAG pdb=$PDB_TAG env=$NEO4J_EP mode=$MODE"

# ── (a) productdb variant ──────────────────────────────────────────────────────
if [ "$PDB_TAG" != NONE ]; then
  ENVBLOCK=""
  if [ "$PDB_ENV" != "-" ]; then
    k="${PDB_ENV%%=*}"; v="${PDB_ENV#*=}"
    ENVBLOCK=$'          env:\n            - name: '"$k"$'\n              value: "'"$v"'"'
  fi
  kubectl apply -f - >/dev/null 2>&1 <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: {name: neo4j-productdb, namespace: $NS, labels: {app: neo4j-productdb}}
spec:
  replicas: 1
  selector: {matchLabels: {app: neo4j-productdb}}
  template:
    metadata: {labels: {app: neo4j-productdb}}
    spec:
      containers:
        - name: neo4j-productdb
          image: "$QUAY:$PDB_TAG"
          imagePullPolicy: IfNotPresent
          ports: [{containerPort: 7979, name: http}]
$ENVBLOCK
---
apiVersion: v1
kind: Service
metadata: {name: neo4j-productdb, namespace: $NS}
spec:
  type: ClusterIP
  selector: {app: neo4j-productdb}
  ports: [{protocol: TCP, port: 7979, targetPort: 7979}]
YAML
  kubectl rollout status deploy/neo4j-productdb -n $NS --timeout=120s >/dev/null 2>&1
  echo "  productdb -> $PDB_TAG ready"
fi

# ── (b) faulted recommendation image + env ─────────────────────────────────────
ENV_PATCH=""
[ "$NEO4J_EP" != "-" ] && ENV_PATCH=",\"env\":[{\"name\":\"NEO4J_PRODUCT_DATABASE_ENDPOINT\",\"value\":\"$NEO4J_EP\"}]"
kubectl patch deploy/$DEP -n $NS --type=strategic \
  -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$DEP\",\"image\":\"$FAULT_IMG\",\"imagePullPolicy\":\"IfNotPresent\"$ENV_PATCH}]}}}}" >/dev/null 2>&1
kubectl rollout status deploy/$DEP -n $NS --timeout=150s >/dev/null 2>&1
echo "  recommendation -> $REC_TAG ready (endpoint=$NEO4J_EP)"

# ── (c) update the watched source so arms copy the correct faulted variant ─────
cp "$HOME/praxis/seeds/${SCEN}/faulted/recommendation_server.py" \
   "$HOME/opentelemetry-demo/src/recommendation/recommendation_server.py"
echo "  source synced -> ~/opentelemetry-demo/src/recommendation/recommendation_server.py"

# ── (d) CONFIRM the fault fires ────────────────────────────────────────────────
sleep 15
pkill -f "port-forward.*frontend-proxy" 2>/dev/null; sleep 1
setsid bash -c "export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:\$PATH; kubectl port-forward svc/frontend-proxy $PF_PORT:8080 -n $NS" >/tmp/setup-pf.log 2>&1 </dev/null &
sleep 4
CURL_MAX=20; [ "$MODE" = LATENCY ] && CURL_MAX=40
CODES=""; LATS=""
for i in 1 2 3 4 5 6; do
  read -r code lat < <(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time "$CURL_MAX" "http://localhost:$PF_PORT/api/recommendations?productIds=OLJCESPC7Z")
  CODES="$CODES $code"; LATS="$LATS $lat"
  sleep 3
done
MAX_MS=$(printf '%s\n' $LATS | awk 'BEGIN{m=0}{v=$1*1000; if(v>m)m=v}END{printf "%d", m}')
N500=$(printf '%s\n' $CODES | grep -c '^500$' || true)
N5XX=$(printf '%s\n' $CODES | grep -cE '^(500|502|503|504|000)$' || true)
N200=$(printf '%s\n' $CODES | grep -c '^200$' || true)
DEADLINE=$(kubectl logs deploy/$DEP -n $NS --since=60s 2>/dev/null | grep -icE "DEADLINE_EXCEEDED|context deadline" || true)
ATTRERR=$(kubectl logs deploy/$DEP -n $NS --since=60s 2>/dev/null | grep -icE "has no attribute|AttributeError|products_list" || true)

FAULT_FIRES=NO
case "$MODE" in
  ERROR)   { [ "$N5XX" -ge 1 ] || [ "$ATTRERR" -ge 1 ]; } && FAULT_FIRES=YES ;;
  HANG)    { [ "$N5XX" -ge 1 ] || [ "$DEADLINE" -ge 1 ] || [ "$MAX_MS" -ge 12000 ]; } && FAULT_FIRES=YES ;;
  LATENCY)
    # faulted should be slow. If it returns 200s, set ceiling = max/3 (fixed several× faster).
    # If it rides the deadline (504), that's HANG-class — flag it, oracle can't do LATENCY.
    if [ "$N200" -ge 1 ] && [ "$MAX_MS" -ge 1500 ]; then
      CEIL=$(( MAX_MS / 3 )); [ "$CEIL" -lt 800 ] && CEIL=800
      echo "$CEIL" > "$HOME/praxis/seeds/${SCEN}/lat_ceiling_ms.txt"
      FAULT_FIRES=YES
      echo "  LATENCY baseline faulted_max=${MAX_MS}ms -> oracle ceiling=${CEIL}ms (seeds/$SCEN/lat_ceiling_ms.txt)"
    elif [ "$N5XX" -ge 1 ] || [ "$DEADLINE" -ge 1 ]; then
      echo "  LATENCY WARNING: faulted rides the deadline (5xx/DEADLINE) — HANG-class, not clean 200-slow"
      FAULT_FIRES=DEADLINE
    fi ;;
esac
echo "  confirm: codes=[$CODES ] max_ms=$MAX_MS n200=$N200 n5xx=$N5XX deadline=$DEADLINE attr_err=$ATTRERR"
echo "FAULT_FIRES_${SCEN}=$FAULT_FIRES"
pkill -f "port-forward.*frontend-proxy" 2>/dev/null || true
[ "$FAULT_FIRES" = YES ] && exit 0 || exit 1
