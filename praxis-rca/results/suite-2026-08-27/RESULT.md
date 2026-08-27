# ±NEAT suite — 4 scenarios × 3 arms × k=2 (2026-08-27)

PRAXIS Code-Cloud-RCA on the live OTel Demo (KinD box). Scenarios **401** (schema
AttributeError → 500), **405** (neo4j HTTP timeout hang → 504), **410** (neo4j
socket livelock → 504), **412** (recursive-LCS latency → slow 200s). Three arms —
**code** (source only), **obscode** (source + raw Jaeger/Prometheus/logs, unfused),
**neat** (source + live `neat watch` fused graph, full arsenal) — same model
(Claude Opus), same budget (40 turns), k=2 seeds, load-isolated. Graded RCI (faulty
service) + RCR (faulty code location) + RESOLVED (RCR **and** the app verifiably
recovers, regression-free). Ground-truth RCI for all four = `service:recommendation`.

## Headline (RESOLVED@8 = 4 scenarios × 2 seeds)

| arm | RCI@8 | RCR@8 | **RESOLVED@8** | mean tokens | mean cost |
|---|---|---|---|---|---|
| **neat** | 8/8 | 7/8 | **7/8 (87.5%)** | 279k | $0.55 |
| code | 8/8 | 6/8 | 6/8 (75%) | 284k | $0.49 |
| obscode | 8/8 | 6/8 | 6/8 (75%) | 328k | $0.63 |

RCR@8 == RESOLVED@8 for every arm (each correct localization also verified; each
miss also failed to resolve). Total cost for all 24 runs: **$13.35**.

## Per-scenario RESOLVED (out of 2 seeds)

| scenario | mode | code | obscode | neat |
|---|---|---|---|---|
| 401 | ERROR | 2/2 | 2/2 | 2/2 |
| 405 | HANG | 2/2 | **0/2** | 2/2 |
| 410 | HANG | 2/2 | 2/2 | 2/2 |
| 412 | LATENCY | **0/2** | 2/2 | 1/2 |

neat is the only arm that never scores 0 on a scenario. But the margin is one run
(7 vs 6), and the story is in *which* runs each arm loses — not a blowout.

## What actually happened (brutally honest)

- **401 / 410 are ties (all 2/2).** Both faults are plainly code-visible (a wrong
  proto field; an unbounded `while True`). A strong Opus code agent reads the source
  and fixes them, so obs and fusion add nothing. 401 was pre-registered as a
  control/warm-up (METHOD.md); 410 turned out the same way.

- **405: neat & code beat obscode (obscode 0/2).** The fix is a timeout on the neo4j
  `requests.get`. code and neat added it (RCR=YES). **obscode, both seeds, deleted
  the entire neo4j feature** — call, helper, import — which clears the symptom
  (FIX/SYMPTOM=YES) but is not the fix (RCR=NO → RESOLVED=NO). Raw traces led it to a
  lazy amputation; the combined find+fix grade correctly withholds credit. This is a
  fusion(+code)-over-unfused win.

- **412 is the cleanest fusion-decisive scenario, and it cuts against code.** The
  fault is *correct-but-slow* code (recursive LCS). **code is deterministically 0/2:**
  with no runtime signal it cannot tell which function is slow, so both seeds
  misattributed the latency to the untimed `socket.recv` (pattern-matching to the
  405/410 hang class) — seed 1 amputated the block, seed 2 added a socket timeout that
  did nothing (verify: 9009 ms, still > the 2463 ms ceiling). The runtime-signal arms
  used the observed per-span latency to point straight at `compare_product_compatibility`
  and reimplement it with DP: **obscode 2/2, neat 1/2.**

- **neat is flaky on 412 (1/2) — a real determinism gap, on the record.** Seed 1
  used blast-radius / observed-dependencies to localize the LCS and fixed it. **Seed 2
  misdiagnosed exactly like the code arm** — added a neo4j `settimeout`, never touched
  the LCS. The fused graph made the right answer *available* (seed 1 proves it) but did
  not *force* the agent to use it. Notably, **obscode (raw traces) was more
  deterministic than neat (fused graph) on this latency fault (2/2 vs 1/2)** — the
  opposite of the thesis for this one scenario. Worth a NEAT-arm-prompt look (lead
  harder with observed-latency / blast-radius before hypothesizing) and a determinism
  re-run at higher k.

## Caveats (do not oversell)

1. **Our `code` arm ≠ PRAXIS's runtime-only=0% baseline.** It has full source
   (read/grep/Edit), so it scores 75%, not 0%. PRAXIS's 0.0% RCR / 61.5% fused
   numbers are a *different* baseline; all three of our arms clear their 61.5% fused
   RCR, precisely because our floor is much stronger. The honest internal comparison is
   neat vs obscode (fusion vs unfused-both-signals) and neat vs code (graph vs
   source-only), not against PRAXIS's published rows.
2. **k=2 is low power.** RESOLVED@2 per (arm,scenario) takes only {0, .5, 1}; the
   determinism claim (CONTRACT wants k≥5) is under-powered here. 412's neat 1/2 is
   exactly the kind of variance k=2 can't resolve — needs a k≥5 re-run.
3. **RCI is near-trivial here (100% for every arm).** The editable service *is* the
   faulty service, so naming it is free. RCI carries no signal in this suite; RCR /
   RESOLVED do the work.
4. **Environment repairs (disclosed, in `stabilize-cluster.sh`).** The built-in
   load-generator was scaled to 0 (it confounds every measurement); product-catalog
   (20Mi) and frontend (250Mi) were chronically OOMKilled and were bumped so the
   regression probe is meaningful. A known-good gold fix scored RESOLVED=NO until this
   was fixed. None of these services is a graded fault.
5. **Minor hygiene leak, immaterial.** NEAT's own artifacts (`neat.patch` install
   plan, `neat-out/` daemon metadata) live in the shared `~/opentelemetry-demo` tree
   the code/obscode arms can grep. Exactly 1 of 8 code runs touched them (412 code
   seed 2: `head neat.patch` + `ls neat-out/`); it read no graph/observed data, never
   ran the neat CLI (PATH held), and still misdiagnosed — so the leak did not change a
   result. Should be excluded from the arms' tree in future runs.

## Oracle validation (pre-registered, both directions)

Before the runs, `validate-oracle.sh` proved every scenario's oracle discriminates:
gold fix → RESOLVED=YES, faulted seed → RESOLVED=NO, clean revert. 401 gold 200s/7ms;
405 gold 200s/2013ms; 410 gold 200s/311ms; 412 gold 200s/7ms (< 2463 ms ceiling).
product-catalog regression probe was 4/4 in every verify after stabilization.

Raw per-run detail: `suite-results.tsv` (also at `~/praxis/runs/suite-results.tsv`).
