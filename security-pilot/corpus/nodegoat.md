# Corpus item: NodeGoat (candidate, hand-verify before locking)

repo: github.com/OWASP/NodeGoat
commit: c5cb68a7084e4ae7dcc60e6a98768720a81841e8  (2023-06-21, lockfileVersion 2, 1479 pkgs)
ecosystem: npm
first-party imports: CommonJS only; 15 third-party pkgs imported by server.js/config/app.

## Reachable (first-party-imported) advisories — 6 deps, 15 advisories
| dep | installed | advisory(s) | fixedIn | fixKind | importers |
|-----|-----------|-------------|---------|---------|-----------|
| mongodb | 2.2.36 | GHSA-mh5c-679w-hh4r (DoS, no CVE alias) | 3.1.13 | MAJOR-BREAKING (2.x->3.x driver; connect cb + 7 DAOs) | server.js:11,30 + app/data/*-dao.js |
| marked | 0.3.5 | CVE-2022-21680, CVE-2022-21681 (ReDoS) + 4 older | 4.0.10 (ReDoS); 0.3.x only for the 4 older | MAJOR-BREAKING (v4 removes `sanitize`, needs ext sanitizer) | server.js:13,126 |
| swig | 1.4.2 | CVE-2023-25345 (arb file read) | NONE (abandoned, latest=1.4.2) | REMOVE/REPLACE (swig-templates/nunjucks + consolidate adapter) | server.js:8,9,116,135 |
| express | 4.16.4 | CVE-2024-29041, CVE-2024-43796 | 4.20.0 | CLEAN-BUMP -> 4.21.2 | server.js:3, app/routes/tutorial.js:1 |
| body-parser | 1.18.3 | CVE-2024-45590 + 2 | 1.20.9 | CLEAN-BUMP -> 1.20.9 | server.js:5 |
| underscore | 1.9.1 | CVE-2021-23358 (CRITICAL ACE), CVE-2026-27601 | 1.13.8 | CLEAN-BUMP -> 1.13.8 | config/config.js:1 |

Clean/hard split: **3 clean (express, body-parser, underscore) / 3 hard (mongodb, marked, swig)** = meets the >=half-not-clean-bump requirement.
audit-noise: ~157 of ~172 CVEs (~90%) in transitive/dev/unused (grunt*, cypress, selenium, mocha, forever tree). `forever`@2.0.0 is a DIRECT prod dep but NOT import-reachable (Procfile binary) -> encodes "direct != reachable".

## ISSUE 1 — regression oracle is NOT `npm test`
`npm test` -> grunt globs test/unit/*.js which DOES NOT EXIST -> zero tests, no-op pass. Useless as the gate.
Real oracle = the Cypress e2e suite (test/e2e/integration/, 15 specs; `npm run test:ci`), needs the app running + MongoDB. The grader's no-regression + not-degenerate for NodeGoat must run the Cypress suite, not npm test. vulnPathTests = the Cypress specs that exercise the vuln paths (hand-map before locking).

## ISSUE 2 — toolchain + instrumentation tension (resolve at bring-up)
Reproducing green needs the pinned toolchain: Node 14 + mongo:4.0 (mongodb 2.x native addons bson/kerberos fail to build on modern Node). But NEAT otel-node + the box run Node 20, and otel-node's OTel SDK likely needs Node >=16/18. So NodeGoat-at-this-commit may not run instrumented on Node 20.
-> Bring-up must find a Node (16/18?) where the app's native addons build AND otel-node attaches, or rebuild addons. neat-ba (per-app verification) + harness own this. If unresolvable at this commit, pick a slightly newer NodeGoat commit whose deps build on a supported Node.

## ISSUE 3 — mongodb fix-target <-> instrumentation coverage (flagged to neat-ba)
Vulnerable = mongodb 2.2.36 (needs the mongodb-2.x instrumentation neat-ba is building). Fix target 3.1.13 is <3.3, and the bundled mongodb instrumentation only covers >=3.3 -> post-fix DB would be DARK, breaking the "actually works" observed check. So either the fix target must be >=3.3 (e.g. 3.7.4) so bundled covers post-fix, or neat-ba's mongodb instrumentation spans 2.x + 3.x-below-3.3. Encode the instrumentable fix target in the ground truth.

## RESOLUTIONS (neat-ba, 2026-11-09)
- Issue 3 (mongodb): Option 1 LOCKED. Keep the honest fixedIn 3.1.13 as the ground-truth fix target. neat-ba's instrumentation hooks mongodb-core (separate pkg for 2.x + 3.0-3.2, same command/cursor shape), so pre-fix 2.2.36 AND post-fix 3.1.13 are both observed; the bundle covers >=3.3. Tested against both.
- Issue 2 (toolchain): otel-node needs Node >=20, so NodeGoat can't run on Node 14 with the attachment. But NodeGoat's native bits are optional (bcrypt-nodejs pure JS; mongodb 2.2 kerberos/bson-ext optional), so it should run on Node 20 against mongo:4.0. neat-ba verifies at bring-up and flags if it bites.
- Issue 1 (oracle = Cypress e2e, not npm test): stands; mine to wire.

Evidence (ephemeral, this session): scratchpad/nodegoat-clone @ pinned sha, scratchpad/osv/*.json.
