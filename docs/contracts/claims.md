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
status: Proposed
---

# Claims and evidence

Status: **Proposed**. The rules below are the ones the 15 October 2026 evidence audit showed we were breaking. Nothing here is settled until Deniz rules on it; the open decisions are listed at the bottom. Until then, treat every rule as binding on anything outward-facing.

## The rule

A number leaves this repo only when every clause below holds for that number. If a clause cannot be met, the number is not published. "Not yet" is an acceptable result. A confounded number is worse than no number.

1. **Grader validity.** The number was produced by a grader that passes the negative-control suite (wrong cause, negated cause, "unknown", wrong service, plausible-but-wrong patch) at the version used for that run. A keyword-presence grader is never a headline grader. See the scoring contract.
2. **Cost is a NEAT effect only when the model is held fixed.** A cost comparison across models (Sonnet+NEAT vs Opus+source) is a configuration comparison, and the accuracy of both sides is stated in the same sentence as the cost ratio. Token totals are reported next to dollar totals; "cheaper" never implies "fewer tokens".
3. **No speed claim without wall-clock.** A speed or "faster" claim cites per-run `wall_s` from the committed TSV of the exact runs, states what the clock includes (install, warm-up, timeouts, failures), and separates time-to-answer from time-to-verified-fix.
4. **Metrics are never collapsed.** RCI (right service) is not "correct diagnosis". CAUGHT, RESOLVED and ROBUST are reported separately and are never summed into one "solved" rate. A mixed total, if shown at all, is labelled as mixed.
5. **An agent result is never attributed to a query.** "An agent using NEAT caught 25/26" is not "`neat divergences` detects 96%". The raw-query hit rate is reported beside the agent rate whenever either is cited.
6. **Reproducible from a committed record.** Every published total reproduces from a committed TSV by the documented procedure. Regrades, exclusions and manual adjustments live in the TSV as rows or a `regrade_reason` column, never only in narrative. A narrative total that does not reproduce is removed.
7. **k is stated with the number.** A k=1 result carries "k=1, preliminary" in the same line. The headline requires the k the experiment-design contract sets.
8. **Developed-against is stated with the number.** Every number names whether the target was developed against or held out. A score on a developed-against target is an upper bound and is labelled as one.
9. **Stale sections are deleted.** When a result is corrected, the old figure is removed or the section is version-labelled. Two different numbers for the same result never coexist unlabelled.
10. **Controls are the same model with the same evidence.** The baseline for a NEAT effect is the same model with source plus raw runtime and deployment evidence under the same budget and permissions, not source alone. A source-only arm is reported as a weaker control, never as the baseline.

## Why

Each clause maps to a finding the audit reproduced from this repo: a grader that accepted answers denying the true cause (1); a 3.3x headline that compared different models at different accuracy (2); a 17% speed figure with no derivation and no durations recorded (3); a 100% RCI shown next to a mixed 35/45 (4); a 96% agent result read as a query result (5); narrative totals that did not reproduce from the TSV and RESOLVED rows contradicting their own definition (6); and a k=1 table cited as a result (7).

## Decisions for Deniz

- The headline k (proposed: 5; the audit asks for enough repeats to characterise variance).
- Whether a developed-against score may appear in outward material at all, or only held-out scores.
- Whether the three-arm same-model control (source / source+raw / source+NEAT) is required for every published comparison, or only for NEAT-effect claims.
- Who owns the wording of homepage claims (GTM) and the evidence standard that gates them (this contract).
