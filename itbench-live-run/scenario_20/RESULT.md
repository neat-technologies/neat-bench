# scenario_20 — Deployment/product-catalog nonexistent image (POD-DOWN / metric class)
groundtruth: Deployment product-catalog (image quay.io/it-bench/hello-bench-invalid:1.0.0); alert KubePodNotReady
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| neat    | 3 | CORRECT | kubectl describe -> ImagePullBackOff -> bad image; NEAT not needed |
| obscode | 3 | CORRECT | same |
VERDICT: neat 3 = obscode 3 TIE. Pod-down/KubePodNotReady = kubectl-obvious, NEAT neutral (alert names workload).
