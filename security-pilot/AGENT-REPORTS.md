# Agent run reports

This bench was built and run **autonomously by a coding agent overnight** (2026-11-10), supervised by an orchestrator that watched the box on a timer, caught problems, and gated the real spend. The sections below are the agent's own phase-by-phase hand-back reports, reproduced verbatim except for sanitization (API key, host IP, and `/home/<user>` paths redacted to `$HOME`). They are the unedited record — including the bugs it hit, the confounds it flagged, and the things it refused to fudge.

This is "show your work" for an agentic bench: nothing in here was cleaned up after the fact.

---

## Phase 1 — FreshProvisioner + first dry stand-up (no API spend)

Built `harness/standup.ts`: per-trial fresh loopback ports (OS-assigned), a per-run `NEAT_HOME` and sibling work dir holding pid files + logs, dispatched per-app to `<app>-fresh.sh` recipes. NEAT arm starts a main-build `neat watch` daemon on the checkout; bare arm starts a plain `otelcol-contrib` (OTLP receiver → file exporter) and hands the capture over. Teardown kills by PID file and `docker rm -f`; no `pkill -f`.

Dry stand-up on nodegoat against the `eb330c2` main-build daemon (stub agent, **no API spend**): NEAT arm 168 nodes / 207 edges, **31 OBSERVED edges**, 12 divergences; bare arm captured 89,895 bytes of traces. Teardown clean, the five pre-existing instrumentation daemons untouched.

OBSERVE-VERIFY at `eb330c2` confirmed the two ingest ADRs live in the graph: DB nodes keyed `database:<engine>:<host>` (distinct `database:mongodb:mongo` + `database:mongodb:127.0.0.1`, OBSERVED `CONNECTS_TO`), and observed-first templated routes (`route:nodegoat GET /allocations/:userId`, not the raw `/allocations/2`).

---

## Phase 2 — Pre-matrix validation gate (12-config smoke, no API spend)

**10/12 configs GRADEABLE, 2 BLOCKED** (paperless + NEAT), all with a diagnosed cause. Bugs found and fixed this phase, beyond the planned tasks:

- **OTLP protocol per-ecosystem** — `standup.ts` hard-coded `http/json`, but gitea's Go `otelc` exporter only speaks `grpc`/`http/protobuf` (`app.log: invalid OTLP protocol`). This was the gitea **0-OBSERVED** root cause. Fixed to per-ecosystem (npm→http/json, Go/PyPI→http/protobuf) → gitea went from 0 to 69 OBSERVED edges with Go DB symbol-grain fusion.
- **`/tmp` ENOSPC** — `otelc` runs `go build -work` which keeps ~1.5G work dirs; several leaked into the 15G tmpfs → linker ENOSPC. Fixed with a per-trial `GOTMPDIR` on the big disk.
- **`neat security scan` pileup** — the tool's exec timeout didn't kill the scan (survived SIGTERM) and the cache deleted on reject, so each retry relaunched → three overlapping scans eroding RAM. Fixed: `run()` spawns detached and SIGKILLs the whole process group on timeout; cache keeps the result.
- Daemon `/health` timeout too short for large repos (gitea extracts 22k nodes); graph-fetch ECONNRESET retry during re-extraction; `runTests` spec/pytest/go id parsers.

Paperless DB fusion verified (distinct `database:postgresql` + `database:redis`, 102 Python symbol-grain OBSERVED edges). uptime-kuma socket.io event-grain confirmed (`infra:socket.io-topic:/#info …`).

---

## Phase 3 — gitea real k=1 + a grader bug caught on the first grade

First real grade (`bare-opus/gitea`) came back `vuln-gone=false` with `x/net@0.62.0 still flagged (osvAffected=false, scanner=true)` — OSV said fixed, `govulncheck` disagreed. Diagnosis from the saved raw `govulncheck -json`: the stream carries 391 OSV-DB entries plus only 8 real findings; the corpus advisories (`GO-2026-6860/6866`) are **not** among the findings — they were cleared at 0.62.0. The old `scanGo` matched the corpus id against the **DB dump**, so it always flagged. **The agent's fix was correct; the grader was wrong.**

