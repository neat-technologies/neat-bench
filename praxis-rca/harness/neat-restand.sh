#!/usr/bin/env bash
export PATH=$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH; export KUBECONFIG=$HOME/.kube/config
export NEAT_AUTH_TOKEN=benchops-neat-token
echo "[$(date +%H:%M:%S)] wait for otel-demo pods ready"
kubectl wait --for=condition=Ready pod --all -n otel-demo --timeout=420s >/dev/null 2>&1
echo "[$(date +%H:%M:%S)] pods ready: $(kubectl get pods -n otel-demo | grep -c Running)/$(kubectl get pods -n otel-demo --no-headers | wc -l)"
echo "[$(date +%H:%M:%S)] neat init on 2.0.1 source"
cd ~/opentelemetry-demo
neat init ~/opentelemetry-demo 2>&1 | tail -2
echo "[$(date +%H:%M:%S)] restart live neat watch daemon"
pkill -f 'neat watch' 2>/dev/null; sleep 3; rm -f ~/opentelemetry-demo/neat-out/graph.json ~/opentelemetry-demo/neat-out/*.ndjson 2>/dev/null
NEAT_AUTH_TOKEN=benchops-neat-token NEAT_OTEL_TOKEN=benchops-neat-token HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 \
  setsid neat watch ~/opentelemetry-demo >~/neat-watch.log 2>&1 &
sleep 8
echo "[$(date +%H:%M:%S)] patch collector -> otlphttp/neat exporter (host 172.18.0.1:4319)"
kubectl get cm otel-collector -n otel-demo -o yaml > /tmp/cm.yaml 2>/dev/null
yq -i '.data.relay |= (from_yaml | .exporters."otlphttp/neat".endpoint="http://172.18.0.1:4319" | .exporters."otlphttp/neat".headers.authorization="Bearer benchops-neat-token" | .exporters."otlphttp/neat".tls.insecure=true | .service.pipelines.traces.exporters += ["otlphttp/neat"] | to_yaml)' /tmp/cm.yaml 2>/dev/null
kubectl apply -f /tmp/cm.yaml >/dev/null 2>&1 && kubectl rollout restart deploy/otel-collector -n otel-demo >/dev/null 2>&1
echo "[$(date +%H:%M:%S)] settle 90s for fusion"; sleep 90
echo "[$(date +%H:%M:%S)] NEAT health + OBSERVED edge count:"
curl -s -H "Authorization: Bearer benchops-neat-token" http://localhost:8098/health
neat observed-dependencies service:recommendation --project default 2>&1 | head -4
echo "[$(date +%H:%M:%S)] DONE restand"
