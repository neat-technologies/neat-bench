# scenario_3 — ConfigMap/flagd-config adHighCpu=on (feature-flag / CPU)
groundtruth: ConfigMap flagd-config
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| obscode | 3 | CORRECT | pods->flagd-config->adHighCpu on |
| neat    | 6 | CORRECT | root-cause ad->flagd (0.18, noisy from flagd-ui OOM); cross-verified via AdService.java:172 + ruled out flagd-ui -> extra work |
VERDICT: **NEAT LOST 6 > 3.** Over-investigation + flagd-ui ambient noise. (Like 43: kubectl-obvious service-named fault -> NEAT localization+cross-check inflates.) flagd-ui still OOM at 512Mi.
Also: flagd-config baseline DIRTY (cartFailure/loadGen leftover on) — arms still isolated adHighCpu correctly.