Fix (`grader-impl.ts`, benefits every Go app): `scanGo` now matches the corpus advisory only against `"finding"` messages, expanded through each finding's OSV aliases. Re-graded offline from the saved `scanner-output.json` (deterministic).

---

## Phase 4 — gitea clean headline (fairness bug fixed, verified not-rigged)

Second grader bug, this one a fairness bug on `actually-works`: `neat-opus` scored false on a webhook `Deliver` "observed-failing" divergence — but the agent only bumped `x/net` and never touched `services/webhook/deliver.go`, which isn't an `x/net` importer. An x/net patch can't make webhook delivery fail; it was an ambient dead-sink during the observed window. Fixed the gate (`recon-tools.ts` + `trial.ts`): a new divergence counts against `actually-works` only if it references a changed-dep importer or a file the agent actually edited.

**Not rigged:** the same ambient divergence was dropped for `neat-sonnet` too, and `neat-sonnet` still correctly FAILS (on `vuln-gone`, because it never applied the edit). The gate removes false positives only.

Clean gitea grades: `bare-opus` PASS (all 4, $13.86/55t) · `neat-opus` PASS (all 4, $1.56/18t) · `neat-sonnet` FAIL legit ($0.09/4t, investigated via 5 NEAT tools, stopped at turn 4 without applying). **NEAT+Opus: the correct fix at ~9× lower cost.**

---

## Phase 5 — uptime-kuma real k=1

All three arms fixed `jsonata 2.1.1 → 2.2.2` correctly. `vuln-gone` + `no-regression` + `actually-works` PASS for all; `not-degenerate` = **UNVERIFIED-hivemq** (HiveMQ CE 2023.5 crashes on startup with a JVM JMX-agent NPE, exits before the testcontainer is ready — image/JDK incompatibility; **not patched**, that would alter the oracle). One `neat-sonnet` no-regression red was a flaky network test (re-run clean, baseline 248 == post 248).

Cost (easy bump): `bare-opus` $6.49/27t · `neat-opus` $14.04/25t (the graph context is **overhead** on a trivial bump) · `neat-sonnet` $1.95/15t (cheapest + correct). Honest read: NEAT's cost advantage is **difficulty-dependent**.

---

## Phase 6 — nodegoat real k=1 (the strongest thesis datapoint)

Per-advisory (6 advisories): all arms cleared express/body-parser/marked/mongodb. **bare missed `swig` (the remove/replace, no fix version) and `underscore`; both NEAT arms removed `swig`** → bare **4/6**, NEAT **5/6**. `underscore` left a transitive `@1.9.1` for all arms (real incomplete fix, needs npm overrides). **Over-fix: none** — no arm touched the direct-but-not-reachable `forever` foil.

Cost: `bare-opus` $9.20/43t/4-of-6 · `neat-opus` **$5.82/24t/5-of-6** (cheaper, fewer turns, fixed more) · `neat-sonnet` $1.88/30t/5-of-6. `actually-works`: NEAT PASS; bare FAIL — bare's 43-turn thrashing took the stand-up app process down (app-lifecycle caveat, noted, not treated as pure fix-quality). `no-regression`/`not-degenerate` = **UNVERIFIED-cypress** (the box can't run the headless e2e suite).

---

## Phase 7 — paperless real k=1 + final results compilation

`bare-opus` fixed `jinja2 3.1.5 → 3.1.6`; `vuln-gone` PASS (OSV + an in-container `pip-audit` cross-check agree) and `actually-works` PASS. `not-degenerate` = **UNVERIFIED-pytest-infra** (the production image ships no pytest/tests). $18.70 / 60 turns / 4.47M input tokens on the 274-dep tree — the priciest bare trial, and exactly where NEAT's dependency scoping should help most — but the NEAT arms are **blocked** on the scan-perf issue.

Compiled `RESULTS.md`. Final cumulative real spend **$73.59** across 10 trials (2 blocked). Box left clean; the pre-existing instrumentation daemons intact.

---

_Sanitized for publication. The orchestrator's prompts and the full raw transcripts are alongside this file (`runs/*/transcript.json`). k=1 pilot — directional, see the README's warning._
