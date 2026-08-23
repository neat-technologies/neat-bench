# scenario_43 — Deployment/frontend dnsPolicy: Default (SELF-CONFIG / DNS fault) [clean re-run; 1st run contaminated by 34 leak]
groundtruth: Deployment frontend; symptom: frontend gRPC UNAVAILABLE "Name resolution failed" on ALL backends
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| obscode | 5  | CORRECT | frontend logs -> name-resolution errors -> dnsPolicy Default vs ClusterFirst |
| neat    | 12 | CORRECT | root-cause MISLED (product-catalog 0.18 + load-generator, #1075); arm distrusted NEAT + over-investigated (test-pod DNS checks across ~7 backends) |
VERDICT: **NEAT LOST 12 > 5.** Cause: #1075 misleading root-cause + arm over-investigation. Self-DNS is a hard class (node fails ALL outbound). RE-RUN after #1075 ships.
