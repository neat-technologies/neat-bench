# The corpus — a realistic startup system, seen by one graph

The benchmark target is not one app. It's a **living, heterogeneous startup stack** — several databases, multiple clouds, serverless, real OSS apps, a mobile build pipeline, staging and prod — and NEAT's job is to be the single fused graph that sees across all of it. This is where the without-NEAT arm hits walls a single app can never produce.

## North-star topology

```
        Cloudflare (Pages + CDN + a Worker at the edge)
                          │
     Vercel  ─────────────┼───────────── Vercel
   Papermark (Next.js)              OSS CRM frontend (Twenty)
       │                                   │
       ▼                                   ▼
  Large backend engine (Node)        CRM backend (NestJS)
  BullMQ workers over Redis                │
       │            │                       │
   AWS Lambda   GCP Cloud Run          Supabase Postgres #2
   (Node/Py)    (Go or Py)   ◀── polyglot, multi-cloud
       │            │
       ▼            ▼
  Supabase Postgres #1     +   Redis (queue/cache)   +   a 2nd store (Mongo/PG)

  Expo (React Native) app  ──EAS build──▶  backend         [several tiny Supabase→Vercel CRUD apps]
  staging AND prod for the apps                            ← the reproducible, skeptic-runnable core

  NEAT: OTel spans from the Node/Python services · connectors for Supabase/Cloudflare/Vercel · watch mode
```

## Every piece earns its place — component → task class

Nothing here is "cool infra"; each component exists to manufacture a class of task NEAT should win.

| component | task class it produces | stratum |
|---|---|---|
| Papermark ↔ engine ↔ Supabase (cross-service data) | which symbol/service actually wrote/read this, across the network wall | **wall** |
| AWS Lambda + GCP Cloud Run in one request path | "which provider/runtime actually served this," cross-cloud root cause | **wall** (multi-cloud) |
| BullMQ/Redis workers (engine) | producer→consumer payload drift with no static link | **wall** (async) |
| Cloudflare edge/Worker | request served at edge vs origin — declared ≠ actual | **wall** (divergence) |
| staging **and** prod | config/env drift, migration-declared-never-applied, dead deps | **wall** (divergence) |
| Papermark / Twenty (real OSS) | found + injectable service-level bugs on real messy code | runtime-rooted |
| several tiny Supabase→Vercel apps | small, legible CRUD | **control** + the reproducible core |
| Expo app + EAS build | EAS build-failure incidents — which commit/phase broke the native build (connector-observed); + the mobile→backend seam | runtime-rooted (incident) |

## What NEAT can see today — the honest coverage map (and the roadmap)

"NEAT sees it all" is the goal; today it's a gradient, and the corpus is precisely the forcing function that closes it:

| layer | NEAT coverage now | so the corpus drives… |
|---|---|---|
| JS/TS (Papermark, Twenty, Node engine, Node Lambdas, Vercel) | **full** — symbol grain + recognizers + connectors | the strong, ready strata |
| Python (a Py Lambda / Cloud Run) | **partial** — routes + ORM, no symbol layer | Python symbol grain |
| Go (a Go Cloud Run) | **partial** — raw-SQL data recognizer (database/sql + sqlx) landed; no call graph / routes yet | Go routes + call graph |
| Ruby / PHP (a service) | **OTel-instrumentable** — auto-instrumentation installers landed (service-grain OBSERVED) | Ruby/PHP static recognizers |
| Mobile **build** (EAS) | **connector-observed** — the EAS build-failure connector mints OBSERVED incidents (commit + build-phase attrs) on the resolved node | done (first incident-emitting connector) |
| Mobile **app code** (RN/Swift) | **no static extractor** — the EAS connector sees builds, not the app's symbol graph | mobile app extraction (later) |
| managed infra (Supabase/CF/Vercel) | **connector-observed** — weaker provenance, not span-traced | connector-vs-trace distinguishability |

_Synced against NEAT 0.7.10. The gradient moves fast (Go raw-SQL, Ruby/PHP installers, and the EAS connector all landed recently) — recheck this table per NEAT release; it's a roadmap that closes itself._

This is honest and strategic: the corpus surfaces exactly where NEAT is blind, and each gap is a filed hardening/language-expansion item, not a hidden weakness.

## Two-layer reproducibility (the non-negotiable)

A skeptic cannot clone AWS+GCP+Cloudflare+Vercel+EAS. So credibility is split:

- **The living env** (the real clouds) = the demo + the multi-cloud/divergence walls. We publish captured **graph snapshots + trace bundles + task specs + oracles**, so the *model-free* numbers (grounded-evidence, static-blindness, wall certification) re-score offline by anyone.
- **The reproducible core** = the tiny Supabase→Vercel apps **+ a locally-dockerizable multiservice subset**, packaged `docker compose up` + `run.sh`, so the full ±NEAT ablation re-runs end to end. This is the SWE-bench-comparable anchor the headline rests on.

Most of the corpus is *not* skeptic-reproducible, and that's a deliberate richness-vs-reproducibility trade — we buy reproducibility back with the core subset.

## Connector provenance split

Managed infra means connector-**inferred** OBSERVED, which is weaker than span-**traced** OBSERVED (and today NEAT can't tell them apart at the edge level). The rule: **app-internal call/data edges stay span-driven** (real traces — for fix + grounded-evidence metrics); **infra/provider edges are connector-observed**, scored at connector provenance, and used only for the divergence/multi-cloud walls. Never launder connector inference into "span-proven."

## Phased buildout — slice-first, each phase runnable and task-bearing

Do **not** stand up the whole company at once. Each phase is a standing subsystem that already yields a batch of stratified instances + a graph snapshot.

- **P0 — reproducible core:** one tiny Supabase→Vercel app, dockerized. Proves the hosted pipeline end-to-end + anchors reproducibility.
- **P1 — first cross-service wall:** Papermark + a Node engine + a shared Supabase Postgres. First *certified* cross-service/data wall.
- **P2 — multi-cloud serverless:** add an AWS Lambda + a GCP Cloud Run in the path. Provider-divergence + polyglot (surfaces the Go/Python gaps).
- **P3 — edge + drift:** Cloudflare Pages/Worker + staging/prod. Edge + config-divergence walls.
- **P4 — async engine + CRM:** the BullMQ/Redis engine + Twenty. Producer→consumer walls + more found-bug surface.
- **P5 — mobile/build:** Expo app + EAS. The EAS build-failure connector already lands OBSERVED build incidents (commit + build-phase), so the first mobile task is **incident-rooted** — "a build started ERRORing after a change; which one?" — answered from the build incident, not the RN source. Then the mobile→backend seam.

## Cost reality

This is a **standing** environment: real multi-cloud spend + ongoing maintenance, and it drifts and breaks. That's partly the point (drift is divergence-task fuel, and it's live `neat watch` dogfood), but it is an operated system, not a one-shot fixture — budget and an owner are prerequisites.

## Proposed roster (concrete, swappable)

Papermark (docs) · Twenty (OSS CRM) · a BullMQ/Redis Node engine (Novu-style) · AWS Lambda (Node + one Python) · GCP Cloud Run (one Go, for the polyglot gap) · Supabase ×2 + Redis + one more store · Cloudflare (Pages + Worker) · Vercel (the apps) · Expo + EAS · 2–3 tiny Supabase→Vercel CRUD apps for the core.

Open choices tracked as junctions: which OSS CRM, which engine, AWS-vs-GCP split per function, and which tiny app is P0.
