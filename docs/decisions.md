# neat-bench decisions

Architecture and method decisions, as ADRs. A contract cites the ADR that settled it; a rule with no ADR is Proposed. An ADR records a decision whose evidence already holds. Nothing below is settled until its status says so; Proposed means it is waiting for Deniz's ruling and lists the options.

Numbering is independent of the neat core decision log.

---

## ADR-001: Bench layout

**Status:** Proposed
**Date:** 2026-10-15

**Context.** The repo carries three generations of harness (`praxis-rca/`, `competitive-rca/`, `harness/` build-autonomy) plus live-run notes. The 15 October evidence audit pinned its findings to commit `6c7b0b6` and cites file paths and line ranges in those directories. A consumer-ready bench needs a clean place to be built against the contracts without inheriting the defects the audit reproduced, and the audited evidence needs to stay where the audit's links point.

**Options.**
- A. Build the new bench in a clean `bench/` subtree. Leave the earlier generations in place, frozen, with a one-line README in each saying they are evidence at the audited commit and are not maintained. Audit links stay valid; no churn.
- B. Move the earlier generations under `legacy/`. Cleaner tree; breaks every link in the audit's source register and in any external reference.
- C. New repository. Cleanest break; splits the evidence trail across two repos and loses the public history that makes the audit checkable.

**Recommendation.** A. The audit's checkability is an asset; keeping its links valid costs nothing.

**Consequences.** Contracts govern `bench/**` and the outward docs. Legacy directories are never edited except to add the frozen notice.

---

## ADR-002: A grader is validated before its output is a result

**Status:** Proposed
**Date:** 2026-10-15

**Context.** The published detection grader (`praxis-rca/harness/grade-detect.sh`) is a keyword-presence matcher. Four negative controls submitted on 15 October 2026 (an answer explicitly denying the true cause; "unknown" with the cause word present; "unavailable, cannot determine why"; a wrong cause with the true one negated) all returned `CAUGHT=YES`. Every historical CAUGHT total and the competitive 19/20 were produced by it. The defect is precise: any mention of the true-cause words passes, even negated or hedged, and several keyword sets are broad enough to match a bare `config` or `unavailable`.

**Decision (proposed).** No grader produces a published number until it passes a committed negative-control suite for every scenario it grades, at the exact version used for the run. The suite is: correct answer (must pass), pure wrong cause, negated true cause, "unknown" with the cause word present, wrong service with the right cause, plausible-but-wrong patch. The suite runs in CI and before every regrade.

**Options for the headline grader.**
- A. Structured answer. The arm must emit a fixed schema (`SERVICE`, `CAUSE_CLASS` from a closed enum per scenario, `LOCATION`) and is graded by exact match. No free text is graded for the headline. Removes negation entirely; costs a prompt-format constraint on every arm.
- B. Negation-aware text grading plus the suite. Keeps free text; rejects a keyword hit inside a negated or hedged clause; tightens the broad sets. Cheaper to adopt; still a heuristic.
- C. LLM-as-judge with a held-out calibration set and reported agreement with human labels. Most flexible; adds a model to the measuring instrument, which must then be frozen and validated like any other.

**Recommendation.** A for RCI and cause class (the headline), B as the fast path during regrades, C only with published calibration. Whatever is chosen, every historical total is regraded through it and the before/after is published.

**Consequences.** The 19/20, the September totals, and the whitepaper numbers are not citable until regraded. The regrade is the first deliverable of the new bench.

---

## ADR-003: The clean baseline is derived from the chart, never snapshotted from a cluster

**Status:** Proposed
**Date:** 2026-10-15

**Context.** The baseline used by `hard-reset.sh` (`deploys-clean.json`) was captured from a running cluster on 14 October and carried injected faults: an `email` init container running `sleep infinity`, a `frontend` readiness probe on port 40, a `valkey-cart` reference to a secret the chart never creates. Hard-reset therefore applied faults while claiming to clear them, and the 14 October clean re-run voided every scenario because the cluster was dirty at launch. The collector-to-NEAT wiring lives in the `otel-collector` configmap, so a chart reinstall is not a safe reset either.

