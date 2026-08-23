# scenario_16 — Deployment/shipping QUOTE_ADDR=quote:0000 (TRACE-VISIBLE dependency fault)
groundtruth: Deployment shipping (ns otel-demo); symptom: checkout HTTP 504
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| neat    | 4 | CORRECT | root-cause service:checkout -> shipping in 1 query; caught frontier:unknown dead-port divergence (353/353 err) |
| obscode | 7 | CORRECT | hand-traced proxy->frontend->checkout->shipping->quote via main.go+quote.rs+manifest; ruled out flagd/checkout/cart |
VERDICT: both correct; NEAT 4 vs obscode 7 = 43% fewer commands. Fusion-decisive (trace-visible dependency).
