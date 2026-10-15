# neat-bench contracts

Binding rules for the bench. Auto-loaded into every Claude Code session opened at this repo root via `@docs/contracts.md` in `CLAUDE.md`.

If you are about to write code, a harness change, or a results doc that conflicts with anything below, stop. The conflict is the bug. Either the rule is wrong (open an ADR superseding it) or the change is wrong. Don't quietly drift.

The PreToolUse hook at `docs/contracts/_hook.sh` surfaces the governing contract automatically: a pointer when you **read** a governed file, the full binding text when you **edit** one. The rules load at the moment of reading, not just on session start. Every contract declares what it governs in its `governs:` frontmatter.

## Per-topic contracts

| # | Contract | File | Governs | Status |
|---|----------|------|---------|--------|
| 1 | Claims and evidence | [`contracts/claims.md`](./contracts/claims.md) | What may be claimed from which evidence; every outward results doc | Proposed |
| 2 | Scoring and grader validity | `contracts/scoring.md` | RCI / RCR / CAUGHT / RESOLVED / ROBUST definitions; negative-control suite a grader must pass; no keyword-only headline grader | not yet written |
| 3 | Run validity | `contracts/run-validity.md` | Verified-clean baseline before launch (against the chart, never a snapshot); stray-fault preflight; VOID semantics; exclusion rules pre-registered | not yet written |
| 4 | Experiment design | `contracts/experiment-design.md` | Same-model three-arm control; both models; k; frozen product/model/prompts/budgets/grader per run; developed-against vs held-out sets | not yet written |
| 5 | Results records | `contracts/results-records.md` | TSV schema (incl. `wall_s`, token categories, `regrade_reason`); every attempt published; narrative totals must reproduce | not yet written |
| 6 | Scenario inventory | `contracts/scenarios.md` | The PRAXIS-30 map, what is wired, the box taxonomy, how a scenario is added | not yet written |
| 7 | Environment and box ops | `contracts/environment.md` | Clean-baseline source of truth, leftover purge between legs, daemon wiring (never helm-reinstall otel-demo) | not yet written |

## Decision log

Architecture and method decisions live in [`docs/decisions.md`](./decisions.md) as ADRs. A contract cites the ADR that settled it. A rule with no ADR is Proposed.
