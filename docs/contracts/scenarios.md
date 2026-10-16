---
name: Scenario inventory
description: What is in the battery, where each scenario comes from, what its RESOLVED means, and how a scenario is added.
governs:
  - "bench/scenarios/*"
  - "*/SCENARIOS.md"
  - "*/INTEGRATION.md"
  - "*/fullsuite-catalog.tsv"
  - "*/catalog*.tsv"
  - "*/ground_truths*.json"
status: Accepted
---

# Scenario inventory

Status: **Accepted** (ADR-006; Deniz, 2026-10-16). The per-scenario tables live in `praxis-rca/SCENARIOS.md` for the PRAXIS set and in `bench/scenarios/` (proposed layout, ADR-001) for every absorbed set; this contract says what those tables must carry and where the battery comes from.

## The battery

| set | origin | licence (verified on the repository, 2026-10-16) | count | RESOLVED signal | runtime and telemetry | status |
|---|---|---|---|---|---|---|
| SREGym, full suite | UIUC | MIT | 90 problems, 10 applications | SREGym mitigation oracle; reported as mitigation until the ADR-005 gates 3 to 5 exist per problem | live self-managed Kubernetes; Prometheus, Loki, Jaeger via MCP | primary external yardstick; NEAT must be verified end-to-end on each application first |
| PRAXIS code faults 401 to 416 | IBM/UIUC, DSN 2026 artifact, Zenodo record 19247887 (DOI 10.5281/zenodo.19163486) | Apache-2.0 | 16 (13 wired; 402 to 404 to wire) | ours: FAIL_TO_PASS test + fault signal + safety gate per fault (ADR-005); PRAXIS itself grades RCI/RCR only | OpenTelemetry demo on kind, live OTel | code-grain headline leg |
| PRAXIS flagd and chaos/manifest | same artifact | Apache-2.0 | 9 + 5 | config or operational remediation only | same | draw-class for fusion; flags public, likely contaminated; 20 and 32 wired |
| ITBench SRE | IBM, checkout 8949d5b on the box | Apache-2.0 | 67 scenarios exposed by the checkout (wired as ITBench-67 in `competitive-rca`) | alert cleared (mitigation) until gated | live, OpenTelemetry demo + Grafana stack | continuity; independent leaderboard |
| ORCA-bench | Traversal / Cornell / Columbia | not yet verified at entry | 884 incidents + 195 no-fault controls from 11 flags | detect leg only on the recording; RESOLVED possible by re-injecting the flags live | six days of recorded telemetry, full source | detect leg at large n; controls design adopted |
| SWE-style static (SWE-bench Live, Multi-SWE-bench) | Microsoft, ByteDance | MIT, Apache-2.0 | subset | FAIL_TO_PASS and PASS_TO_PASS | none; OBSERVED is inert | non-regression control only; not yet entered |

Excluded for RESOLVED and why: offline localisation sets (OpenRCA, RCAEval, RCA100, LEMMA-RCA, Cloud-OpsBench) have no system to run, and replay is not live; Defects4J, BugsInPy, GitBug-Java, AgentIssue-Bench, Commit0, TheAgentCompany are static or off-target; RepoBench, CrossCodeEval, LiveCodeBench by construction; SWE-rebench is a dataset without a repository to verify. The register with sources is `docs/research/bench-research-2026-10-16.md`.

## Rules

1. **No self-authored faults** (`CONTRACT.md` clause 7). Every fault comes from a third-party artifact with a public ground truth. A FAIL_TO_PASS test or a fault signal we write for a third-party fault is an oracle, not a fault. "Diagnosis only" in the table means the source ships no fix verifier, never that the bug cannot be fixed.
2. **Every scenario row carries**: id, origin set, target application and service, `fault_box` (strict-code | strict-runtime | both | fusion), `strength` (strong | weak | control), `obs_class`, bootstrap yes/no, the fault in one sentence, the ground-truth location, the fault signal, the fix the oracle looks for, the contamination statement, the NEAT extraction depth for the service's language at the pinned version, and whether it is held out.
3. **A bench enters only with its licence verified on its repository** and recorded above; a "from memory" licence is not a record.
4. **Weight the battery toward fusion-decisive classes** and label single-span-to-one-line faults as controls (`CONTRACT.md` clause 6, task selection). The inventory states the count per box and per strength so a reader can see what the aggregate is made of.
5. **The oracle agent passes every scenario in CI** (scoring contract, rule 4) before the scenario counts.
6. **Classes where runtime context cannot matter are declared as nulls** in the inventory before a run (experiment-design contract, rule 8).
7. **Mitigation is not resolution.** An absorbed scenario whose only verifier is "alert cleared" or "system healthy" is reported under mitigation until the ADR-005 gates exist for it.
8. **No NEAT-effect number for an application NEAT is not verified on.** An application enters the scored battery only after NEAT is shown end-to-end on it (nodes, fused OBSERVED edges on real spans, the daemon live under the preflight); until then its scenarios run as development only.

## Why

The audited suite wired 15 of PRAXIS's 30, concentrated 13 of them on one service, and had two fusion-decisive scenarios; ADR-004 shows that battery size, not repeats, decides what effect the bench can see, and ADR-006 says where the growth comes from.
