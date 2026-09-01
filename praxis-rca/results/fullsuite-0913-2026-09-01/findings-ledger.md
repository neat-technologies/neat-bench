# 0.9.13 full-suite bench — findings ledger (batch-file at end)

Split by owner. HARD RULE: NEAT-core bugs → neat-technologies/neat issues; bench-harness/grader
findings → neat-bench repo. Never mix bench artifacts into the core repo.

## BENCH-HARNESS (neat-bench)

1. **401 preflight race — flagship fusion scenario auto-voids.**
   O3 gate ("incident store for service:recommendation must be empty at preflight") breaches on
   FAST-erroring serving faults: the demo's own loadgenerator + the still-active fault re-mint
   incidents into the fresh daemon in the ~12s between restand and the gate check. 405 (also
   serving) passes only because its fault is a 15s HANG (spans don't complete in-window). Fix:
   gate must tolerate loadgen traffic for serving faults (baseline-relative incident delta, not
   absolute-zero), OR restand immediately before the scoring window. Impact: loses the single most
   important fusion scenario. All 5 seeds void → 0 data.

2. **412 fault-didn't-confirm — pure-algo scenario auto-voids.**
   Recursive-LCS is a latency bug with no error symptom; confirm-load looks for 5xx/hang and finds
   nothing → void. Either add a latency-ceiling confirm for 412, or drop it (weak scenario — it's
   the honest static-control where NEAT shouldn't help anyway).

3. **Grader understates the out-of-band set (406/408/409/414/20/32) — DESIGN QUESTION.**
   On a bootstrap crash the pod never emits spans, so the true cause (neo4j bootstrap hang / bad
   image) is NOT trace-visible. NEAT correctly returns "service unreachable, zero telemetry, cause
   is in deployment state — check deploy/logs" (#1128 working, see NEAT-core note). grade-detect.sh
   counts that as a hard MISS because it wants the specific neo4j-bootstrap cause string. But
   "unreachable → go look at deploy state" IS the correct SRE call for a trace-only tool. Question
   for the oracle: should a correct service + correct unreachable-classification earn CAUGHT (or a
   partial), rather than 0? This single decision swings the whole out-of-band number.

## NEAT-CORE (neat)

1. **#1128 `unreachable` is WORKING — positive, not a bug (evidence, 406).**
   The haiku arm quoted NEAT's incident card verbatim: *"recommendation is unreachable and has not
   produced any telemetry — no server spans... failing before it can start serving... cause is in
   the deployment state, not in the application code. Evidenced by 128+ erroring inbound calls from
   frontend with zero server-side spans."* That is the textbook honest-degradation answer. So the
   "neat 0/2 on 406" is a GRADER artifact, not a NEAT failure. Keep as launch evidence.

2. **[OPEN — verify at end] 413 neat 3/5 — is the miss NEAT-nondeterminism or haiku variance?**
   Same graph state across 5 seeds; neat missed seeds 2 & 5. If get_root_cause / incident output
   varies run-to-run on an identical graph, that's a real core determinism bug (NEAT's load-bearing
   word). If it's just haiku sampling, no core issue. MUST diff the transcripts before filing.

3. **[OPEN — architectural, not a bug] out-of-band deploy faults could be root-caused, not just
   flagged, IF the k8s substrate (#1131 declared-image ⋈ observed-image) were wired into the bench.**
   20 (bad image) and the bootstrap crashes are literally deploy-mismatches — exactly what #1131's
   deploy-mismatch divergence names. The bench runs trace-only (no ~/.neat/k8s.json), so #1131 can't
   fire. Not a core bug; it's a bench-coverage gap that also shows a real product story: the trace
   layer says "unreachable," the k8s substrate would say "declared image X, running image Y."

## RESOLVE-GAP ROOT CAUSE (decisive — investigated 405/410 transcripts)

**BENCH #4 — SEVERE: grader rewards feature-AMPUTATION over repair. Distorts the entire resolve column.**
   opus wins 405/410 RESOLVED by DELETING the faulted neo4j path wholesale — removes `import requests`,
   the entire `get_additional_product_from_database()` fn, the call site, the env lookup. Service returns
   200 because the broken feature is GONE, not fixed. `RESOLVED` oracle only checks 200s + latency ceiling,
   so amputation passes; `anticheat_breach=NO` never caught it. Meanwhile haiku (neat) attempts a real
   repair: 405 adds `timeout=2` — THE CATALOG'S OWN STATED INTENDED FIX — clears the hang
   (SYMPTOM_CLEARED=YES) but returns 500 (no fallback) → graded NO. So the "opus 5/5 vs neat 0/5" resolve
   split is substantially opus gaming the oracle by deleting code while haiku faithfully repairs.
   FIX: add a PASS_TO_PASS that the neo4j-additional-products behavior is preserved (or detect wholesale
   deletion of the faulted path). This likely FLIPS the resolve column. Single highest-value bench fix.

**BENCH #5 — 405 fix-spec under-specified.** Catalog says fix = "add timeout"; but with the endpoint down,
   timeout alone → 500, not 200. The real passing fix needs timeout+fallback. The scenario misleads the
   arm about what "resolved" requires.

**NEAT/thesis #4 — resolve gap is NOT fatal model weakness (the answer to "is the model weak").**
   haiku located the exact fault AND wrote the intended fix with a clean edit (405 timeout). Its only
   shortfall is fix-COMPLETENESS (no fallback) — the single most NEAT-addressable gap: NEAT's OBSERVED
   layer knows a bare timeout turns a hang into a 5xx, so an ADR-221-style incident-card work-order can
   spec "timeout + fallback." Give the cheap model a complete work-order and it repairs instead of guessing.

**NEAT/thesis #5 — one real, BOUNDED haiku weakness (410, honest).** haiku's 410 edit removed only the
   env-lookup line, left the hanging call intact → SYMPTOM_CLEARED=NO. An incoherent multi-step edit. That
   IS model execution weakness — but bounded, and exactly the kind a prescriptive work-order scaffolds around.

## Running tally (update as run completes)
- 413 detect: neat 3/5, obscode 5/5
- 405 resolve: neat 0/5 (RCR 5/5), obscode 5/5
- 410 resolve: neat 2/5, obscode 5/5
- 407 detect: neat 5/5, obscode 5/5  ← instrumented parity
- 406 detect: neat 0/2 so far (grader artifact per NEAT-core #1), obscode 1/1
- VOID: 401, 412
- pending: 408 409 415 416 414 20 32
