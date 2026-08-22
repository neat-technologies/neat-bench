# Audit brief: is the ITBench-series work generalizable, or fudged to beat the benchmark?

**For a fresh agent. You have no prior context — this brief is self-contained.**

## The one question

> How much of the ITBench/otel-demo change series made NEAT genuinely better — atomic, modular, generalizable to *any* system — and how much was coded **just to beat the bespoke problems of that one benchmark** (overfitting: hardcoded to otel-demo's shapes, tuned to its literal data, or engineered so a green otel-demo number looks like universal capability when it isn't)?

Your job is to answer that **per-change, with evidence from the code**, then give an overall verdict. Disbelieve the prior findings below by default — they're a starting hypothesis, not a conclusion. Confirm or overturn each against `origin/main`.

## Background (what happened)

NEAT is a tool that fuses static code + runtime OpenTelemetry into one graph for AI-agent RCA. To produce a launch-gating "number," it was benchmarked on **otel-demo** (the OpenTelemetry reference microservices app, ~16 polyglot services) using **ITBench-Lite** fault snapshots (SRE-incident scenarios). Over ~a week, a wave of recognizer + RCA-engine changes landed on `main`, driven by "make NEAT fuse everything in otel-demo" and "make the RCA benchmark pass." **The risk this audit checks: did those changes generalize, or did they quietly overfit to otel-demo?**

## The change set to audit (verify against `origin/main` git log + `docs/decisions.md`)

