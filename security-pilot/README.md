# NEAT security-remediation bench (pilot)

**Does giving a coding agent NEAT — a live, fused graph of code + runtime + infra, with per-edge provenance — let it fix real CVEs in real apps more cheaply and more completely than the same model working alone?**

This directory is the full, raw pilot that asks that question. Harness, corpus, the independent grader, the Recon QA stack, every per-trial transcript and grade, the agent's own run reports, and the honest limitations — nothing held back.

> ### ⚠️ Read this first: these are **k=1, directional** numbers
> Every result here is a **single run per (app × arm)** — a pilot, not a published benchmark. One run has no variance bars. **Do not cite any number here as "NEAT's benchmark result."** The headline claims hold up directionally and every number is reproducible from the pins below, but the real figure waits on **k=5** and on closing the bench-environment gaps listed under [Open items](#open-items). We publish the pilot raw — wins, confounds, and warts — because that is the only honest way to build this in public.

## What ran

- **3 arms:** `bare-opus` (Opus, no NEAT) · `neat-opus` (Opus + NEAT) · `neat-sonnet` (Sonnet + NEAT, the cost-wedge arm). Same task, same tools, same effort/turn budget — **NEAT is the only variable.**
- **4 real OSS apps**, each checked out at a commit with a real, reachable CVE: **gitea** (Go, `golang.org/x/net`), **uptime-kuma** (Node, `jsonata` RCE), **nodegoat** (Node, 6 advisories incl. a no-fix remove/replace), **paperless-ngx** (Python, `jinja2` sandbox breakout).
- **10 real agent trials** via the Anthropic API (2 paperless+NEAT configs blocked — see Open items). **Total spend: $73.59.**
- **A NEAT-independent grader** (OSV + the ecosystem scanners `npm audit`/`pip-audit`/`govulncheck`, never NEAT's own scanner) on four criteria: *vuln-gone · no-regression · not-degenerate · actually-works*.

## Headline — NEAT's advantage scales with investigation difficulty

This is a **stronger and more honest** claim than "NEAT always wins," and it is exactly the thesis: NEAT replaces *investigation*, which matters most when investigation is hard.

| App | Difficulty | bare Opus | NEAT + Opus | NEAT + Sonnet |
|---|---|---|---|---|
| **gitea** | hard (deep reachability) | PASS · $13.86 · 55 turns | **PASS · $1.56 · 18 turns** | FAIL (never applied) |
| **nodegoat** | hard (6 advisories) | 4/6 · $9.20 · 43 turns | **5/6 · $5.82 · 24 turns** | 5/6 · $1.88 |
| **uptime-kuma** | trivial (1 clean bump) | PASS · $6.49 | overhead · $14.04 | **PASS · $1.95** |
| **paperless-ngx** | 274-dep tree | PASS · $18.70 · 60 turns | *blocked* | *blocked* |

- **Hard work is where NEAT pays off.** On gitea, NEAT+Opus produced the correct fix at **~9× lower cost / 3× fewer turns** than bare Opus — bare burned 55 shell calls exploring; NEAT went to the graph and was surgical. On nodegoat, NEAT fixed **more** (5/6 incl. the hard `swig` remove/replace that bare missed) at **lower** cost, with **zero over-fix** of the non-reachable `forever` foil.
- **On a trivial bump, the graph is overhead** for the big model (kuma: NEAT+Opus $14.04 > bare $6.49) — when `npm audit` already points straight at the dep, there's nothing to investigate.
- **Cheap-model + NEAT is the robust win:** `neat-sonnet` was the cheapest *correct* arm on every app it fixed.

Full per-trial table (all four criteria, tokens, turns, per-phase time, tool-calls, reachable-precision, over-fix, diff shape) is in **[RESULTS.md](RESULTS.md)**.

## What's clean vs. what's limited (no infra failure is dressed up as a fix failure)

- **Clean, un-caveated for every app:** `vuln-gone`, `actually-works`, and cost/turns.
- **`gitea` is the one app with all four criteria real** (Go's `go test` runs cleanly in the bench env).
- **`no-regression` / `not-degenerate` are bench-environment-limited** for kuma/nodegoat/paperless and marked **`UNVERIFIED-<reason>`**, never counted as fix failures: kuma needs a HiveMQ testcontainer that crashes on this box; nodegoat's suite is headless Cypress with no browser stack here; paperless's prod image ships no pytest. These are infrastructure gaps, not fix-quality signals.

## The grader earned its keep

Two grader-correctness bugs were found *during* the run and fixed (both live in `harness/`):
1. **scanner scoping** — `scanGo` matched the CVE id against `govulncheck`'s whole advisory-DB dump instead of its actual *findings*, so it flagged `x/net` even after the fix. Fixing it flipped gitea from a false fail to PASS.
2. **divergence fairness** — the `actually-works` "no new divergence" check was penalizing NEAT for an *ambient* divergence (a webhook sink unrelated to the fix). Scoped it to fix-attributable files. **Verified not-rigged:** the same ambient divergence was dropped for `neat-sonnet` too, and it still correctly fails on `vuln-gone`.

## Reproduce

Every trial is pinned. NEAT daemon = a main build at commit **`eb330c2f382f`** (reports 0.11.0); per trial a fresh checkout at the vulnerable commit, own `NEAT_HOME`, fresh ports. Prices `opus $4/$20`, `sonnet $2/$10` per MTok; `EFFORT=high`, `MAX_TURNS=60`, `k=1`.

```bash
# one app, real API (set ANTHROPIC_API_KEY in your env first)
REAL_APP=gitea \
  BENCH_NEAT_CLI=<path to neat cli.cjs @ eb330c2f> \
  PATH="$HOME/go/bin:$PATH" \
  npx tsx harness/run-app-real.ts
# gitea re-grade from saved artifacts:
npx tsx harness/re-grade-gitea.ts
```

App commits: gitea `829b49c1` (v28.2.0) · uptime-kuma `1f0755fb` (2.5.3) · nodegoat `c5cb68a` · paperless-ngx `e6253caa` (v2.15.3). Corpus ground truth (the CVEs, the reachable set, the precision foils) is in `corpus/`.

## What's here

- `harness/` — the runner, the manual Anthropic tool-use agent loop, the per-trial stand-up/teardown (`standup.ts`), the independent grader (`grader.ts` + `grader-impl.ts`), the re-grader.
- `recon/` — the bench-internal QA stack (`recon_qa` journeys + the attributability divergence gate) that powers `actually-works`.
- `corpus/` — the four apps' pinned commits, CVEs, reachable sets, and precision foils.
- `nodegoat/ uptime-kuma/ gitea/ paperless-ngx/` — the per-app stand-up recipes (instrumented app + OTel + NEAT daemon).
- `runs/` — the real-trial artifacts: per-trial `run.json`, `grade.json`, the independent `scanner-output.json`, the full agent `transcript.json`, test + recon output, and the OBSERVED-layer graph dumps.
- `RESULTS.md` — the full results write-up.
- `AGENT-REPORTS.md` — the autonomous agent's own phase-by-phase run reports (this bench was built and run overnight by an agent; these are its unedited hand-backs).

## Open items

Before any outward/benchmark number:
1. **k=5** for variance.
2. **paperless + NEAT scan perf (core)** — `neat security scan` on 274 deps takes >28 min (per-dep OSV queries); needs an OSV batch path / advisory mirror / daemon-graph-backed scan. This blocked the NEAT arms on the biggest dep tree — exactly where scoping should win most.
3. **Bench-env test infra** — a working HiveMQ image (kuma), a headless browser stack (nodegoat Cypress), in-container pytest (paperless) to make `no-regression`/`not-degenerate` real on those three.
4. **nodegoat `underscore` transitive** — all arms left a transitive `underscore@1.9.1`; full vuln-gone needs transitive resolution (npm overrides).
5. **Task prompt** — on gitea, `neat-sonnet` investigated via NEAT then stopped without applying the fix; the prompt should push "apply, don't just investigate" equally across arms.

_Sanitized for publication: API keys, host IP, and internal infra paths are redacted; the target apps are public OSS. k=1 pilot, 2026-11-10._
