# neat-bench decisions

Architecture and method decisions, as ADRs. A contract cites the ADR that settled it; a rule with no ADR is Proposed. An ADR records a decision whose evidence already holds. Nothing below is settled until its status says so; Proposed means it is waiting for Deniz's ruling and lists the options. Accepted names who ruled and on which date.

Numbering is independent of the neat core decision log. The verbatim spec this bench was built against is `CONTRACT.md` at the repo root; nothing here overrides it, and where an ADR refines a clause it says which one and that the refinement is Deniz's ruling.

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

**Consequences.** Contracts govern `bench/**` and the outward docs; until this ADR is ruled, the `bench/` globs in the contracts are inert and the contracts bind through the legacy paths they also name. Legacy directories are never edited except to add the frozen notice. Where a legacy doc (`competitive-rca/README.md`, `docs/BENCHOPS-RUNBOOK.md`, `docs/METRICS.md`, `docs/DESIGN.md`) states a rule the contracts changed, the contract wins and the doc gets the notice.

---

## ADR-002: A grader is validated before its output is a result

**Status:** Accepted (validation gate, controls, oracle agent: Deniz, 2026-10-16). The form of the headline grader is still Proposed; options below.
**Date:** 2026-10-15, revised 2026-10-16

**Context.** The published detection grader (`praxis-rca/harness/grade-detect.sh`) is a keyword-presence matcher. Four negative controls submitted on 15 October 2026 (an answer explicitly denying the true cause; "unknown" with the cause word present; "unavailable, cannot determine why"; a wrong cause with the true one negated) all returned `CAUGHT=YES`. Every historical CAUGHT total and the competitive 19/20 were produced by it. The defect is precise: any mention of the true-cause words passes, even negated or hedged, and several keyword sets are broad enough to match a bare `config` or `unavailable`.

This is a named failure class, not a local accident. It is item O.b.1 (negation) of the Agentic Benchmark Checklist (Zhu et al., NeurIPS 2025 D&B, arXiv 2507.02825), and the same class that forced public corrections of τ-bench (a trivial empty-response agent scored 38%) and SWE-bench Verified (24% of the top-50 leaderboard positions found incorrect). The checklist's remedies are concrete and we adopt them. See `docs/research/bench-research-2026-10-16.md` §1.

**Decision.** No grader produces a published number until it passes a committed negative-control suite for every scenario it grades, at the exact version used for the run. The suite is: correct answer (must pass), pure wrong cause, negated true cause, "unknown" with the cause word present, wrong service with the right cause, a candidate list naming several causes (must fail: no credit for hedged lists), plausible-but-wrong patch. The suite runs in CI and before every regrade. Three more instruments are mandatory from the first consumer run:

1. **No-fault control scenarios.** Scenarios with nothing injected, graded by the same grader; every CAUGHT, RCI and RCR on them is a false positive and the false-positive rate is published beside the headline (ORCA-bench ships 195 such controls against 884 incidents).
2. **A trivial-agent baseline.** An arm that always answers "unknown", and one that always blames the most common culprit service, run through the grader; its score is published and must be near zero.
3. **An oracle agent.** A scripted arm that applies the ground-truth fix must score 100% RESOLVED on every scenario on every bench version. It runs in CI. A scenario the oracle cannot resolve is not in the battery (ABC T.9; Terminal-Bench oracle precedent).

Any LLM judge anywhere in the pipeline is calibrated against at least 100 human-labelled samples by at least two labellers, with the agreement statistic published (SREGym and ORCA-bench both report κ = 0.90). No LLM judge in RESOLVED (ADR-005).

**Options for the headline grader (Proposed).**
- A. Structured answer. The arm must emit a fixed schema (`SERVICE`, `CAUSE_CLASS` from a closed enum per scenario, `LOCATION`) and is graded by exact match. No free text is graded for the headline. Removes negation entirely; costs a prompt-format constraint on every arm.
- B. Negation-aware text grading plus the suite. Keeps free text; rejects a keyword hit inside a negated or hedged clause; tightens the broad sets. Cheaper to adopt; still a heuristic.
- C. LLM-as-judge with a held-out calibration set and reported agreement with human labels. Most flexible; adds a model to the measuring instrument, which must then be frozen and validated like any other.

