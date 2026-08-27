#!/usr/bin/env bash
# stabilize-cluster.sh — one-time environment repair for the ±NEAT suite (DISCLOSED).
# ─────────────────────────────────────────────────────────────────────────────
# Two confounders were found on the box and fixed here, in the open:
#
#  1. The OTel Demo's built-in `load-generator` (Locust) was running, driving
#     continuous synthetic traffic to the whole storefront. That overlaps every
#     verify measurement and saturates the recommendation worker pool (workers=10),
#     exactly the confound the harness's load-isolation exists to avoid. We supply
#     our OWN controlled load only during the agent phase (run-suite start_load), so
#     the built-in generator must be OFF. -> scaled to 0.
#
#  2. `product-catalog` (memory limit 20Mi) and `frontend` (250Mi) were chronically
#     OOMKilled (49 / 54 restarts). A crash-looping HEALTHY dependency makes the
#     regression probe (product-catalog 200s) meaningless and confounds every verify
#     — a known-good gold fix scored RESOLVED=NO with product-catalog 0/4 until this
#     was fixed. NONE of the PRAXIS faults (401/405/410/412) live in these services;
#     they are healthy deps. Bumping their memory is environment repair, NOT a fix to
#     any graded fault. Disclosed here so it is on the record, never smoothed over.
#
# After this, product-catalog is 4/4 in every verify and the gold fixes score YES.
# Run once after the cluster is up (idempotent).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
NS=otel-demo

echo "[stabilize] scaling built-in load-generator to 0 (harness supplies controlled load)"
kubectl scale deploy/load-generator -n $NS --replicas=0

echo "[stabilize] raising memory limits on OOM-prone HEALTHY request-path deps"
kubectl set resources deploy/product-catalog -n $NS --limits=memory=256Mi
kubectl set resources deploy/frontend         -n $NS --limits=memory=512Mi
kubectl set resources deploy/currency         -n $NS --limits=memory=128Mi
kubectl set resources deploy/checkout         -n $NS --limits=memory=128Mi
kubectl set resources deploy/quote            -n $NS --limits=memory=128Mi

for d in product-catalog frontend currency checkout quote; do
  kubectl rollout status deploy/$d -n $NS --timeout=120s
done
echo "[stabilize] done — deps stable, load-generator off"
