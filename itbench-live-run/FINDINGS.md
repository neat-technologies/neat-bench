# ±NEAT on live ITBench (SRE) — BenchOps findings [LIVING DOC, run in progress 2026-08-23]

## Question
Does an AI agent using NEAT's fused code+runtime graph diagnose real incidents faster/more-directly than the same agent without it? Controlled ± experiment on a LIVE KinD cluster running the OpenTelemetry Astronomy Shop, faults from ITBench's own catalog, NEAT installed as the published package (neat.is@0.9.2) fused via the demo's OTel collector.

## Method (control variables)
- One cluster, one fault at a time. Faults injected by ITBench's OWN injector (`make inject-scenario-faults`), graded vs its `groundtruth.yaml` k8s entity.
- Arms = fresh Claude subagents, SSH in, DIAGNOSE-ONLY, identical symptom prompt. Vary ONE thing: signal access.
  - **obscode** = kubectl + source (~/opentelemetry-demo, tag-matched). **neat** = obscode + NEAT graph (`neat ask/root-cause/incidents/divergences/... --project default`).
- Metric: correctness (names the right k8s object + misconfig) + ssh-command count (directness).
- Harness discipline (hard-won): targeted revert (rollback ONLY the mutated deployment; cheap applies for svc/configmap/netpol/secret) so no cross-scenario contamination and no mass-restart noise; observe HEALTHY baseline THEN inject (so NEAT sees the transition); clean incident window per scenario.

## Results so far (all CORRECT unless noted; lower cmds = better)
| scenario | fault class | neat | obscode | winner |
|---|---|---|---|---|
| 16 shipping QUOTE_ADDR | trace-visible dependency | 4 | 7 | **neat** |
| 30 ad Service targetPort | trace-visible routing | 2 | 4 | **neat** |
| 34 valkey --requirepass | datastore auth (CONNECTS_TO) | 5 | 7 | **neat** (despite #1075) |
| 24 checkout KAFKA_ADDR | silent config (async, not trace-visible) | 3-4 | 3 | tie |
| 2 cartFailure flag | feature-flag ConfigMap | 5 | 4 | tie |
| 20 product-catalog bad image | pod-down (KubePodNotReady) | 3 | 3 | tie |
| 43 frontend dnsPolicy=Default | self-config (DNS) | 12 | 5 | obscode (#1075) |
| 31 frontend-ingress NetworkPolicy | connectivity block | (running) | (running) | - |

## Finding: WHERE NEAT pays off
NEAT roughly HALVES diagnostic steps when the ROOT is far from the SYMPTOM and requires topology reasoning (16/30/34: root-cause traversal jumps symptom->origin; obscode must correlate the call chain by hand). NEAT is NEUTRAL when the symptom already sits at the fault or the alert names the workload (24/2/20). It is localization-assist on ITBench (ground truths are k8s objects NEAT doesn't model; NEAT points at the service, the agent's kubectl names the object).

## NEAT bug found by the benchmark -> filed + fixed
**#1075** get_root_cause blames load-generator on datastore/self-config faults: the victim/load-origin navigation (ADR-189/190, traverse.ts:1549) overrides the correct seed verdict; isVictimSeed reads only inbound saturation, never the node's failing OUTBOUND dependency (isFailingCallEdge is CALLS-only, missing CONNECTS_TO). Cost the neat arm the loss on 43 and inflated 34. Fix = PR **#1076** (hasFailingOutbound gate). ADR (amends 189/190) + contract note pending on the PR. RE-RUN 34/43 after #1076 ships to latest.

## Confounds found + fixed (methodology log)
- kubectl apply --server-side does NOT remove injected added-args/secrets (owned by ITBench's field manager) -> contamination 34->43. Fixed: targeted rollout-undo of the mutated deployment + delete non-baseline secrets.
- Injected secret self-poisoned the baseline names list when captured non-pristine. Fixed: capture from true pristine.
- replace-force ALL deployments floods NEAT with flagd reconnection errors (425) that swamp the fault. Fixed: targeted revert (<=1 deployment ever restarts).
- Ambient flagd-ui OOM -> intermittent ad/recommendation DEADLINE_EXCEEDED noise, present in baseline, both arms dismiss it (fair confound).

## Scope / pending
67 ITBench SRE scenarios; 62 target otel-demo (runnable), 5 target bookInfo (not deployed, skipped). ~18 chaos-mesh Schedule faults (intermittent, caveated). Continuing across the taxonomy. This doc consolidates to neat-bench (BenchOps home) with its own ADRs/contracts; NOTHING bench goes on neat-technologies/neat.
