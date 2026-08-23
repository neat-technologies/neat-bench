# ITBench ±NEAT suite — run order (value-first)
# arms per scenario: neat vs obscode (identical toolkit ± NEAT graph), diagnose-only, live cluster
# grade: ROOT CAUSE line vs groundtruth.yaml k8s entity; metric: correctness + ssh-command count

A trace-visible dependency/propagation (NEAT home turf):  16* 27 30 36 43 114 34
B chaos stress/latency/loss (trace-visible resource):     21 22 25 61 62
C feature-flag ConfigMaps (gt=flagd-config):              1* 2 3 12
D istio / network policy:                                 31 47 48 50 51
E pod-down / infra (expected all-arms ties):              20 23 33 38 39 40 41 42 44 45 46 49 52 53 56 58 59 63 105 102 30 114
F scheduled-chaos replicas:                               80 81 83 91

* = already done (16: neat 4/correct; 1: earlier neat 9<obscode 12<obs 18)

## APP MAP (2026-08-23 discovery)
otel-demo (NEAT instrumented) = runnable. bookInfo (NOT deployed) = SKIP: 36,47,48,50,53.
Chaos-mesh faults (17,18,19,21,22,25,26,27,29,35,54,55,61,62,80,81,83,91) = intermittent + Schedule-gt = CAVEATED class, deprioritized.
Clean direct otel-demo run set: 1*,2,3,4,5,6,7,8,10,11,12,13,14,15 (flags); 16*,24* (env); 30* (svc port),114 (svc del),34 (valkey pw); 43 (dns),31 (netpol); 20,23,56,57 (image); 33,39 (node); 38 (hpa); 40 (valkey oom); 41,46,52,102 (resources); 42 (preempt); 44 (anti-affinity); 45,59,60 (init); 49 (probe); 58 (scale0); 63 (secret); 105 (bad cmd); 51 (api surge).
DONE: 24(neat3-4/obs3) 16(neat4/obs7) 30(neat2/obs4). [1 earlier: neat9/obs12/obsonly18]
