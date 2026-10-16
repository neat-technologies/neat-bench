# Benchmark research for neat-bench: methodology, headline numbers, reproducibility, playgrounds, absorbable benches, and the gap

Date: 2026-10-16. Researcher: Claude (web research pass). Scope: literature and practice survey; nothing here was run on the box. Every claim is tagged **KNOWN** (cited to a source I fetched or a search result that quoted it) or **INFERRED** (my reasoning on top of the sources). Where a source is secondary, vendor-written, or internally inconsistent I say so.


> **Editor's note (2026-10-16, after the report was written):** licences the report marks "from memory" were verified on the repositories the same day: OpenTelemetry demo Apache-2.0, Chaos Mesh Apache-2.0, Online Boutique Apache-2.0, SREGym MIT, ITBench Apache-2.0, AIOpsLab MIT, DeathStarBench Apache-2.0 by repository metadata (README mentions GPLv2 for parts; last pushed July 2024). The PRAXIS artifact is Zenodo record 19247887 (Apache-2.0); the DOI 10.5281/zenodo.19163486 cited in `praxis-rca/INTEGRATION.md` resolves to that record, and the report's original `records/19163486` URL did not. Also verified the same day: SWE-bench Live MIT, Multi-SWE-bench Apache-2.0; SWE-rebench is a dataset without a repository and stays unverified. The rankings and ADR-002/004/005/006 rest on this report.

---

## Executive summary

**The short version.** The field has converged, since 2024, on a fairly small set of things that make an agent benchmark trusted: a grader that is proven not to pass wrong answers (negation, guessing, empty output), environments frozen in containers, repeats with paired statistics and confidence intervals, cost and wall-clock next to accuracy, published trajectories, and an open harness a stranger can rerun. Our audit finding (keyword-presence grader accepted negated answers) is exactly the failure class catalogued as item O.b.1 of the Agentic Benchmark Checklist (Zhu et al., NeurIPS 2025) and is the same kind of flaw that got τ-bench (38% from an empty-response agent) and SWE-bench Verified (24% of top-50 positions wrong) publicly corrected. **KNOWN** [ABC].

**The headline number that survives scrutiny** is a *paired, per-scenario difference* on a verified outcome (RESOLVED), same model snapshot, same scaffold, same budget, k repeats, with a 95% CI computed on the per-scenario differences and clustered by scenario; reported alongside n, k, cost per task, and the negative-control false-positive rate. Not a ratio ("3.3×"), not a detection rate, not a comparison against a deliberately weakened arm. **INFERRED** from Miller 2024, Kapoor et al. 2024/25, Bjarnason et al. 2026.

**Power reality.** With Miller's paired minimum-detectable-effect formula and 30 scenarios, you can detect roughly a 25–30 pp paired effect at 80% power; more repeats barely help past k≈5 because scenario-level variance dominates. Detecting a 10–15 pp effect needs on the order of 90–150 scenarios. **INFERRED** (formula KNOWN [Miller]; arithmetic below in §2.4).

**Playground.** The OpenTelemetry Demo on Kubernetes is the right substrate and is now the de facto standard: ITBench (IBM), PRAXIS (IBM/UIUC), ORCA-bench (Traversal/Cornell), SREGym (UIUC), RCA100 (CAS/Alibaba) and the `agent-breakage` substrate all use it. It ships 20 flagd fault flags across 13 languages/~19 services and fits a 16-core/29 GB box. **KNOWN** (details §4).

**There is no open, credible benchmark today for "agent fixes a bug in a running distributed system using telemetry + code" with verified RESOLVED.** The closest are: SREGym (90 problems, live, oracle-verified mitigation, but mostly ops-level mitigation rather than code fixes; MIT; 350 stars), Incident-Arena (20 tasks, deterministic two-gate verifier incl. re-firing the fault, some tasks require rebuilding a service from source; availability unclear), and TraceRoot (5 incidents, reproducer-verified code fix, tiny). PRAXIS and ORCA-bench, the two that are most "code + telemetry", are *diagnosis-only*. **KNOWN** (§5, §6).

### Ranked absorption list (top candidates for neat-bench)