**Recommendation.** A for RCI and cause class, B as the fast path during regrades, C only with published calibration. Whatever is chosen, every historical total is regraded through it and the before/after is published. The historical answers are free text, so the regrade path is B regardless; the first consumer run's headline grader waits on the ruling.

**Consequences.** The 19/20, the September totals, and the whitepaper numbers are not citable until regraded. The regrade is the first deliverable of the new bench. The scoring contract (`docs/contracts/scoring.md`) carries the rules.

---

## ADR-003: The clean baseline is derived from the chart, and a reset must remove what an injector added

**Status:** Proposed (re-premised 2026-10-16 after the live cluster showed the original context was wrong)
**Date:** 2026-10-15, revised 2026-10-16

**Context.** On 15 October this ADR said the baseline file `deploys-clean.json` carried injected faults and that `hard-reset.sh` therefore applied them. On 16 October the live cluster showed otherwise; the evidence is committed at `docs/research/2026-10-16-cluster-audit.md` and the corrected facts are these. The file (17 Deployments, captured 2026-10-14 00:50 box time) is clean: no `sleep infinity`, no port-40 probe, no `invalid-node` selector, and `kubectl diff` against the live cluster differs only in a memory limit we set on purpose. The faults were still live because the fields that carry them are owned by the field manager `OpenAPI-Generator`, the PRAXIS injector's Python client, stamped 2026-10-14T09:17Z (the `email` init container) and 10:05Z (the `frontend` readiness probe). Every reset path since then (a helm upgrade, hard-reset's `kubectl apply --server-side --force-conflicts`, a restore from the chart render by `kubectl apply`) ran under a different manager and, by server-side-apply semantics, never removes a field another manager owns. `verify-baseline.sh` checks the storefront, node selectors, image drift and neo4j, and not init containers, probes or limits, so it reported CLEAN=YES over the faults. The 14 October clean re-run voided every scenario because the cluster was dirty at launch. The collector-to-NEAT wiring lives in the `otel-collector` configmap, so `helm uninstall` on a running bench box is never a reset (`CLAUDE.md`, environment contract rule 4).

**Decision (proposed).** The clean state is defined as the pinned chart (`opentelemetry-demo` 0.36.4, app 2.0.1; the release carries no custom values) rendered by `helm template`, plus one documented, versioned patch for the collector-to-NEAT export, plus the documented per-deployment deltas the bench sets on purpose (today: `fraud-detection` memory 512Mi). A reset brings each deployment to that rendering by a method that removes fields regardless of who owns them: `kubectl replace` from the rendering, or a JSON patch that deletes the injected path. Server-side apply, client-side apply and helm upgrade are not resets. A run may not launch until a read-only audit diffs every live deployment against the rendering (init containers, probe ports, resource limits, images, node selectors, replicas, env) and shows only the documented deltas, and the stray-fault preflight is empty. The audit output is recorded in the run directory.

**Options.**
- A. Replace or patch per deployment from the rendering, keep the release and the cluster in place. Keeps the daemon wiring; the audit script that found the surviving faults (`ops/audit-vs-chart.sh`) is the gate.
- B. When A cannot converge: destroy the kind cluster and recreate it from the stand-up script (fresh cluster, chart render, collector patch, audit), with Deniz's explicit go per incident. Never `helm uninstall` inside a running cluster.

**Recommendation.** A, with B as the documented recovery path.

**Consequences.** `deploys-clean.json` is retired as the source of truth; the rendering is. `verify-baseline.sh` is replaced by the chart audit. The environment and run-validity contracts carry the method as the stricter reading until this ADR is ruled. The injector's own cleanup is not trusted either; the audit is what says clean.

---

## ADR-004: Experiment design for a NEAT-effect claim, and the value of k

**Status:** Accepted in part (Deniz, 2026-10-16): the scenario is the unit of inference and the battery grows before k does; k=5 with a k=10 top-up on close cells; the unfused source-plus-raw-evidence arm (`obscode`) is the baseline; paired per-scenario analysis with intervals, pass^k beside pass@1, cost per successful resolution; pre-declared nulls; a held-out slice with a per-class contamination statement; a pre-registered analysis plan. Proposed: whether both models are required for every headline (recommended: yes, as in the October bench), and whether competitor arms are a separate comparison (recommended: yes).
**Date:** 2026-10-15, revised 2026-10-16 with the literature pass in `docs/research/bench-research-2026-10-16.md`

