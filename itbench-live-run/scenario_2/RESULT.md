# scenario_2 — ConfigMap/flagd-config cartFailure flag on (feature-flag class, trace-visible)
groundtruth: ConfigMap flagd-config; symptom: cart intermittently failing add-item
| arm | ssh cmds | verdict | note |
|-----|----------|---------|------|
| neat    | 5 | CORRECT | root-cause cart->flagd, verified flagd-config vs source |
| obscode | 4 | CORRECT | pods (flagd-ui OOM red herring)->flagd-config->source |
VERDICT: both correct; neat 5 ~= obscode 4 (TIE). Flag class = NEAT-neutral (symptom already at cart).
