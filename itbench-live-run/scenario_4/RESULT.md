# scenario_4 — ConfigMap/flagd-config productCatalogFailure=on (feature-flag, shared dep)
groundtruth: ConfigMap flagd-config
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| obscode | 5 | CORRECT | survey -> ruled out flagd-ui OOM -> flagd-config productCatalogFailure on |
| neat    | 7 | CORRECT | NEAT localized product-catalog, but flagd Ready=False (flagd-ui OOM) -> PROVIDER_NOT_READY noise -> extra cross-checking |
VERDICT: NEAT LOST 7 > 5. SYSTEMIC CONFOUND: flagd-ui OOMs at any limit -> flagd Ready=False -> NEAT flagd signal noisy -> inflates neat on ALL flag scenarios. Removing flagd-ui sidecar for scenarios 5-15.
