# neat-bench contracts

Binding rules for the bench. Auto-loaded into every Claude Code session opened at this repo root via `@docs/contracts.md` in `CLAUDE.md`.

If you are about to write code, a harness change, or a results doc that conflicts with anything below, stop. The conflict is the bug. Either the rule is wrong (open an ADR superseding it) or the change is wrong. Don't quietly drift.

The PreToolUse hook at `docs/contracts/_hook.sh` surfaces the governing contract automatically: a pointer when you **read** a governed file, the full binding text when you **edit** one. The rules load at the moment of reading, not just on session start. Every contract declares what it governs in its `governs:` frontmatter.

The verbatim spec these contracts refine is `CONTRACT.md` at the repo root. A contract cites the clause it restates; none overrides it. Where an older doc in this repo (`competitive-rca/README.md`, `docs/BENCHOPS-RUNBOOK.md`, `docs/METRICS.md`, `docs/DESIGN.md`) states a rule a contract changed, the contract wins; those docs are evidence of earlier generations and get a frozen notice once ADR-001 is ruled.

## Per-topic contracts

| # | Contract | File | Governs | Status |
|---|----------|------|---------|--------|
| 1 | Claims and evidence | [`contracts/claims.md`](./contracts/claims.md) | What may be claimed from which evidence; the headline form; every outward results doc | Accepted (3 decisions open) |
| 2 | Scoring and grader validity | [`contracts/scoring.md`](./contracts/scoring.md) | RCI / RCR / CAUGHT / RESOLVED; the negative-control suite; no-fault controls, trivial agents, oracle agent; verifiers and oracles; no LLM judge in a headline metric | Accepted (headline grader form Proposed) |
| 3 | Run validity | [`contracts/run-validity.md`](./contracts/run-validity.md) | Chart-audit launch gate; reset must remove injector-owned fields; preflight per window; VOID; pre-registered exclusions; the per-window report | Accepted (reset method per ADR-003, Proposed) |
| 4 | Experiment design | [`contracts/experiment-design.md`](./contracts/experiment-design.md) | `obscode` baseline; scenario as unit; k=5 then top-up; battery before repeats; held-out; pre-registered analysis | Accepted (two ADR-004 items Proposed) |
| 5 | Results records | [`contracts/results-records.md`](./contracts/results-records.md) | TSV schema incl. `wall_s` and token categories; run manifest; what is published; totals reproduce | Accepted |
| 6 | Scenario inventory | [`contracts/scenarios.md`](./contracts/scenarios.md) | The battery and its sources, licences verified, what each RESOLVED means, how a scenario is added, NEAT verified per application first | Accepted |
| 7 | Environment and box ops | [`contracts/environment.md`](./contracts/environment.md) | Stand-up script, clean = chart rendering, never helm-reinstall, purge between legs, pull queue across boxes, boot hygiene | Accepted (two ADR-007 choices open) |

The `bench/` paths in the `governs:` blocks are the proposed layout of ADR-001 and are inert until it is ruled; the contracts bind today through the legacy paths they also name.

## Decision log

Architecture and method decisions live in [`docs/decisions.md`](./decisions.md) as ADRs. A contract cites the ADR that settled it. A rule with no ADR is Proposed. The research register behind ADR-002, 004, 005 and 006 is [`docs/research/bench-research-2026-10-16.md`](./research/bench-research-2026-10-16.md); the cluster evidence behind ADR-003 is [`docs/research/2026-10-16-cluster-audit.md`](./research/2026-10-16-cluster-audit.md).
