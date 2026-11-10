# Recon (bench-internal) — the QA stack for the security bench

Status: bench-internal, not a NEAT-core product feature. Lives in the bench workspace
(~/neat-bench/security-pilot/recon/), kept local during the pilot. Grounded in NEAT's own
proven OBSERVED-e2e harness (e2e/brief/: load.ts drives journeys, assertions.ts reads the
graph + asserts OBSERVED shape + divergences) and the retired autonomous-remediation
propose->assess->gate->WATCH loop (the watch step is post-change confirmation by observation).

Recon = agentic QA testing + flushing + poke-holes. Three capabilities, each an agent-facing
tool in the NEAT-arm harness, plus the deterministic QA oracle the grader calls.

## 1. QA (post-change correctness) — the "actually works" oracle
Not "tests stay green." Drive the app and confirm it still works, product/usage-wise, post-fix.
Per app we define journeys (the e2e/brief load.ts pattern, generalized): the app's real test
suite PLUS a usage workload that exercises the real routes/handlers/deps (the same traffic
that feeds OBSERVED). A trial's correctness = all of:
  - the app's baseline-green tests still green (native framework per app),
  - the usage journeys return their expected status/shape (the app behaves),
  - the OBSERVED layer still materializes for the exercised routes (the app actually ran them),
  - get_divergences shows no NEW declared-vs-observed drift the fix introduced
    (a route/handler/dep that used to be observed and is now dark = a real regression the
    unit tests may miss).
Deterministic. This is what replaces the weak "no regression (tests only)" gate.

## 2. Flush (on demand)
Force a fresh, honest observation window so the agent (and the oracle) never read stale state:
drive the journeys -> poll the graph until OBSERVED edges update (fresh lastObserved,
spanCount>0, per assertions.ts) -> re-run get_divergences + get_graph_diff. Wraps NEAT's
existing refresh plumbing (OTLP push + the REST connector-poll + re-extract) from the bench
side; no NEAT-core change needed. Agent tool: recon_flush() -> fresh graph state + what changed.

## 3. Poke-holes (active verify)
Let the NEAT arm challenge NEAT's own claims instead of trusting them. Example: "is CVE-X
really reachable?" -> flush + drive the specific path that would exercise the vulnerable
symbol -> check whether the OBSERVED edge/ reachable-observed materializes, or whether
divergence shows it dark. Surfaces where a static claim (reachable-static) disagrees with
runtime. Agent tool: recon_probe(claim) -> observed verification + the evidence.

## Agent-facing interface (exposed to the NEAT arms over the API harness)
  recon_qa(app)      -> { works: bool, testFailures[], journeyFailures[], newDivergences[] }
  recon_flush()      -> { freshAsOf, changed: graphDiff, divergences[] }
  recon_probe(claim) -> { verdict: observed|unobserved|diverged, evidence }
The bare arm does NOT get these. It gets the raw OTel capture (traces+logs as files) only.

## Build
- per-app journeys/ (one module per target: uptime-kuma, nodegoat, paperless, gitea),
  modeled on e2e/brief/load.ts.
- verifier.ts: generalized assertions.ts (OBSERVED shape + freshness + divergence delta),
  parameterized by service id instead of hard-coded brief-api.
- flush.ts: drive + poll-until-fresh + re-diverge.
- recon-tools.ts: the three tools, wired into the NEAT-arm agent loop.
- Reads NEAT over REST/MCP (graph, divergences, graph-diff). No neat-core edits.

## Depends on
True-neat instrumentation (neat-ba's lane): every route/handler/dep observed on all 4 apps
incl. Gitea Go runtime, and logs fused as log-traces. Recon reads richer as that lands; it
does not block on the full set to scaffold.
