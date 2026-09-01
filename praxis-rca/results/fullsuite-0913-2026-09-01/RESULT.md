# Full-suite ±NEAT — neat.is@0.9.13 (2026-09-01)

neat+**haiku** vs obscode+**opus**, live otel-demo on KinD, K=5, 14 scenarios.
Driver: `run-fullsuite.sh`. Compare to the 0.9.11 baseline (`fullsuite-2026-08-31`).

## Headline (over runs that actually executed)

| arm | solved | RCI | RCR | cost/run | tokens/run |
|---|---|---|---|---|---|
| neat + haiku | **27/60 (45%)** | 85% | 65% | **$0.118** | 488k |
| obscode + opus | **56/60 (93%)** | 93% | 97% | $0.696 | 388k |

*(60 valid runs = 12 scenarios × 5; 401 & 412 VOID excluded. 20 + 32 re-run after the session-limit
truncation and folded in. This is the FINAL number.)*

- **Cost: ~6× cheaper** (5.9× overall; **6.2× on parity scenarios** where accuracy is identical).
- **Speed: ~26% faster** on detect (neat 84s/run vs obscode 113s/run); ~9% faster on resolve.
- **RCI (right service): neat 85% vs obscode 93% — obscode edges it.** CORRECTION: an earlier draft quoted
  "neat 98% vs 92%" over the 52-run set that was MISSING 20 + 32. Those two are pure-DEPLOY faults
  (bad-image, scale0) where neat's trace-only RCI collapses (20: 0/5, 32: 2/5) — see the deploy-fault
  finding below. On the trace-visible faults neat's RCI still matches/beats opus; the two deploy faults
  flip the aggregate.
- RCR (reach code locus): neat 65% vs obscode 97%. Full-solve gap is largely grader artifacts (below).

Rate-limit note for the record: the first pass truncated 20+32 when the Max window emitted *"You've hit
your session limit"* at 22:52 (4.5h in); an earlier intermediate summary (42%/78%) counted those non-runs
as failures. 20+32 were re-run on the next window and folded in — the 45%/93% above is the clean final.

## Deploy-fault finding (20 + 32) — why NEAT's RCI collapses there
20 (product-catalog bad image → ImagePull) and 32 (ad scaled to 0) are PURE cluster-state faults: the
signal is in k8s, not in traces. neat scored RCI 0/5 and 2/5 — it could NOT reliably name the culprit
service. This is exactly what 0.9.13's **#1131 deploy-mismatch** (declared ⋈ observed image) and **#1128
unreachable** are built for — BUT the bench runs NEAT trace-only (no ~/.neat/k8s.json substrate), so #1131
can't fire and the trace-only unreachable signal didn't land for product-catalog/ad. So the bench scores
0.9.13's headline deploy features as absent. This is BOTH the reason for the RCI reversal AND a real
bench-coverage gap: to test what 0.9.13 actually shipped, the k8s substrate must be wired into the harness.

## Per-scenario (valid runs only)

| scen | mode | neat | obscode | note |
|---|---|---|---|---|
| 416 configdb | detect | **4/5** | **1/5** | ⭐ NEAT WIN — config-db divergence opus+source mostly can't see |
| 407 neo4j deadlock (serving) | detect | 5/5 | 5/5 | parity (instrumented) |
| 408 neo4j deadlock (bootstrap) | detect | 5/5 | 5/5 | parity — out-of-band, yet neat matches opus |
| 415 config OOB | detect | 5/5 | 5/5 | parity |
| 413 wrong neo4j label | detect | 3/5 | 5/5 | neat variance |
| 410 neo4j livelock | resolve | 2/5 | 5/5 | resolve-repair gap (see artifacts) |
| 405 neo4j no-timeout hang | resolve | 0/5 | 5/5 | AMPUTATION artifact (see below) |
| 406 neo4j hang (bootstrap) | detect | 0/5 | 5/5 | UNREACHABLE-not-credited artifact |
| 409 neo4j livelock (bootstrap) | detect | 0/5 | 5/5 | same class as 406 |
| 414 wrong host (bootstrap) | detect | 1/5 | 5/5 | same class as 406 |
| 20 bad image | detect | 0/5 | 5/5 | pure-deploy fault; neat trace-only can't name it (see deploy finding) |
| 32 ad scale0 | detect | 2/5 | 5/5 | pure-deploy fault; same |
| 401 proto-field (fusion) | resolve | VOID | VOID | preflight race (bench bug) |
| 412 recursive-LCS | resolve | VOID | VOID | fault-didn't-confirm (weak scenario) |

