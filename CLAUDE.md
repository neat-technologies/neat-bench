# CLAUDE.md

Agent guide for neat-bench. Read this first if you are a fresh Claude session or a human picking this up cold.

## Binding rules

`@docs/contracts.md` is the index, auto-loaded with this file. Per-topic contracts live under `docs/contracts/` and are surfaced automatically when you touch a governed file: a pointer on read, the full binding text on edit (PreToolUse hook at `docs/contracts/_hook.sh`, wired in `.claude/settings.json`). If you write code, a harness change, or a results doc that conflicts with a contract, stop. The conflict is the bug.

**Open sessions at this repo's root.** The hook keys off `CLAUDE_PROJECT_DIR`; a session opened elsewhere never fires it and the contracts never load. That is the one way to silently lose the guardrail.

## What this repo is

The benchmark that measures whether NEAT makes a coding agent better at building and debugging a real running system than the same agent without it. It runs on the bench box, never on a laptop. Two things are true at once and both are recorded here: the experiments are real, and the 15 October 2026 evidence audit showed the scoring and the claims had drifted past the evidence. The contracts exist so that cannot happen quietly again.

The audit report, the findings it reproduced, and what they imply are the starting point for every design decision in `docs/decisions.md`.

## Layout

- `bench/` is the proposed home of the consumer-ready bench built against the contracts (ADR-001, awaiting the layout ruling). `ops/` holds the box-side scripts.
- `praxis-rca/`, `competitive-rca/`, `harness/`, `itbench-live-run/` are earlier generations. They are evidence, frozen at the commits the audit cites. They are not patched in place.
- `docs/contracts/` are the rules. `docs/decisions.md` is why.

## Conventions

- One issue, one branch named `<num>-<slug>`, one PR. PR body says `Refs #N`, never `Closes #N`.
- Commits and PRs read like a colleague wrote them. Plain English, no release-notes bullets.
- Sibling PRs branch from `main`, never from each other.
- A PR stays open for Deniz unless he says otherwise in the session. Contracts and ADRs are his rulings: draft them with options, never write the ruling and proceed.
- No bench code, contracts, or ADRs in the neat core repo. Ever. The separation is a hard rule.

## Don't do

- Don't publish, cite, or put in a doc any number that fails `docs/contracts/claims.md`. "Not yet" is a valid result.
- Don't snapshot a running cluster and call it the clean baseline; clean is the chart rendering, proven by the chart audit (environment rules 3 and 4, run-validity rule 1).
- Don't call a server-side apply, a client-side apply or a helm upgrade a reset; none removes a field the fault injector owns (run-validity rule 2, ADR-003).
- Don't `helm uninstall` or reinstall the demo inside a running bench cluster (environment rule 4).
- Don't run any leg of the bench on a laptop (environment rule 1).
- Don't trust a grader that has not passed the negative-control suite, and don't publish its number without the controls beside it (scoring rules 1 and 4).
- Don't let a model decide RESOLVED: it is RCR plus a verified, regression-free fix, every gate a script (scoring definitions, ADR-005).
- Don't publish a point without its interval, and don't buy repeats when the battery is what is too small (experiment-design rules 3 to 5).
- Don't write an ADR on unverified evidence. Reproduce every number and behavioural claim first.
