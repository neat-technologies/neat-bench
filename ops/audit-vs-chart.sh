#!/usr/bin/env bash
# audit-vs-chart.sh — read-only. Renders the otel-demo chart at the pinned version with the
# release's own values, then compares every live Deployment in otel-demo against the render:
# init containers, probe ports, memory limits, images, nodeSelector. Prints only divergences.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
NS=otel-demo
W=$(mktemp -d)
echo "=== release + chart version ==="
helm list -n $NS --no-headers 2>&1 | awk '{print $1, $8, $9, $10}'
helm get values $NS -n $NS -o yaml > "$W/values.yaml" 2>/dev/null || echo "{}" > "$W/values.yaml"
echo "values: $(tr -d '\n' < "$W/values.yaml" | head -c 80)"
helm template $NS open-telemetry/opentelemetry-demo --version 0.36.4 -n $NS -f "$W/values.yaml" > "$W/render.yaml" 2> "$W/render.err" || { echo "RENDER FAILED"; head -5 "$W/render.err"; exit 1; }
kubectl create --dry-run=client -o json -f "$W/render.yaml" > "$W/render.json" 2>/dev/null
kubectl -n $NS get deploy -o json > "$W/live.json"
kubectl -n $NS get deploy email frontend valkey-cart fraud-detection -o json --show-managed-fields > "$W/mf.json"
cat > "$W/audit.py" <<'PY'
import json,sys
def load_multi(path):
    txt=open(path).read(); dec=json.JSONDecoder(); i=0; out=[]
    while i < len(txt):
        while i < len(txt) and txt[i].isspace(): i+=1
        if i>=len(txt): break
        o,j=dec.raw_decode(txt,i); out.append(o); i=j
    return out
def flatten(docs):
    items=[]
    for d in docs:
        items += d.get("items",[]) if d.get("kind")=="List" else [d]
    return items
r=flatten(load_multi(sys.argv[1])); l=flatten(load_multi(sys.argv[2])); mf=flatten(load_multi(sys.argv[3]))
print("=== managedFields owners of the suspect fields ===")
for o in mf:
    n=o["metadata"]["name"]
    for m in o["metadata"].get("managedFields",[]):
        f=json.dumps(m.get("fieldsV1",{}))
        tags=[t for t in ("initContainers","livenessProbe","readinessProbe","f:limits","nodeSelector") if t in f]
        print("  %-16s mgr=%-28s op=%-7s t=%s has=%s" % (n, m.get("manager"), m.get("operation"), (m.get("time") or "")[:19], tags))
R={i["metadata"]["name"]:i for i in r if i.get("kind")=="Deployment"}
L={i["metadata"]["name"]:i for i in l if i.get("kind")=="Deployment"}
def probe(p):
    p=p or {}
    return p.get("httpGet",{}).get("port") or p.get("tcpSocket",{}).get("port") or p.get("grpc",{}).get("port") or "-"
def sig(d):
    s=d["spec"]["template"]["spec"]; c=s["containers"][0]
    return {
      "init":[(ic.get("name"), " ".join((ic.get("command") or [])+(ic.get("args") or []))[:50]) for ic in s.get("initContainers",[])],
      "live":probe(c.get("livenessProbe")), "ready":probe(c.get("readinessProbe")),
      "mem":((c.get("resources") or {}).get("limits") or {}).get("memory","-"),
      "image":c.get("image","").split("@")[0],
      "nodeSel":s.get("nodeSelector") or {},
      "replicas":d["spec"].get("replicas",1),
      "nenv":len(c.get("env") or []),
    }
print("=== live vs chart divergences (Deployments) ===")
print("chart deployments=%d live deployments=%d" % (len(R), len(L)))
print("only-live:", sorted(set(L)-set(R)), " only-chart:", sorted(set(R)-set(L)))
for n in sorted(set(L)&set(R)):
    a,b=sig(L[n]),sig(R[n]); diff={k:(a[k],b[k]) for k in a if a[k]!=b[k]}
    if diff: print("  %s: %s" % (n, "; ".join("%s live=%s chart=%s" % (k,v[0],v[1]) for k,v in diff.items())))
PY
python3 "$W/audit.py" "$W/render.json" "$W/live.json" "$W/mf.json"
echo "=== render kept at $W ==="