**Context.** The September bench isolated nothing (Sonnet+NEAT vs Opus+obscode changes the model and the tool at once) but ran k=5 and recorded time. The October bench put both models on every arm (so the same-model comparison exists) and added ROBUST, but ran k=1, recorded no time, and its clean re-run produced no data. The effects this bench has actually observed are 10 to 15 points, all keyword-graded and so suspect in level: +12.5 (Aug 27, same model, 7/8 vs 6/8, k=2), +15 (detect lift 16/20 to 19/20 vs `code`, k=1), -11 (Sept 13, 35/45 vs 40/45, model-confounded). The design has to be able to resolve an effect of that size, or it resolves nothing.

**What the literature says about k.**
- Miller, *Adding Error Bars to Evals* (Anthropic 2024, arXiv 2411.00640): the unit of inference is the question, not the run. With K resamples per question, Var = (ω² + E[σ²]/K) / n where n is the number of questions and ω² is the between-question variance; "once E[σ²]/K is small relative to Var(x), increasing K further will have little effect." Cluster standard errors when questions are related ("over 3x larger than naive"); use paired differences "wherever practicable." Power: n = (z_α/2 + z_β)² (ω² + σ_A²/K_A + σ_B²/K_B) / δ². Do not lower temperature to reduce variance.
- PRAXIS (arXiv 2512.22113), the upstream of this battery: five seeds per ⟨LLM, scenario⟩ on 30 scenarios, mean ± dispersion.
- ITBench (arXiv 2502.05352): 10 runs per scenario per model, pass@1.
- METR (arXiv 2503.14499): 8 runs per agent-task pair, hierarchical bootstrap over task families, tasks, runs.
- Bjarnason et al., *On Randomness in Agentic Evals* (arXiv 2602.07150): about 60,000 SWE-bench Verified trajectories; a single-run pass@1 moves 2.2 to 6.0 points by run choice, SD above 1.5 points even at temperature 0; size runs by power analysis; report pass@k and pass^k.
- *A Sober Look* (arXiv 2504.07086): for 30-to-40-item benchmarks, seed-to-seed SD of 5 to 15 points; one item moves 2.5 to 3.3 points; at least ten seeds for small benchmarks.
- τ-bench (arXiv 2406.12045): pass^k, the chance all k trials succeed; reliability degrades sharply with k.
- Kapoor et al., *AI Agents That Matter* (arXiv 2407.01502): five runs, t-based intervals, cost on the same axis as accuracy, holdout sets matched to the generality claimed.

Observed practice sits between k=3 and k=10, with the reliability-focused benchmarks at 8 to 10 and the upstream PRAXIS at 5. Nobody serious reports k=1.

**What the math says for this battery.** Minimum detectable paired effect (80% power, two-sided 0.05; δ = 2.80 · sqrt((ω² + 2σ²/k)/n) with σ² = 0.25) under two plug-ins for the between-scenario variance ω². The first, ω² = 0.02, is a conservative rounding of a pilot estimate (ω² ≈ 0.013, across-arm correlation ρ ≈ +0.69) taken from the Sept 13 k=5 run; that run is model-confounded (Opus+obscode vs Sonnet+NEAT) and keyword-graded, so only its variance structure is used, the estimate is unreproduced by any committed script, and it is labelled as such. The second is the worst-case Bernoulli bound (ω² = 0.25), which is what an outside reviewer will plug in.

| scenarios | k=5, ω²=0.02 | k=10, ω²=0.02 | k=5, worst case | k=10, worst case |
|---|---|---|---|---|
| 15 | 25.0 pp | 19.1 pp | 42.8 pp | 39.6 pp |
| 30 | 17.7 pp | 13.5 pp | 30.2 pp | 28.0 pp |
| 60 | 12.5 pp | 9.6 pp | 21.4 pp | 19.8 pp |
| 90 | 10.2 pp | 7.8 pp | 17.5 pp | 16.2 pp |
| 150 | 7.9 pp | 6.0 pp | 13.5 pp | 12.5 pp |

