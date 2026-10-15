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

## ADR-004: Experiment design for a NEAT-effect claim

**Status:** Proposed
**Date:** 2026-10-15

**Context.** The September bench isolated nothing (Sonnet+NEAT vs Opus+source changes the model and the tool at once) but ran k=5 and recorded time. The October bench put both models on every arm (so the same-model comparison exists) and added ROBUST, but ran k=1, recorded no time, and its clean re-run produced no data. The audit's replacement list: freeze product, model, prompts, budgets, prices and grader per run; develop on one task set and evaluate on an untouched one; compare the same model with source alone, source plus raw runtime and deployment evidence, and source plus NEAT; include unfamiliar systems and tasks where runtime context should not help; repeat enough to characterise variance; publish everything.

**Decision (proposed).** A NEAT-effect claim requires, for the same model: three arms (source / source+raw runtime and deployment evidence / source+NEAT), both models, k of at least five per cell, per-run wall-clock and token categories recorded, a held-out scenario set never used during development, and the grader of ADR-002. Cost and speed are reported per arm with the accuracy on the same line. Developed-against results are published only as upper bounds and labelled.

**Options.**
- k: 5 (proposed) or 3 with a bootstrap interval. Five is the September precedent and the audit's "enough to characterise variability".
- Held-out source: the unwired PRAXIS scenarios (402-404, the flagd set) held back from development; or a second target system NEAT was not engineered against. The second is the stronger test and the one the core repo's own definition of success demands.
- Whether competitor arms are part of the NEAT-effect design or a separate comparison with its own, weaker claims.

**Recommendation.** k=5; both held-out sources, the second target being the one that counts; competitors as a separate comparison.

**Consequences.** One cell is 5 runs; the three-arm, two-model, 15-scenario core is 450 agent runs before competitors. That is the price of a number that survives an audit.
