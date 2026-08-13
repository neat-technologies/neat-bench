# neat-bench

**Agents that scale the coding bubble.** The benchmark for what NEAT adds to a coding agent: point the *same* model at a real system with and without NEAT's fused static+runtime graph, and measure the difference — accuracy, safety, efficiency, autonomy, concurrency, reach, and trust.

It is **one rig, a dashboard of numbers** — not a single score. The rig: a same-model agent, run **±NEAT**, against **certified walls** (tasks whose answer is provably *not* in the source, only in runtime behaviour), scored by **objective oracles**. The keystone is model-free.

## Why this exists

An earlier fixture ([`neat-agent-bench`](../neat-agent-bench)) tied on correctness because its target was *legible* — a strong agent read its way through. The lesson: NEAT's edge only appears where reading the source **cannot** get you there. So this benchmark measures exactly that boundary, and refuses to count anything that isn't on it.

## The suite (SWE-bench-shaped, stratified)

Found tasks on runnable services, scored by a judge-free test oracle (FAIL_TO_PASS + PASS_TO_PASS), run ±NEAT, and **reported per runtime-dependence stratum** so a tie and a blowout don't average into "modest":

- **static-solvable** — the answer is in the source; NEAT should **tie** (honest control).
- **runtime-rooted** — reachable only via runtime behaviour; NEAT **wins**.
- **wall** — provably absent from source (certified); the without-NEAT arm **can't finish**.

Schema, strata, and the curation pipeline: [`docs/INSTANCES.md`](docs/INSTANCES.md). Seed in `instances/` (2 controls + 2 runtime-rooted ported from validated bugs + 1 wall candidate) — `npm run validate`.

## The keystone: Grounded-Evidence Rate (model-free)

> Of the load-bearing facts the agent leaned on, what % trace back to something **real** (an observed trace) vs. invented or merely *declared by code that may be lying*?

It grades the agent's **context, not its outcome**, so it's nearly model-free — the most skeptic-proof number in the set. Three tiers: `observation-grounded` (3) · `declared-only` (2, may be diverged — the northsea class) · `unbacked` (1). Paired with a **sufficiency** guard so "assert less, score higher" can't game it.

## Status (honest)

**Proven and running** — the model-free bricks, selftested against a real captured graph (`npm run selftest`):

| brick | what it does | proof |
|---|---|---|
| `harness/claim-classifier.mjs` | the EXTRACTED-twin JOIN — classifies each observed edge CONFIRMED / GRAIN_REFINED / IDENTITY_SUSPECT / BLIND | quarantines the `database:mongodb`↔`database:127.0.0.1` split instead of banking it as a blindness win |
| `harness/grounded-evidence.mjs` | the keystone — tiers agent claims + sufficiency | 40% grounded on the sample, tiers correct |
| `harness/wall-certificate.mjs` | proves a task is a genuine wall (source-absence + BLIND carrying edge) | **refuses** to certify the sample wall on the legible fixture |
| `harness/aggregate.mjs` | per-(wall×arm×N) roll-up with spread + ±NEAT delta | rolls up synthetic trials |

**Scaffolded, needs a live target** — marked `TODO(live)` in the code, no results faked:

- `harness/provision/` — target-descriptor-driven provisioner (clone→instrument with a **local NEAT checkout**→daemon→**drive the target's own test suite**→snapshot). Span-driven, **no connectors** (connector-pulled OBSERVED is not a real trace).
- `harness/arms/` — the ±NEAT agent-arm runner, **wired to Claude Code headless** (`claude -p --output-format stream-json`, MCP via `--mcp-config`, `--allowedTools` arm split). The metrics + claims pipeline (`parse-claude-stream` → `extract-claims` → `grounded-evidence`) is proven on fixtures **and against a captured real Claude Code run** (`fixtures/real-claude-stream.jsonl`); a full ±NEAT run needs a provisioned target + a running daemon.
- `run.sh` — one-command orchestration.

## Quickstart

```bash
npm run selftest          # runs every model-free brick against the real fixture graph
node harness/claim-classifier.mjs fixtures/express-mongoose.graph.json
```

Running the full rig against a real target needs a local NEAT checkout (`NEAT_REPO=/path/to/Neat`) and Docker; see `docs/DESIGN.md`.

## The dashboard

Seven groups of metrics, one rig. Full definitions + oracle + *model-free-vs-ablation* tag in [`docs/METRICS.md`](docs/METRICS.md). Headlines: **Grounded-Evidence Rate**, **first-pass fix accuracy**, **no-prod-break rate**, **autonomous-resolution rate**, **walls-cleared**.

## Docs

- [`docs/DESIGN.md`](docs/DESIGN.md) — the rig, the arms, the perfect-NEAT→walls loop, the dev loop.
- [`docs/METRICS.md`](docs/METRICS.md) — the full metric catalog.
- [`docs/WALLS.md`](docs/WALLS.md) — the three axes and the model-free wall certificate.
- [`docs/HONESTY.md`](docs/HONESTY.md) — the guards that keep a number unbreakable.
- [`docs/INSTANCES.md`](docs/INSTANCES.md) — the instance schema, the three strata, and the curation pipeline.
- [`docs/CORPUS.md`](docs/CORPUS.md) — the realistic multi-cloud startup system the suite runs on, and its phased buildout.
- [`docs/NEAT-FINDINGS.md`](docs/NEAT-FINDINGS.md) — NEAT bugs the meter surfaced, linked to filed issues.

## The rule

*A number a skeptic can break is worse than no number.* Work → prove → ship; prove means *try to break it against ground truth*, and only the survivors ship.
