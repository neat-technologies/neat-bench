#!/usr/bin/env bash
# usage: verify-fix-401.sh <src_dir_with_recommendation_server.py> <tag>
export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:$PATH
SRC="$1"; TAG="$2"
D=$(mktemp -d); cp "$SRC/recommendation_server.py" "$D/"
cat > "$D/Dockerfile" <<DF
FROM quay.io/shengkunrz/it-bench-dev:dev-recommendation
COPY recommendation_server.py /usr/src/app/recommendation_server.py
DF
docker build -q -t praxis-fix-401-$TAG:latest "$D" >/dev/null 2>&1 || { echo "BUILD FAIL"; exit 1; }
kind load docker-image praxis-fix-401-$TAG:latest --name kind-dev >/dev/null 2>&1
kubectl set image deploy/recommendation -n otel-demo recommendation=praxis-fix-401-$TAG:latest >/dev/null 2>&1
kubectl rollout status deploy/recommendation -n otel-demo --timeout=90s >/dev/null 2>&1
sleep 100
ERRS=$(bash ~/praxis/oracle-401.sh)
READY=$(kubectl get deploy recommendation -n otel-demo -o jsonpath='{.status.readyReplicas}')
echo "TAG=$TAG fault_errors_after=$ERRS ready=$READY  -> $([ "${ERRS:-1}" -eq 0 ] && echo PASS || echo FAIL)"
rm -rf "$D"
