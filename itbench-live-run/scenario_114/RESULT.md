# scenario_114 — Service/product-catalog DELETED — SKIPPED (weak RCA fit)
groundtruth: Service product-catalog (ns otel-demo)
Finding: deletion => graceful degradation (empty product lists), near-zero error spans; all callers Running, no incidents.
Only reliable signal = kubectl get svc (product-catalog absent) — equal for both arms. NEAT stale-edge threshold > observation window.
CATEGORY: metric-only/graceful-degradation. NEAT structurally neutral (k8s-object fault, no trace symptom). Not discriminating -> skipped.