**Decision (proposed).** The clean state is defined as the pinned chart (`opentelemetry-demo` 0.36.4, app 2.0.1, no custom values) rendered by `helm template`, plus one documented, versioned patch for the collector-to-NEAT export. `hard-reset` reconciles the live cluster to that rendering per deployment (server-side apply, taking field ownership) and purges every deployment the chart does not define. A run may not launch until a preflight proves the live cluster matches the rendering and the stray-fault check is empty. The preflight result is recorded in the run directory.

**Options.**
- A. Reconcile per deployment from the rendering (as above). Keeps the daemon wiring; proven to recover a wrecked cluster on 15 October.
- B. Full `helm uninstall` and reinstall per run, then re-apply the collector patch. Guaranteed pristine; slower; one forgotten patch step silently blinds NEAT.

**Recommendation.** A, with B as the documented recovery path when A cannot converge.

**Consequences.** `deploys-clean.json` is retired. The preflight becomes a launch gate, not a per-scenario check only.

---

## ADR-004: Experiment design for a NEAT-effect claim, and the value of k

**Status:** Proposed
**Date:** 2026-10-15 (revised the same day with the literature and a pilot estimate)

**Context.** The September bench isolated nothing (Sonnet+NEAT vs Opus+source changes the model and the tool at once) but ran k=5 and recorded time. The October bench put both models on every arm (so the same-model comparison exists) and added ROBUST, but ran k=1, recorded no time, and its clean re-run produced no data. The effects this bench has actually observed are 10-15 points: +12.5 (Aug 27, same model, 7/8 vs 6/8), +15 (detect lift 16/20 to 19/20), -11 (Sept 13, 35/45 vs 40/45). The design has to be able to resolve an effect of that size, or it resolves nothing.

**What the literature says about k.**
- Miller, *Adding Error Bars to Evals* (Anthropic 2024, arXiv 2411.00640): the unit of inference is the question, not the run. With K resamples per question, Var = (ω² + E[σ²]/K) / n where n is the number of questions and ω² is the between-question variance; "once E[σ²]/K is small relative to Var(x), increasing K further will have little effect." Cluster standard errors when questions are related ("over 3x larger than naive"); use paired differences "wherever practicable." Power (Eq. 9): n = (z_α/2 + z_β)² (ω² + σ_A²/K_A + σ_B²/K_B) / δ².
- PRAXIS (arXiv 2512.22113), the upstream of this battery: "repeated each ⟨LLM, scenario⟩ experiment five times with distinct random seeds" on 30 scenarios (2,250 trajectories), mean ± dispersion.
- ITBench (arXiv 2502.05352): SRE scenarios run 10 times per scenario per model, pass@1 with standard error.
- METR (arXiv 2503.14499): 8 runs per agent-task pair, three-level hierarchical bootstrap over task families, tasks, runs.
- Bjarnason et al., *On Randomness in Agentic Evals* (arXiv 2602.07150): 10 runs x 6 configs on SWE-bench Verified; a single-run pass@1 moves 2.2-6.0 points by run choice, SD above 1.5 points even at temperature 0; "estimate pass@1 from multiple independent runs per task, especially when measuring small improvements," and set the run count by power analysis.
- *A Sober Look* (arXiv 2504.07086): for small benchmarks, at least ten seeds; variance "drops sharply for K >= 10."
- τ-bench (arXiv 2406.12045) and τ²-bench: pass^k, the chance all k trials succeed, at least 3-4 trials per task; reliability degrades sharply with k (gpt-4o retail pass^1 61%, pass^8 under 25%).
- Kapoor et al., *AI Agents That Matter* (arXiv 2407.01502): five runs per agent, t-based intervals, cost-controlled comparisons, and the warning that most benchmarks have no held-out set.
- SkillsBench and *Resolution Diagnostics for Paired LLM Evaluation* (ICML 2026): the task is the inference unit; trials aggregate to a task-level rate; paired bootstrap plus sign-flip permutation; treating trials as independent "would overstate precision," and the unpaired shortcut mis-sizes N by about two in close comparisons.

