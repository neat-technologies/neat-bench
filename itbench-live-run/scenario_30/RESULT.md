# scenario_30 — Service/ad targetPort 9999 (TRACE-VISIBLE service-routing fault)
groundtruth: Service ad; symptom: ad gRPC DEADLINE_EXCEEDED
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| neat    | 2 | CORRECT | root-cause->ad, 1 kubectl confirmed Service targetPort 9999 black-hole |
| obscode | 4 | CORRECT | pods->endpoints->service->source; ruled out flagd-ui |
VERDICT: both correct; NEAT 2 vs obscode 4 (half). Fusion-decisive.
