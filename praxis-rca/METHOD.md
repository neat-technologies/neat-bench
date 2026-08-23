# BenchOps — PRAXIS Code-Cloud-RCA, ±NEAT, find **and** fix

The launch benchmark. NEAT's real value — the **fused code+runtime graph as an agent's full-stack eyes** — measured on a public, third-party, code-grain RCA benchmark where fusion is provably decisive. Not divergence-detection; the graph as context for localizing **and fixing** code-level root causes in a live microservice system.

## Why this benchmark
- **Public + reproducible:** PRAXIS "Code-Cloud-RCA" (arXiv 2512.22113, IBM+UIUC), Zenodo `10.5281/zenodo.19163486` (Apache-2.0), in `itbench-hub/ITBench`. 30 scenarios on the **OpenTelemetry Demo** — the same app our box already fuses.
- **Code grain:** graded at RCI (faulty *service*) **and RCR (faulty statement/function/config)** — the grain where fusion wins. (ITBench-SRE's k8s-object grain is where a kubectl agent already wins → draws. We are NOT running that.)
- **Third-party faults = no self-overfitting.** The faults are authored by IBM+UIUC, patterned on real outages — we did not pick them to flatter NEAT. **We never inject our own bugs.** (That was the whole point of moving off the SRE grind.)
- **Published baseline to anchor against:** runtime-only agent = **0.0% RCR** / 11.4% RCI; PRAXIS fused = **61.5% / 73.9%** (gpt-5-codex, Pass@1). The 0% runtime-only row is the story on a plate.

## Arms (control variables: same model = Claude Opus, same scenario state, same token/step budget; ONLY the code-intel tooling differs)
| arm | code access | runtime signal | graph | isolates |
|---|---|---|---|---|
| **code** | full source | none | none | the floor (raw-code ceiling) |
| **obs + graphify** | full source | observability (traces/metrics from **driving full user flows**) | **graphify builds its OWN code graph**, run like normal | the realistic strong baseline: both signals, **unfused** |
| **opus + neat** | full source | **live `neat watch` daemon** ingesting live OTel | NEAT fused code+runtime graph | **the join** |

If `opus+neat` beats `obs+graphify`, the win is provably the **fusion**, not "NEAT has data the baseline lacks" — both have code + runtime; only NEAT joins them. Stronger than anything PRAXIS published (they never tested both-but-unfused).

**Honesty guard:** the `obs+graphify` arm must be genuinely strong — a real graphify graph, real trace access, told to use both. A weak graphify setup strawmans the baseline and the win is fake.

## Per-scenario loop
1. **Start scenario** — inject PRAXIS fault N into the live OTel Demo on the KinD box (faithful to the artifact's injector; state identical across arms).
2. **Inject headless Claude** — one fresh Claude Opus agent per arm, diagnose-**and-fix**, per-arm tooling only.
3. **Download code-intel packages** — arm sets up its tooling: `code` = nothing; `obs+graphify` = graphify builds its graph + a load driver runs full user flows; `neat` = `neat init` + live `neat watch` daemon fused via the collector.
4. **Run & observe** — the agent localizes the root cause AND produces a **fix** (a patch).
5. **Verify the fix** — apply the agent's patch → rebuild/redeploy the affected service → drive load → assert the **symptom clears** (the graded fix oracle; see SCORING.md). Fall back to reference-patch match only if apply-and-verify is infeasible for a scenario, and label it.
6. **Grade find + fix together** — RCI/RCR localization AND fix-resolves-fault, one combined score per arm.
7. **File a per-scenario report** (REPORT-TEMPLATE.md) into `praxis-rca/results/scenario_N/`.

## NEAT-weakness sub-loop (runs inside the main loop)
When NEAT shows **any** weakness — a bug, a misdirection, a low-confidence/misleading answer, a missing capability, anything that made the neat arm slower or wrong:
1. **File a GitHub issue** on `neat-technologies/neat` with the exact reproduction from the scenario. No fudging, no minimizing.
2. **Dispatch one of my own subagents** (isolated worktree, off `main`) to research + fix it — real fix, tests, PR.
3. **Ship to npm `latest` immediately** (the release train), so the next scenarios run the improved NEAT.
4. Continue. Re-run affected scenarios on the new version.

**Hard rule:** not a single line of bench code / contracts / ADRs on `neat-technologies/neat`. Bench lives here in `neat-bench`. NEAT bugs surface there as **issues**; fixes land in core and ship to `latest`; `main` governance stays as the core team runs it.

## Anti-fudge firewall
- Third-party faults only (PRAXIS's), pre-registered scenario list frozen before runs.
- Same model, same budget, identical injected state across arms; randomize arm order; ≥3 seeds/scenario; report variance.
- Fix verified by the app actually recovering, not by an LLM saying "looks fixed."
- Every NEAT weakness filed + fixed transparently — the fixes are part of the public record, not hidden.

## Status / open inputs
- PRAXIS artifact format + fix-verification path: under recon (agent `a39febdcf70d89088`).
- graphify identity (user skill vs Augment product): pending user confirm; obs+graphify arm wired on answer.
- Box: user re-spawning; harness (KinD + OTel-Demo + collector→NEAT fusion) transfers from the SRE run.
