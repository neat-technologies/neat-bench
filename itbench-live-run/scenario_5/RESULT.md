# scenario_5 — ConfigMap/flagd-config adFailure=on (feature-flag; CLEAN flagd, flagd-ui removed)
groundtruth: ConfigMap flagd-config; neat 4 ~= obscode 3 TIE. First clean flag test (flagd-ui removed) -> no PROVIDER_NOT_READY noise, neat NOT inflated. Confirms flag class = tie. (3/4 were flagd-ui-confounded losses, re-run candidates.)