Both columns say the same thing: **scenarios buy what repeats cannot.** Going from k=5 to k=10 moves the detectable effect by 2 to 6 points at any battery size; doubling the battery moves it by 5 to 12. A 10-to-15-point effect is not resolvable at 30 scenarios under either plug-in, and is resolvable around 60 to 90 under the pilot variance, 90 to 150 under the worst case. Which plug-in is right is an empirical question the first consumer run answers with a committed script under `docs/research/`; until then both are stated.

**Decision.** A NEAT-effect claim requires, for the same model snapshot, scaffold, turn budget and prompts:

1. **Arms defined by what they remove.** `obscode` is the baseline: the same model with source plus the raw runtime signals, unfused: traces and metrics (Jaeger, Prometheus) and logs, plus `kubectl` and deployment state. `neat` is the same source, traces, metrics and logs fused through a live NEAT daemon, plus the same `kubectl` and deployment state. `code` is source only, no `kubectl`, and is a weaker control, reported as such and never as the baseline. This refines `CONTRACT.md` clause 3 (which names source, traces and metrics) by naming logs and `kubectl` explicitly as inputs both arms receive, matching what the October runs already did (`praxis-rca/results/fullsuite-2026-08-31/RESULT.md`), under Deniz's 2026-10-16 ruling that the baseline is what a human on call would have.
2. **Both models**, each compared to itself (Proposed as a requirement; recommended).
3. **The scenario is the unit of inference.** Analysis is paired by scenario; the interval is a hierarchical bootstrap over target system, scenario and run; standard errors are clustered by scenario family. pass@1 with its interval, pass^k and pass@k are all reported; a point without an interval is not a result.
4. **k=5 on the full battery**, then a top-up to k=10 only on comparisons whose observed gap sits inside its interval. k=3 is for development and smoke; k=1 is never a result.
5. **The battery grows before k does.** The target is at least 90 scenarios with a verified-fix signal (ADR-006 says which). A sub-10-point effect is not promised below that.
6. **Per-run wall-clock, token categories and dollar cost recorded** and reported with the accuracy on the same line (claims contract, rules 2 and 3).
7. **A held-out slice never used during development**, and a per-class contamination statement: PRAXIS code faults are novel by construction; OpenTelemetry demo feature-flag faults are public and are labelled as likely contaminated.
8. **Pre-declared nulls.** Scenario classes where runtime context cannot matter (source-visible faults such as 411 and 412) are declared as expected nulls before the run and reported as such. A null where one is expected is evidence the instrument works, not a loss.
9. **Competitor arms** are a separate comparison with its own, weaker claims, never inside the NEAT-effect design (Proposed; recommended).
10. **The analysis plan is pre-registered**: committed, with its hash, before the first scored window of a run.

**Consequences.** The first consumer run at 30 scenarios is about 900 agent runs for the 3-arm, 2-model core, and will certify only a large effect; its job is to calibrate ω² and the instruments. The scenario inventory contract must grow before the headline run, not after. Every published comparison carries an interval and a pass^k. The experiment-design contract (`docs/contracts/experiment-design.md`) carries the rules.

---

## ADR-005: RESOLVED is a verified, regression-free fix, decided by oracles, never by a judge

**Status:** Accepted (Deniz, 2026-10-16)
**Date:** 2026-10-16

**Context.** `CONTRACT.md` clause 4 and `praxis-rca/SCORING.md` §2 and §3 define RESOLVED as correct code-grain localisation plus a fix verified by the application recovering with no regression (`fix_ok = symptom_cleared AND no_regression`; `RESOLVED = find_RCR AND fix_ok`). The research pass shows why that definition is the asset: the open benches that verify "mitigation" (ITBench, AIOpsLab, SREGym) accept "alert cleared" or "system healthy", which a restart, a scale-to-zero or a symptom-suppressing change can satisfy, and SREGym's own critique of its predecessors names this. The one bench with a stronger verifier (Incident-Arena, Oct 2026) gates on the outcome under fresh traffic and on a safety check that restarts the service, re-fires the fault, and inspects scope and data integrity; it has 20 tasks and no public repository was found. On the code side, SWE-bench's FAIL_TO_PASS and PASS_TO_PASS tests are the accepted standard, and UTBoost showed that weak tests let 15.7% of "passing" patches through. Seven historical rows in this repo carry `RESOLVED=YES` with `RCR=NO`, contradicting the definition: four in `praxis-rca/results/fullsuite-2026-08-31/fullsuite-results.tsv` (405 obscode/opus seeds 1, 2, 4; 410 neat/haiku seed 4), two in `fullsuite-0913-2026-09-01/` (405 obscode/opus seeds 1, 3), one in `fullsuite-track2-0912/` (405 obscode/opus seed 2). The October tables also split "RESOLVED" from "ROBUST" (regression-free), which let a fix that clears the symptom by amputating the path count as resolved.

