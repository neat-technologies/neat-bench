#!/usr/bin/env bash
for arm in neat code; do
  echo "[$(date +%H:%M:%S)] verify 411 $arm"
  bash ~/praxis/verify-generic.sh ~/praxis/runs/411/$arm/src 411$arm quay.io/shengkunrz/it-bench-dev:logicc-recommendation ~/praxis/oracle-rec.sh
  kubectl set image deploy/recommendation -n otel-demo recommendation=quay.io/shengkunrz/it-bench-dev:logicc-recommendation >/dev/null 2>&1
  export KUBECONFIG=$HOME/.kube/config PATH=$HOME/.local/bin:$PATH; kubectl rollout status deploy/recommendation -n otel-demo --timeout=90s >/dev/null 2>&1
done; echo "[$(date +%H:%M:%S)] DONE 411 verify"
