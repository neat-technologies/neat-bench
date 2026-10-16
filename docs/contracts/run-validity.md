---
name: Run validity
description: When a run is a data point. The clean-cluster launch gate, the preflight before every scored window, VOID semantics, pre-registered exclusions, and the report every window writes.
governs:
  - "bench/harness/*"
  - "ops/*"
  - "*/preflight*.sh"
  - "*/run-*.sh"
  - "*/hard-reset*.sh"
  - "*/verify-baseline*.sh"
  - "*/audit-vs-chart*.sh"
  - "*/stabilize*.sh"
  - "*/neat-restand*.sh"
  - "*/setup-scenario*.sh"
  - "*/setup-divergence*.sh"
  - "*/create-pristine*.sh"
  - "*/repin*.sh"
  - "*/worker*.sh"
status: Accepted
---

# Run validity

Status: **Accepted** (Deniz, 2026-10-16) for rules 1 and 3 to 9, which restate `CONTRACT.md` O1 to O3 and O5 and add the launch gate and the per-window report. Rule 2 (the reset method) follows ADR-003, which is Proposed; until ruled it applies as the stricter reading, and the audit in rule 1 is the gate regardless of how the cluster got clean.

## Rules

1. **A run launches only on a cluster proven clean against the chart.** Before the first scored window, a read-only audit (`ops/audit-vs-chart.sh`) diffs every live deployment against the pinned chart rendering (init containers, probe ports, resource limits, images, node selectors, replicas, env) and shows only the documented deltas; the stray-fault preflight is empty; no leftover workloads from a previous leg exist in any namespace. The audit output is written to the run directory. A storefront that answers is not evidence of clean (the 15 October `CLEAN=YES` was reported over two live faults).
2. **A reset removes what an injector added** (pending ADR-003). The reset brings each deployment to the rendering by a method that removes fields regardless of field-manager ownership (`kubectl replace`, or a JSON patch deleting the injected path). Server-side apply, client-side apply and helm upgrade do not count as a reset; they leave fields owned by the injector in place.
3. **Preflight immediately before every scored window** (`CONTRACT.md` O1 to O3): the daemon is live and has ingested real OBSERVED edges for the target; the no-NEAT arms' read-root carries zero NEAT artifacts and the `code` arm's PATH excludes `neat` and `kubectl`; the incident store is empty; the prior fault is fully reverted; the rollout is settled; no non-target service is scaled to zero or unready. A breach writes VOID for that window.
4. **VOID is not a miss** (`CONTRACT.md` O5). A truncated or budget-exhausted agent, a preflight breach, a daemon that died mid-window, or a cluster that changed under the agent writes `VOID` with a `void_reason`. VOID rows stay in the TSV and are counted in the published funnel; they are never silently dropped and never scored as a failure. A grader problem found afterwards is a regrade (scoring contract, rule 6), not a VOID.
5. **Exclusions are pre-registered.** Any rule that removes a scenario or a run from an aggregate is committed before the run starts, with its reason. A post-hoc exclusion is reported as such, with the aggregate shown both ways.
6. **Confounds are recorded, never hidden.** Every row carries a `confounds` column (results-records contract): cluster age, load during verification, sampling, turn budget, any manual intervention. Empty is a valid value; absent is not.
7. **One fault, one cluster, one window.** A cluster carries one injected fault at a time; all arms and models for that window run against it in parallel; the next fault is injected only after the reset and audit of rules 1 and 2 pass again.
8. **Every window is reproducible from its record.** The run directory holds the manifest (results-records contract), the audit and preflight outputs, the injected scenario id and parameters, each arm's answer and trajectory, and the verifier output. A window missing any of these is VOID.
9. **Every window writes a report, and every NEAT weakness is filed** (`CONTRACT.md` clauses 1 and 2). The report names the scenario, the arms, the outcome per arm, the confounds, and any NEAT weakness, bug or misdirection seen; each weakness becomes an issue on the core repository, fixed and shipped before the affected scenarios are re-run. Not "note it and move on".

## Why

The 14 October clean re-run voided 100 of 100 PRAXIS rows because the cluster was dirty at launch; the preflight did its job and the launch gate did not exist. On 16 October two injected fields were found live on the cluster that every reset since 14 October had "cleaned", because server-side apply never prunes another manager's fields and the baseline check did not look at the fields that carried them (ADR-003, evidence at `docs/research/2026-10-16-cluster-audit.md`). A run that trips any rule above is confounded before it is scored, and a confounded number is worse than no number.