Observed practice therefore sits between k=3 and k=10, with the reliability-focused benchmarks (ITBench, METR, Sober Look) at 8-10 and the upstream PRAXIS at 5. Nobody serious reports k=1.

**What the math says for this battery.** Minimum detectable effect (80% power, two-sided 0.05, worst-case Bernoulli variance), from Miller's formula with the scenario as the unit:

| scenarios | k=3 | k=5 | k=10 | k=20 | floor (k→∞) |
|---|---|---|---|---|---|
| 15, ω²=0.02 | 31 pp | 25 pp | 19 pp | 15 pp | 10 pp |
| 30, ω²=0.02 | 22 pp | 18 pp | **14 pp** | 11 pp | 7 pp |
| 60, ω²=0.02 | 16 pp | 13 pp | 10 pp | 8 pp | 5 pp |

ω² is the between-scenario variance of the arm difference. A pilot estimate from the September k=5 data, after subtracting within-scenario sampling noise: **ω² ≈ 0.013 (SD ~12 pp) with across-arm correlation ρ ≈ +0.69** on the Sept 13 same-tier run (9 scenarios). The Sept 1 Haiku-vs-Opus run gives ω² ≈ 0.24 and ρ ≈ -0.26, which is the model confound, not the battery, and is excluded. The levels in that data came from the keyword grader and are suspect; the variance structure is what the estimate uses. ω² = 0.02 is the conservative plug-in.

Two conclusions follow. First, **the scenario count is the binding constraint**: at 15 scenarios the floor is 10 pp and reaching 15 pp needs k=20; repeats cannot buy what scenarios buy, and scenarios also buy generalisation. Second, **k=10 at 30 scenarios is the first cell that resolves the effect size this bench actually produces** (14 pp); k=5 at 30 scenarios (18 pp), the PRAXIS-matched design, resolves only a large effect. A sub-10 pp NEAT effect is not resolvable below roughly 60 scenarios and must not be promised.

**Decision (proposed).** A NEAT-effect claim requires, for the same model: three arms (source / source+raw runtime and deployment evidence / source+NEAT), both models, a battery of at least 30 scenarios with a held-out subset never used during development, per-run wall-clock and token categories recorded, and the grader of ADR-002. The scenario is the unit of inference. Analysis is paired by scenario with a hierarchical bootstrap (target, scenario, run) and reports the interval, never the point alone. pass^k is reported beside the mean pass rate. The run plan is adaptive: **k=5 on the full battery first** (PRAXIS-matched; 900 runs for the 3-arm, 2-model core), then **top up to k=10 on every comparison whose observed gap is inside its interval**, which is where Bjarnason and the resolution-diagnostics work say the repeats earn their cost. k=3 is for development and smoke only. k=1 is never a result.

**Options.**
- k for the first full run: 5 (proposed; PRAXIS precedent, Kapoor) or 10 outright (ITBench, Sober Look; 1,800 runs, roughly twice the cost and box time).
- Battery: 30 (all of PRAXIS, wiring 402-404 and the flagd set) or 60 (PRAXIS plus a second target system NEAT was not engineered against). The second is what resolves a 10 pp effect and is the test the core repo's own definition of success demands.
- Held-out source: the unwired PRAXIS scenarios held back, or the second target. The second is stronger.
- Competitor arms: inside the NEAT-effect design, or a separate comparison with its own weaker claims (proposed: separate).

**Recommendation.** Battery to 30 now and 60 as the headline target; k=5 first, k=10 top-up on close cells; competitors separate.

**Consequences.** The first full run is about 900 agent runs (roughly $45-450 depending on model mix, one to two box days with parallel arms); the top-up adds 300-600. Every published comparison carries an interval and a pass^k. The scenario inventory contract must grow before the run, not after.
