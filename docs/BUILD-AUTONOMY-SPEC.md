# Build-Autonomy bench — spec v0

The launch bench. Measures whether the **same agent** builds a real feature more autonomously and
correctly **with NEAT than without it**, on a codebase NEAT was not engineered against, graded by the
repo's own tests. Replaces the RCA bench as the number we post.

## The one principle

**Same model on both arms. NEAT is the only variable.** No haiku-vs-opus confound. The delta is NEAT.

## Instance schema

Every instance is:

```
{
  repo:            <clonable OSS repo>
  base_sha:        <commit with the feature REMOVED — the starting state>
  solution_sha:    <commit with the feature present — provenance for the test sets, never shown to the agent>
  task:            <plain-English feature ask, exactly what a maintainer would file>
  fail_to_pass:    [<tests that FAIL at base_sha and must PASS after — the new behavior>]
  pass_to_pass:    [<tests that PASS at base_sha and must STAY passing — the regression + amputation guard>]
  observed:        <how OBSERVED is populated: a traffic driver script OR "test-suite exercise">
  wall:            <one sentence: why reading the code isn't enough — the NEAT thesis for this instance>
}
```

`base_sha` is built by taking a complete implementation and **removing one feature** (its endpoints,
wiring, and the tests that cover it stay — they become `fail_to_pass`). Everything else is `pass_to_pass`.

## Metric

**Resolved = every `fail_to_pass` passes AND every `pass_to_pass` still passes.** Objective, no LLM
judge, and the `pass_to_pass` clause **kills amputation** — you can't delete code to pass, the existing
tests catch it. Headline is resolved-rate, NEAT vs no-NEAT, same model.

Sub-metrics (where the NEAT story lives):
- **`pass_to_pass` break-rate** — regressions the agent caused. This is the blast-radius signal: the
  no-NEAT arm breaks callers it never saw.
- **turns-to-resolve** and **cost** — NEAT looks up what the other arm greps for.
- **files touched vs. files that needed touching** — precision.

## Task selection — the rule that decides everything

Pick tasks where **reading the code isn't enough.** Three flavors, one per instance below:
1. **Blast radius** — the change ripples to consumers a grep won't cheaply surface.
2. **Runtime-informed** — the correct implementation depends on how the code is actually used at runtime.
3. **Dynamic wiring** — the "how it connects" is registry/DI/decorator-driven, not greppable.

Self-contained-function tasks are legible; a strong model solves them graph-free and it's a tie. Those
don't go in.

## Target

Primary candidate: a **RealWorld "conduit" backend** — a real, spec'd API (auth, articles, comments,
favorites, follows, feed) with a **shared, ready-made e2e test collection** (the RealWorld API suite),
DB-backed, multi-endpoint, genuinely cross-cutting, and **NEAT has never seen it.** Multiple language
implementations exist, so we can pin one NEAT supports.

Language note (honesty): symbol-grain fusion is deepest on JS/TS today, so a TS/Express or Nest impl
flatters NEAT most — which is exactly why we should **also** curate a Python (FastAPI) impl. Cherry-
picking NEAT's best language would be the same "odds in our favour" we just called out in RESULTS.md.
Plan: instance 1 on TS (deepest fusion), instances 2–3 include a Python impl.

Fallbacks if conduit's suite is too thin: a larger tested service (Saleor/Django, a full-stack FastAPI
template) with SWE-bench-style task construction.

## The first three instances

Concrete task shapes, grounded in conduit. **Exact `base_sha`/`solution_sha` and test IDs are pinned at
curation (clone + run), not invented here** — this spec fixes the design, not fabricated identifiers.

### Instance 1 — "Implement article favoriting" (blast radius)
- **task:** Favoriting is missing. Implement `POST/DELETE /articles/:slug/favorite`, and make every
  article response carry the correct `favorited` (for the current user) and `favoritesCount`.
