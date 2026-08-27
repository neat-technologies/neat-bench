#!/usr/bin/env bash
# setup-divergence.sh — stand up ONE divergence-bench scenario (detection, no fix).
# ─────────────────────────────────────────────────────────────────────────────
# Reads divergence-ground-truth.tsv. Resets the cluster to a clean baseline first
# (recommendation/product-catalog/ad -> healthy stock), then applies this scenario's
# fault by deploy type:
#   recimage : deploy matching neo4j-productdb + faulted recommendation image + env,
#              and sync the faulted recommendation_server.py into the watched source
#              (so the neat daemon's EXTRACTED layer reflects the fault).
#   setimage : point product-catalog at a bad image (20).
#   scale0   : scale ad to 0 replicas (32).
# Confirms the fault fires (serving -> 5xx/hang; bootstrap -> pod never Ready;
# 20 -> product-catalog ImagePull; 32 -> ad replicas 0). Prints FAULT_FIRES_<scen>.
#
#   setup-divergence.sh <scenario>
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GT="$HERE/divergence-ground-truth.tsv"; NS=otel-demo; PF=18082
Q=quay.io/shengkunrz/it-bench-dev
HEALTHY_REC=ghcr.io/open-telemetry/demo:2.0.1-recommendation
HEALTHY_PC=ghcr.io/open-telemetry/demo:2.0.1-product-catalog
HEALTHY_AD=ghcr.io/open-telemetry/demo:2.0.1-ad
SRC=$HOME/opentelemetry-demo/src/recommendation/recommendation_server.py

SCEN="${1:?usage: setup-divergence.sh <scenario>}"
row="$(grep -E "^${SCEN}\b" "$GT" | grep -vE '^#' | head -1)"
[ -n "$row" ] || { echo "setup-div-$SCEN: no ground-truth row" >&2; exit 1; }
IFS=$'\t' read -r _s STRENGTH DEPLOY TARGET REC_TAG PDB_TAG NEO4J_EP EXTRA_ENV RCI BOOT <<<"$row"
echo "[$(date +%H:%M:%S)] setup-div-$SCEN: strength=$STRENGTH deploy=$DEPLOY target=$TARGET boot=$BOOT rci=$RCI"

# ── reset baseline (idempotent) ────────────────────────────────────────────────
kubectl scale deploy/ad -n $NS --replicas=1 >/dev/null 2>&1
kubectl set image deploy/product-catalog -n $NS product-catalog=$HEALTHY_PC >/dev/null 2>&1
if [ "$DEPLOY" != recimage ]; then
  # non-rec fault -> recommendation must be HEALTHY (stock image + stock source)
  kubectl set image deploy/recommendation -n $NS recommendation=$HEALTHY_REC >/dev/null 2>&1
  docker run --rm --entrypoint cat $HEALTHY_REC /usr/src/app/recommendation_server.py > "$SRC" 2>/dev/null
fi

apply_env () {  # build env json array from NEO4J_EP + EXTRA_ENV
  local arr=""
  [ "$NEO4J_EP" != "-" ] && arr="{\"name\":\"NEO4J_PRODUCT_DATABASE_ENDPOINT\",\"value\":\"$NEO4J_EP\"}"
  if [ "$EXTRA_ENV" != "-" ]; then
    IFS=';' read -ra kvs <<<"$EXTRA_ENV"
    for kv in "${kvs[@]}"; do
      [ -n "$arr" ] && arr="$arr,"
      arr="$arr{\"name\":\"${kv%%=*}\",\"value\":\"${kv#*=}\"}"
    done
  fi
  echo "$arr"
}

case "$DEPLOY" in
  recimage)
    if [ "$PDB_TAG" != NONE ] && [ "$PDB_TAG" != "-" ]; then
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
          image: "$Q:$PDB_TAG"
          imagePullPolicy: IfNotPresent
          ports: [{containerPort: 7979, name: http}]
---
apiVersion: v1
kind: Service
metadata: {name: neo4j-productdb, namespace: $NS}
spec: {type: ClusterIP, selector: {app: neo4j-productdb}, ports: [{protocol: TCP, port: 7979, targetPort: 7979}]}
YAML
      kubectl rollout status deploy/neo4j-productdb -n $NS --timeout=120s >/dev/null 2>&1
    fi
    ENVARR="$(apply_env)"
    ENVPATCH=""; [ -n "$ENVARR" ] && ENVPATCH=",\"env\":[$ENVARR]"
    kubectl patch deploy/recommendation -n $NS --type=strategic \
      -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"recommendation\",\"image\":\"$Q:$REC_TAG\",\"imagePullPolicy\":\"IfNotPresent\"$ENVPATCH}]}}}}" >/dev/null 2>&1
    # sync faulted source into the watched tree (EXTRACTED reflects the fault)
    docker run --rm --entrypoint cat "$Q:$REC_TAG" /usr/src/app/recommendation_server.py > "$SRC" 2>/dev/null
    kubectl rollout status deploy/recommendation -n $NS --timeout=90s >/dev/null 2>&1 || true
    echo "  recommendation -> $REC_TAG (ep=$NEO4J_EP extra=$EXTRA_ENV)"
    ;;
  setimage)
    # match ITBench: scale to 0 first so the broken image is the ONLY pod (service
    # actually goes down), not a rolling update that keeps the old healthy pod.
    kubectl scale deploy/$TARGET -n $NS --replicas=0 >/dev/null 2>&1; sleep 4
    kubectl set image deploy/$TARGET -n $NS $TARGET=$REC_TAG >/dev/null 2>&1
    kubectl scale deploy/$TARGET -n $NS --replicas=1 >/dev/null 2>&1
    echo "  $TARGET -> $REC_TAG (bad image, forced sole replica)"
    sleep 10
    ;;
  scale0)
    kubectl scale deploy/$TARGET -n $NS --replicas=0 >/dev/null 2>&1
    echo "  $TARGET -> replicas=0"
    sleep 5
    ;;
