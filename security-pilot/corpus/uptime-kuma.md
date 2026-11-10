# Corpus item: uptime-kuma (candidate, hand-verify before locking)

PICK: Rank 1 — jsonata RCE at tag 2.5.3 (critical, genuinely reachable, clean bump, real 0-regression proof).

repo: github.com/louislam/uptime-kuma
commit: 1f0755fb044fe08e99fccde6722062fb2bf6c8f4  (tag 2.5.3, 2026-08-22)
ecosystem: npm
testCmd: node test/test-backend.mjs (node --test) + playwright (test-e2e). Hand-map the jsonPath-monitor test for the not-degenerate guard.

## Reachable advisory
dep: jsonata, installed 2.1.1 (manifest ~2.1.0), fixedIn 2.2.1, fixKind: BUMP (minor, same major).
advisories (all affect 2.1.1):
- CVE-2026-77413 / GHSA-8gq3-vp5j-2grp — CRITICAL RCE (fixedIn 2.2.0)
- CVE-2026-77414 / GHSA-2943-5xfg-gq5f — CRITICAL RCE (2.2.1)
- CVE-2026-77415 / GHSA-66mm-25pp-rfff — CRITICAL RCE (2.2.1)
- CVE-2026-52746 / GHSA-86vw-mfpg-wwv9 — HIGH DoS $toMillis (2.2.0)
- CVE-2026-12208 / GHSA-663r-x48j-fg8p — MODERATE proto-pollution (2.2.1)
importers (verified at 2.5.3):
- server/monitor-types/mqtt.js:4 require("jsonata"); used :79, :106 jsonata(monitor.jsonPath)
- server/monitor-types/mongodb.js:4 require("jsonata"); used :27 jsonata(monitor.jsonPath)
vulnPath: a user-configured monitor with a jsonPath -> jsonata(jsonPath) compiled+evaluated -> direct RCE reach (attacker-controlled input).
fix target: jsonata 2.2.1 (clean bump; ~2.1.0 -> ~2.2.x in package.json + lockfile).
0-regression ground truth: project shipped jsonata 2.2.2 in 2.5.4 (sha ed828eac9f5c7d46328f957854ad08545306b868) -> strong proof the bump is non-breaking.

## audit-noise at 2.5.3
~47 flagged packages (~9 reachable-prod, ~23 prod-vuln, ~24 dev/transitive). jsonata is 1 of ~47 -> heavy noise, good negative-control (bare over-fixes the tree, NEAT scopes to the reachable RCE).

## NOTE on commit vs instrumentation-validation
The TRIAL checks out at 2.5.3 (the vulnerable commit). The OBSERVED-pipeline validation I ran earlier is at 2.5.9 (same express + socket.io instrumentation path, #1597). Re-run the daemon/attach at 2.5.3 for the trial. The fix (jsonata 2.1.1->2.2.1) is in-process JS, no DB/runtime shape change, so OBSERVED is unaffected pre/post.

## backups (if we want a second uptime-kuma item later)
form-data CRLF @2.4.0 (lockfile-only patch bump, but low true-reach: field name is literal "data") — good "imported-but-low-reach" case.
mysql2 @2.5.9 (heaviest DB reachability, live on the version we run, but large bump + no project-adoption 0-regression proof).

Evidence (ephemeral): scratchpad/locks/*.json, osv_details.json; durable join at tool-results/bfnf80cr3.txt.