**Decision.** A run is RESOLVED only when all of the following hold, each decided by a script, none by a model:

1. **Localisation**: RCR per the scoring contract (right file and symbol or config key).
2. **Fix verified under fresh traffic**: the agent's patch is applied to an isolated source copy, the image rebuilt and redeployed, the same user-flow load that reproduced the fault is driven, and the scenario's pre-registered fault signal returns to its clean baseline and stays there for a full window.
3. **Code-fault test gate**: for every code fault, a FAIL_TO_PASS test that fails on the faulted tree and passes on the oracle patch; the agent's patch must pass it.
4. **No regression**: the pass-to-pass suite for the other core flows still passes, and the fix does not retain behaviour absent from the fault-free reference (`praxis-rca/SCORING.md` §2 step 4).
5. **Safety gate**: the deployment runs a newly built image digest with replicas at least one; no scale-to-zero, no revert to the stock image, no deletion of the failing path; re-firing the fault's trigger after the fix does not reproduce the symptom; data written by the flows is intact.
6. **The oracle agent passes gates 2 to 5 on the same scenario in CI**; a scenario the oracle cannot pass is not in the battery.

`SYMPTOM_CLEARED`, `F2P`, `NO_REGRESSION` and `SAFETY` are recorded as separate columns so a cleared-but-mislocalised or cleared-but-amputated run stays visible. There is no separate ROBUST metric in the new schema: the legacy `robust` column of the October TSVs is what RESOLVED means here, and the legacy `resolved` column is reported as "symptom cleared with localisation" when cited. `RESOLVED=YES` with `RCR=NO` is a schema violation and is rejected at write time. No LLM judge decides any of the six gates; a judge may annotate, never grade.

**Consequences.** Every absorbed bench that only offers "alert cleared" is extended with gates 3 to 5 before its RESOLVED counts; until then it is reported as mitigation, not resolution. The seven historical contradicting rows are re-summed under this definition in a new file beside the legacy TSVs. The scoring contract carries the rules.

---

## ADR-006: Which open benches the battery absorbs, and what they may claim

**Status:** Accepted (Deniz, 2026-10-16; full SREGym rather than Lite, and ORCA for the detect leg, ruled the same day after the first draft said Lite)
**Date:** 2026-10-16

**Context.** ADR-004 needs 90 or more scenarios with a verified-fix signal, on systems with code, infrastructure and live telemetry so that NEAT's OBSERVED layer can matter. The research pass (`docs/research/bench-research-2026-10-16.md` §4 to §6) enumerated the candidates. No open bench today verifies "fix a bug in a running distributed system using telemetry and code" at more than 20 tasks with public artifacts: PRAXIS and ORCA-bench stop at diagnosis; ITBench, AIOpsLab and SREGym verify mitigation; Incident-Arena has the verifier but 20 tasks and no public repository found; TraceRoot has 5 incidents; every bench with code-fix verification at scale is a static repository with no runtime; every bench with telemetry at scale is offline localisation. "Diagnosis only" means the bench ships no fix verifier, never that the bug cannot be fixed: a verifier can be written for any fault whose system can be run.

