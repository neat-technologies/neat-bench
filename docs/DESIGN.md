# Design

The canonical record of what this benchmark is and why — the anti-drift anchor. Every decision here traces to a deliberate choice, not a default.

## Positioning

**Agents that scale the coding bubble.** NEAT's job is to give a coding agent accurate full-stack context — static code fused with live runtime — so agents go further (autonomy/reach), faster/cheaper (efficiency), more of them at once (concurrency), without breaking things (safety) or hallucinating (accuracy). The benchmark measures that scaling.

## The rig (one apparatus, many numbers)

Same-model agent, run twice — **with** the NEAT MCP graph and **without** (file-read + grep only) — against one task, everything else held identical. Two layers:

- **The number = the ±NEAT ablation.** NEAT is the only variable, so a delta is attributable to NEAT, not to the model's good day. Same model, same harness, same prompt, tree reset between arms.
- **The marketing = the head-to-head.** Plain Claude / Cursor / Devin stop at a wall; the NEAT-agent walks through. Same walls, same objective oracle.

## Walls (the target)

A **wall** is a task whose answer is *provably absent from the source* and present only in runtime behaviour — so the without-NEAT arm fails for a principled reason, not an obscure one. Each wall ships with a **model-free certificate** (see `WALLS.md`): a source-absence predicate that must return empty, plus the OBSERVED/INFERRED carrying edge that holds the fact. The certificate leverages `claim-classifier.mjs`, so a task where static actually knew the answer (or where the "gap" is a NEAT identity artifact) **cannot** certify. The wall is a wall by construction.

Three axes (as agent tasks): **data** (which symbol writes this table, across an ORM/dynamic boundary), **dispatch** (the concrete impl that ran behind an interface/DI), **async** (a consumer breaks because a producer symbol changed an event payload). First target is **data-axis** — NEAT's ORM/DB observed path is its most mature, so "perfect-enough" is cheapest there.

## The perfect-NEAT → run-at-walls loop

Build NEAT into the *perfect* NEAT for the chosen wall, then run it at the wall. "Perfect" is **wall-driven**: harden only the critical path that wall's answer depends on — not the whole audit. Building the meter surfaces the fixes the meter needs (e.g. the DB-identity split the classifier caught on run one), and those become the next work. See `NEAT-FINDINGS.md`.

## The dev loop

**Work → Prove → Ship**, where *prove = try to break it against ground truth*, not "looks right to me." Prove feeds back into work: the bug the meter catches becomes the next thing to build. Nothing counts until it survives a skeptic — the same thing NEAT itself sells, pointed at our own work.

## Target sequencing

1. **Prove the rig on a known/dogfood target first** — fast, we control it, validates the pipeline end-to-end (even if the numbers tie).
2. **Swap in an independent, non-legible target for the number we publish** — a skeptic discounts dogfood.

**First target: a queue-backed app** (BullMQ/Redis + a DB) — the producer→consumer link is *guaranteed* blind (no static reference), cheapest real signal; it exercises the data path too. NestJS+TypeORM (buyer-representative, DI+ORM) is the next target. See the open junctions issue.

## Hard constraints (do not deviate)

- **Span-driven, no connectors.** Traffic comes from the target's own test suite as OTel spans. Connector-pulled OBSERVED (Supabase/Vercel) is NEAT's *inference* about a provider, indistinguishable from a real trace at the edge level — it does not count as "proven."
- **Local NEAT checkout, not the npm package.** The published `neat init` under-instruments (no call-site span processor → no file:line OBSERVED). Build core from `NEAT_REPO`.
- **Service/boundary grain is the safe floor; symbol grain is the differentiator.** Symbol-grained observed is the bread and butter — the whole reason NEAT is a graph and not a tracer — so the walls live there, but see `HONESTY.md` on the leaf-vs-ancestor grain wrinkle.
