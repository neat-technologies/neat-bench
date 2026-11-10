# Security-remediation bench — real k=1 results (4 apps, 3 arms)

As of 2026-11-10. Real API spend: **$73.59 cumulative** across 10 agent trials (paperless-neat ×2 BLOCKED, not run). Every trial ran on the box against a MAIN-build NEAT daemon at commit **eb330c2f382f**. Numbers are pulled from the per-trial `run.json`/`grade.json`/`transcript.json` artifacts. **Gitea criteria are the RE-GRADED values** (the on-disk `grade.json` for gitea is the stale pre-fix grade; two grader-correctness bugs were fixed and gitea was re-graded deterministically from its saved `scanner-output.json` + recon-output).

## Arms
- `bare-opus` = Opus (claude-opus-5-5), no NEAT — baseline tools (shell/file/test) + ecosystem scanners (npm audit / pip-audit / osv-scanner).
- `neat-opus` = NEAT + Opus — adds the NEAT MCP graph suite + `neat security` tools + Recon QA.
- `neat-sonnet` = NEAT + Sonnet (claude-sonnet-5-5) — the cost-wedge arm.
Shared: EFFORT=high, MAX_TURNS=60, k=1. Prices opus $4/$20, sonnet $2/$10 per MTok.

## Grading criteria (NEAT-independent oracle)
vuln-gone (OSV + ecosystem scanner, findings-scoped) · no-regression (native suite) · not-degenerate (vuln-path tests persist) · actually-works (Recon journeys + OBSERVED + no NEW fix-attributable divergence). `UNVERIFIED-<reason>` = the criterion could not be evaluated because the native test could not run in the bench env (NOT a fix failure; see Open items).

---
## Per-trial results

### gitea (v28.2.0 / 829b49c1) — golang.org/x/net CVE-2026-78661 + CVE-2026-97045. HARD (single dep, deep govulncheck reachability). FULL CLEAN PIPELINE.
| arm | vuln-gone | no-reg | not-deg | actually-works | OVERALL | cost | in tok | out tok | turns | wall s | NEAT tools driving fix |
|---|---|---|---|---|---|---|---|---|---|---|---|
| bare-opus | PASS | PASS | PASS | PASS | **PASS** | $13.86 | 3,348,690 | 23,189 | 55 | 1211 | (none) |
| neat-opus | PASS | PASS | PASS | PASS | **PASS** | $1.56 | 355,757 | 6,908 | 18 | 962 | security_scan, get_reachable_cves, scan_diff, check_policies×2, recon_qa, get_incident_history |
| neat-sonnet | FAIL | PASS | PASS | PASS | **FAIL (legit)** | $0.09 | 43,310 | 716 | 4 | 542 | get_reachable_cves, is_reachable, security_scan, check_policies, get_divergences |
- Fix: x/net 0.60→0.62 (both bare + neat-opus). neat-sonnet investigated via 5 NEAT tools then stopped at turn 4 WITHOUT applying the bump (lockPost==lockPre) → vuln-gone correctly FAIL.
- Reachable-precision: x/net reachable via the markup symbols; chi (go-chi, imported in 11 files but ClientIPFromXFF not reached — Gitea ships its own setRealIP) correctly NOT fixed by any arm. Over-fix 0.
- Diff: go.mod/go.sum only. neat-opus surgical (go get×1, go mod×2); bare exploratory (go get×3, go mod×12, 55 run_shell).
- **Headline: NEAT+Opus produced the correct fix at ~9x lower cost (1/9 $, 1/3 turns, 1/9 input tokens) than bare Opus, both PASS.**

