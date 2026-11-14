# Bench scope decisions

Deliberate scope choices that affect the citable number. Each is a uniform rule applied to every arm,
recorded so the number is defensible and reproducible.

## Production audit scope (2026-11-13)

**Decision.** The ecosystem scanners audit production dependencies only. For npm this is the standard
`npm audit --omit=dev` (grader-impl.ts `scanNpm`). pip-audit and govulncheck audit the resolved
production build by construction.

**Rationale.** The bench grades the security posture of what an app ships. A vulnerability confined to
dev-only tooling (build/test deps) and its transitive closure never enters the deployed artifact, so it
is outside the scope of a production vulnerability gate. Example that forced the decision: OWASP NodeGoat
pins `underscore@1.9.1` as a direct production dependency (the corpus target, `GHSA-cf4h-3jhx-xvhq`) and
also carries `underscore@1.8.3` nested under `grunt-retire`, a devDependency. An agent that correctly
remediates the production dependency still trips a whole-tree audit on the dev-only copy.

**Why this is not grader-gaming.**
- It is a uniform, ecosystem-standard rule (`--omit=dev` is npm's own flag), applied identically to
  every arm. `gradeTrial(item, treePath, recon, { preFlagged })` takes no arm, so the grade is
  arm-agnostic by construction: bare-opus is held to the exact same scope as the NEAT arms.
- The prod/dev split is npm's classification of the lockfile, not any scanner's or product's findings.
  The oracle stays independent of the thing under test.
- Every corpus advisory targets a production dependency, so no corpus target is dropped. The rule only
  removes dev-only noise.

**Effect on the number.** This can move a trial from FAIL toward PASS when the only residual is a
dev-only advisory (e.g. NodeGoat). It is a measurement-validity correction, not a difficulty reduction:
the production advisories still must be cleared, with no regression and no degenerate removal.

## Baseline-compared feature and liveness checks (2026-11-14)

**Decision.** `not-degenerate` and `actually-works` only attribute a failure to the fix when the same
check was healthy before the fix.

- `not-degenerate`: a vuln-path test guards the feature only if it was green at baseline. Green before
  and failing after is FAIL. A vuln-path test with no green baseline in this environment (container-gated,
  absent) cannot be guarded and reads UNVERIFIED, never FAIL.
- `actually-works`: journeys are driven once before the agent runs. A journey that worked at baseline and
  fails after is FAIL. Journeys that already failed at baseline (the app never came up here) read
  UNVERIFIED.

**Rationale.** Both criteria ask "did the fix break something". That question has no answer for a check
that was already red. Scoring a pre-existing failure against the fix produced false FAILs: uptime-kuma's
MQTT vuln-path tests need a HiveMQ testcontainer that did not start, and NodeGoat did not boot on a
saturated host, for the bare arm as well as the NEAT arms.

**Why this is not grader-gaming.** The rule is arm-agnostic (same baseline probe, same comparison for
every arm) and it only ever moves a verdict from FAIL to UNVERIFIED, never to PASS. UNVERIFIED trials are
counted out of the headline. A real break (green before, red after) still fails.

**Corpus consequence.** uptime-kuma's jsonata advisory gains two container-free vuln-path tests
(`test-globalping.js`, "should handle JSON query check (valid|invalid)") that reach
`evaluateJsonQuery() -> jsonata().evaluate()`, so the feature is guarded even when HiveMQ is down.

## Run hygiene (2026-11-14)

- **One NEAT build per run.** `runMatrix` refuses to start a NEAT arm unless `BENCH_NEAT_CLI` and
  `NEAT_BIN` are both set and name the same build. An unset `NEAT_BIN` used to fall back to the global
  `neat`, so the security tools and the daemon could be different versions without any signal.
- **One artifact directory per rep.** Seed 0 writes `<arm>/<app>`, later seeds `<arm>/<app>-s<seed>`.
- **Verify-before-done gate.** When an agent stops, the loop re-drives the app's journeys and re-runs its
  suite, baseline-compared as above; a break introduced by the fix is handed back (bounded by
  `BENCH_MAX_VERIFY_REJECTS`). It applies to every arm and uses the app's own checks, not the corpus
  vuln-path list.

## Test-broker image on newer kernels (2026-11-14)

uptime-kuma's MQTT tests start `hivemq/hivemq-ce:2023.5` through testcontainers. That image ships
Java 11, whose cgroup v2 reader throws a NullPointerException on recent kernels (seen on 7.0), so the
broker exits before any test connects and every MQTT test, including the three json-query guards on
the jsonata path, reads as failing at baseline.

A bench host on such a kernel builds `uptime-kuma/hivemq-shim/Dockerfile` and tags it
`hivemq/hivemq-ce:2023.5`, keeping the original as `:2023.5-upstream`. The shim is the same broker
with `JAVA_TOOL_OPTIONS=-XX:-UseContainerSupport`. Nothing in the app or its tests changes, and the
shim applies to every arm equally. With it, all 19 tests in `test-mqtt.js` are green at the pinned
commit, so `not-degenerate` can resolve to PASS or FAIL for this target.

## Recipes carry no credential literals (2026-11-14)

A recipe reads a seeded test login from the app's own seed file, and generates any throwaway
instance secret per trial. A placeholder in a recipe breaks standup (paperless) or silently thins
the warm-up traffic (nodegoat login), so neither is left as a literal.

## `actually-works` is arm-agnostic and reads nothing from NEAT (2026-11-14)

**Decision.** The `actually-works` verdict rests on two things only: the patched checkout rebuilds and
restarts, and every journey answers as it did at baseline. NEAT's own post-fix signals (new
declared-vs-observed divergences, OBSERVED still materializing) are recorded next to the verdict and
are available to the agent through `recon_qa`, but they do not decide it.

**Rationale.** Those signals exist only for the NEAT arms. Grading on them held the NEAT arms to a
check the bare arm never faces, and put NEAT inside its own oracle, against the rule that the grader
is NEAT-independent. They also varied with how much traffic the baseline happened to see: a NodeGoat
trial failed on two "new" divergences that were ordinary signed-in database calls the baseline had
not exercised.

**Journeys are compared, not just pinged.** Each journey's answer (status, plus a digest where the
body is deterministic) is captured before the agent runs. A journey that gave one stable answer at
baseline and answers differently after the fix is a failure. Redirects are not followed. Each app has
at least one journey on its signed-in or vulnerable path where the app allows it (NodeGoat signed-in
walk, paperless storage-path template render, gitea untrusted-markup render).
