#!/usr/bin/env bash
export PATH=$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH; export KUBECONFIG=$HOME/.kube/config
echo "[$(date +%H:%M:%S)] uninstall otel-demo 2.2.0"
helm uninstall otel-demo -n otel-demo 2>&1 | tail -1
sleep 10
echo "[$(date +%H:%M:%S)] add otel helm repo"
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null 2>&1
helm repo update >/dev/null 2>&1
echo "[$(date +%H:%M:%S)] install chart 0.36.4 (app 2.0.1)"
helm install otel-demo open-telemetry/opentelemetry-demo --version 0.36.4 -n otel-demo --create-namespace --wait --timeout 12m 2>&1 | tail -3
echo "[$(date +%H:%M:%S)] deployed image tag:"; kubectl get deploy recommendation -n otel-demo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null; echo
echo "[$(date +%H:%M:%S)] re-checkout source at 2.0.1 for NEAT"
cd ~/opentelemetry-demo && git fetch --tags --quiet 2>&1 | tail -1 && git checkout 2.0.1 2>&1 | tail -2
echo "[$(date +%H:%M:%S)] DONE repin"
