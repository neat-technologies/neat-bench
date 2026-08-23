# NEAT findings the meter surfaced

Building the benchmark is a prove-machine pointed at NEAT itself. Each item below is a NEAT behaviour the benchmark's honesty depends on; each is filed as an issue on `NEAT-Technologies/Neat` and joins the wall-driven hardening list ("perfect NEAT → run at walls"). Several were predicted by the provenance audit and then confirmed in real snapshot data.

| # | finding | issue | benchmark impact | worked around today? |
|---|---|---|---|---|
| 1 | DB identity split — `database:mongodb` (declared) vs `database:127.0.0.1` (observed) never fuse | [neat#979](https://github.com/neat-technologies/neat/issues/979) | inflates static-blindness ~100 pts on the very first fixture | yes — classifier quarantines as `IDENTITY_SUSPECT` |
| 2 | STALE edges parse back as OBSERVED → invisible to divergence | [neat#980](https://github.com/neat-technologies/neat/issues/980) | can't tell "went quiet" from "never ran"; no time axis | not yet — avoid STALE-dependent walls |
| 3 | `missing-extracted` has no FrontierNode guard | [neat#981](https://github.com/neat-technologies/neat/issues/981) | unresolved peers read as "static missed it" | classifier only counts BLIND, not raw divergence |
| 4 | INFERRED/STALE divergence buckets are write-only | [neat#982](https://github.com/neat-technologies/neat/issues/982) | inference doesn't suppress a contradictory `missing-observed` | metrics don't use raw divergence counts |
| 5 | confidence is a producer tier, not calibrated; two functions disagree | [neat#983](https://github.com/neat-technologies/neat/issues/983) | can't trust the float as P(correct) | metrics key on provenance tier + the join, never the float |
| 6 | no graph-completeness signal at query time | [neat#984](https://github.com/neat-technologies/neat/issues/984) | no denominator to normalize; language recall gaps hidden | coverage stated as a hard rule (`HONESTY.md` §2–3) |
| 7 | symbol-attribution grain (leaf vs handler-frame floor) is unmarked | [neat#985](https://github.com/neat-technologies/neat/issues/985) | can't read leaf vs ancestor off the graph | scored on the on-the-true-stack bar |

## The loop

These aren't blockers on the benchmark — they're the *output* of building it. #979 is the most load-bearing for the data axis (the first wall target), so it leads the hardening. Fixing it also makes an eventual NEAT-vs-NEAT ablation honest, because today NEAT's own static is too weak to be the "static" baseline.

---

# PRAXIS code-grain findings (fusion-decisive class)

Second wave, surfaced running the PRAXIS Code-Cloud-RCA faults against a live `neat watch` daemon on the OTel Demo (CONTRACT rule 1: every weakness filed → subagent fix → ship to `latest` → re-verify). These are on the code/RCR grain — where fusion is supposed to be decisive and runtime-only scores 0%.

| # | finding | issue | shipped | benchmark impact |
|---|---|---|---|---|
| 8 | `get_divergences` only reported edge-grain; missed symbol/field-grain code↔runtime mismatch (the `products_list` class) | [neat#1082](https://github.com/neat-technologies/neat/issues/1082) | **0.9.3** (PR #1085, ADR-215) | the direct route to code-grain faults was blind; classifier added, but see #1087 |
| 9 | `incidents`/`root-cause`/`ask` 500 "Invalid string length" on a long-lived daemon (unbounded errors.ndjson serialization) | [neat#1083](https://github.com/neat-technologies/neat/issues/1083) | **0.9.3** (PR #1084) | queries the neat arm depends on died mid-run on busy daemons; **verified fixed live on 0.9.3** (918 incidents serialize clean) |
| 10 | root-cause blamed the load generator on outbound-dependency faults | [neat#1075](https://github.com/neat-technologies/neat/issues/1075) | **0.9.3** (PR #1076, ADR-214) | misdirected RCI on the propagation class |
| 11 | **incidents drop the code locus from `exceptionStacktrace`** — when the exception span carries a stacktrace but no `code.filepath` attr, the incident attributes to the **service**, not the declaring `file:line`. Defeats RCR, code-grain root-cause, AND #1085's symbol-grain divergence for the whole Python code-fault class. | [neat#1087](https://github.com/neat-technologies/neat/issues/1087) | in flight (fix subagent) | **the keystone.** This is why runtime-only RCR = 0% — the location is in the trace, unjoined. Turns RCI into RCR for the fusion-decisive class. |

## 0.9.3 release + live re-verification (2026-08-24)

Shipped #1076 + #1084 + #1085 as **0.9.3** to npm `latest` (lockstep bump, tag `v0.9.3`, publish workflow green through the umbrella-tarball smoke). Restanded the box on 0.9.3 (24/24 pods, daemon fused 2220 nodes / 2510 edges, the 401 `products_list` fault live).

- **#1084 — VERIFIED FIXED live.** `neat incidents service:recommendation` returns all 918 incidents and `root-cause` responds cleanly; both previously 500'd on this daemon.
- **#1085 — shipped but INERT live.** `neat divergences` still returns only edge-grain findings (28, all `missing-extracted`/`missing-observed`); zero symbol/field-grain. The classifier is correct but `symbolLocus` returns null: the incident carries no `code.filepath` and `affectedNode` is `service:recommendation`. The code location lives only in the unparsed `exceptionStacktrace` (`recommendation_server.py:96 in get_product_list`). This is #1087 — filed, fix dispatched. #1085's payoff unlocks once #1087 lands.

The honest read: the 0.9.3 fixes are real (one verified live, two shipped), but the single biggest lever on the launch number — code-grain localization for stacktrace-only exception spans — is #1087, now the top of the queue. The graph already carries `symbol:recommendation:recommendation_server.py#get_product_list`; only the OBSERVED→EXTRACTED stacktrace join is missing.
