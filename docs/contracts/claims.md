---
name: Claims and evidence
description: What may be claimed from which evidence. No confounded or unreproducible number leaves this repo.
governs:
  - "README.md"
  - "RESULTS.md"
  - "results.md"
  - "*/results.md"
  - "*/RESULT.md"
  - "*/summary.md"
  - "docs/*"
  - "bench/results/*"
  - "bench/docs/*"
status: Accepted
---

# Claims and evidence

Status: **Accepted** (Deniz, 2026-10-16) for rules 1 to 13. The rules below are the ones the 15 October 2026 evidence audit showed we were breaking, plus the headline-framing rules the 16 October research pass settled (ADR-004, ADR-005). The decisions still open are listed at the bottom; until they are ruled, the stricter reading applies.

## The rule

A number leaves this repo only when every clause below holds for that number. If a clause cannot be met, the number is not published. "Not yet" is an acceptable result. A confounded number is worse than no number.

1. **Grader validity.** The number was produced by a grader that passes the negative-control suite (wrong cause, negated cause, "unknown", wrong service, candidate list, plausible-but-wrong patch) at the version used for that run, and the no-fault control false-positive rate and the trivial-agent score for that run are published beside it. A keyword-presence grader is never a headline grader. See the scoring contract.
2. **Cost is a NEAT effect only when the model is held fixed.** A cost comparison across models (Sonnet+NEAT vs Opus+obscode, the September design) is a configuration comparison, and the accuracy of both sides is stated in the same sentence as the cost ratio. Token totals are reported next to dollar totals; "cheaper" never implies "fewer tokens". The cost figure that may stand alone is cost per *successful* resolution at equal-or-better RESOLVED, same model, same turn cap.
3. **No speed claim without wall-clock.** A speed or "faster" claim cites per-run `wall_s` from the committed TSV of the exact runs, states what the clock includes (install, warm-up, timeouts, failures), and separates time-to-answer from time-to-verified-fix.
4. **Metrics are never collapsed.** RCI (right service) is not "correct diagnosis". CAUGHT, RESOLVED and ROBUST are reported separately and are never summed into one "solved" rate. A mixed total, if shown at all, is labelled as mixed.
5. **An agent result is never attributed to a query.** "An agent using NEAT caught 25/26" is not "`neat divergences` detects 96%". The raw-query hit rate is reported beside the agent rate whenever either is cited.
6. **Reproducible from a committed record.** Every published total reproduces from a committed TSV by the documented procedure. Regrades, exclusions and manual adjustments live in the TSV as rows or a `regrade_reason` column, never only in narrative. A narrative total that does not reproduce is removed.
7. **k is stated with the number.** A k=1 result carries "k=1, preliminary" in the same line. The headline requires k=5 (ADR-004); a k=3 figure is development only.
8. **Developed-against is stated with the number.** Every number names whether the target was developed against or held out. A score on a developed-against target is an upper bound and is labelled as one.
9. **Stale sections are deleted.** When a result is corrected, the old figure is removed or the section is version-labelled. Two different numbers for the same result never coexist unlabelled.
10. **Controls are the same model with the same evidence.** The baseline for a NEAT effect is the same model with source plus raw runtime and deployment evidence (`obscode`) under the same budget and permissions, not source alone. A source-only arm (`code`) is reported as a weaker control, never as the baseline.
11. **The headline is a paired RESOLVED difference with its interval.** The form is: n scenarios, k runs, same model snapshot, scaffold and cap; NEAT arm minus baseline arm in points; the 95% interval of the per-scenario differences clustered by scenario; pass^k for both arms; the no-fault false-positive rate. A point without an interval is not a result. pass@1 and pass^k are both shown; neither substitutes for the other.
12. **Framings that are never used.** A ratio without its denominators and accuracies ("3.3x cheaper", "96% detection"). A comparison against a crippled arm presented as "without NEAT". A mixed-condition comparison (different subsets, different caps, faulted versus pristine trees per arm, the best of several NEAT configurations). A detection rate as the headline when a RESOLVED rate exists.
13. **Nulls are reported.** Scenario classes pre-declared as ones where runtime context cannot matter are reported with their (expected) null result. A null where one is expected is evidence the instrument works and is not removed to improve an aggregate.

## Why

Each clause maps to a finding the audit reproduced from this repo or to a reviewer attack the research pass documented: a grader that accepted answers denying the true cause (1); a 3.3x headline that compared different models at different accuracy (2); the homepage's "17% faster" with no derivation anywhere in this repo and no durations ever recorded (3); a 100% RCI shown next to a mixed 35/45 (4); a 96% agent result read as a query result (5); narrative totals that did not reproduce from the TSV and RESOLVED rows contradicting their own definition (6); a k=1 table cited as a result (7); and the first things sceptics attack on any agent benchmark, in order: contamination, grader quality, scaffold confounds, single runs without error bars, vendor self-reporting with private best-of-N, cherry-picked subsets, hidden cost (11 to 13).

## Decisions still open for Deniz

- Whether a developed-against score may appear in outward material at all, or only held-out scores. Until ruled: held-out only.
- Whether the three-arm same-model control is required for every published comparison, or only for NEAT-effect claims. Until ruled: every comparison.
- Who owns the wording of homepage claims (GTM) and the evidence standard that gates them (this contract).
