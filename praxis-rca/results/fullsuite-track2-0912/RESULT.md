# Track 2 — Feature-validation ±NEAT — neat.is@0.9.14 + k8s substrate (2026-09-13)

opus+obscode vs **sonnet+neat**, live otel-demo on KinD, K=5. The question Track 2 answers:
**do the features we shipped since the bench was designed measurably move the numbers on the faults
they target?** Distinct from Track 1 (the model question). Changes vs the 0.9.13 sonnet run: bumped to
0.9.14 (FRONTIER hang stack live), wired the k8s substrate (`~/.neat/k8s.json`), aligned the manifest to
the running cluster (2.0.1) for a clean baseline. Grader UNCHANGED.

## Headline (9 graded scenarios; 5 voided — see below)

| arm | solved | RCI | RCR | cost/run | tokens/run |
|---|---|---|---|---|---|
| sonnet + neat | **35/45 (78%)** | **100%** | 80% | **$0.174** | 264k |
| opus + obscode | 40/45 (89%) | 91% | 93% | $0.398 | 173k |

- **RCI (right service): sonnet 100% vs opus 91% — neat names the culprit MORE reliably**, with the cheap model.
- **Cost: ~2.3× cheaper** ($0.174 vs $0.398).
- **Speed: comparable** — detect ~equal (sonnet 55s vs opus 57s), resolve sonnet ~15% slower (236s vs 205s;
  the richer 0.9.14 graph + substrate surface costs it a few turns).

## Per-scenario (graded)

| scen | mode | sonnet+neat | opus | note |
|---|---|---|---|---|
| 401 | resolve | 5/5 | 5/5 | parity (haiku voided this) |
| 405 | resolve | 5/5 | 5/5 | parity — haiku was 0/5; sonnet closes the repair gap |
| 410 | resolve | 4/5 | 5/5 | near-parity |
| 413 | detect | 4/5 | 5/5 | |
| 407 | detect | 4/5 | 4/5 | parity (deadlock, serving) |
| **406** | detect | **4/5** | **3/5** | ⭐ **FRONTIER-hang WIN** — 0/5 (0.9.13) → 4/5, beats opus |
| 409 | detect | 0/5 | 3/5 | livelock bootstrap — FRONTIER hang doesn't classify a livelock (honest limit) |
| 415 | detect | 4/5 | 5/5 | |
| 416 | detect | 5/5 | 5/5 | parity (config-db) |

## Feature deltas — what Track 2 was built to measure

**1. FRONTIER hang (0.9.14) — WORKS, measurably.**
Scenario **406 (neo4j bootstrap hang): 0/5 (0.9.13 sonnet) → 4/5 (0.9.14), and it beat opus (3/5).**
The shipped hang sensor lifted the exact scenario class it targets. Honest boundary: **409 (livelock
bootstrap) stayed 0/5** — a livelock spins rather than hangs silently, so the hang sensor doesn't stage it.
407 (deadlock, serving) held ~parity (5/5→4/5, one-seed variance).

**2. k8s deploy-mismatch (#1131) — feature PROVEN, but the bench scenarios VOIDED (untested in-scenario).**
The substrate was wired and verified working in a smoke test: it polled the cluster cleanly, stamped 23
`observedImage`, and deploy-mismatch fired correctly (declared 2.0.0 vs running 2.0.1 across the fleet
before the manifest was aligned). **But scenarios 20 (bad image) and 32 (scale0) VOIDED before the arms ran**
— on the incident-store preflight race (below), not anything substrate-related. So the head-to-head
deploy-mismatch bench number was not captured. The feature works; the harness couldn't score it.

## The 5 voids — one recurring harness bug

- **412** — pure-algo, fault-didn't-confirm (as always; weak scenario).
- **408, 414, 20, 32** — ALL voided on the SAME breach: *"O3 incident store for service:X is NOT empty"*.
  This is the incident-store preflight race — the demo loadgen + the still-active fault re-mint incidents
  into the fresh daemon in the ~12s between restand and the gate. It's **structural for FAST-erroring faults**
  (bad-image, scale0, deadlock-bootstrap, wrong-host-bootstrap): they pile incidents up fast → gate fails.
  HANG faults (406) win the race → get scored. **This is the same bug that voided 401 in the haiku run** —
  now the #1 recurring bench blocker, and it's specifically eating the deploy + fast-fault scenarios (20/32/408/414).

## Follow-ups (priority order)
1. **Fix the incident-store preflight race** (bench) — clear the incident store immediately before the scored
   window, or make the gate baseline-relative instead of absolute-zero. Unblocks 20/32/408/414 — without it,
   the deploy-mismatch feature can't be scored in-bench.
2. Re-run 408/414/20/32 after that fix → capture the real deploy-mismatch number (expected: neat wins 20/32
   via the divergence, which pure error-hunting misses).
3. Add a stuck-rollout scenario (no-incident deploy-mismatch — #1131's signature case, untested).

## Verdict
On the 9 scenarios the harness could score: **sonnet+neat is 78% solved, RCI 100% (beats opus's 91%),
~2.3× cheaper, comparable speed** — and **FRONTIER hang measurably lifted its target scenario (406: 0/5→4/5,
beating opus)**. The deploy-mismatch feature is proven working (smoke) but the bench's own preflight race
prevented scoring it. Net: the shipped hang feature earns its keep; the deploy feature's in-bench number is
blocked on a harness fix, not on NEAT.
