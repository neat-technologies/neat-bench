# Competitive RCA bench

An 8-arm root-cause-analysis benchmark. The question it answers is narrow and head-to-head: hand the *same* coding agent an incident on a live system, swap only the context source it reads from, and measure how far each source carries the agent toward naming the fault and clearing it.

Every arm is the same model under the same budget and the same prompt. The one variable is the signal the agent gets to lean on — raw source, a static graph, a runtime observability product, or NEAT's fused static+runtime graph. That isolation is the whole point: differences in the score are differences in the context, not the agent.

## The arms (8)

| arm | signal the agent reads from |
|---|---|
| `code` | raw read-only source only — **the baseline** (same model, no NEAT) |
| `graphify` | a static code graph built from the source |
| `obscode` | a runtime/observability-code signal over the live system |
| `neat` | NEAT's fused static+runtime graph, over MCP (`mcp__neat__*`) |
| `sentry` | Sentry's error/issue signal |
| `datadog` | Datadog's APM/trace signal |
| `qodo` | Qodo PR-Agent's AI review of the fault-as-diff |
| `greptile` | Greptile code search — **unconfigured this run, excluded from results** |

The `code` arm is the control. It is the same model with no NEAT and no third-party signal — just the source a developer would open in an editor. Every other arm is that same agent with one extra pair of eyes bolted on, so each arm's number reads as "what this signal adds over reading the code." NEAT's claim is specifically against `code`: same model, ±NEAT.

## Models (2)

Each arm runs under two models so a result isn't an artifact of one of them:

- `claude-opus-5-5`
- `claude-sonnet-5-5`

PRAXIS reports CAUGHT per model out of 10, and combined out of 20.

## Suites

Both suites run on a KinD cluster hosting the OpenTelemetry demo — a real multi-service storefront (frontend, cart, checkout, product-catalog, recommendation, ad, payment, and friends) wired to a live collector, so the OBSERVED signal arms have genuine traces to read.

**PRAXIS-14** — 14 curated scenarios on the demo: 10 **detect** (localize the faulty service and the nature of the fault) and 4 **resolve** (also apply a fix that clears it). These are image, env, and code faults — the kind where runtime behaviour diverges from what the source declares.

**ITBench-67** — 67 faults: 14 app-flag faults (a feature flag served in a state the code doesn't commit — remediated through the scoped `fix-flag.sh` tool) and 53 infra/chaos faults injected into the cluster. The detect and resolve legs run the same arm-vs-arm structure as PRAXIS.

## Grade ladder

A run climbs three rungs. Each is strictly harder than the one below it, and nothing is credited for a near miss.

1. **CAUGHT** — the agent named the **right service** *and* the **right nature of the fault**. Localizing the service alone does not count; the root-cause has to be the real one.
2. **RESOLVED** — the agent applied a change and the **fault actually cleared** (the storefront is healthy again on the affected path), verified against the live system, not self-reported.
3. **ROBUST** — RESOLVED **and zero regressions**. A `pass2pass` baseline captures the storefront's healthy behaviours before the fault; after the fix lands, the same probes re-run and any green-to-red flip counts as a regression. ROBUST is RESOLVED with that regression count at zero.

Detect scenarios are graded to CAUGHT. Resolve scenarios are graded to RESOLVED and ROBUST.

## Harness

The scripts under [`harness/`](harness/) drive the rig. Credentials are never embedded — the arms source them from env-file paths (`$HOME/.bench-creds/creds.env`, `$HOME/.bench-key`) and read keys like `$DD_API_KEY` / `$ANTHROPIC_API_KEY` from the environment.

| script | what it does |
|---|---|
| `run-full81.sh` | top-level orchestrator: PRAXIS-14, then ITBench detect, then the flag-resolve leg, all arms, both models, into one run directory |
| `run-praxis-matrix.sh` | the PRAXIS-14 matrix — clean baseline, warm the storefront, capture the pass2pass baseline, run detect (parallel arms) then resolve (RESOLVED + ROBUST) |
| `run-neat-mcp-detect.sh` | the `neat` detect arm — a real-user setup: `neat claude install` writes the directive, the agent pulls from NEAT's MCP server on its own |
| `run-qodo.sh` | the `qodo` resolve arm — the agent's signal is Qodo's AI review of the fault diff plus read-only source, then it patches |
| `run-flagfix.sh` | a single flag-fault resolve run for one arm — diagnose, then remediate through `fix-flag.sh` |
| `run-itbench-resolve.sh` | the ITBench app-flag resolve leg — inject each flag fault, run the arm, verify it cleared |
| `fix-flag.sh` | the scoped ACT tool an arm calls to set a flag's variant back to its committed value and reload flagd |
| `verify-flag.sh` | checks a flag fault cleared: flagd serves the committed value *and* the storefront is healthy |
| `pass2pass.sh` | the regression leg of ROBUST — capture the healthy baseline, re-check it after a fix |
| `summarize-overnight.sh` | rolls a results TSV up into the per-model, per-arm CAUGHT / RESOLVED / ROBUST tables |

Several scripts referenced here (`run-fullsuite.sh`, `run-itbench.sh`, `bench-reset.sh`, the competitor libs) live on the bench host alongside the cluster and are driven by these entrypoints.

## Results

See [`results.md`](results.md) for the current numbers. They are preliminary — a single k=1 pass — and the certified multi-k tables follow once the full matrix has re-run clean.