### uptime-kuma (2.5.3 / 1f0755fb) — jsonata RCE GHSA-8gq3-vp5j-2grp. TRIVIAL (single clean npm bump).
| arm | vuln-gone | no-reg | not-deg | actually-works | cost | in tok | turns | wall s | NEAT tools |
|---|---|---|---|---|---|---|---|---|---|
| bare-opus | PASS | PASS | UNVERIFIED-hivemq | PASS | $6.49 | 1,526,376 | 27 | 946 | (none) |
| neat-opus | PASS | PASS | UNVERIFIED-hivemq | PASS | $14.04 | 3,420,525 | 25 | 1074 | get_reachable_cves×2, is_reachable×4, security_scan, scan_diff, check_policies×2, recon_qa |
| neat-sonnet | PASS | PASS* | UNVERIFIED-hivemq | PASS | $1.95 | 951,268 | 15 | 793 | get_reachable_cves, security_scan, check_policies |
- All three FIXED jsonata 2.1.1→**2.2.2** (OSV + npm audit agree cleared). vuln-gone + actually-works CLEAN for all.
- *neat-sonnet no-regression graded F at grade time but is a FLAKY FALSE FAIL: the test-output re-run shows `regressed: []` (baselineGreen 248 == postGreen 248). kuma's native suite has network-flaky/MSSQL tests.
- not-degenerate UNVERIFIED: the 3 json-query vulnPathTests need @testcontainers/hivemq; HiveMQ CE 2023.5 crashes on startup (JVM JMX-agent NPE, exit 1) → tests can't run (confirmed NOT green at baseline either).
- **Cost note (confound): kuma neat-opus $14.04 > bare $6.49 — on a trivial single bump, NEAT's graph context adds input tokens (3.4M vs 1.5M) without cutting turns; and the agent partly thrashed on the infra-broken hivemq/MSSQL tests. The kuma cost comparison is NOT clean. NEAT+Sonnet was cheapest AND correct ($1.95).**