- **wall:** `favorited`/`favoritesCount` appear on **every** article-shaped response — single article,
  article list, feed, create, update. A naive impl wires the two favorite endpoints and the article
  serializer it can see, and misses that the list/feed serializers build the response a different way →
  those responses lack the fields → their tests break.
- **fail_to_pass:** the favorite/unfavorite endpoint tests + the "article shows favorited/count" asserts.
- **pass_to_pass:** the whole article list / feed / single-article suite (they must keep returning valid
  articles, now with the two new fields correct).
- **NEAT signal:** `get_dependencies`/`blast-radius` on the Article response shape surfaces every builder
  of it; the no-NEAT arm greps `favoritesCount`, finds one serializer, and breaks the others.

### Instance 2 — "Fix the slow feed" (runtime-informed)
- **task:** `GET /articles/feed` is slow. Make it fast without changing its output.
- **wall:** the slowness is an N+1 — the feed fetches author, favorite-state, and tag-list **per
  article**. Which of those is the real cost is only obvious from the actual query fan-out under traffic;
  a static read shows three plausible loops and no signal which one dominates.
- **observed:** a traffic driver hits the feed under a seeded dataset so NEAT's OBSERVED layer carries
  the real per-request query pattern.
- **fail_to_pass:** a query-count / latency-ceiling test on the feed endpoint (fails at base_sha).
- **pass_to_pass:** the feed correctness suite (same articles, same order, same shape).
- **NEAT signal:** `get_observed_dependencies` / the DB-call fan-out shows the N+1 is per-article and
  which relation dominates; the no-NEAT arm optimizes a declared loop and may miss the hot one.

### Instance 3 — "Add a bookmarks resource" (dynamic wiring)
- **task:** Add `GET/POST/DELETE /bookmarks` (a user bookmarks articles), authenticated like the rest.
- **wall:** wiring a new resource correctly means matching the app's **registration pattern** — router
  mount, auth middleware/decorator, DB-session injection, and the shared error/response envelope. None
  of that is one grep; it's a convention spread across the framework's wiring.
- **fail_to_pass:** the new bookmarks endpoint tests (auth-required, CRUD, correct envelope).
- **pass_to_pass:** every existing endpoint (nothing else moved).
- **NEAT signal:** the graph's CONTAINS/registration + auth edges show the exact wiring convention and
  where each piece registers; the no-NEAT arm reverse-engineers it and tends to miss the auth or the DI.

## Harness shape

```
per instance:
  clone repo @ base_sha  →  install + boot  →  (instance 2/3: drive traffic to populate OBSERVED)
  stand a NEAT daemon on the repo  →  snapshot the graph
  ARM A (no-NEAT): same model, edit/bash/test tools, NO neat MCP
  ARM B (+NEAT):   same model, same tools, PLUS neat MCP (graph queries)
  each arm: agent works to a turn budget → produces a diff → apply → run fail_to_pass + pass_to_pass
  grade: resolved = all fail_to_pass green AND all pass_to_pass green; record break-rate, turns, cost
  K seeds per arm; report the ±NEAT delta
```

Void-free by construction — there is no incident store, so no preflight race. Reproducible — a fixed
`base_sha` + a captured graph snapshot is the same inputs every run.

## Curation procedure (next step, evidence-first)

For instance 1, in order, verifying each before moving on:
1. Pick + pin a conduit impl and SHA; get its test suite green (`solution_sha`).
2. Cut `base_sha` by removing favoriting; confirm the favorite tests now FAIL and everything else PASSES
   — that split IS `fail_to_pass` / `pass_to_pass`, recorded from a real run, not authored.
3. Instrument + boot; stand a NEAT daemon; snapshot.
4. Dry-run both arms once to confirm the task is solvable and the harness grades correctly.
5. Only then lock the instance and add 2 and 3.

No instance is "real" until steps 1–2 have actually run. That's the discipline the RCA bench skipped.
