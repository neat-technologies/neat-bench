# ±NEAT bench — current results & honest read

Last updated 2026-09-16. This is the candid state of the RCA bench: the two most recent runs, what
the numbers are, where the test cut against NEAT, **where it quietly flattered NEAT**, and what we're
building next to get a number worth posting. Nothing here is the launch number yet — see "What's next."

## The two most recent runs

Both are **sonnet+neat vs opus+source** on the live otel-demo (KinD), K=5, graded clean (exclude VOID
and any non-run row). Full per-run detail in `praxis-rca/results/`.

### 1. Track 2 — neat.is@0.9.14 + k8s substrate (2026-09-13)

| arm | solved | RCI | RCR | cost/run | tokens/run |
|---|---|---|---|---|---|
| sonnet + NEAT | **35/45 (78%)** | **100%** | 80% | **$0.174** | 264k |
| opus + source | 40/45 (89%) | 91% | 93% | $0.398 | 173k |

- **~2.3× cheaper**, speed comparable (detect ~equal, resolve ~15% slower).
- **NEAT's RCI beat opus (100% vs 91%)** — the graph named the faulty service more reliably than
  source + kubectl + Jaeger, with the cheaper model.
- **Marquee feature result — FRONTIER hang (0.9.14):** scenario 406 (bootstrap hang) went **0/5 →
  4/5, beating opus (3/5)**. Honest boundary: 409 (livelock) stayed 0/5 — a livelock spins, it doesn't
  hang, so the sensor doesn't stage it.
- **9 of 14 scenarios graded.** VOID: 408, 414, 20, 32 (the void plague, below) + 412 (dead scenario).
- **Deploy-mismatch (#1131) never scored.** The substrate was proven working in a smoke test (23
  `observedImage` stamped, divergence fires correctly) — but scenarios 20/32 voided before the arms
  ran. The feature works; the harness couldn't score it.

### 2. Sonnet 0.9.13, partial (2026-09-02)

| arm | solved | RCI | RCR | cost/run | tokens/run |
|---|---|---|---|---|---|
| sonnet + NEAT | **29/40 (72%)** | **100%** | 75% | **$0.208** | 350k |
| opus + source | 40/40 (100%) | 100% | 95% | $0.687 | 404k |

- 8 scenarios graded (401, 413, 405, 410, 407, 406, 409, 415); run cut short when the box was physically
  relocated. VOID: 408, 412.
- **The result that mattered: sonnet closed the repair gap haiku couldn't.** 405 (neo4j hang, resolve)
  went **0/5 (haiku) → 5/5 (sonnet)**; the resolve scenarios reached ~parity with opus. haiku was
  NEAT's eyes; sonnet is eyes and hands. **~3.3× cheaper** than opus.

For contrast, the haiku baseline (0.9.13) was 27/60 (45%) — the model swap to sonnet is what moved the
NEAT arm from 45% to ~78%, almost entirely by closing repair.

## Limitations — where the test cut against NEAT

1. **Amputation loophole (resolve scenarios).** The RESOLVED oracle only checked "does the service
   return 200s," not "does the feature still work." opus's winning move was to **delete the broken
   code**; the service returns 200 because the failing path is gone. NEAT's answers tried to *repair*.
   The grader rewarded destructive shortcuts, which opus reached for more.
2. **Honest degradation uncredited (out-of-band: 406/409/414).** These pods crash at startup and emit
   zero telemetry — the cause isn't in the trace stream. NEAT correctly says *"unreachable, cause is in
   the deploy state, check logs."* The grader wanted the specific cause string, which the kubectl-access
   arm could read from pod logs. NEAT was penalized for the correct answer for its inputs. **Proven
   model-invariant** — haiku and sonnet fail these identically, so it's grading, not capability.
3. **The void plague.** A preflight gate ("incident store must be empty") loses a ~12s race against the
   demo's load generator for **fast-erroring faults** — so bad-image (20), scale-0 (32), and the
   bootstrap crashes (408, 414) void before the arms run. These are **exactly NEAT's differentiator
   scenarios** (deploy-mismatch, out-of-band), so the harness's own bug deletes the runs NEAT should win.
4. **Model confound (earlier runs).** Most runs swapped the model (haiku/sonnet vs opus), so NEAT's
   contribution can't be cleanly isolated from the model's.
5. **Small, partial samples.** Box relocation, Max-window session walls, and manual pause/resume left
   several runs at 8–13 of 14 scenarios. Noise is real.
6. **Wrong shape.** A one-shot symptom→cause RCA quiz structurally understates NEAT — its real value is
   scale, divergence discovery, and persistent build context, none of which this shape measures.

## What stacked the odds in NEAT's favour

Read this as hard as the section above — a number is only trustworthy if it names its own thumb on the
scale.

1. **The target is engineered-against.** NEAT's fusion (compat, recognizers) has been developed against
   otel-demo. A score on a familiar target **overstates** NEAT versus a codebase it has never seen.
2. **100% instrumentation.** otel-demo is fully OTel-instrumented — NEAT's OBSERVED best case. Real
   systems are partially instrumented, where NEAT's runtime layer is thinner. The demo flatters every
   OBSERVED-dependent win.
3. **Narrow fault distribution.** 14 scenarios, most of them neo4j-in-recommendation faults — a
   distribution NEAT's fusion handles well, not a representative spread of real incidents.
4. **RCI is NEAT's friendliest metric.** "Name the right service" is coarse and exactly what the graph
   is built to ace. NEAT's 100% RCI is real, but it is the most favorable lens; it is not full
   diagnose-and-fix.
5. **The incident-card hand-off.** On scored scenarios the NEAT arm reads pre-digested incident cards —
   the agent does less of its own reasoning. That's the product working, but it means part of what looks
   like agent autonomy is NEAT's pre-computation.

Net: the grader and the void race pushed the number **down** (against NEAT); the target familiarity,
full instrumentation, and RCI-lens pushed it **up** (for NEAT). We don't yet know the size of either
thumb precisely — which is the whole reason for the rebuild.

## What's next — a number worth posting

The current bench is being retired as the launch number. Two replacements, both built on the same
principle: **same model on both arms, ±NEAT — the only variable is NEAT.**

1. **Build Autonomy bench (the headline).** SWE-bench-shaped: real feature/bug tasks on a repo NEAT was
   *not* engineered against, graded by the repo's own tests — **FAIL_TO_PASS** (the new behavior) **and
   PASS_TO_PASS** (nothing else breaks). That PASS_TO_PASS clause is objective, needs no LLM judge, and
   **kills amputation dead** — you can't delete a feature to pass. The NEAT signal is **blast-radius**:
   the no-NEAT arm breaks callers it never saw (PASS_TO_PASS fails) and burns turns grep-reconstructing
   context the graph hands over. Void-free by construction — there is no incident store to race.
2. **Fair-RCA, rebuilt (support).** Same-model ±NEAT; RESOLVED requires behavior-preserved (no
   amputation) and credits honest "cause-not-in-trace"; **graded against a captured graph snapshot** so
   there is no live race to lose — deterministic and reproducible.

Target: a small curated set of real OSS services for the number we post, plus a design-partner repo as
the internal gut-check we don't. Task selection is the one rule that decides whether it works — pick
changes where **reading the code isn't enough** (cross-cutting blast radius, or correctness that depends
on runtime behavior). Legible tasks are ties by construction; NEAT's edge only shows past that wall.