esac

# ── confirm the fault fires (robust to the recommendation request cache) ───────
# The faulted recommendation images gate the neo4j/field path behind a ~50% cache
# (`if random.random() < 0.5 or first_run`), so a short probe can hit only cache-hits
# and miss the fault. Drive MANY requests + grep recommendation logs as a backstop.
FAULT_FIRES=NO; DETAIL=""
reclog_errs () { kubectl logs deploy/recommendation -n $NS --since=90s 2>/dev/null | grep -icE "AttributeError|has no attribute|DEADLINE_EXCEEDED|context deadline|Traceback|IndexError|out of range|getaddrinfo|Name or service not known|ConnectionError|Timeout|neo4j"; }
if [ "$DEPLOY" = scale0 ]; then
  reps=$(kubectl get deploy/$TARGET -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  DETAIL="ad readyReplicas=${reps:-0}"; { [ "${reps:-0}" = "" ] || [ "${reps:-0}" -eq 0 ]; } && FAULT_FIRES=YES
elif [ "$DEPLOY" = setimage ]; then
  sleep 6
  st=$(kubectl get pods -n $NS -l app.kubernetes.io/component=$TARGET -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
  ready=$(kubectl get deploy/$TARGET -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  DETAIL="$TARGET waiting=$st ready=${ready:-0}"
  { echo "$st" | grep -qiE 'ImagePull|ErrImage|InvalidImage|CrashLoop' || [ "${ready:-0}" = "0" ] || [ "${ready:-0}" = "" ]; } && FAULT_FIRES=YES
else
  # recimage (serving OR bootstrap). Bootstrap images also call neo4j on the serving
  # path, so a Ready bootstrap pod still fails on requests — so: bootstrap crash counts,
  # AND if Ready we fall through to the serving probe.
  if [ "$BOOT" = yes ]; then
    sleep 30
    ready=$(kubectl get deploy/recommendation -n $NS -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    rst=$(kubectl get pods -n $NS -l app.kubernetes.io/component=recommendation -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
    wr=$(kubectl get pods -n $NS -l app.kubernetes.io/component=recommendation -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
    if [ "${ready:-0}" = "0" ] || [ "${ready:-0}" = "" ] || [ "${rst:-0}" -ge 1 ] || echo "$wr" | grep -qiE 'CrashLoop|Error'; then
      FAULT_FIRES=YES; DETAIL="bootstrap: readyReplicas=${ready:-0} restarts=${rst:-?} waiting=$wr"
    fi
  fi
  if [ "$FAULT_FIRES" = NO ]; then
    sleep 8
    pkill -f "port-forward.*frontend-proxy" 2>/dev/null; sleep 1
    setsid bash -c "kubectl port-forward svc/frontend-proxy $PF:8080 -n $NS" >/tmp/setupdiv-pf.log 2>&1 </dev/null &
    sleep 4
    N5=0; MX=0; N2=0
    for i in $(seq 1 18); do
      read -r c t < <(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 18 "http://localhost:$PF/api/recommendations?productIds=OLJCESPC7Z")
      ms=$(awk "BEGIN{printf \"%d\", $t*1000}"); [ "$ms" -gt "$MX" ] && MX=$ms
      case "$c" in 200) N2=$((N2+1));; 500|502|503|504|000) N5=$((N5+1));; esac
      sleep 1
    done
    LOGE=$(reclog_errs)
    DETAIL="n200=$N2 n5xx=$N5 max_ms=$MX reclog_errs=$LOGE"
    { [ "$N5" -ge 1 ] || [ "$MX" -ge 12000 ] || [ "${LOGE:-0}" -ge 1 ]; } && FAULT_FIRES=YES
    pkill -f "port-forward.*frontend-proxy" 2>/dev/null
  fi
fi
echo "  confirm: $DETAIL"
echo "FAULT_FIRES_${SCEN}=$FAULT_FIRES"
[ "$FAULT_FIRES" = YES ] && exit 0 || exit 1
