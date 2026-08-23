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

6. **"our new method … PRAXIS one … no self-injected bugs."** (Established this session.)
   Faults come from the **third-party PRAXIS Code-Cloud-RCA** benchmark (public, Zenodo, code-grain). We NEVER inject our own bugs. Grade at code grain (RCR), the grain where fusion is decisive — not ITBench-SRE's k8s-object grain (that draws).

## Non-negotiables (the anti-fudge firewall)
- No self-authored faults. No excluding losses to inflate a number. No LLM-judged "resolved."
- Identical injected state + model + budget across arms; only tooling differs. ≥3 seeds; report variance.
- Every NEAT weakness is **on the record** (filed + fixed in public), never smoothed over.
- Zero bench code / contracts / ADRs on `neat-technologies/neat`. Bench governance lives here.

Method detail: [praxis-rca/METHOD.md](praxis-rca/METHOD.md) · Scoring: [praxis-rca/SCORING.md](praxis-rca/SCORING.md)