The OpenTelemetry demo is the de facto substrate (ITBench, PRAXIS, ORCA-bench, SREGym, RCA100 all use it), fits the box, and is instrumented in 13 languages. NEAT's extractor on main (2026-10-16) parses 11 of them with tree-sitter (JavaScript, TypeScript, Python, Go, Java, C++, C#, Kotlin, PHP, Ruby, Rust) and emits symbol nodes for all, but static call and topology edges are JavaScript/TypeScript-only (core issue #1158, open), Java and C++ have manifest discovery and no route, data or call recognizers, and file-grain runtime stamping exists for JavaScript, Python and Go only. So the demo's services split into a "deep static plus OBSERVED" class and a "shallow static, OBSERVED-carried" class, and the inventory labels each service with the depth NEAT reaches at the pinned version. SREGym's other applications (Go gRPC hotel reservations, Django Saleor, a TypeScript-plus-Go Slack clone, the C++ Thrift social network, the 41-service Java-heavy train ticket system) widen that split; closing it on the core side is Deniz's 2026-10-16 directive to the instrumentation seat, and the bench does not publish a NEAT-effect number for an application until NEAT is verified end-to-end on it.

Licences, verified on the repositories on 2026-10-16 by their licence metadata: OpenTelemetry demo Apache-2.0; PRAXIS artifact (Zenodo record 19247887, which the DOI 10.5281/zenodo.19163486 in `praxis-rca/INTEGRATION.md` resolves to) Apache-2.0; ITBench Apache-2.0; SREGym MIT; AIOpsLab MIT; Chaos Mesh Apache-2.0; Online Boutique Apache-2.0; DeathStarBench Apache-2.0 by repository metadata with the README stating GPLv2 for parts, last pushed July 2024; SWE-bench Live MIT; Multi-SWE-bench Apache-2.0. SWE-rebench is a dataset, not a repository, and is unverified.

**Decision.** The battery is built from, in this order:

1. **SREGym, the full suite** (90 problems on five live applications: DeathStarBench, TrainTicket, the OpenTelemetry demo and two in-house apps; 34 ported from AIOpsLab and ITBench, 43 new of similar kinds, 13 unique; mitigation oracle per problem; MIT). It runs on a self-managed Linux cluster with root, which each bench box is. Absorbed with its oracle; its rows are reported as mitigation until the ADR-005 gates 3 to 5 exist for each problem, at which point they are RESOLVED. AIOpsLab is absorbed through it, not separately.
2. **PRAXIS Code-Cloud-RCA**, all 16 code faults (401 to 416, wiring 402 to 404), each extended with the ADR-005 verifier (a FAIL_TO_PASS test and a fault signal) so the leg yields RESOLVED. This is the code-grain headline leg. The 9 feature-flag and 5 chaos/manifest scenarios stay in the inventory as config-grain and operational classes, labelled draw-class for fusion and likely contaminated (the flags are public).
3. **ITBench SRE**, the 67 scenarios the box checkout exposes (ITBench at 8949d5b; `competitive-rca` wired them as ITBench-67), kept for continuity and for the independent leaderboard; "alert cleared" is reported as mitigation until gated.
4. **ORCA-bench for the detect leg**: 884 incidents and 195 no-fault controls generated from 11 feature flags on the OpenTelemetry demo with six days of recorded telemetry. Used for RCI/RCR at large n with our exact-match grader against its ground truth (flag, service, onset), never its LLM judge; its control-task design is adopted. Its faults are flags and so can also be re-injected live on our cluster for RESOLVED rows, config-grain. The recording itself is never the measured substrate for a NEAT-effect claim (`CONTRACT.md` clause 5: live daemons).
5. **Static SWE-style benches** (SWE-bench Live, Multi-SWE-bench) only as a non-regression control arm where OBSERVED is inert: a flat result is expected, a drop is a NEAT bug.
6. **Design stolen, not absorbed**: Incident-Arena's two-gate verifier.
7. **Excluded for RESOLVED**: OpenRCA, RCAEval, RCA100, LEMMA-RCA, Cloud-OpsBench and other offline localisation sets (no system to run; replay is not live); Defects4J, BugsInPy, GitBug-Java, AgentIssue-Bench, Commit0, TheAgentCompany as off-target; RepoBench, CrossCodeEval, LiveCodeBench by construction.

No self-authored faults (`CONTRACT.md` clause 7 and the non-negotiables). Writing a FAIL_TO_PASS test or a fault signal for a third-party fault is an oracle, not a fault. A bench enters the inventory only with its licence verified on its repository and recorded in the scenario contract.

