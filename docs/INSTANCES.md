# Instances — the suite (SWE-bench-shaped, stratified for NEAT)

The benchmark is a **suite of found tasks on runnable services**, scored by a judge-free test oracle, run ±NEAT, and **reported per runtime-dependence stratum**. This is SWE-bench's skeleton with the two changes NEAT forces.

## What we take from SWE-bench

- **Found tasks:** a real issue + the real PR that fixed it. `repo @ base_commit` + the issue text is all the agent sees.
- **Judge-free oracle:** the repo's own tests. **FAIL_TO_PASS** (fail on the bug, pass on the fix) + **PASS_TO_PASS** (green before and after — the regression guard). Resolved iff all FAIL_TO_PASS flip green and no PASS_TO_PASS breaks. *(PASS_TO_PASS is our no-prod-break metric for free.)*
- **% resolved at scale**, on a leaderboard.

## What NEAT changes (or we tie)

1. **Runnable services, not libraries.** SWE-bench's repos are mostly libraries (django, sympy) — dead snapshots with no runtime to observe. NEAT's OBSERVED layer needs a live, instrumented system emitting spans, so instances carry a **`runtime_workload`** (the test suite or a traffic script that fires the relevant path) and we bias to services: web apps, APIs, microservices, queue workers.
2. **Stratify by runtime-dependence; report per stratum.** An undifferentiated suite ties, because most tasks are static-solvable. Every instance is tagged, and `% resolved` is reported **per stratum** — the mean of a tie and a blowout is "modest" and buries the finding.

| stratum | the answer is… | expected ±NEAT | role |
|---|---|---|---|
| `static-solvable` | in the source; a static read gets there | **tie** | honest control — if NEAT "wins" here, something's rigged |
| `runtime-rooted` | reachable only via runtime behaviour (non-local cause, dynamic dispatch, config/env divergence, incident-rooted) | **NEAT wins** | the differentiator |
| `wall` | *provably* absent from source (certified by `wall-certificate.mjs`) | **without-NEAT can't finish** | the high-signal tail — sharpest subset of runtime-rooted, not the whole suite |

## Instance schema

```jsonc
{
  "id": "unique-id",
  "origin": "found | constructed",          // SWE-bench is found; injected bugs are constructed
  "source": "issue URL, or a corpus name",
  "stratum": "static-solvable | runtime-rooted | wall",
  "repo": "https://github.com/...",
  "base_commit": "sha",                       // the buggy state the agent starts from
  "problem_statement": "the issue text / symptom — ALL the agent sees",
  "gold_patch": "path or inline — the reference fix, never shown to the agent",
  "oracle": {
    "type": "tests | probe",
    "fail_to_pass": ["test::ids"],            // type=tests
    "pass_to_pass": ["test::ids"],
    "probe": { "request": "...", "healthy": "...", "buggy": "..." }  // type=probe
  },
  "runtime_workload": { "mode": "test-suite | traffic", "cmd": "...", "preload_otel": true },
  "runtime_dependence": "why static can or cannot reach the answer (the stratum rationale)",
  "wall_certificate": {                        // REQUIRED iff stratum=wall
    "absence_predicate": { "cmd": "grep/AST over src/", "expect": "empty" },
    "carrying_edge": { "type": "...", "source": "...", "target": "..." }
  },
  "root_cause": { "file": "...", "line": 0, "function": "...", "detail": "..." },
  "required_facts": [ { "type": "...", "source": "...", "target": "..." } ],  // grounded-evidence sufficiency
  "validated": { "symptom_reproduced": true, "oracle_runs": false },          // honest status
  "neat_signal": { "decisiveness": "HIGH|MEDIUM|LOW|NONE", "note": "..." }
}
```

`harness/instance-validate.mjs` checks well-formedness + the stratum rules (a `wall` must carry a `wall_certificate`; an oracle is `tests` xor `probe`). The **execution** check — that FAIL_TO_PASS actually fails on `base_commit` and passes on `gold_patch`, and that a `wall` certifies — is the `TODO(live)` seam (needs the repo stood up), run through `run.sh`.

## Curation pipeline (a candidate → a validated instance)

Mirrors how SWE-bench was built, plus NEAT's runtime step:

1. **Find** a real issue + its fixing PR in a runnable service repo.
2. **Pin** `base_commit` (pre-fix) and record `gold_patch` (the PR diff).
3. **Confirm FAIL_TO_PASS fails** at `base_commit` and **passes** under `gold_patch`; pick PASS_TO_PASS from the suite's already-green tests.
4. **Define the runtime workload** — the test/traffic that makes the relevant path emit spans (must hit *real* datastores/queues, not mocks).
5. **Classify the stratum.** For a `wall`, author the `absence_predicate` + `carrying_edge` and run `wall-certificate.mjs`; it only counts if it certifies.
6. Mark `validated`.

## Seed

The seed reuses the 12 already-validated bugs from `neat-agent-bench` (real, symptom-reproduced-live, and pre-stratified by their `neat_signal.decisiveness`: LOW/NONE → static-solvable, MEDIUM → runtime-rooted, B2 HIGH/`grep_suffices:false` → the near-wall). They are `origin: constructed` on a legible target — a valid **control-heavy seed** that proves the schema and oracle end-to-end. The `runtime-rooted` and `wall` strata are then grown with `origin: found` instances on service repos (candidates carry `validated.oracle_runs: false` until the pipeline runs). *Found > constructed; the seed is scaffolding, not the published suite.*