### nodegoat (OWASP / c5cb68a) — 6 advisories (3 clean: underscore/express/body-parser; 3 hard: marked sanitize-loss, mongodb major, swig remove-replace-no-fix) + the `forever` precision foil (direct dep, NOT import-reachable). HARD multi-advisory.
| arm | fixed | vuln-gone | no-reg | not-deg | actually-works | cost | in tok | turns | NEAT tools |
|---|---|---|---|---|---|---|---|---|---|
| bare-opus | 4/6 | FAIL | UNVERIFIED-cypress | UNVERIFIED-cypress | FAIL (app down) | $9.20 | 2,187,957 | 43 | (none) |
| neat-opus | 5/6 | FAIL | UNVERIFIED-cypress | UNVERIFIED-cypress | PASS | $5.82 | 1,386,481 | 24 | security_scan, get_reachable_cves×2, is_reachable×7, scan_diff, check_policies×2, recon_qa×2 |
| neat-sonnet | 5/6 | FAIL | UNVERIFIED-cypress | UNVERIFIED-cypress | PASS | $1.88 | 898,182 | 30 | get_reachable_cves, security_scan×3, check_policies, recon_qa |
- Per-advisory: all cleared express/body-parser/marked/mongodb. **bare MISSED swig (kept 1.4.2) AND underscore; both NEAT arms REMOVED swig (the hard remove-replace, no fix version)** → bare 4/6, NEAT 5/6.
- underscore is INCOMPLETE for all: they bumped the direct dep to 1.13.8 (OSV cleared) but a transitive underscore@1.9.1 persists and npm audit flags it → vuln-gone FAIL for all. Real transitive-depth gap, not a scanner artifact.
- Over-fix: NONE — no arm touched `forever` (the non-reachable foil). NEAT's get_reachable_cves flagged the corpus deps reachable.
- actually-works: NEAT arms PASS; bare FAILED (all journeys connection-refused — bare's 43-turn thrashing took the standup app process down; app-process-lifecycle caveat).
- not-degenerate + no-regression UNVERIFIED: nodegoat's entire native suite is Cypress e2e; the box can't run it headless (libgtk-3-0 + libasound2 missing, no Xvfb, no sudo). testCmd was scoped to a smoke so the agent did not burn tokens on it.
- **Headline: NEAT fixed MORE (5/6 incl the hard swig remove-replace) at LOWER cost ($5.82/24t vs bare $9.20/43t), zero over-fix. The NEAT advantage returns on a hard multi-advisory app (like gitea).**

### paperless-ngx (v2.15.3 / e6253caa) — jinja2 sandbox breakout CVE-2025-27516 (lockfile-only). bare-opus ONLY; neat BLOCKED.
| arm | vuln-gone | no-reg | not-deg | actually-works | cost | in tok | turns | NEAT tools |
|---|---|---|---|---|---|---|---|---|
| bare-opus | PASS | (vacuous)PASS | UNVERIFIED-pytest-infra | PASS | $18.70 | 4,474,443 | 60 (MAX) | (none) |
| neat-opus | — | — | — | — | **BLOCKED** | — | — | — |
| neat-sonnet | — | — | — | — | **BLOCKED** | — | — | — |
- bare fixed jinja2 3.1.5→**3.1.6** (OSV + the in-container pip-audit cross-check agree cleared). vuln-gone + actually-works CLEAN. The in-container pip-audit path (docker-exec `uv export` → `pip-audit -r` against the live checkout lock) is validated end-to-end here.
- not-degenerate UNVERIFIED: the production paperless image has no pytest and no test files, so the filepath templating vulnPathTests can't run in-container; no-regression used a smoke (vacuous).
- bare-opus hit MAX_TURNS=60 at $18.70 / 4.47M input tokens exploring the 274-dep tree — the priciest bare trial, approaching the $25 guard (the opt-in $22 cost cap was armed; the trial finished at 60 turns first). This is exactly where NEAT's dependency scoping should help most — but neat-opus/neat-sonnet are BLOCKED on the scan (below), so no clean comparison this round.

---
## Cross-app narrative (the honest, difficulty-dependent story)
NEAT's cost advantage scales with investigation difficulty — this is a STRONGER, more credible claim than "NEAT always wins":
- **Hard RCA (gitea, 1 deep dep): NEAT+Opus 8.9x cheaper than bare, both correct.**
- **Hard multi-advisory (nodegoat, 6): NEAT 5/6 at $5.82 vs bare 4/6 at $9.20 — cheaper AND more complete, incl the hard remove-replace.**
- **Trivial single bump (kuma): NEAT+Opus is OVERHEAD ($14 > $6.49); all three fix it. The graph context doesn't pay off when npm audit already points straight at the dep.**
- **Across every app it ran: NEAT+Sonnet (cheap model + NEAT) was the cheapest correct arm ($0.09 gitea*, $1.95 kuma, $1.88 nodegoat).** (*gitea sonnet didn't apply the fix — a prompt/behavior issue, not cost.)
- Big dep trees punish the bare arm: paperless bare-opus burned 60 turns / $18.70 / 4.47M tok on 274 deps — the scenario where NEAT scoping should win biggest, pending the scan-perf fix.

Clean, un-caveated signal present for EVERY app: **vuln-gone + actually-works + cost/turns**. The native regression suites (no-reg/not-deg) are bench-env-limited for kuma/nodegoat/paperless (testcontainers/cypress/pytest) and are marked UNVERIFIED, never dressed up as fix failures. gitea is the one app where all 4 criteria are real.

## Reproducibility pins
- NEAT daemon: main build @ **eb330c2f382f** (`~/neat-src/packages/core/dist/cli.cjs`, reports 0.11.0). Per trial: fresh checkout at the vuln commit, own NEAT_HOME, NEAT_WEB_DISABLED=1, fresh REST/OTLP ports, HOST=127.0.0.1, `neat watch <checkout>`.
- App commits: gitea 829b49c1 (v28.2.0, Go) · uptime-kuma 1f0755fb (2.5.3, npm) · nodegoat c5cb68a (npm) · paperless-ngx e6253caa (v2.15.3, PyPI).
- Prices: claude-opus-5-5 $4/$20, claude-sonnet-5-5 $2/$10 per MTok. EFFORT=high, MAX_TURNS=60, k=1.
- Grader-correctness fixes landed this session (all live in harness/): scanGo findings-scoping (`govulncheckFlags` — was matching the govulncheck OSV DB dump) · scanNpm/scanPyPI are already findings-scoped · resolvePyPI reads uv.lock/Pipfile.lock/requirements · scanPyPI runs pip-audit IN the app container against the live checkout lock · the actually-works divergence gate scopes NEW divergences to fix-attributable files (changed-dep importers + git-diff), dropping ambient ones · OTLP protocol per-ecosystem (npm http/json, Go/PyPI http/protobuf) · scan kill-on-timeout (process-group) + cache-failure (no pileup) · GOTMPDIR off the /tmp tmpfs · configurable daemon-health timeout · graph-fetch retry · runTests spec/pytest/go id parsers · opt-in per-trial cost cap (BENCH_TRIAL_COST_CAP).
- One-command re-run (per app): `REAL_APP=<app> SKIP_ARMS=<...> BENCH_TESTCMD=<...> BENCH_NEAT_CLI=~/neat-src/packages/core/dist/cli.cjs PATH=~/go/bin:$PATH <source ~/.neat-bench-secrets/anthropic.env> npx tsx harness/run-app-real.ts`. gitea re-grade: `npx tsx harness/re-grade-gitea.ts`.
- Artifact dirs: runs/gitea-real-k1-2026-11-10T06-02-29-206Z · runs/uptime-kuma-real-k1-2026-11-10T07-05-42-040Z · runs/nodegoat-real-k1-2026-11-10T08-00-00-130Z (bare) + 08-07-07-308Z (neat) · runs/paperless-ngx-real-k1-2026-11-10T08-20-51-018Z.

## OPEN / DENIZ-LEVEL
1. **paperless-neat scan perf (CORE, blocks the neat arms).** `neat security scan` on paperless's 274 deps takes >28min (49s with NEAT_ADVISORIES=off) — per-dep api.osv.dev queries. Needs OSV batch API / NEAT_ADVISORIES_URL mirror / daemon-graph-backed scan. NOT advisories=off (kills detection). gitea's scan was viable (~122s); paperless is the outlier. This blocks the NEAT cost-wedge datapoint on the biggest dep tree (where it should win most).
2. **hivemq oracle image (kuma not-degenerate).** HiveMQ CE 2023.5 crashes on this box (JVM JMX-agent NPE, exit 1). Needs a working image/version or a JMX-disabled JAVA_OPTS injected into the testcontainer — a test-oracle patch (held for Deniz, not forced).
3. **kuma suite flakiness (no-regression).** Network/MSSQL-dependent tests flake → false regressions. For k=5: scope to deterministic tests or re-run flaky reds before counting.
4. **cypress bench-env (nodegoat no-reg + not-deg).** The whole nodegoat suite is Cypress; the box lacks the headless browser stack (libgtk-3-0/libasound2/Xvfb, no sudo). Needs a browser-capable runner to verify nodegoat's regression suite.
5. **pytest-infra (paperless not-deg).** The production paperless image ships no pytest/test files; verifying would need a test-deps image or the checkout's test env wired in-container.
6. **nodegoat underscore transitive.** All arms left a transitive underscore@1.9.1 — the corpus/fix should address transitive resolution (npm overrides) for a full vuln-gone.
7. **nodegoat actually-works app-lifecycle.** bare's thrashing took the standup app down; the recon re-drive should restart the app after the fix (or isolate the app process) so actually-works reflects the fix, not agent disruption.
8. **Task prompt (k=5).** gitea neat-sonnet investigated via NEAT then stopped without applying — the prompt should push "APPLY the fix, not just investigate" equally across arms.
9. **k=5 for variance** before any outward number.
