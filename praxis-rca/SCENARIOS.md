# PRAXIS scenarios

The PRAXIS battery runs on the OpenTelemetry demo on KinD and injects ground-truth faults. Every scenario has an oracle: the true culprit service and the true fault nature. This page is the single list of what each scenario is. The source of truth for fault parameters is `harness/divergence-ground-truth.tsv` (detect) and `harness/ground-truth.tsv` (resolve); `harness/fullsuite-catalog.tsv` adds the box and the metric mode.

## How the numbers are counted

There are **15 distinct scenarios**: 10 detect, 4 resolve, plus 411 (a resolve scenario kept as a control, not in the current suite).

The detect leg is scored out of **20** because each of the 10 detect scenarios runs on both models (opus and sonnet): 10 x 2 = 20 detect runs per arm. The resolve leg is 4 x 2 = 8 runs per arm. The "/20" on the scoreboard is detect runs, not a count of scenarios.

## The box: where the bug lives

Each scenario is boxed by what it takes to find the bug. The box is what separates NEAT's fusion from a reader of raw logs.

| box | meaning |
|---|---|
| `strict-code` | the bug is visible in source alone; a code reader should win |
| `strict-runtime` | the bug exists only in runtime or config, invisible from source; needs cluster state |
| `both` | needs code and runtime, but a raw-log reader can stitch it by hand (one error span to one code line) |
| `fusion` | needs the cross-service join that is expensive to stitch by hand: declared-vs-observed divergence, blast radius over observed edges, multi-hop root cause |

`strength` is the pre-run split of how decisive a scenario is for fusion: `strong` scenarios need graph reasoning, `weak` ones are reachable by stitching one span to one line. Headline numbers should weight toward strong; weak scenarios are controls.

## Detect (10): diagnose only

Graded CAUGHT when the arm names the right service and the right nature of the fault.

| scen | box | strength | target | bootstrap | fault |
|---|---|---|---|---|---|
| 413 | fusion | strong | recommendation | no | wrong neo4j host (`master-neo4j-productdb`) set via env; a declared-vs-observed host divergence across services |
| 414 | strict-runtime | strong | recommendation | yes | wrong neo4j host, fires at startup so the pod never serves |
| 407 | both | weak | recommendation | no | neo4j deadlock-timeout while serving |
| 408 | both | weak | recommendation | yes | neo4j deadlock-timeout at bootstrap |
| 406 | both | weak | recommendation | yes | neo4j no-timeout hang at bootstrap, pod crashes at start |
| 409 | both | weak | recommendation | yes | neo4j livelock (unbounded retry loop) at bootstrap |
| 415 | both | weak | recommendation | no | config `NUM_PRODUCTS` larger than the catalog, list index out of bounds (config x code) |
| 416 | both | weak | recommendation | no | bad config-db variant |
| 20 | strict-runtime | weak | product-catalog | no | deployment pointed at a bad image (`app-image:latest`), ImagePull fails |
| 32 | strict-runtime | strong | ad | no | deployment scaled to `replicas=0`, the service goes silent |

`bootstrap = yes` means the fault fires at startup and the pod never serves. These emit no telemetry, so the cause is in the deploy state, not the trace stream.

## Resolve (4): find, fix, and oracle-verified recovery

Graded RESOLVED when the fault actually clears after the agent's fix, and ROBUST when it clears with zero regressions against a captured pass-to-pass baseline. All four target `recommendation`; the fix location is graded by `grade.sh`.

| scen | box | strength | oracle | fault | the fix the oracle looks for |
|---|---|---|---|---|---|
| 401 | fusion | strong | ERROR | proto field renamed `products_list` to `products`; the symptom is at the frontend, the cause is at a recommendation symbol, and the cross-service root cause is the join | use `products` in `get_product_list` (`recommendation_server.py` ~85/96) |
| 405 | both | weak | HANG | neo4j call with no timeout hangs while serving | add a timeout/retry around the `requests.get` (~129) |
| 410 | both | weak | HANG | neo4j livelock: an unbounded `while True` socket retry while serving | bound the retry loop (~143) |
| 412 | strict-code | - | LATENCY | recursive LCS in `compare_product_compatibility` blows up at `NUM_PRODUCTS=14`; pure algorithm, no runtime needed to find it | reimplement LCS with DP/memoization (~157) |

## Control: 411

| scen | box | target | fault | fix |
|---|---|---|---|---|
| 411 | strict-code | recommendation | `validate_product_format` has inverted if/else branches, so every `ListRecommendations` raises `AssertionError("Unmet validation constraint")` (injected function, absent in the fault-free image) | swap the branches (~140-145) |

411 is a static code smell: the inverted logic is obviously wrong on read, so a strong code agent finds it directly and NEAT's runtime localization adds nothing. It is kept as a control for the class of source-findable faults, where fusion has no edge by construction. It is not in the current suite.

## What the distribution tells you

13 of 15 scenarios target `recommendation`, and most are neo4j-flavored. Only two (401, 413) are `fusion`, the class where NEAT's cross-service join is the decisive capability. The battery exercises fusion but does not showcase it: widening toward blast-radius, cross-service divergence, and multi-hop root cause is the way to make PRAXIS measure what NEAT is for.
