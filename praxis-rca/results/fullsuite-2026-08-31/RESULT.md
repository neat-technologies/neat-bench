# Full-suite ±NEAT bench — final notes (2026-08-31)

**Arms:** `neat` = **haiku** against the live fused daemon (divergences / observed-deps /
root-cause / incidents / blast-radius + the incident card via `neat-card.sh`).
`obscode` = **opus** with raw source + raw observability (Jaeger, Prometheus, pod logs)
+ `kubectl`. 13 scenarios, k=5, real otel-demo on kind, NEAT 0.9.11.

**Metric:** detect = CAUGHT (named the faulty service AND the fault nature). resolve
(401/405/410) = RCR AND oracle-recovery. Grading is model-free keyword match over the
arm's diagnosis text (`grade-detect.sh` / `grade.sh`), preflight-gated per CONTRACT O1–O5.

---

## Headline

|            | neat + haiku  | obscode + opus |
|------------|---------------|----------------|
| **Overall**| **34/64 (53%)** | 61/65 (94%)  |
| cost / run | **$0.14**     | $0.67 (~4.8×)  |

The average hides the actual finding. Split by **where the fault's cause lives:**

| bucket                                          | neat + haiku        | obscode + opus       |
|-------------------------------------------------|---------------------|----------------------|
| **Instrumented** — cause rides an OTel span     | **29/35 (83%)** @ $0.12 | 31/35 (89%) @ $0.72 |
| **Out-of-band** — cause leaves the trace stream | 5/29 (17%) @ $0.16  | 30/30 (100%) @ $0.60 |

**One sentence.** NEAT sees what's instrumented. On faults whose cause rides a span it's
within 6 points of opus-with-everything at ~6× less cost — and it *beat* obscode on 405.
It goes blind exactly where the cause leaves the trace stream: bootstrap crash / hang /
livelock (cause in logs), k8s deploy state (cause in `kubectl`), raw-socket deps (no span
at all past the last instrumented hop).

---

## Per scenario

| scen | fault                               | bucket        | neat | obscode |
|------|-------------------------------------|---------------|------|---------|
| 401  | proto field mismatch (AttributeError)| instrumented | 5/5  | 5/5     |
| 407  | neo4j deadlock (serving)            | instrumented  | 5/5  | 5/5     |
| 408  | neo4j hang (serving)                | instrumented  | 4/5  | 4/5     |
| 415  | index-out-of-range (NUM_RETURN)     | instrumented  | 5/5  | 5/5     |
| 413  | wrong neo4j host (serving)          | instrumented  | 4/5  | 5/5     |
| 405  | neo4j no-timeout hang               | instrumented  | **3/5** | 2/5  |
| 410  | neo4j livelock (serving)            | instrumented  | 3/5  | 5/5     |
| 406  | neo4j **bootstrap** hang            | out-of-band   | 0/5  | 5/5     |
| 409  | neo4j **bootstrap** livelock        | out-of-band   | 0/4* | 5/5     |
| 414  | wrong neo4j host (**bootstrap** crash)| out-of-band | 0/5  | 5/5     |
| 20   | product-catalog **bad image**       | out-of-band   | 1/5  | 5/5     |
| 32   | ad **scaled to 0**                  | out-of-band   | 2/5  | 5/5     |
| 416  | neo4j-productdb missing env (raw socket)| out-of-band| 2/5  | 5/5     |

\* 409 neat graded on 4 seeds — seed 1 truncated mid-run by a transient 429. It missed all
four valid seeds regardless (hallucinated "memory leak line 87", the same fabrication as 406).

Catalog-box view: fusion neat 9/10 vs 10/10 · both neat 22/40 vs 35/40 · **strict-runtime
neat 3/15 vs 15/15** (the collapse — all three are bootstrap/deploy faults).

---

## NEAT limit vs model limit

The test: does the *graph* hold the signal? If yes and neat still missed → **model**. If the
signal isn't in the graph → **NEAT**.

- **Pure NEAT ceiling** (no model recovers it): 406 / 409 / 414 (cause in crash/boot logs,
  culprit emits no span) and the *why*-half of 20 / 32 (cause in k8s deploy state).
- **Model limitation** (graph had it, haiku misread): 20 — the graph resolved the failing
  edge to the named target `service:product-catalog`, one hop away, yet haiku blamed the
  *caller's* config. 32 — `frontend → service:ad [100% error]` was right there, but haiku
  named `ad` only 2/5. A stronger model likely follows the edge.
- **Neither** (neat wins): 401 / 407 / 408 / 415.
- **Baked-in confound:** neat=haiku, obscode=opus, so *part* of obscode's lead is just the
  stronger model. A neat+**opus** run on 20/32/410/406 would split graph-blind from
  haiku-misread with numbers. Not run — that's a bench decision.

---

## Fixes (the out-of-band blind spot IS mostly a data-source gap, not a fusion flaw)

1. **k8s connector** (closes 20/32, helps 406/409/414) — pull deploy image / replicas /
   endpoints / pod status+events into the graph as connector-OBSERVED, fused with the code
   deps and the observed refused-edges. Uses the existing connector plane. *Deferred k8s
   track — a scoping call, not a capability gap.*
2. **Raw-socket dependency recognizer** (closes 416's localization) — recognize
   `socket.connect(host,port)` with host from config → emit a declared dependency edge so a
   refused `:134` call joins to "target = neo4j-productdb, unreachable." EXTRACTED-layer,
   recognizer work.
3. **Honest degradation** (406/409/414) — NEAT issue #1123: name the unreachable *service*
   and say "cause downstream, unobserved" instead of hallucinating. In flight. Exact cause
   needs a narrow crash/exit signal (pod `terminated.message`) — not full log ingest.

---

## Caveats — don't over-read this number

- obscode is the **correct** "agent without NEAT": it has `kubectl` + logs because those are
  standard tools. Not over-provisioned. The neat arm is deliberately graph-only because
  NEAT's *claim* is "the graph subsumes cluster inspection" — the bench tests that claim,
  and finds where it breaks (down/unreachable services emit nothing).
- This is a **PRAXIS-shaped, single-injected-fault RCA** bench. It structurally understates
  NEAT's real value — scale, divergence-discovery, persistent cross-service context (the
  northsea shape). It answers "can a cheap model + graph localize one injected fault," not
  "is NEAT valuable."
- 416 re-graded accept-either (`recommendation` OR `neo4j-productdb`); that raised obscode
  3/5 → 5/5 (honest direction — it under-credited obscode's deeper answer before).
