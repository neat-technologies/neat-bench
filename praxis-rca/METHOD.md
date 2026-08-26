# BenchOps — PRAXIS Code-Cloud-RCA, ±NEAT, find **and** fix

The launch benchmark. NEAT's real value — the **fused code+runtime graph as an agent's full-stack eyes** — measured on a public, third-party, code-grain RCA benchmark where fusion is provably decisive. Not divergence-detection; the graph as context for localizing **and fixing** code-level root causes in a live microservice system.

## Why this benchmark
- **Public + reproducible:** PRAXIS "Code-Cloud-RCA" (arXiv 2512.22113, IBM+UIUC), Zenodo `10.5281/zenodo.19163486` (Apache-2.0), in `itbench-hub/ITBench`. 30 scenarios on the **OpenTelemetry Demo** — the same app our box already fuses.
- **Code grain:** graded at RCI (faulty *service*) **and RCR (faulty statement/function/config)** — the grain where fusion wins. (ITBench-SRE's k8s-object grain is where a kubectl agent already wins → draws. We are NOT running that.)
- **Third-party faults = no self-overfitting.** The faults are authored by IBM+UIUC, patterned on real outages — we did not pick them to flatter NEAT. **We never inject our own bugs.** (That was the whole point of moving off the SRE grind.)
- **Published baseline to anchor against:** runtime-only agent = **0.0% RCR** / 11.4% RCI; PRAXIS fused = **61.5% / 73.9%** (gpt-5-codex, Pass@1). The 0% runtime-only row is the story on a plate.

## Arms (control variables: same model = Claude Opus, same scenario state, same token/step budget; ONLY the tooling differs)
Three arms: **`code`**, **`obscode`**, **`neat`**.

| arm | code access | runtime signal | fused? | isolates |
|---|---|---|---|---|
| **code** | source (read/grep/LSP) | none | — | the floor (raw-code ceiling) |
| **obscode** | source (read/grep/LSP) | raw observability — traces + metrics (Jaeger/Prometheus), from the same live app | **NO** — two separate signals, the agent joins them by hand | the realistic strong baseline: **both signals, unfused** |
| **neat** | source | **live `neat watch` daemon** ingesting live OTel | **YES** — one fused code+runtime graph, full arsenal | **the join** |

`obscode` and `neat` get the **same two inputs** — the code, and the runtime. The only difference is that `neat` fuses them into one queryable graph and `obscode` hands the agent both raw and lets it stitch. So if `neat` beats `obscode`, the win is provably **the fusion itself**, not "NEAT has data the baseline lacks." Stronger than anything PRAXIS published (they never tested both-but-unfused).

**Honesty guard:** `obscode` must be a genuinely strong baseline — real, complete trace/metric access (not a crippled subset), full source, and explicitly told to use both. A weak `obscode` strawmans the baseline and the fusion win is fake.

## Full NEAT extent — the anti-"glorified obscode" rule (task selection)
The tasks must **require NEAT's whole reasoning surface**, not its weakest one. If a scenario is winnable by joining **one error span to one code line**, it is a **weak** scenario for this bench: `obscode` reaches it too (see the trace, read the file), so it tests NEAT's thinnest edge and *understates* fusion. A scenario earns its place only when the answer needs graph reasoning `obscode` cannot cheaply reconstruct by hand:
- **blast-radius** over OBSERVED edges (what else the fault reaches, transitively);
- **divergence** — declared (EXTRACTED) vs observed (OBSERVED) across the system, not one file;
- **time-travel graph-diff** — healthy snapshot vs broken, what actually changed;
- **stale-edges** — a dependency that went silent;
- **multi-hop root-cause** through the fused graph, not a single hop.

Weight scenario selection toward the **fusion-decisive** class (neo4j-timeout 405–410, propagation/blast-radius, cross-service divergence) and *away* from single-service "error→line" faults. Concretely: the 401 `products_list` data-schema fault is **close to glorified obscode** (an obs+code agent sees the `AttributeError` and reads the file) — its fusion margin is thin, so it is a control/warm-up, not a headline. The headline scenarios are the ones where the graph is load-bearing.

## Per-scenario loop — each run is: Load Scenario → Load Tools → Load Headless Agent
1. **Load Scenario** — inject PRAXIS fault N into the live OTel Demo on the KinD box (faithful to the artifact's injector; state identical across all three arms).
2. **Load Tools** — set up ONLY this arm's tooling: `code` = source access (read/grep/LSP), nothing else; `obscode` = source access **+** raw trace/metric access (Jaeger/Prometheus over the live app), the two unfused; `neat` = `neat init` + a live `neat watch` daemon fused via the collector, the full arsenal exposed.
3. **Load Headless Agent** — one fresh Claude Opus agent for this arm, same model + budget as the others, told to diagnose-**and-fix** with its arm's tools only.
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
- `obscode` arm = raw code (read/grep/LSP) + raw traces/metrics (Jaeger/Prometheus), unfused (Cem, 2026-08-27). graphify dropped — leaner, and it isolates fusion over the same two signals.
- Box: user re-spawning; harness (KinD + OTel-Demo + collector→NEAT fusion) transfers from the SRE run.