**Consequences.** Live scenarios with a mitigation or fix signal: 16 + 90 + 67 = 173 before held-out splitting, which clears the ADR-004 target without a self-authored fault. The infrastructure cost is real: SREGym's five applications are more images and more stand-up on the new boxes; ORCA needs the Harbor harness and about 50 GB of telemetry. The scenario inventory contract (`docs/contracts/scenarios.md`) lists each set with what its RESOLVED means. The research file is the register of what was rejected and why, so the question is not reopened without new evidence.

---

## ADR-007: Execution across several boxes

**Status:** Accepted for the architecture (Deniz, 2026-10-16). Two operating choices are Proposed below.
**Date:** 2026-10-16

**Context.** The bench runs on the boxes, never on a laptop (`CLAUDE.md`). Three gaming PCs are available; the existing box is verified at 16 cores, 29 GiB usable RAM and 915 GB disk; the other two are reported by Deniz as 32 GB and 500 GB each and are unverified until their stand-up captures `nproc`, `free` and `df`. The unit of parallelism is a cluster, not a machine: one injected fault per cluster at a time, every arm and model in parallel against it (`CONTRACT.md` O3). The one clean throughput datum is the 12 October `praxis-final` pass: 4 scenario windows in 100 minutes with 8 concurrent agent runs per window (4 arms × 2 models), about 25 minutes per window including reset. A full ADR-004 pass at 30 scenarios, 3 arms, 2 models, k=5 is 150 windows: about 62 hours on one cluster, 21 on three, 10 on six. Observed on the box on 2026-10-16: the full ITBench stack (istio, chaos-mesh, clickhouse, opensearch, prometheus) plus a crash-looping duplicate demo put the box at 14 GiB used, and the worker node carrying the load generator with browser traffic on sat near 790% CPU in `docker stats`, most of it headless Chromium.

**Decision.**

1. **Stand-up is a script.** `standup-box.sh` installs docker, kind, kubectl, helm, Node 20, NEAT at a pinned version, renders the pinned chart with the collector patch (ADR-003), fetches the pristine source and the fault artifacts, installs the bridge guard, captures the hardware line, and disables sleep. A human installs the OS, Tailscale and SSH keys and copies credentials; nothing else is done by hand. The script doubles as the reproducibility kit a stranger runs.
2. **Work is pulled, never pushed.** One box holds a queue of cells (scenario, arm set, model, seed). Each cluster runs a worker under systemd: claim a cell atomically, reset and audit (ADR-003), preflight, inject, fan out arms, grade, push the run directory and the result row back, repeat. A dead box or a dropped link leaves its cell unclaimed. No driving session is needed; the workers are harness scripts.
3. **Store everything, regrade offline.** Every run keeps the answer, the trajectory, tokens, wall-clock, the preflight and audit records. Instrument iterations (grader, controls) are regrades over stored answers, not reruns.
4. **Layout.** The two new boxes run lean clusters (demo plus NEAT, and the SREGym applications) for the PRAXIS and SREGym legs; the existing box keeps the ITBench stack as the single ITBench runner. One lean cluster per box until the load-generator choice below is ruled; two per box if browser traffic is off.
5. **Boot hygiene.** Wired ethernet, sleep disabled, the bridge guard on boot. On 2026-10-16 the box booted at 18:23 and was reachable over Tailscale at 19:49; "up" and "reachable" are different states, and the worker reports both.

**Proposed (Deniz's call).**
- Load-generator browser traffic on the lean clusters: off (recommended; it is most of the worker node's CPU and is what limits a box to one cluster) or on (keeps the frontend's browser spans in the telemetry). Whichever is chosen is recorded in the run manifest.
- Budget per full pass: from `praxis-final` per-run cost, roughly $300 to $600 at k=5; two passes plus smokes per weekend is about $1k.

**Consequences.** The environment contract (`docs/contracts/environment.md`) carries the stand-up, queue and hygiene rules. The results-records contract carries the manifest fields the worker must write. The scripts that exist today live under `ops/` in this repo (`audit-vs-chart.sh`, `fix-kind-bridge.sh`, `recover-20261016.sh`); `standup-box.sh` and the worker are the next deliverables, and the box-local `hard-reset.sh` and `verify-baseline.sh` under `~/praxis/harness` are retired by ADR-003.
