# Honesty guards

The rules that keep a number unbreakable. Each exists because a specific skeptic move would otherwise break it. These are enforced in code where possible.

## 1. Separate blindness from grain-refinement and identity artifacts

An OBSERVED `file→db` edge counts as `missing-extracted` even when a coarser EXTRACTED `service→db` already declared the dependency — that is **grain-refinement**, not blindness. And `database:mongodb` vs `database:127.0.0.1` are one store under two names NEAT doesn't fuse — an **identity artifact**. Neither supports the headline. `claim-classifier.mjs` buckets every observed edge CONFIRMED / GRAIN_REFINED / IDENTITY_SUSPECT / BLIND, and only BLIND is a blindness win. *A raw `missing-extracted` count would inflate the number 100 points on the very first fixture — it did; the classifier caught it.*

## 2. Coverage-bounded, stated honestly

OBSERVED exists only for exercised paths. The claim is always "of the edges your tests exercise," never "of your whole system." The denominator is the discovered graph (static ∪ observed over the run), never an imagined complete graph.

## 3. Cross-language counts are not comparable

On a Python repo NEAT loses its whole symbol layer and every JS-only infra recognizer, **with no flag saying so** — low recall is indistinguishable from a sparse system. So OBSERVED-only counts inflate on Python purely because the extractor is blind there. Never compare an edge-count metric across languages; report per-language.

## 4. Span-driven, no connectors

Traffic is the target's own test suite as OTel spans. Connector-pulled OBSERVED is NEAT's inference about a provider — indistinguishable from a real trace at the edge level and often graded *higher* via volume replay. It does not count as proven. The provisioner uses OTel spans only.

## 5. Confidence is not a probability — do not use it as one

NEAT's `confidence` is a producer/heuristic tier dressed as a 0–1 float (a `package.json` fact and a fuzzy SDK recognizer both get 0.85), and two independent confidence functions assign the same edge different numbers. It ranks; it is not calibrated P(correct). Metrics key on **provenance tier** (OBSERVED/INFERRED/EXTRACTED/STALE) and the EXTRACTED-twin join, never on the confidence float.

## 6. The grain trust gradient (the bread-and-butter caveat)

OBSERVED is most trustworthy as "these two coarse endpoints exchanged traffic" and gets less so the finer the grain, because the handler-frame floor can land a call on the enclosing route handler rather than the leaf. Crucially that is a **true ancestor on the runtime call stack** — *correct but coarser*, not a false edge. So symbol-grain attribution is scored on the **on-the-true-stack** bar (defensible) with the exact-leaf gap reported as the known coarsening. Genuinely-wrong cases (cross-request context leaks, minified sourcemap offsets, frontier alias collisions) are narrow and get steered around when selecting walls — they are internal QA, not a published axis.

## 7. Grounded ≠ certainly-true

"Backed by real stuff" means **traceable to a real observation**, not infallible — NEAT's attribution has the grain wrinkle above. The keystone claims *traceable-to-a-trace*, still a massive delta over invented, never *provably correct*.

## 8. Publish the losses

The controls that keep the benchmark honest live on the *static* side — structural tasks where NEAT should tie or lose. If NEAT loses where it should win, or a wall won't certify, that gets reported, not buried. *A number a skeptic can break is worse than no number.*