Recognizer / fusion wave (ADR-192 … ADR-209 era, PRs ~#1018–#1065):
- **Language symbol grain**: Python/Go (#1018), Ruby (#1021), Dockerfile-declared service (#1023), PHP (#1024), C# (#1026), Java (#1030), Kotlin (#1036), Rust (#1039), C++ (#1041).
- **#1035 / ADR-200** — nearest-service-wins file ownership (root-service dedup).
- **#1032** — C# service discovery for a `.csproj` nested under `src/`.
- **#1004 / #1037** — guard self-referential imports so one file can't crash extraction.
- **#1044 / ADR-203** — Kafka topic recognizer, Go Sarama producer (`extract/calls/kafka.ts`).
- **#1046 / ADR-204** — frontend Next.js route fusion via `next.span_name` + `[param]`→`:param` (an `ingest.ts` change).
- **#1048 + #1055 / ADR-205, ADR-207** — C# datastore recognizers (EF Core/Npgsql → Postgres/table, Valkey/Redis client).
- **#1049 + #1053 / ADR-206** — HTTP route recognizers: Rust Actix-Web, PHP Slim, Ruby Rack/Sinatra (`extract/routes.ts`).
- **#1056 / #1061 / ADR-208** — keep streaming/long-lived spans out of the per-edge latency digest (`latency-digest.ts`, `ingest.ts` `spanIsStreaming`).
- **#1050 / #1062 / ADR-209** — `get_root_cause` walks a STALE-only causal chain to the deepest callee at 0.3 confidence instead of dead-ending (`traverse.ts`).
- **#1051** — `ask` mis-resolves `database:` ids (rides #1029/ask branch).
- **#1065** — incident recording keys only on `span.statusCode === 2`, blind to gRPC/HTTP status errors (fix in flight; see below).

Also present but a separate *feature*, not a benchmark fix — audit lightly: **#1029** (the `neat ask` verb + opt-in hard-gate hook).

## Classification framework — put each change in exactly one bucket

1. **Generalizable improvement** — fixes a real, framework/language-general gap; benefits any comparable system. Evidence: matches a *framework idiom* or *language grammar*, gated on a real signal (an import, a manifest), no otel-demo literals.
2. **Benchmark-priority-inflated** — a real capability, but its *urgency/existence* was manufactured by a benchmark artifact (e.g., the 8-month-old snapshot forcing everything STALE). Real, but low production priority; fine if honestly bounded.
3. **Bespoke / fudged** — coded to beat *this* benchmark: otel-demo service names or literal values hardcoded, magic constants tuned to otel-demo's data, matching otel-demo's exact strings rather than the framework idiom, or tests that only assert on otel-demo.
4. **Harness, not NEAT** — lives in the benchmark rig (neat-bench), not the NEAT engine. Note it but it can't overfit NEAT.

## Red flags to hunt (what "fudged" looks like)

- Any literal `"checkout"`, `"orders"`, `"cart"`, `"astronomy-db"`, `flagd`, `oteldemo`, `otel-demo`, or ITBench scenario ids in **non-test, non-fixture** engine code (`packages/core/src/**`). Grep for them.
- Recognizers that match a **literal route/topic/host string** instead of the **framework construct** (e.g. matching `"/getquote"` vs matching Slim's `$app->post(...)` DSL).
- Recognizers **not gated** on a real framework signal (a Sarama recognizer that fires on any Go struct named `ProducerMessage`; a Sinatra recognizer that fires without `require 'sinatra'`).
- Magic numeric constants (latency ceilings, confidence values, thresholds) that only make sense for otel-demo's numbers.
- Tests/fixtures that are **copies of otel-demo** rather than minimal synthetic cases — a recognizer "passing" only because its fixture *is* the target it was built for.
- Confidence/labels that **overstate** — presenting a stale/low-evidence result as high-confidence to make a benchmark pass.

## My preliminary findings — verify or overturn each

I did a first pass. Treat as hypotheses:

- **Recognizers look framework-general, not otel-demo-literal.** Spot-checks: `extract/calls/kafka.ts` is gated on a real `"/sarama"` import and matches the general `sarama.ProducerMessage{Topic: …}` shape; the Sinatra recognizer in `extract/routes.ts` is gated on a real `require 'sinatra'` / `Sinatra::Base` and matches the verb DSL, explicitly deferring regex-routes/namespaces as honest gaps. **No `if service == "checkout"` found.** → **Verify this holds for ALL recognizers** (Slim, Actix, C# EF/Npgsql, Valkey, Next.js route fusion). Check each: idiom vs literal, gated vs ungated, fixture-synthetic vs otel-demo-copy.
- **#1065** (gRPC/HTTP incidents) is the *most* generalizable — `isError = span.statusCode === 2` misses the dominant real-world error representation (error-in-attribute). Fix helps every gRPC/HTTP system. Confirm the fix (when it lands) doesn't special-case otel-demo.
- **#1061** (streaming-span latency exclusion) — general (any streaming RPC). Confirm the streaming detector keys on span *shape* (duration ceiling / SSE / stream markers), not on flagd specifically.
- **#1035, #1004, #1032, language grain** — expected generalizable structural/robustness fixes. Confirm.
- **#1050** (STALE-chain walk, ADR-209) is the one honest asterisk — a real capability, but its urgency came from the 8-month-old snapshot (in a live system, edges are fresh and this path rarely fires). Check it's honestly bounded (0.3 confidence, "stale-derived / low-confidence" labeling, doesn't fake freshness) and **not** guarded by anything otel-demo-specific.
- **Coverage is otel-demo-shaped even where each recognizer is general** — we built Slim because otel-demo's `quote` is Slim, Actix because `shipping` is Actix. Assess whether any docs/claims present "fuses all of otel-demo" as if it were universal.

## Also assess: was correctness fudged to make the number look good?

The RCA "number" swung 3/4 ↔ 0/4 across graph conditions; root cause was **#1065** (the graph literally couldn't see the failing service's errors). Check nothing was tuned to make a *specific* scenario pass — e.g. thresholds/confidence in `traverse.ts` / `ask.ts` picked to favor otel-demo's topology, or scenario-specific branches. The honest fix path is #1065 (see the failing service's incidents at all), not tuning the ranker.

## Output format

For each change: **bucket (1–4) · one-line justification · file:line evidence · confidence**. Then:
- A table of all changes by bucket.
- An overall ratio (% generalizable / % priority-inflated / % fudged).
- A flat list of any genuine overfitting found (bucket 3), most severe first, each with the exact code and a proposed de-fudge.
- One honest paragraph: does a green otel-demo number, given these changes, warrant claiming general capability — and what would have to be true (frameworks *not* in otel-demo, a non-otel-demo target) to warrant it.

## Scope / rules

- Audit `origin/main` engine code (`packages/core/src/**`). Read the ADRs in `docs/decisions.md` for intent, but judge the **code**, not the prose.
- Test and fixture files matter only as evidence (a recognizer whose only test is an otel-demo copy is weaker than one with synthetic cases).
- Don't fix anything — this is a read-only audit. Produce the report; the humans decide.
- Be adversarial and specific. "Looks fine" is not a finding; a `file:line` with a reason is.
