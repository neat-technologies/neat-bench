# neat-bench BINDING CONTRACT

This is the load-bearing spec for the ±NEAT benchmark. If any code, harness, arm, or report conflicts with this, **the conflict is the bug — stop and fix it.** Re-read this before every run. It is Cem's word, verbatim, and it is what "real" means here.

---

## The spec (Cem, verbatim — do not paraphrase, do not soften)

> ok build everything into neat-bench with our new method and get ready to do the runs
>
> remmeber, the loop is:
>
> Run scenario
> When neat presents a weakness, bug, misdirection or ANYTHING, file an issue for it to be researched and fixed without any fudging and for it to be fixed by one of your own subagents then immediately put on latest.
>
> The bench should be:
>
> Start Scenario
> inject headless claude
> download code intel packages
> run n observe
>
> after each one, file a report
>
> do all that setup while i spawn the box again
>
> Also, graphify should start its own graph, and full user flows, like normal. AND THE BUG SHOULD BE FIXED. NOT JUST FOUND. BY EACH AGENT. GRADE FINDING AND FIXING TOGETHER.
>
> AND NEAT SHOULD HAVE LIVE DAEMONS

---

## What this binds (each clause → the rule it enforces)

1. **"Run scenario … file an issue … fixed by one of your own subagents then immediately put on latest."**
   Every NEAT weakness / bug / misdirection / low-confidence-or-misleading answer / missing capability → **GitHub issue on `neat-technologies/neat`, no fudging** → **my own subagent** researches + fixes (isolated worktree, real fix + tests + PR) → **shipped to npm `latest` immediately** → affected scenarios re-run on the new version. Not "note it and move on." File → fix → ship.

2. **"Start Scenario / inject headless claude / download code intel packages / run n observe / after each one, file a report."**
   The per-scenario pipeline, in order. Fresh headless Claude per arm. Each arm sets up ONLY its own code-intel tooling. Observe the run. **A report per scenario**, every time.

3. **"graphify should start its own graph, and full user flows, like normal."**
   The obs+graphify arm builds graphify's OWN code graph and drives FULL user flows to generate real observability — used the normal way, not a strawman. It must be a genuinely strong baseline (both signals, unfused) or the fusion win is fake.

4. **"AND THE BUG SHOULD BE FIXED. NOT JUST FOUND. BY EACH AGENT. GRADE FINDING AND FIXING TOGETHER."**
   Localization alone is NOT a pass. Each arm must emit a **fix**; the fix is **verified by the app actually recovering** (apply → redeploy → symptom-clears). The headline metric `RESOLVED` = correct code-grain localization **AND** verified fix. No "looks fixed" credit.

5. **"AND NEAT SHOULD HAVE LIVE DAEMONS."**
   The neat arm runs against a **live `neat watch` daemon** ingesting live OTel from the running app — not a snapshot, not replay. Fused, live, current.

6. **USE NEAT'S FULL ARSENAL — it is a fused reasoning graph, NOT an OTel feeder.** (Cem, corrective: *"neat has blast radius from observed, time travel states, policies and the like — why are you just using neat as an otel feeder rn"*.) Reducing the neat arm to `root-cause` + `incidents` (surfacing an error string) HANDICAPS it and is why it drew — that benchmarks NEAT's weakest surface against a strong code agent. The neat arm MUST be given and MUST lead with the full graph-reasoning surface:
   - **`neat divergences`** — declared (EXTRACTED) vs observed (OBSERVED) code↔runtime mismatch, down to the field/symbol. (This is the direct route to code-grain faults like accessing a non-existent field.)
   - **`neat diff --against <healthy-snapshot>`** — TIME-TRAVEL: snapshot the healthy graph BEFORE injection; diff after to see exactly what changed. (Harness MUST capture a healthy baseline snapshot per scenario.)
   - **`neat blast-radius <node>`** — impact/propagation from the observed graph.
   - **`neat stale-edges`** — edges that went silent (vanished dependency).
   - **`neat policies`** — policy violations; **`neat search`** — semantic search over the fused graph; **`neat dependencies` / `observed-dependencies`** — full transitive edges.
   Workflow: reason over the GRAPH (divergence + graph-diff + blast-radius) to localize the code-grain root cause and its blast radius — do NOT just eyeball a root-cause error string. If NEAT's full surface still can't localize where it should, THAT is a filed NEAT weakness (rule 1), not a reason to fall back and call it a draw.

7. **"our new method … PRAXIS one … no self-injected bugs."** (Established this session.)
   Faults come from the **third-party PRAXIS Code-Cloud-RCA** benchmark (public, Zenodo, code-grain). We NEVER inject our own bugs. Grade at code grain (RCR), the grain where fusion is decisive — not ITBench-SRE's k8s-object grain (that draws).

## Non-negotiables (the anti-fudge firewall)
- No self-authored faults. No excluding losses to inflate a number. No LLM-judged "resolved."
- Identical injected state + model + budget across arms; only tooling differs. ≥3 seeds; report variance.
- Every NEAT weakness is **on the record** (filed + fixed in public), never smoothed over.
- Zero bench code / contracts / ADRs on `neat-technologies/neat`. Bench governance lives here.

Method detail: [praxis-rca/METHOD.md](praxis-rca/METHOD.md) · Scoring: [praxis-rca/SCORING.md](praxis-rca/SCORING.md)
