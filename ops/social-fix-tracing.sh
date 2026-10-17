#!/usr/bin/env bash
# social-fix-tracing.sh — SREGym's socialNetwork image exports OTLP gRPC to the bare name
# otel-collector:4317 (no such Service in the app namespace) and its Jaeger sampler is
# probabilistic 0.01. Point the OTLP exporter at SREGym's collector, sample everything, restart.
# Folded into sregym-smoke-deploy.py for future deploys; kept as the one-shot for a live app.
export PATH="$HOME/.local/bin:$PATH"; export KUBECONFIG="$HOME/.kube/config"
NS="${1:-social-network}"
K="kubectl --context kind-kind -n $NS"
echo "== ExternalName otel-collector -> observe collector"
if ! $K get svc otel-collector >/dev/null 2>&1; then
  $K create service externalname otel-collector --external-name otel-collector.observe.svc.cluster.local >/dev/null && echo "  created"
else
  echo "  present"
fi
echo "== sampler -> const 1 in every jaeger-config.yml ConfigMap"
$K get cm -o json > /tmp/social-cms.json
python3 - "$NS" <<'PY'
import json, re, subprocess, sys
ns = sys.argv[1]
for item in json.load(open("/tmp/social-cms.json"))["items"]:
    y = (item.get("data") or {}).get("jaeger-config.yml")
    if not y:
        continue
    y2 = re.sub(r'type: *"?probabilistic"?', 'type: "const"', y)
    y2 = re.sub(r"param: *[0-9.]+", "param: 1", y2)
    if y2 == y:
        continue
    patch = json.dumps({"data": {"jaeger-config.yml": y2}})
    subprocess.run(["kubectl", "--context", "kind-kind", "-n", ns, "patch", "cm", item["metadata"]["name"], "--type=merge", "-p", patch], check=False, capture_output=True)
    print("  patched", item["metadata"]["name"])
PY
echo "== restart application deployments"
for d in $($K get deploy -o name | grep -vE "mongodb|memcached|redis|jaeger"); do $K rollout restart "$d" >/dev/null; done
$K rollout status deploy/compose-post-service --timeout=240s | tail -1
sleep 90
echo "== compose-post OTLP exporter errors in last 50 log lines: $($K logs deploy/compose-post-service --tail=50 2>/dev/null | grep -ciE 'DNS resolution|UNAVAILABLE')"
echo "== collector accepted spans by receiver"
POD=$(kubectl --context kind-kind -n observe get pod -l app-name=otel-collector -o jsonpath='{.items[0].metadata.name}')
timeout 60 kubectl --context kind-kind -n observe debug -q -i "$POD" --image=busybox:1.36 --target=otel-collector -- wget -qO- http://127.0.0.1:8888/metrics 2>/dev/null | grep -E '^otelcol_receiver_accepted_spans' | sed 's/{[^}]*receiver="\([a-z/]*\)"[^}]*}/ \1 /'
