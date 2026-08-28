# Detection bench — does `neat divergences` surface the fault? (2026-08-28)

13 divergence-shaped PRAXIS scenarios on the live OTel Demo. **Metric is DETECTION,
not resolution:** deploy the fault, ask each arm to DIAGNOSE it (faulty service +
root-cause nature/location), record caught/missed. No fix, no verify. Per scenario we
record three things: (1) does the RAW `neat divergences` query surface the fault —
the headline capability; (2) does the neat AGENT (full arsenal, prompt leads with
divergences) catch it; (3) does the code AGENT (source-only) catch it. k=2 seeds.
Ground-truth RCI: 401/405–416 = recommendation, 20 = product-catalog, 32 = ad.

## The number

| capability | caught | note |
|---|---|---|
| **`neat divergences` RAW query** | **1/13 (8%)** | fires ONLY on 401 (symbol/field mismatch) |
| any raw neat query (divergences + root-cause + incidents + stale-edges) | 4/13 (31%) | 401, 407, 408, 415 |
| **neat AGENT** (full arsenal) | **25/26 (96%)** | one miss: 414 seed-2 (flake) |
| **code AGENT** (source-only) | **20/26 (77%)** | fails on the pure deployment/cluster faults (20, 32) |

## Per-scenario

| scen | strength | fault | div_fired | any-query | neat agent | code agent |
|---|---|---|---|---|---|---|
| 401 | strong | field mismatch products_list | **YES** | YES | 2/2 | 2/2 |
| 405 | weak | neo4j hang (deadlock serving) | NO | NO | 2/2 | 2/2 |
| 406 | weak | neo4j hang (deadlock bootstrap) | NO | NO | 2/2 | 2/2 |
| 407 | weak | neo4j deadlock-timeout serving | NO | YES | 2/2 | 2/2 |
| 408 | weak | neo4j deadlock-timeout bootstrap | NO | YES | 2/2 | 2/2 |
| 409 | weak | neo4j livelock bootstrap | NO | NO | 2/2 | 2/2 |
| 410 | weak | neo4j livelock serving | NO | NO | 2/2 | 2/2 |
| 413 | strong | wrong DB host (master-neo4j) | NO | NO | 2/2 | 1/2 |
| 414 | strong | wrong DB host (bootstrap) | NO | NO | 1/2 | 1/2 |
| 415 | weak | bad config NUM_PRODUCTS>catalog | NO | YES | 2/2 | 2/2 |
| 416 | weak | bad config-db | NO | NO | 2/2 | 2/2 |
| 20 | weak | product-catalog bad image | NO | NO | 2/2 | **0/2** |
| 32 | strong | ad scaled to replicas=0 | NO | NO | 2/2 | **0/2** |

## What this means (brutally honest)

**The headline `neat divergences` claim does NOT hold as a general fault detector for
this set.** The raw `neat divergences` query fired on exactly **1 of 13** faults — the
401 field/contract mismatch, which it surfaces cleanly as an `observed-symbol-mismatch`
(`recommendation_server.py:96`, "declared access `products_list` vs runtime shape
disagree at symbol grain"). It fired on **1 of the 4 STRONG** scenarios and **0 of the 9
weak** ones. It is a STRUCTURAL / symbol-grain tool (declared-vs-observed edges and
symbol shapes); it does not fire on:
- **runtime hangs** (405–410 neo4j) — a timeout is not a structural divergence;
- **wrong-host / config faults** (413/414/415/416) — the bad value lives in deployment
  ENV, not in an edge the query compares;
- **silent services** (20 product-catalog down, 32 ad scaled to 0) — the relevant edge
  IS present in the output (`frontend → ad`, `frontend → product-catalog`) but only as
  generic `missing-observed`/`missing-extracted` coverage noise that the query emits for
  ~15 edges every run regardless of fault; it does not flag the service as *down*.

**Where detection actually comes from: the AGENT + the rest of the fused graph, not
`divergences`.** The neat agent caught 25/26 by pivoting to `observed-dependencies`
(e.g. 413: recommendation is a "pure receiver"; 32: `frontend→ad` 84/84 errors, ad has
no server-side spans), `root-cause service:frontend`, and `incidents` (ECONNREFUSED /
DEADLINE_EXCEEDED). The raw single-query layer surfaced the fault on its own in only
4/13 — and even those relied on `root-cause`/`incidents` (the neo4j *timeout* variants
407/408 where recommendation itself errors), not `divergences`. Divergences alone is the
weakest surface; the agent using the whole graph is the strong one.

**The fusion win is on the pure deployment/cluster faults.** The neat agent (96%) beats
the code agent (77%) by 19 points, and that gap lives entirely in faults whose cause is
NOT in any source file:
- **20 (product-catalog bad image) and 32 (ad scaled to 0): code 0/2, neat 2/2.** There
  is no source footprint at all — a bad image tag, a scaled-to-0 deployment. The code
  agent burned its whole turn budget grepping every service and found nothing; the neat
  agent read it straight off OBSERVED (`frontend→ad` 84/84 errors, ad has no server-side
  spans, ECONNREFUSED). These two are the cleanly fusion-decisive detections.
- **413/414 (wrong DB host): code 1/2, neat 2/2.** Partially source-visible — the faulted
  image ships a code comment ("should be `primary-neo4j-productdb`"), so a source agent
  can *sometimes* infer the misconfig; it's flaky (1/2) because the wrong value itself
  lives in the deployment env, not the code. neat reads the failing resolution off
  OBSERVED and gets it 2/2 (bar one flake on 414).

So the honest framing is: it is the agent's OBSERVED reasoning that wins on deployment
faults, **not the `divergences` verb** (which fired on none of 413/414/20/32).

## Caveats / integrity notes

- **`neat divergences` timing.** The 401 symbol-mismatch only appears once enough
  OBSERVED AttributeError incidents have accumulated; an earlier snapshot (pre-warm)
  showed only coverage noise. The suite runs an 80s OBSERVED warm-up before querying.
- **Strict divergences grader.** "Fired" requires a FAULT-SPECIFIC signal in the raw
  output, not a generic coverage edge that merely names the service — deliberately
  conservative so the 8% is honest, not inflated by noise. Raw outputs are saved per
  scenario (`divruns/<scen>/divergences.txt`) for audit.
- **Code arm was re-run clean.** Run-1's code arm was confounded (a `recommendation_
  server.py.stock-bak` healthy backup left in the source tree gave code a free diff, and
  a stale `neo4j_products_db.py` mis-fed the 20/32 runs). Both removed; the 77% above is
  the clean re-run (correct full source synced per scenario, `SERVICE:`-line RCI grading).
  Curiously the aggregate was 77% in run-1 too, but the *distribution* moved: with the
  stock-bak diff, code misread the 413/414 wrong-host faults as the 405-style hang (0/2)
  yet its 20/32 rows were mis-graded as hits by the looser run-1 grader; clean, code
  gets 413/414 partially right (1/2) and cleanly fails 20/32 (0/2). The neat/divergences
  numbers were graph-based and unaffected — identical before and after the grader fix.
- **k=2** is low power; detection is less noisy than resolution but the 414 neat 1/2 is
  the kind of variance k=2 cannot resolve.

Raw per-run detail: `divergence-results.tsv` (run-1, all arms) + `code-clean-results.tsv`
(clean code re-run) + `neat-side-regraded.tsv`. Also at `~/praxis/runs/`.
