#!/usr/bin/env bash
export KUBECONFIG=$HOME/.kube/config; export PATH=$HOME/.local/bin:$PATH
for arm in neat code; do
  echo "[$(date +%H:%M:%S)] verify $arm"
  bash ~/praxis/verify-fix-401.sh ~/praxis/runs/401/$arm/src $arm
  kubectl set image deploy/recommendation -n otel-demo recommendation=quay.io/shengkunrz/it-bench-dev:dev-recommendation >/dev/null 2>&1
  kubectl rollout status deploy/recommendation -n otel-demo --timeout=90s >/dev/null 2>&1
done
echo "[$(date +%H:%M:%S)] DONE verify-all"