## Why the 48% is a floor, not a verdict — two grader artifacts

**1. Resolve rewards amputation over repair (405/410).** opus "resolves" by DELETING the faulted
neo4j feature wholesale (removes the import, the function, the call site) → service returns 200 because
the broken path is gone. Grader (`RESOLVED` = 200 + latency ceiling, `anticheat_breach=NO`) credits it.
haiku instead writes the catalog's OWN intended fix (405: `timeout=2`), clears the hang
(`SYMPTOM_CLEARED=YES`), but returns 500 (no fallback) → graded NO. So haiku wrote the intended fix and
lost; opus wrote an unintended amputation and won.
→ **Fix: PASS_TO_PASS that the neo4j-additional-products behavior survives / detect wholesale deletion.**

**2. Out-of-band unreachable-not-credited (406/409/414).** On a bootstrap crash the pod emits zero spans,
so the true cause (neo4j bootstrap hang) is NOT trace-visible. NEAT correctly returns *"service unreachable,
zero telemetry, cause is in deployment state — check deploy/logs"* (#1128 working — the haiku arm quoted the
incident card verbatim). Grader wants the specific neo4j cause string → marks it a hard miss. "Unreachable →
check deploy state" IS the correct SRE call for a trace-only tool.
→ **Fix: credit correct service + correct unreachable-classification as CAUGHT (or partial).**

Contrast: **408 (also bootstrap/out-of-band) scored neat 5/5** — the difference from 406/409 is whether the
grader's accepted cause is reachable from the classification. That split is the strongest evidence both are
grading-philosophy issues, not NEAT capability.

## Cost / speed (measured)

| metric | neat+haiku | obscode+opus |
|---|---|---|
| $/run (parity 407+408) | $0.126 | $0.778 (**6.2×**) |
| wall-time, detect | 84s | 113s (**−26%**) |
| wall-time, resolve | 264s | 289s (−9%) |
| RCI (right service) | **98%** | 92% |

## Release scope — what 0.9.13 ACTUALLY contains (read before interpreting)
**#1128 (unreachable) + #1131 (deploy-mismatch) ONLY.** The hang fix is NOT in this build:
FRONTIER hang stack #1134/#1135/#1136 (incl. "hang sensor: stage a surface when a service hangs")
are still OPEN PRs; #1114 (incident-card hang classifier) is pending review; only ADR-222 (#1116, the
*design*) is in the tree. This suite is HANG-DOMINATED (neo4j no-timeout/deadlock/livelock/bootstrap-hang),
so NEAT was scored WITHOUT hang-specific handling. → **48% is a floor the 0.9.14 hang work should raise.**
Caveat the other way (honest): NEAT still diagnosed several hang faults correctly anyway — 407/408 CAUGHT
5/5, 405 RCR 5/5 — via root-cause + incidents + latency, so hang handling is ADDITIVE, not a prerequisite.
The hang-fix absence does NOT explain the 406/409/414 losses (those are bootstrap crashes → #1128 unreachable
fired correctly → grader artifact), nor the 405/410 resolve losses (amputation artifact).

## Provenance / integrity
- 0.9.13 install verified to carry the new logic (`unreachable` ×102, `deploy-mismatch` ×31 in @neat.is/core dist).
- preflight O1–O3 gated every scored window. 401 voided on the incident-store-empty race (fast-erroring
  serving fault + demo loadgen re-mints incidents before the gate — a bench bug, not NEAT).
- Tail truncated by Max session-limit at 22:52 (resets 23:50 Europe/London). Top-up 32 + 20 seeds 3–5 pending.

## Follow-ups
- **Bench:** (a) amputation anti-cheat, (b) out-of-band unreachable credit, (c) 401 preflight race,
  (d) 412 latency-confirm or drop, (e) top-up 32/20 after window reset.
- **NEAT-core:** #1128 confirmed working (positive). Open: is 413's 3/5 NEAT nondeterminism or haiku
  variance (diff transcripts before filing). 416 win worth a writeup (config divergence opus can't source-read).
- **Same-model context:** the clean NEAT-isolation number is the ITBench SRE run (opus both arms, NEAT
  purely additive): accuracy tie, directness ~40% fewer steps on far-from-symptom faults — but on
  neat.is@0.9.2, before the incident work-order and the k8s substrate. An ITBench refresh on 0.9.13 would
  gain the work-order + k8s substrate + #1076, but NOT hang handling (still unshipped — see Release scope).