| Rank | Bench | Gives RESOLVED? | Runtime/telemetry (NEAT-relevant)? | Integration cost | Credibility | Verdict |
|---|---|---|---|---|---|---|
| 1 | **SREGym** (UIUC, MIT) | Yes: problem-specific mitigation oracle (client success rate + system state) | Yes: live k8s, Prometheus/Loki/Jaeger via MCP; OTel demo among 5 apps | Medium: already Python+kind; Lite profile 8 vCPU/16 GB; full profile wants self-managed cluster | High (absorbs AIOpsLab + ITBench problems; NeurIPS 2026 submission) | Absorb SREGym-Lite first; its mitigation oracle is the model for our RESOLVED |
| 2 | **PRAXIS Code-Cloud-RCA** (IBM/UIUC, DSN'26, Apache-2.0 artifact) | No (RCI/RCR pass@1 only) | Yes: OTel demo, live, 16 code faults | Low: we already run it | High (peer-reviewed, artifact-evaluated) | Keep for RCI/RCR; add our own FAIL_TO_PASS fix check per code fault to extend it to RESOLVED |
| 3 | **ITBench SRE** (IBM, Apache-2.0) | Yes: mitigation pass@1 = alert cleared | Yes: OTel demo + Grafana/Loki/Jaeger/Prometheus | Low–medium: already in harness; only 11 of 94 scenarios public | High (IBM + Artificial Analysis leaderboard) | Keep; note that "alert cleared" is a weak RESOLVED (symptom suppression passes) |
| 4 | **ORCA-bench** (Traversal/Cornell) | No (read-only RCA, LLM judge) | Yes: OTel demo, 6 days of telemetry, full source access, **195 control (no-fault) tasks** | Medium (Harbor/Terminus-2 harness) | Medium-high (κ=0.90 judge validation, 40-task Verified subset) | Steal the *control-task* design for negative controls; don't absorb for RESOLVED |
| 5 | **Incident-Arena** (Abundant/CMU et al., Oct 2026) | Yes: two-gate deterministic verifier (outcome under fresh traffic + safety: restart/re-fire fault) | Yes: k3s, Prometheus+Loki; Saleor/Frappe/Mattermost-like | High (AWS m7i.2xlarge per trial; artifacts not confirmed public) | Medium (preprint, 20 tasks) | Steal the verifier design (re-fire the fault, check persistence). Absorb only if artifacts ship |
| 6 | **AIOpsLab** (Microsoft, MLSys'25, MIT) | Yes: mitigation evaluator checks whole-system health | Yes: DeathStarBench HotelRes/SocialNetwork, Prometheus/Jaeger/Filebeat | Medium (superseded by SREGym which ports its problems) | High | Absorb via SREGym rather than directly |
| 7 | **TraceRoot** (ICML'26 workshop) | Yes: end-to-end reproducer, no judge | Partial: 5 FastAPI services, structured logs | Low if artifacts exist; 5 incidents only | Low (workshop, 2 authors) | Pattern reference only |
| 8 | **SWE-bench Live / SWE-rebench / Multi-SWE-bench** | Yes: FAIL_TO_PASS ∧ PASS_TO_PASS | **No** runtime telemetry (static repo) | Low (Docker per task) | High | Use as the *control* arm to show NEAT doesn't regress static repair; NEAT's OBSERVED layer can't matter here |
| 9 | **Cloud-OpsBench** (snapshot twin, 452–754 cases) | No (localization) | Snapshot only, no live system | Low (runs on a laptop) | Medium | Useful for cheap large-n localization sweeps, not for RESOLVED |
| — | RCAEval, OpenRCA, RCA100/AIOps2025, LEMMA-RCA | No (offline localization datasets) | Offline telemetry files only | Low | Medium (OpenRCA has a published label critique) | Exclude for RESOLVED; RCAEval RE3 (90 code-level cases) is a localization-only bonus |
| — | Defects4J, BugsInPy, GitBug-Java, AgentIssue-Bench, SWE-Gym, Commit0, TheAgentCompany | Yes (tests), static | No | Low–medium | Varies | Not where NEAT's edge is; see §5 |
| — | RepoBench, CrossCodeEval, LiveCodeBench | No (completion / competitive programming) | No | — | — | Excluded by construction |

---

## 1. What makes a good agent benchmark

### 1.1 The sources and what each one actually established

**Kapoor, Stroebl et al., "AI Agents That Matter" (TMLR 2025; arXiv 2407.01502).** KNOWN. Cost-controlled evaluation: simple baselines on HumanEval matched complex agents at ~2 orders of magnitude lower cost (Warming 93.2% @ $2.45 vs LATS 88.0% @ $134.50). Recommends plotting accuracy vs dollar cost as a convex Pareto frontier; reporting token counts so cost can be recomputed; holdout sets matched to the intended generality level (distribution-, task-, domain-, general-purpose); found only 1/1, 3/6, 1/8, 0/2 benchmarks at those levels had appropriate holdouts. Reproduced published agents with **5 runs, reporting mean/min/max and t-distribution 95% CIs**; many published numbers exceeded the authors' max over 5 runs. Found shortcuts (STeP hardcoding URL paths on WebArena) and grading bugs (LATS, STeP each marked some incorrect tasks correct). Notes a full SWE-bench run at $4/task cap exceeds $8,000, which is why error bars are rarely reported.

**Miller (Anthropic), "Adding Error Bars to Evals" (arXiv 2411.00640).** KNOWN. Report SE of the mean with n. Cluster SEs on the unit of randomization when questions are grouped; clustered SEs were up to 3.05× naive (DROP). Resample K answers per question to reduce variance (K=2 cuts the conditional-variance term by 1/3, K=4 by 1/2; ceiling 2/3 in the worked example); **do not lower temperature to reduce variance** (it changes the thing measured). For two-model comparisons use **paired per-question differences**: SE_paired = sqrt(SE_A² + SE_B² − 2·SE_A·SE_B·Corr). Power: n = (z_{α/2}+z_β)²·(ω² + σ_A²/K_A + σ_B²/K_B)/δ²; worked example gives n≈969 for a 3 pp effect, hence "new evals should contain at least ~1,000 questions". With n=198, raising K from 1 to 10 shrinks MDE from 13.2% to 7.5%.

**Hochlehnert et al., "A Sober Look at Progress in LM Reasoning" (arXiv 2504.07086).** KNOWN. Seed-to-seed Pass@1 SD of 5–15 pp on 30–40-item benchmarks; one item moves the score 2.5–3.3 pp; same model on five compute clusters differed by up to 8%; eval frameworks differ by 1–4.5 pp; temperature sweeps move scores up to 15%. Recommends ≥10 seeds for small benchmarks, Docker-pinned stack, fixed framework, robust parser, releasing prompts and outputs. (30 scenarios is our size: this paper is directly about us.)

**Bjarnason, Silva, Monperrus, "On Randomness in Agentic Evals" (arXiv 2602.07150).** KNOWN. ~60,000 SWE-bench Verified trajectories, 3 models × 2 scaffolds: single-run pass@1 varies 2.2–6.0 pp depending on which run you pick; SD >1.5 pp **even at temperature 0** (infrastructure nondeterminism); trajectories diverge within the first few percent of tokens. Recommends multiple runs sized by power analysis and reporting **pass@k (optimistic) and pass^k (pessimistic)** for k>1. "Reported improvements of 2–3 pp may reflect evaluation noise."

**Zhu et al., "Establishing Best Practices for Building Rigorous Agentic Benchmarks" — the ABC checklist (NeurIPS 2025 D&B; arXiv 2507.02825).** KNOWN. Task validity T.1–T.10 (pin tool versions; clear state per task; isolate agent from ground truth; freeze environment at release; verify annotations and setup; **provide an automatic oracle solver**; inspect pilot outliers). Outcome validity: handle equivalent expressions, **handle negation (O.b.1)**, block answer-listing and guessing, pilot-test LLM judges for accuracy/self-consistency, manually verify unit tests and measure coverage, fuzz, cover end-to-end branches, remove non-determinism, check relevant *and irrelevant* state after state-modifying tasks, make state space rich enough that trivial changes don't pass. Reporting R.1–R.13: open dataset + harness, contamination measures, update plan, construct validity statement, document mitigations, quantify effect of unavoidable flaws, **report statistical significance**, interpretation guidance, **baselines including human experts and trivial agents**. Findings: SWE-bench Verified's tests are insufficient such that "24% of the top 50 leaderboard positions are incorrect"; τ-bench counts empty responses as success (trivial agent 38%, beating GPT-4o); applying ABC to CVE-Bench reduced overestimation by 33 pp absolute.

**UTBoost (Yu et al., ACL 2025; arXiv 2506.09289).** KNOWN. 26 of 500 Verified tasks have insufficient tests; 15.7% (92/584) of passing patches are wrong under augmented tests; 24.4% of leaderboard entries affected, 11 rank changes; 82.6% of errors in Django+sympy. A follow-up (SWE-ABS, arXiv 2603.00520) claims to strengthen 50.2% of instances and reject 19.78% of previously accepted patches — secondary, not independently verified here.

**OpenAI, "Why we no longer evaluate SWE-bench Verified" (23 Feb 2026).** KNOWN via search excerpts (the page itself returned 403 to my fetch). Reasons: gains "increasingly reflect how much a model was exposed to it during training"; many task statements underspecified so several valid interpretations exist while tests cover one; models that had seen fixes were more likely to pass. Recommended SWE-bench Pro meanwhile. Secondary sources claim an audit of 138 hardest tasks found 59.4% materially flawed, and that OpenAI later (July 2026) retracted the Pro recommendation after ~30% of Pro tasks were estimated broken — **unconfirmed from a primary source**.

**SWE-bench Verified (OpenAI + SWE-bench authors, Aug 2024).** KNOWN. 500 tasks screened by professional developers; engineers hand-labelled 50 samples as an onboarding test annotators had to pass; annotators estimated time-to-fix and flagged gameable tests; annotations published; 196 "<15 min" and 45 ">1 h" splits. Number of annotators and inter-rater agreement not in what I retrieved.

**SWE-bench Pro (Scale, arXiv 2509.16941).** KNOWN. 1,865 instances: 731 public / 858 held-out / 276 commercial; GPL-licensed repos for public+held-out (legal deterrent to training), proprietary startup code for commercial; only results released for commercial; held-out set is an overfitting control. Scaffold sensitivity: three products running the same Claude Opus 4.5 weights scored 50.2–55.4% vs Scale's SEAL scaffold 45.9% — **secondary blog sources**, consistent with each other but not confirmed on Scale's page.

**SWE-bench Live (Microsoft, NeurIPS 2025; arXiv 2505.23419).** KNOWN. 1,319 tasks from issues created since 2024 across 93 repos; one Docker image per task; RepoLaunch automates environment setup; same agent/LLM pairs score consistently lower than on SWE-bench → overfitting evidence. The "monthly" cadence in our question was not confirmed.

**SWE-rebench (Nebius, NeurIPS 2025 D&B; arXiv 2505.20411).** KNOWN. Automated pipeline; >21k tasks under CC BY 4.0; leaderboard flags "potentially contaminated" when issue date precedes model release; leaderboard runs each model **5 times** with a standardized ReAct scaffold at 128K context.

**Terminal-Bench 2.0 / Harbor (arXiv 2601.11868; tbench.ai).** KNOWN. 89 tasks, each a unique Docker environment with a human-written oracle solution and tests on the final container state; "substantial manual and LM-assisted verification"; one 1.0 task (download-youtube) was removed because an external site changed. Leaderboard shows resolution rate with **95% CI whiskers plus cost and tokens**. Trials per task, reviewer counts/hours (sources conflict: "300 hours per task" vs "3 reviewer-hours per task") not confirmed from primary pages.

**HAL — Holistic Agent Leaderboard (Princeton, ICLR 2026; arXiv 2510.11977).** KNOWN. 21,730 rollouts, 9 models × 9 benchmarks, ~$40k; harness tracks tokens/cost without touching agent code; released 2.5B tokens of agent logs; LLM-aided log inspection found agents searching HuggingFace for answers and misusing credit cards. Leaderboard reports run-to-run variation as min–max (e.g. "61.00% (−7/+7) across 2 runs"). Higher reasoning effort reduced accuracy in most runs.

**Epoch AI Benchmarking Hub.** KNOWN. 16 runs per model on GPQA Diamond, 8 on MATH L5; error bars ±1 SE "following arXiv 2411.00640"; API-default temperature; Inspect framework; publishes task definitions as gists and plans to pin git revisions; separates own runs from vendor-reported scores with provenance columns; vendor claims differ from Epoch runs (Claude 3.5 Sonnet 65% claimed vs 0.55±0.03 measured). Epoch's **benchmark reviews** (as of Sep 2026): 9 flawed / 4 verified / 2 insufficient info; "flawed" threshold = errors in ≥20% of inspected sample or a grading problem that corrupts at scale; criteria: label noise, grading validity, contamination, comparability, construct validity, setup fairness. DeepSWE v1.1 was flagged on false negatives.

**METR Time Horizon 1.1 (Jan 2026).** KNOWN. 228 tasks; ~8 runs per task per model (per Epoch's summary); CIs by bootstrap over task families, tasks and runs (authors say this may overestimate run-level variance); human baselines measured for only 5 of 31 8h+ tasks; doubling time moved from 165 to 131 days just from changing task composition; scaffold/infra change (Vivaria→Inspect) moved GPT-4o and o3 scores significantly. Honest about all of this in the post, which is why it is trusted.

**BetterBench (Reuel et al., NeurIPS 2024 D&B).** KNOWN. 46 criteria across the lifecycle; most benchmarks are weakest at implementation; "most benchmarks do not report statistical significance of their results nor allow for their results to be easily replicated"; publishes a minimum checklist.

**The Leaderboard Illusion (Singh et al., NeurIPS 2025).** KNOWN. Private best-of-N testing (27 Meta variants before Llama-4), silent deprecation, unequal sampling → Bradley-Terry scores biased. Lesson transferable to us: never test N variants of the NEAT arm privately and report the best.

**τ-bench pass^k (Sierra).** KNOWN. pass^k = probability all k i.i.d. trials succeed, averaged over tasks; GPT-4o retail pass^8 < 25%; success judged by database end-state, not conversation text.

**EvalCards / Evaluation Cards / pre-registration.** KNOWN. Two separate "EvalCards" efforts (arXiv 2511.21695; Ghosh/Reuel et al. arXiv 2606.09809 with a checklist item for public, timestamped design preregistration). "Preregistration for Experiments with AI Agents" (arXiv 2606.11217) proposes a template that discloses pilot history (prompt iterations, models tried). PRML is a tamper-evident SHA-256 manifest spec with Inspect adapters. **INFERRED:** adoption is early; no major benchmark pre-registers today, so doing it would be differentiating, not expected.

**What sceptics actually say (HN, via Algolia API, KNOWN quotes):** "models released after this date may have seen these exact issues"; "the contamination factor is huge"; "how well can the model cheat flaws in SWEBench Verified"; "requiring specific class or function names to pass"; "included a lot of tasks that didn't really make sense"; "without a bigger effort to show what the benchmark is and how other models perform"; "a bit of unavoidable multiple model testing bias"; "from 12.47% to 3.97%" (after filtering leaky instances). The Devin launch is the canonical cautionary tale: evaluated on a 25% subset, "unassisted vs assisted" framing contested, Upwork claim reported untrue by Pragmatic Engineer. KNOWN (secondary).

### 1.2 The concrete checklist (what neat-bench must have, mapped to sources)

Grader validity
- [ ] **Negative controls**: no-fault scenarios must score 0 on CAUGHT/RCI/RCR; ORCA-bench's 195 control tasks of 1,079 is the model. KNOWN [ORCA]. Also a "trivial agent" baseline (empty answer / "unknown" / always-blame-frontend) must score ~0. KNOWN [ABC R.13, τ-bench finding].
- [ ] **Negation-aware grading** (ABC O.b.1) and no credit for listing candidates (O.b.2). KNOWN.
- [ ] **Oracle solver** (ABC T.9): a scripted agent that applies the ground-truth fix must score 100% RESOLVED on every scenario, every time — this is what Terminal-Bench calls the oracle solution. KNOWN.
- [ ] **Human audit + inter-rater**: if any LLM judge remains, pilot it against ≥2 humans on ≥100 samples and report κ (SREGym κ=0.90 Sonnet-4.6 vs expert; ORCA κ_w=0.90). KNOWN. Also publish annotations (SWE-bench Verified precedent).
- [ ] **Check irrelevant state** after a fix (ABC O.g.2): Incident-Arena's safety gate (service restart, re-fire fault, scope, data intact) is the model for RESOLVED. KNOWN.

Construct validity
- [ ] Write down what capability each metric claims to measure (ABC R.5–R.6) and the known threats: "alert cleared" ≠ root cause fixed; keyword RCR ≠ causal diagnosis (the Traversal critique of OpenRCA). KNOWN.
- [ ] Faults must be recoverable from the telemetry+code given (Traversal's Bank-0 example: no observable onset → unanswerable). KNOWN.

Contamination / held-out
- [ ] Record scenario creation dates vs model release dates (SWE-rebench flag). KNOWN. OTel demo flags are public since years → treat flag-fault scenarios as likely-contaminated and say so; code faults we inject are novel by construction. INFERRED.
- [ ] Keep a held-out slice (SWE-bench Pro: 858 held-out as overfitting control; ITBench-AA: 19 of 59 held-out). KNOWN.
- [ ] Canary string in all task artifacts (DeepSWE practice). KNOWN.

Repeats and statistics
- [ ] k ≥ 5 per scenario per arm (Kapoor 5; SWE-rebench 5; Hochlehnert ≥10 for n≈30; ITBench 10; SREGym 3). KNOWN.
- [ ] Report pass@1 mean with SE, **and** pass^k, **and** pass@k (Bjarnason). KNOWN.
- [ ] **Paired** per-scenario differences between arms, SE clustered by scenario (and by fault family if scenarios share a root). KNOWN [Miller].
- [ ] Power analysis stated up front; MDE reported. KNOWN [Miller; Bjarnason].
- [ ] Fixed temperature (API default), never tuned per arm. KNOWN [Miller; Epoch].

Cost and wall-clock
- [ ] Dollar cost, input/output tokens, turns, and wall-clock per task per arm; Pareto plot (Kapoor; HAL; Terminal-Bench; ITBench-AA $/task). KNOWN.

Process
- [ ] Pre-register the analysis plan and metrics before the clean run (timestamped commit). INFERRED best practice; KNOWN that Evaluation Cards asks for it.
- [ ] Publish all trajectories and grader inputs (HAL 2.5B tokens; SWE-Gym trajectories). KNOWN.
- [ ] Version + freeze: tag the bench, pin model snapshot IDs, Docker digests, chart versions; new review required after any fix (Epoch: a fixed version needs re-review). KNOWN.
- [ ] Third-party rerun: ask Epoch / HAL / Artificial Analysis-style independent runners; at minimum publish a one-command rerun kit. INFERRED.

---

## 2. The most effective and trustable headline number

### 2.1 What credible benches put forward

| Bench | Headline form | Extras shown with it |
|---|---|---|
| SWE-bench Verified / Live / Pro | "% resolved" on n instances | scaffold name, date, (Pro) split; checked logs on leaderboard |
| Terminal-Bench 2.0 | resolution rate with 95% CI whiskers | cost, tokens, agent name |
| HAL | accuracy with min–max over runs | cost per run, Pareto plot, full logs |
| Epoch | mean ± 1 SE over 8–16 runs | prompt/temperature, provenance of each number |
| METR | 50% time horizon with bootstrap CI | explicit list of caveats (baseline coverage, composition sensitivity) |
| ITBench (paper) | diagnosis pass@1 and mitigation pass@1 over 10 runs | MTTD/MTTR, ablation removing traces (13.81%→9.52% diagnosis; 11.43%→2.86% mitigation) |
| ITBench-AA | mean AP@full-recall over 59 tasks × 3 repeats | $/task, turns, held-out 19 |
| PRAXIS | RCI/RCR pass@1 ± over 5 seeds (e.g. RCR 61.54 ± 4.27) | tokens per successful diagnosis (884.9k→166.5k), MTTD |
| SREGym | diagnosis / mitigation / end-to-end success, 3 trials | TTD/TTM, tokens; split by problem origin |
| Incident-Arena | Pass@1 with Pass^3 and Pass^5 | failure taxonomy, 3,000 trials |
| τ-bench | pass^1 default; pass^k for reliability | — |

KNOWN for each row (sources in §7).

### 2.2 What gets attacked first (in order of frequency in what I read)

1. Contamination / "the model has seen it" (HN, OpenAI's Verified note, SWE-rebench, SWE-bench Live). KNOWN.
2. Grader/test quality: tests that accept wrong fixes (UTBoost), judges that accept non-answers (τ-bench), labels not recoverable from data (OpenRCA). KNOWN.
3. Scaffold confound: same weights, 50.2–55.4% depending on harness; "harness disclosure" is now a procurement demand. KNOWN (secondary).
4. Single-run numbers / no error bars / n too small (Kapoor; Bjarnason; Hochlehnert). KNOWN.
5. Vendor self-reporting and best-of-N private testing (Leaderboard Illusion; Epoch's claimed-vs-measured gaps). KNOWN.
6. Cherry-picked subsets and unequal assistance (Devin 25% subset, "assisted vs unassisted"). KNOWN (secondary).
7. Cost hidden (Kapoor). KNOWN.

### 2.3 How serious benches frame "same model with vs without tool X"

- **PRAXIS** is the closest precedent for us: same LLM, baseline SRE-Agent vs SRE-Agent+code tools vs PRAXIS, with two ablations (Obs. Ctx. = no program context; Raw Code = no graph traversal), 5 seeds, ± reported, and tokens-per-success. It *excludes* fault classes where all variants tie (deployment/infra faults) from the ablation table and says so. KNOWN. INFERRED lesson: name every arm by what it removes, not by product name, and report the scenario classes where the tool cannot matter as a pre-declared null.
- **Verdent's ablation** on SWE-bench Verified (Sonnet 4.5, advanced tools removed → "changed very little") and **Augment's** "same model, different harness" claims on SWE-bench Pro show the two outcomes: honest ablation that finds a null, and vendor framing that attributes the whole gap to the product. KNOWN (vendor sources).
- **ITBench's** trace-removal ablation is the academic version of "without the OBSERVED layer". KNOWN.
- The **agent-breakage** substrate ran retrieval-on vs control as paired arms with REPS=20 per arm, 360-run density sweeps and an n=40 rerun, and reported the pooled effect (+3.9 pp) as not significant. KNOWN. One star on GitHub, but methodologically it is what a NEAT-effect falsification should look like.

### 2.4 Standard for "X% cheaper / faster"

KNOWN practice: fix the model and report cost at the *same accuracy* (Kapoor's Pareto frontier; Augment's later claim "same solve rate, materially fewer tokens"; PRAXIS's "tokens per successful diagnosis"). INFERRED standard: a cost claim is only meaningful as (a) tokens/dollars per *successful* RESOLVED, (b) at matched or better accuracy, (c) same model snapshot, same turn cap, (d) wall-clock reported separately since it depends on API latency that day. "5.3× fewer tokens" (PRAXIS) is acceptable because the denominator is successes and the ± is shown.

**Power arithmetic for our size (INFERRED, formula KNOWN [Miller]).** δ_MDE = (z_{α/2}+z_β)·sqrt((ω² + σ_A²/K + σ_B²/K)/n). For binary per-scenario outcomes, ω² (variance across scenarios of the arm difference) is bounded by 0.25 and σ² ≤ 0.25. With n=30, K=5, ω²=0.25: sqrt((0.25+0.05+0.05)/30)=0.108 → δ≈2.8×0.108≈**30 pp**. K=10: ≈28 pp. n=90, K=5: ≈17.5 pp. n=150, K=5: ≈13.5 pp. Conclusion: at 30 scenarios we can only certify a NEAT effect of roughly a quarter to a third of the scale; smaller effects need more *scenarios*, not more repeats. If ω² is really lower (NEAT helps uniformly), the MDE shrinks, but we cannot assume that in a pre-registration.

### 2.5 Three defensible framings for a NEAT-effect claim

1. **Paired RESOLVED delta.** "On n=30 PRAXIS scenarios × k=5, same model (snapshot id), same scaffold, same 100-turn/$ cap, the NEAT arm resolved +X pp more than the source+logs arm (paired 95% CI [a, b], SE clustered by scenario; pass^5 Y vs Z; control-scenario false-positive rate 0/5)." Every element has a precedent above.
2. **Reliability framing.** "pass^5 RESOLVED: NEAT A% vs baseline B%" alongside pass@1 — τ-bench / Incident-Arena / k8s-ai-bench all report pass^k; it is the number an SRE buyer cares about and it is harder to game by retries. KNOWN precedent.
3. **Cost-at-parity.** "Tokens (and $) per successful resolution: NEAT T₁ vs baseline T₂ at equal-or-better RESOLVED" with a Pareto plot of the arms. KNOWN precedent (Kapoor, PRAXIS).

### 2.6 Three framings that get torn apart

1. **Ratios without denominators** ("3.3× better", "96% detection"). Detection (CAUGHT) is the softest outcome and the one our audit showed was graded by keyword presence; a ratio hides n, k and CI. Sceptics' attack #2 and #4.
2. **Comparing against a crippled arm and calling it "without NEAT"** (e.g. source-only with no logs when real engineers have logs). This is the Devin "assisted vs unassisted" trap. The fair baseline is the strongest cheap alternative: source + raw logs + kubectl + Grafana/Jaeger access, i.e. what ORCA-bench and SREGym give their agents.
3. **Mixed-condition arms** (different scenario subsets, faulted vs pristine source trees per arm — our known source-tree asymmetry; different turn caps; different model snapshots across arms; picking the best of several NEAT configurations). Leaderboard Illusion + Kapoor's shortcut findings. KNOWN.

---

## 3. Reproducibility: what the best benches actually ship

| Mechanism | Who does it | Detail (KNOWN) |
|---|---|---|
| Per-task container images | SWE-bench (base/env/instance Docker layers, `--cache_level`), SWE-bench Live (one image per task), SWE-Gym (`xingyaoww/sweb.eval.x86_64` per instance), Terminal-Bench (unique container per task), AgentIssue-Bench (Docker Hub per issue), GitBug-Java (~50 GiB image + ~80 GiB deps), TheAgentCompany (175 task images, 30+ GB) | heavy on disk; this is accepted |
| Oracle/gold solution shipped | Terminal-Bench (human oracle per task), Defects4J (triggering tests must fail-before/pass-after, flaky excluded), ABC T.9 | run the oracle in CI on every bench version |
| Result schemas | SWE-bench: predictions JSONL `{instance_id, model_name_or_path, model_patch}`; per-run `results.json` with resolved/unresolved/empty/error/"likely infra failure"/ambiguous counts; per-instance `report.json`, `test_output.txt`, `run_instance.log`, `eval.sh`, `patch.diff` | copy this layout |
| Cloud eval service | SWE-bench `sb-cli`, Terminal-Bench Harbor (horizontal to thousands of containers), SWE-bench Modal backend | optional for us |
| Pinned model + settings | Epoch (API-default temperature, empty system prompt, Inspect task gists, planning git-revision pinning); SWE-rebench (standardized ReAct, 128K) | pin snapshot ids and scaffold commit |
| Published trajectories/logs | HAL (2.5B tokens), SWE-Gym (trajectories), SWE-bench leaderboard (logs required per submission), ITBench-AA | publish ours |
| Repeats on leaderboard | SWE-rebench 5; ITBench 10; Epoch 8–16; METR ~8; ITBench-AA 3; SREGym 3; InfraBench 3 | k=5 is the modal choice |
| Hardware note | SWE-bench (advise disk + `--max_workers`), SREGym-Lite (8 vCPU/16 GB kind), ITBench (m4.xlarge; "pseudo-cluster on a laptop"), Incident-Arena (fresh m7i.2xlarge per trial), OTel demo helm (~4 GB memory per docs, 6 GB per SigNoz) | state ours |
| Snapshot-based determinism | Cloud-OpsBench (frozen state + mocked kubectl, "runs in seconds on a laptop"), ITBench-AA (offline snapshots), OpenRCA (80 GB files) | cheap but kills the live/OBSERVED dimension |
| Run manifests / canaries | DeepSWE (canary GUID in all artifacts), PRML (hashed pre-commitment) | add both |
| Environment drift handling | Terminal-Bench removed download-youtube; DeepSWE v1.1 fixed dependency drift and removed flaky tests; "Reproducible APR is hard" found 21.6% of Defects4J unusable under strict rules | expect drift in OTel demo images; pin chart + image digests |

**"Reproducible by a stranger in an afternoon" (INFERRED, from the above):** one repo; `make bench` that creates the kind cluster, installs pinned OTel demo chart + collector config, runs the oracle agent over all scenarios and asserts 100% RESOLVED; a `run.json` manifest (bench tag, chart version, image digests, model snapshot ids, temperature, turn/$ caps, k, seed); a `results/` tree in SWE-bench's layout; a `verify.py` that recomputes every headline number from the published trajectories; hardware line ("16 cores / 29 GB / Node 20 / kind vX"); and a published cost (ITBench-AA-style $/task). Rerun kits that exist today: SWE-bench (Docker + sb-cli), Terminal-Bench/Harbor (`harbor run --dataset terminal-bench@2.0 --agent oracle`), SREGym (`uv run main.py --suite sregym-lite --agent stratus --model ...`, ~90 min setup), agent-breakage (~90 min setup, ~5 h per arm, $30–60 per arm). None of the live SRE ones is "an afternoon" for the *full* suite; SREGym-Lite (17 problems) is. KNOWN for the commands/timings; the afternoon claim is INFERRED.

---

## 4. The best playground for NEAT

| Environment | Telemetry | Languages | Faults w/ ground truth | Licence | Maintained? | Fits 16c/29 GB? |
|---|---|---|---|---|---|---|
| **OpenTelemetry Demo (Astronomy Shop)** | Full OTel: traces, metrics, logs; collector → Jaeger/Prometheus/OpenSearch/Grafana | ~19 services, 13 languages (ORCA-bench count) | **20 flagd flags** (adFailure, adHighCpu, adManualGc, aiRunawayAgent, aiSlowResponse, cartFailure, cartMetricCardinalityOverflow, emailMemoryLeak, emitRawPii [not a fault], failedReadinessProbe, imageSlowLoad, intlShippingSlowdown, kafkaConsumerDead, kafkaQueueProblems, loadGeneratorFloodHomepage, paymentFailure, paymentUnreachable, productCatalogFailure [targeting rule currently can never turn on], productCatalogLockContention, recommendationCacheFailure); plus PRAXIS's 16 code faults + 9 flag + 5 chaos/manifest; ITBench's scenarios; ORCA-bench's flag schedules; RCA100's chaos drills | Apache-2.0 (from memory; not re-fetched — **verify**) | Yes, CNCF | Yes (helm default ~4 GB; we already run it) |
| ITBench SRE | Grafana/Loki/Jaeger/Prometheus on OTel demo | as above | 42 SRE scenarios (11 of 94 open-sourced; repo README says "6 SRE scenarios with 21 mechanisms") | Apache-2.0 | Active (May 2026 announcement) | Yes |
| SREGym | Prometheus/Loki/Jaeger as MCP servers | 5 apps, 139 services (DeathStarBench, TrainTicket, Astronomy Shop, 2 in-house) | 90 problems incl. OS/eBPF, disk-sector, metastable, concurrent | MIT | Active (2,488 commits, 350★) | Lite yes (8 vCPU/16 GB); full "self-managed cluster, Linux, root" — our box qualifies in principle |
| AIOpsLab | Prometheus/Jaeger/Filebeat+Logstash | DeathStarBench HotelRes/SocialNetwork (C++/Go/etc.) | 48 problems (table sums to 50), Chaos Mesh + functional faults | MIT | 1k★, 640 commits; superseded by SREGym | Yes |
| Incident-Arena | Prometheus + Loki via read-only Obs-MCP | Saleor (Python), Frappe/ERPNext (Python), Mattermost-like (Go) | 20 tasks, config/runtime/image layer | not stated | preprint Oct 2026 | Designed for m7i.2xlarge (8 vCPU/32 GB) per trial → borderline |
| Cloud-OpsBench | snapshot: metrics/logs/k8s objects | Online Boutique (11 gRPC services) + TrainTicket | 452/40 types (paper) or 754/57 (repo) | arXiv CC BY; code licence not stated | active | Yes (no cluster needed) — but no live system |
| ORCA-bench | 6 days of Prometheus/OpenSearch/Jaeger via Grafana API, ~50 GB | OTel demo | 884 incident + 195 control tasks from 11 flags | not stated; on Harbor hub | Jul/Aug 2026 | Data volume heavy; read-only |
| OpenRCA | offline logs/metrics/traces 68 GB | Telecom/Bank/Market (enterprise, no code) | 335 cases | MIT | ICLR'25; 438★ | Needs 80 GB disk/32 GB RAM; no live system |
| RCAEval | offline metrics (RE1), +logs/traces (RE2/RE3) | Online Boutique, Sock Shop, TrainTicket | 735 cases; RE3 = 90 code-level (F1–F5 undefined in README) | MIT | Active (Sep 2026 changelog) | Yes, offline |
| RCA100 / AIOps2025 | six modalities | HipsterShop + OTel demo | >500 expert-labelled cases, competition-validated | not stated (aiops.cn) | 2026 | Offline |
| TrainTicket | tracing/monitoring opt-in flags | 41 services; Java/Node/Python/Go | fault replication in separate papers; TrainTicketTrace (SANER'26) 9 seeded versions | Apache-2.0 | 916★, 65 open issues | Heavy (41 services); memory not stated |
| DeathStarBench | Jaeger in apps (from memory) | SocialNetwork, MediaService, HotelReservation | via AIOpsLab/SREGym | **Ambiguous**: sidebar Apache-2.0 vs README GPLv2 | 957★, 86 open issues | Yes |
| Sock Shop | none built in | Java/Go/Node | via RCAEval | Apache-2.0 | **Archived 29 Dec 2023** | Yes, but dead |
| Online Boutique | OTel tracing, gRPC | 11 services, Go/Python/Node/Java/C# | via RCAEval/Cloud-OpsBench/NetArena | Apache-2.0 (from memory) | Google-maintained | Yes |
| Chaos Mesh / LitmusChaos | n/a (fault injectors) | — | Chaos Mesh: Pod/Network/Stress/IO/DNS/Time/JVM/Kernel/HTTP/BlockDevice/cloud; LitmusChaos ChaosHub count not confirmed | Apache-2.0 (from memory) | CNCF | Yes |
| k8s-ai-bench (GKE Labs) | none | — | create/fix/scale tasks, Pass@1/Pass@5/Pass^5, ephemeral kind clusters | Apache-2.0 | 19★ | Yes |
| agent-breakage | k3d; pgvector; TEI embeddings | — | 9 anchor scenarios + coverage tranches; 24 root-cause vocabulary | Apache-2.0 | 1★, v0.1.0 | Yes |

KNOWN unless marked "from memory".

**Verdict (INFERRED):** stay on the OpenTelemetry Demo. It is the only environment where (a) every service is OTel-instrumented by construction so the OBSERVED layer is dense, (b) five independent groups have now published fault catalogues against it, so our scenarios can be cross-referenced rather than invented, (c) the 13-language mix stress-tests NEAT's extractor honestly (NEAT reads JS/TS/Python natively; Go/Java/C#/Rust/PHP/Ruby/C++/Kotlin services are static-blind → a built-in "static can't see it, OBSERVED can" experiment), and (d) it fits the box. Its weaknesses: flag faults are public and well-known (contamination), several flags are trivially localisable from the flag name in flagd config, and the demo's app code is small per service. The code-fault leg (PRAXIS's 16 + ours) is where NEAT's edge should show and is contamination-clean by construction.

---

## 5. Open benches we can absorb (RESOLVED-signal focus)

Legend for "RESOLVED means": F2P = FAIL_TO_PASS ∧ PASS_TO_PASS tests; Oracle = scripted state/health check; Judge = LLM judge; Loc = localization only.

### 5.1 Live-system benches (NEAT-relevant)

| Bench | Origin / licence | Size, languages | RESOLVED means | Live + telemetry? | Infra | Contamination / age | Integration cost |
|---|---|---|---|---|---|---|---|
| **SREGym** | UIUC (Clark, Su et al.), MIT | 90 problems; 5 apps/139 services; 34 ported from AIOpsLab+ITBench, 43 similar-new, 13 unique | Mitigation **Oracle** per problem (fault resolved + client request success rate + process/k8s state); diagnosis = 9-question **Judge** checklist, pass ≥7/9, κ=0.90 | Yes; Prometheus/Loki/Jaeger via MCP | Lite: kind 8 vCPU/16 GB; full: self-managed cluster | New (May 2026); ported problems were easy (Stratus+Sonnet-4.6 >80% mitigation) | **Medium**: Python/uv/Helm 4; our harness would call its oracles; needs cluster co-tenancy with our OTel demo |
| **ITBench SRE** | IBM + UIUC, Apache-2.0 | 42 SRE scenarios (11 of 94 open) on OTel demo | Mitigation pass@1 = **alert cleared** (Oracle on alert state) | Yes; Grafana/Loki/Jaeger/Prometheus | m4.xlarge; laptop pseudo-cluster | 2025; incidents modelled on IBM SaaS | **Low**: already wired |
| **PRAXIS Code-Cloud-RCA** | IBM/UIUC, DSN'26; Zenodo artifact Apache-2.0 (zip 950 kB) | 30 scenarios: 16 code (schema mismatch 4, ext-dependency handling 6, logic 2, label mismatch 2, const misconfig 2), 9 flag ConfigMap, 2 manifest, 3 Chaos Mesh | **Loc only** (RCI/RCR pass@1). Fix not evaluated | Yes; live k8s OTel demo | kind | Dec 2025–Apr 2026; code faults novel | **Low** (already wired). Extending to RESOLVED needs our own per-fault fix verifier |
| **AIOpsLab** | Microsoft, MLSys'25, MIT | 48 problems (table: 50), HotelRes + SocialNetwork | Mitigation **Oracle**: whole-system health ("all services up") + TTM | Yes; Prometheus/Jaeger/Filebeat | kind/Helm | 2025 | **Medium**; better absorbed via SREGym |
| **Incident-Arena** | Abundant AI / Adrenaline / CMU / Comenius / MGH, licence n/a | 20 tasks (13 Slack-like, 6 Frappe, 1 Saleor) | **Oracle, two gates**: outcome (latency/error/goodput under fresh traffic) + safety (restart, re-fire fault, scope, data integrity) | Yes; Prometheus+Loki read-only MCP; some tasks give source to rebuild one service | fresh k3s on m7i.2xlarge per trial | Oct 2026 | **High** (per-trial VM; artifacts "released with the paper" but no repo found) |
| **TraceRoot** | 2 authors, ICML'26 workshop | 5 incidents, 5 Python/FastAPI services | **Oracle**: end-to-end reproducer, no judge; agent edits source | Partial (structured logs) | Docker | 2026 | **Low** if artifacts exist; too small to matter alone |
| **ORCA-bench** | Traversal/Cornell/Columbia; dataset licence n/a; Harbor hub | 1,079 tasks (884 incident + 195 control), OTel demo, 11 flags | **Loc only**, read-only, Judge 0–3 (κ_w=0.90); 40-task Verified | Yes (6-day recorded telemetry ~50 GB + live code access) | Terminus-2 harness | Jul 2026; flags public | **Medium**; absorb the control-task idea and difficulty tiers (vague reports, TTD 15 min–24 h) |
| **Cloud-OpsBench** | SYSU/CUHK (Lyu), code licence n/a | 452–754 cases, Online Boutique + TrainTicket | **Loc only** (stage/component/reason; A@1, trajectory alignment) | Snapshot twin, mocked kubectl | laptop | Feb 2026 | **Low** but no live system |
| **InfraBench** | Wisconsin (Arpaci-Dusseau), HotInfra'26 | 12 incidents, L1–L4 (Ceph, Slurm…) | per-check risk scoring; 3 repeats | infra-level, not app telemetry | varies | 2026 | **High**, off-target |
| **k8s-ai-bench** | GKE Labs, Apache-2.0 | count n/a; create/fix/scale | state checks (not described); Pass@1/@5/^5 | no app telemetry | kind | 2025–26 | **Low**, but ops-only |
| **agent-breakage** | Odmark, Apache-2.0 | 9 anchors + tranches | 4-axis score vs ground truth | k3d | k3d + pgvector + TEI | 2026 | n/a as bench; methodology reference |
| **MicroRemed** | arXiv 2511.01166 | remediation via Ansible playbooks | playbook execution | ? | ? | 2025 | not investigated further |

### 5.2 Offline RCA datasets (localization only — excluded for RESOLVED, noted for completeness)

OpenRCA (335 cases, 68 GB, MIT; label-recoverability critique by Traversal: Bank-0 no observable onset, Bank-60 label has fewer anomalies than 13 others), RCAEval (735 cases; RE3 90 code-level; MIT; active), RCA100/AIOps2025 (>500, HipsterShop + OTel demo, competition-validated), LEMMA-RCA (multi-domain, Zenodo), TrainTicketTrace (SANER'26), Nezha (a method, not a dataset; its two benchmark datasets are cited as small with missing data). KNOWN. None gives a fix signal; all are useful only for cheap localization sweeps at large n.

### 5.3 Static-repo benches (RESOLVED via tests; no runtime telemetry)

| Bench | Origin / licence | Size, languages | RESOLVED | Infra | Contamination / age | Cost |
|---|---|---|---|---|---|---|
| SWE-bench Verified | Princeton + OpenAI; MIT harness | 500 Python | F2P | Docker per instance | **Retired by OpenAI Feb 2026** (contamination, underspecified tasks); 26 insufficient-test instances (UTBoost) | Low |
| SWE-bench Pro | Scale; harness MIT (secondary); dataset licence not confirmed | 731 public / 858 held-out / 276 commercial; GPL repos | F2P | Docker | Sep 2025; verifier audit claims 8% FP / 24% FN (Datacurve, **unconfirmed**); secondary claim OpenAI retracted recommendation Jul 2026 | Low |
| SWE-bench Live | Microsoft, NeurIPS'25 | 1,319 Python, 93 repos, issues ≥2024 | F2P | Docker per task | continuously refreshed | Low |
| SWE-rebench | Nebius, NeurIPS'25; CC BY 4.0 | >21k Python | F2P | Docker | date-stamped contamination flags; 5 runs | Low |
| SWE-bench Multimodal | Princeton | 617/619 JS (counts vary by source) | F2P | Docker | 2024 | Low–medium |
| Multi-SWE-bench | ByteDance, NeurIPS'25; Apache-2.0 | 1,632 (Java/TS/JS/Go/Rust/C/C++), 68 annotators; mini 400; flash 300; RL 4,723 | F2P | Docker (built on demand) | 2025 | Low–medium |
| SWE-bench-java | (grouped with Multi-SWE-bench by surveys) | count not retrieved | F2P | Docker | 2024 | Low |
| SWE-Gym | Pan et al., ICML'25; Apache-2.0 | 2,438 Python, 11 repos; Lite 234 | F2P | per-instance Docker images | 2024 | Low (training set, not eval) |
| Defects4J | Just et al.; MIT | 854 bugs, 17 Java projects; Java 11 | triggering tests fail-before/pass-after, flaky excluded | JVM | bugs 10–15 years old; contamination/memorization reported; 21.6% unsuitable under strict APR reproducibility | Medium (Java toolchain) |
| BugsInPy | SMU; licence not captured | 493 bugs, 17 Python projects | tests | Docker | 2020 | Medium (reproducibility known to be uneven) |
| GitBug-Java / GitBug-Actions | Silva et al., MSR'24 | 199–200 Java bugs from 2023 commits, 55 repos | GitHub-Actions-reproduced tests | ~50 GiB image + ~80 GiB deps | post-2023 cutoff by design; later memorization reports | High (disk) |
| AgentIssue-Bench | Fudan/NTU | 50 agent-system issues; Docker Hub images | F2P | Docker | 2025; resolve rates 0.67–4.67% | Low |
| Terminal-Bench 2.0 | tbench.ai | 89 tasks, shell | tests on final container state | Docker/Harbor | 2025–26 | Low (Harbor) |
| TheAgentCompany | CMU; MIT | 175 tasks; GitLab/Plane/ownCloud/RocketChat | checkpoint scripts (evaluator encrypted) | Docker Compose, 30+ GB, t3.2xlarge | 2024 | Medium; off-target |
| Commit0 | Cornell/Cohere; MIT | 57 Python libraries | unit-test pass rate | Docker/Modal | 2024; last dated update Sep 2024 | Low; off-target (build-from-spec) |
| RepoBench / CrossCodeEval | — | completion | **excluded**: next-line completion, no fix | — | — | — |
| LiveCodeBench | — | competitive programming | **excluded**: no repo, no system | — | — | — |

KNOWN unless noted.

### 5.4 Ranking rationale (INFERRED)

(a) RESOLVED: SREGym, ITBench, AIOpsLab, Incident-Arena, TraceRoot, all SWE-* (static). (b) Runtime context where NEAT can matter: SREGym, ITBench, PRAXIS, ORCA-bench, Incident-Arena, AIOpsLab. (c) Cost: PRAXIS/ITBench already wired; SREGym-Lite medium; Incident-Arena high. (d) Credibility: peer-reviewed + independent leaderboard (ITBench via Artificial Analysis), peer-reviewed artifact (PRAXIS), large active repo absorbing predecessors (SREGym). Hence the top-3: SREGym (for RESOLVED oracles on a live system), PRAXIS (code faults, extend with our fix check), ITBench (continuity + independent leaderboard). Static SWE-* benches belong in neat-bench only as a **non-regression control**: NEAT's OBSERVED layer is inert there, so a flat result is the expected and desirable outcome and a drop would be a real bug.

---

## 6. Gaps and opportunity

**Is there an open, credible benchmark for "agent fixes a bug in a running distributed system using telemetry + code"?** No. KNOWN by enumeration above:
- PRAXIS and ORCA-bench have code + live telemetry on the OTel demo but stop at diagnosis (ORCA deliberately omits the action loop).
- ITBench, AIOpsLab and SREGym verify *mitigation* on a live system, but their faults are predominantly ops/config/resource faults; mitigation means rollback/scale/config edits, and the oracle is "alert cleared" or "system healthy", which a symptom-suppressing action can satisfy. SREGym's own critique of its predecessors: single fault in a clean environment, no noise, brittle label matching.
- Incident-Arena has the strongest verifier (re-fires the fault; checks persistence, scope, data) and some rebuild-from-source tasks, but it is 20 tasks, per-trial AWS VMs, and I could not find a public repo.
- TraceRoot has reproducer-verified code fixes on a live (tiny) system: 5 incidents, workshop paper.
- Everything with code-fix verification at scale (SWE-*) is static; everything with telemetry at scale (OpenRCA, RCAEval, Cloud-OpsBench) is offline localization.

**Who has tried and how they were received (KNOWN):** AIOpsLab (Microsoft, MLSys'25) — 1k★, widely cited, then absorbed; ITBench (IBM) — adopted by Artificial Analysis as an independent leaderboard (ITBench-AA, 59 snapshot tasks, 3 repeats, $/task), but the public live set is 11 scenarios and the IBM dataset card itself admits snapshots "lack the dynamic characteristics of live environments"; SREGym — 350★ in months, NeurIPS 2026 submission, positioned explicitly as the successor to both; OpenRCA (ICLR'25) — publicly criticised by Traversal for unrecoverable labels and missing change data; SWE-bench Verified — retired by its co-creator after contamination and test-quality findings; vendor "AI SRE benchmarks" (Aurora, nofire.ai, PulseSRE) exist but are self-reported. The pattern: benches that published oracles, repeats and ablations (ITBench's trace-removal, PRAXIS's seeds) got adopted; benches with soft labels got torn apart.

**What neat-bench would need to be *the* reference (INFERRED, each item anchored to a cited practice):**
1. A RESOLVED oracle of Incident-Arena strength: fresh-traffic outcome gate (SLO restored) **and** safety gate (restart pods, re-fire the fault trigger where applicable, assert scope and data integrity), plus for code faults a FAIL_TO_PASS test that the oracle patch passes and the buggy tree fails (SWE-bench semantics). No LLM judge anywhere in RESOLVED.
2. ABC-grade grader validity for RCI/RCR: negation handling, no credit for candidate lists, trivial-agent and control-scenario baselines reported, human audit of ≥100 graded samples with κ.
3. Scenario count ≥90 (SREGym size) to get MDE under ~20 pp; reuse SREGym/ITBench/PRAXIS scenarios where licences allow and add our code faults; declare which classes are "NEAT cannot matter" nulls up front (PRAXIS did this for infra faults).
4. Four arms defined by what they remove, same model snapshot and scaffold, k=5, paired clustered CIs, pass@1 + pass^5, $/task, tokens per success; pre-registered analysis plan in a hashed manifest before the clean run.
5. Container-pinned environment, oracle agent in CI, SWE-bench-style result tree, published trajectories, canary GUID, one-command rerun with a stated hardware line; an invitation to a third party (HAL / Epoch / Artificial Analysis style) to rerun one arm.
6. A held-out slice (ITBench-AA 19/59; SWE-bench Pro 858) and a contamination statement per scenario class (flag faults = public since years; code faults = novel).
7. Honest limitations section in the METR style: scaffold sensitivity, composition sensitivity, which fault classes the OBSERVED layer actually touched.

**Opportunity (INFERRED):** the field has telemetry-only RCA benches and code-only repair benches; the fused "diagnose from OBSERVED + fix in code + verify under traffic" bench does not exist at >20 tasks with public artifacts. That is exactly NEAT's claimed edge, and the first group to ship it with the rigour above (and to show a null where the tool should not matter) will own the reference point, as SREGym is doing for ops-level mitigation right now.

---

## 7. References

Methodology
- Kapoor, Stroebl et al., AI Agents That Matter — https://arxiv.org/abs/2407.01502 ; https://agents.cs.princeton.edu/
- Miller, Adding Error Bars to Evals — https://arxiv.org/abs/2411.00640 ; https://www.anthropic.com/research/statistical-approach-to-model-evals
- Hochlehnert et al., A Sober Look at Progress in LM Reasoning — https://arxiv.org/abs/2504.07086
- Bjarnason, Silva, Monperrus, On Randomness in Agentic Evals — https://arxiv.org/abs/2602.07150
- Zhu et al., Establishing Best Practices for Building Rigorous Agentic Benchmarks (ABC) — https://arxiv.org/abs/2507.02825 ; NeurIPS 2025 D&B
- Yu et al., UTBoost — https://arxiv.org/abs/2506.09289 ; https://ddkang.substack.com/p/swe-bench-verified-is-flawed-despite
- SWE-ABS — https://arxiv.org/pdf/2603.00520
- OpenAI, Why we no longer evaluate SWE-bench Verified — https://openai.com/index/why-we-no-longer-evaluate-swe-bench-verified/
- OpenAI, Introducing SWE-bench Verified — https://openai.com/index/introducing-swe-bench-verified/
- Reuel et al., BetterBench — https://arxiv.org/abs/2411.12990 ; https://betterbench.stanford.edu/
- Singh et al., The Leaderboard Illusion — https://arxiv.org/abs/2504.20879
- Kapoor et al., Holistic Agent Leaderboard — https://arxiv.org/abs/2510.11977 ; https://hal.cs.princeton.edu/about
- Epoch AI Benchmarking Hub methodology — https://epoch.ai/benchmarks/about ; benchmark reviews summary — https://www.theneuron.ai/news/epoch-ai-benchmark-reviews-nine-flawed/
- METR Time Horizon 1.1 — https://metr.org/blog/2026-1-29-time-horizon-1-1 ; https://epoch.ai/benchmarks/metr-time-horizons
- τ-bench — https://arxiv.org/abs/2406.12045
- EvalCards — https://arxiv.org/abs/2511.21695 ; Evaluation Cards — https://huggingface.co/papers/2606.09809 ; Preregistration for Experiments with AI Agents — https://arxiv.org/pdf/2606.11217 ; PRML — https://oecd.ai/en/catalogue/tools/prml-%E2%80%94-pre-registered-ml-manifest-specification
- HN sceptic comments (Algolia API) — https://hn.algolia.com/api/v1/search?query=SWE-bench%20contamination&tags=comment
- Devin claims critique — https://newsletter.pragmaticengineer.com/i/143712983/devin-reversing-ambitious-claims-and-an-open-source-threat
- Scaffold spread on SWE-bench Pro (secondary) — https://agentmarketcap.ai/blog/2026/04/18/swe-bench-pro-scaffold-premium-5-15-point-procurement-gap ; https://codex.danielvaughan.com/2026/06/17/benchmark-literacy-guide-reading-coding-agent-benchmarks-critically/
- Augment claims (vendor) — https://www.augmentcode.com/blog/auggie-tops-swe-bench-pro ; Verdent ablation (vendor) — https://www.verdent.ai/blog/swe-bench-verified-technical-report

Coding benches
- SWE-bench evaluation guide — https://swebench.com/SWE-bench/guides/evaluation/ ; datasets — https://swebench.com/SWE-bench/guides/datasets
- SWE-bench Pro — https://arxiv.org/abs/2509.16941 ; https://hub.harborframework.com/datasets/scale-ai/swe-bench-pro
- SWE-bench Live — https://arxiv.org/abs/2505.23419
- SWE-rebench — https://arxiv.org/abs/2505.20411
- SWE-bench Multimodal — https://arxiv.org/abs/2410.03859
- Multi-SWE-bench — https://arxiv.org/abs/2504.02605 ; https://github.com/multi-swe-bench/multi-swe-bench
- SWE-Gym — https://arxiv.org/abs/2412.21139 ; https://github.com/SWE-Gym/SWE-Gym
- Defects4J — https://github.com/rjust/defects4j ; Reproducible APR is hard — https://arxiv.org/abs/2604.26674
- BugsInPy — https://github.com/soarsmu/BugsInPy
- GitBug-Java — https://arxiv.org/abs/2402.02961 ; https://github.com/gitbugactions/gitbug-java
- AgentIssue-Bench — https://arxiv.org/abs/2505.20749 ; https://github.com/alfin06/AgentIssue-Bench
- Terminal-Bench — https://arxiv.org/abs/2601.11868 ; https://www.tbench.ai/news/announcement-2-0 ; https://www.tbench.ai/leaderboard/terminal-bench/2.0
- TheAgentCompany — https://arxiv.org/abs/2412.14161 ; https://github.com/TheAgentCompany/TheAgentCompany
- Commit0 — https://arxiv.org/abs/2412.01769 ; https://github.com/commit-0/commit0
- RepoBench — https://arxiv.org/abs/2306.03091 ; CrossCodeEval — https://arxiv.org/abs/2310.11248
- DeepSWE — https://deepswe.datacurve.ai/blog/deepswe-v1-1

SRE / RCA benches and environments
- ITBench paper — https://arxiv.org/abs/2502.05352 ; repo — https://github.com/itbench-hub/ITBench ; ITBench-Lite — https://huggingface.co/datasets/ibm-research/ITBench-Lite ; ITBench-AA — https://artificialanalysis.ai/articles/itbench-aa-launch ; https://huggingface.co/blog/ibm-research/itbench-aa
- PRAXIS — https://arxiv.org/abs/2512.22113 ; artifact — https://zenodo.org/records/19247887 (DSN 2026 AE record, Apache-2.0; verified 2026-10-16)
- AIOpsLab — https://arxiv.org/abs/2501.06706 ; https://github.com/microsoft/AIOpsLab/ ; MLSys'25 listing — https://www.microsoft.com/en-us/research/people/jonathanmace/publications/
- SREGym — https://arxiv.org/abs/2605.07161 ; https://github.com/SREGym/SREGym
- Incident-Arena — https://arxiv.org/html/2610.00648v1
- ORCA-bench — https://arxiv.org/abs/2607.28545 ; https://www.traversal.com/blog/orca-bench-how-ready-are-language-model-agents-for-oncall
- Cloud-OpsBench — https://arxiv.org/abs/2603.00468 ; https://github.com/LLM4Ops/Cloud-OpsBench
- OpenRCA — https://github.com/microsoft/OpenRCA ; critique — https://www.traversal.com/blog/openrca-isnt-root-cause-analysis-why-that-matters
- RCAEval — https://arxiv.org/abs/2412.17015 ; https://github.com/phamquiluan/RCAEval ; https://zenodo.org/records/14504481
- RCA100 / AIOps2025 — https://arxiv.org/abs/2606.29193
- LEMMA-RCA — https://arxiv.org/abs/2406.05375
- TraceRoot (Executable Ground Truth) — https://icml.cc/virtual/2026/68276
- MicroRemed — https://arxiv.org/abs/2511.01166
- InfraBench — https://arxiv.org/abs/2608.11234
- NetArena — https://arxiv.org/abs/2506.03231
- agent-breakage / measurement substrate — https://arxiv.org/abs/2605.23058 ; https://github.com/odmarkj/agent-breakage
- k8s-ai-bench — https://github.com/gke-labs/k8s-ai-bench ; kube-agent-benchmarks — https://github.com/crafting-demo/kube-agent-benchmarks ; PulseSRE sre-bench — https://github.com/PulseSRE/sre-bench ; agentkube SRE-bench — https://github.com/agentkube/SRE-bench
- OpenTelemetry Demo flags — https://raw.githubusercontent.com/open-telemetry/opentelemetry-demo/main/src/flagd/demo.flagd.json ; docs — https://opentelemetry.io/docs/demo/feature-flags/ ; helm — https://opentelemetry.io/docs/platforms/kubernetes/helm/demo/
- TrainTicket — https://github.com/FudanSELab/train-ticket ; TrainTicketTrace (SANER'26) — https://conf.researchr.org/details/saner-2026/saner-2026-workshops-tutorials-track/43/
- DeathStarBench — https://github.com/delimitrou/DeathStarBench
- Sock Shop (archived) — https://github.com/microservices-demo/microservices-demo
- Chaos Mesh — https://chaos-mesh.org/docs/simulate-pod-chaos-on-kubernetes/ ; LitmusChaos — https://www.cncf.io/blog/2020/08/28/introduction-to-litmus/

Weak-source notes: agentmarketcap.ai, codesota, aiwiki, morphllm, buildmvpfast and similar aggregator blogs were used only where their figures agreed with each other and nothing primary contradicted them; they are marked secondary in the text. The OpenAI Verified post and the LitmusChaos hub could not be fetched directly. OTel demo, Online Boutique and Chaos Mesh licences are from memory and should be confirmed on the repos before being written into a contract.
