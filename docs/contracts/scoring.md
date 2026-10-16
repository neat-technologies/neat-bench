---
name: Scoring and grader validity
description: What RCI, RCR, CAUGHT and RESOLVED mean, what a grader must pass before its output is a result, and the controls that run beside every scored run.
governs:
  - "bench/grader/*"
  - "bench/scoring/*"
  - "bench/verifier/*"
  - "*/grade*.sh"
  - "*/grade*.mjs"
  - "*/verify*.sh"
  - "*/oracle*.sh"
  - "*/validate-oracle*.sh"
  - "*/pass2pass*.sh"
  - "*/SCORING.md"
  - "*/*ground-truth*.tsv"
status: Accepted
---

# Scoring and grader validity

Status: **Accepted** (ADR-002, ADR-005; Deniz, 2026-10-16). The headline grader's form (structured answer versus negation-aware text) is open in ADR-002; rule 2 below governs the regrade path and any text grading, and the first consumer run's headline waits on the ruling.

## Definitions

These restate `CONTRACT.md` clause 4 and `praxis-rca/SCORING.md` §1 to §3; a change here needs an ADR.

- **RCI**: the faulty service is named. Exact match to the ground-truth entity.
- **RCR**: the faulty statement, function or config key is named. Canonicalised match to the ground-truth location; test files excluded.
- **CAUGHT** (detect legs only): RCI and the right fault nature, as a closed class per scenario.
- **SYMPTOM_CLEARED**: the scenario's pre-registered fault signal returns to its clean baseline under the same user-flow load and stays there for a full window.
- **F2P**: the scenario's FAIL_TO_PASS test passes on the agent's patch (code faults).
- **NO_REGRESSION**: the pass-to-pass suite for the other core flows still passes and the fix retains no behaviour absent from the fault-free reference.
- **SAFETY**: newly built image digest, replicas at least one, no scale-to-zero, no stock-image revert, no deletion of the failing path, the re-fired trigger does not reproduce the symptom, data intact.
- **RESOLVED**: RCR and SYMPTOM_CLEARED and F2P and NO_REGRESSION and SAFETY (ADR-005). `RESOLVED=YES` with `RCR=NO` is rejected at write time. There is no separate ROBUST metric; the legacy `robust` column is what RESOLVED means here.
- **VOID**: the run is not a data point (run-validity contract). A VOID is never a miss.

Command or tool count is not a metric and is never reported as a win or loss (`CONTRACT.md` clause 8).

## Rules

1. **A grader is validated before its output is a result.** For every scenario it grades, at the exact version used for the run, the grader passes the committed negative-control suite: correct answer (pass), pure wrong cause (fail), negated true cause (fail), "unknown" with the cause word present (fail), wrong service with the right cause (RCI fail), a list of several candidate causes (fail), plausible-but-wrong patch (RESOLVED fail). The suite runs in CI and before every regrade. A grader that has not passed it is a development tool, not an instrument.
2. **No credit for hedged or listed answers.** An answer that names several causes, or names the true cause inside a negation or a hedge, scores as wrong. Equivalent expressions of the same cause score as right; the equivalence set is committed per scenario, not improvised at grading time.
3. **No LLM judge in any headline metric.** RCI, RCR, CAUGHT and RESOLVED are decided by scripts against committed ground truth and oracles. A model may annotate a run for failure-mode analysis; its output never changes a score. If a judge is ever used for a secondary metric, it is calibrated against at least 100 human-labelled samples from at least two labellers, the agreement statistic is published, and its version is frozen for the run.
4. **Three controls run beside every scored run** and are published with it: the no-fault control scenarios (false-positive rate), the trivial agents (always "unknown"; always the most common culprit), and the oracle agent (must score 100% RESOLVED on every scenario). A scenario the oracle cannot resolve is not in the battery.
5. **Grade at the substrate's grain and label the bound** (`CONTRACT.md` O4). Every scenario carries `obs_class` (error-observable, fast-fail-observable, hang-emit-nothing); an emit-nothing hang is a substrate bound, not a NEAT defect, and the grader keys on the class.
6. **Regrades are records.** When a grader changes, every historical answer is regraded through the new version, the before and after are published, and the TSV carries a `regrade_reason` per changed row (results-records contract). The old totals are deleted or version-labelled (claims contract, rule 9). A grader problem found after a run is a regrade, never a VOID.
7. **The fix oracle, the FAIL_TO_PASS test and the fault signal are pre-registered and frozen** before the first scored window of a run (`praxis-rca/SCORING.md` §6). Changing any of them mid-run voids the run. The verifier and oracle scripts this contract governs are those instruments.

## Why

The 15 October audit reproduced a keyword-presence grader that passed four negated or "unknown" answers and had graded every historical CAUGHT total (ADR-002). The same failure class forced public corrections of τ-bench and SWE-bench Verified, and the Agentic Benchmark Checklist names it (O.b.1). "Alert cleared" verifiers in the open SRE benches accept symptom suppression, and the October split of RESOLVED from "regression-free" let an amputating fix count, which is why RESOLVED here is one conjunction decided by the application recovering under traffic, a test, a regression suite and a safety gate, never by a judge (ADR-005).
