#!/usr/bin/env bash
export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:$PATH
SRC="$1"; TAG="$2"; BASE="$3"; ORACLE="$4"
D=$(mktemp -d); cp "$SRC/recommendation_server.py" "$D/"
printf "FROM %s\nCOPY recommendation_server.py /usr/src/app/recommendation_server.py\n" "$BASE" > "$D/Dockerfile"
docker build -q -t praxis-fix-$TAG:latest "$D" >/dev/null 2>&1 || { echo "$TAG BUILD FAIL"; exit 1; }
kind load docker-image praxis-fix-$TAG:latest --name kind-dev >/dev/null 2>&1
kubectl set image deploy/recommendation -n otel-demo recommendation=praxis-fix-$TAG:latest >/dev/null 2>&1
kubectl rollout status deploy/recommendation -n otel-demo --timeout=90s >/dev/null 2>&1
sleep 100
ERRS=$(bash "$ORACLE"); READY=$(kubectl get deploy recommendation -n otel-demo -o jsonpath='{.status.readyReplicas}')
echo "TAG=$TAG errors_after=$ERRS ready=$READY -> $([ "${ERRS:-1}" -eq 0 ] && echo PASS || echo FAIL)"
rm -rf "$D"
