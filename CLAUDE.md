# CLAUDE.md

Agent guide for neat-bench. Read this first if you are a fresh Claude session or a human picking this up cold.

## Binding rules

`@docs/contracts.md` is the index, auto-loaded with this file. Per-topic contracts live under `docs/contracts/` and are surfaced automatically when you touch a governed file: a pointer on read, the full binding text on edit (PreToolUse hook at `docs/contracts/_hook.sh`, wired in `.claude/settings.json`). If you write code, a harness change, or a results doc that conflicts with a contract, stop. The conflict is the bug.

**Open sessions at this repo's root.** The hook keys off `CLAUDE_PROJECT_DIR`; a session opened elsewhere never fires it and the contracts never load. That is the one way to silently lose the guardrail.

## What this repo is

The benchmark that measures whether NEAT makes a coding agent better at building and debugging a real running system than the same agent without it. It runs on the bench box, never on a laptop. Two things are true at once and both are recorded here: the experiments are real, and the 15 October 2026 evidence audit showed the scoring and the claims had drifted past the evidence. The contracts exist so that cannot happen quietly again.

The audit report, the findings it reproduced, and what they imply are the starting point for every design decision in `docs/decisions.md`.

## Layout

- `bench/` is the consumer-ready bench being built against the contracts (see ADR-001 for the layout ruling).
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
- Don't snapshot a running cluster and call it the clean baseline. Clean is derived from the pinned chart; a snapshot of a live cluster has carried injected faults before.
- Don't `helm uninstall` or reinstall the demo on the box. The collector-to-NEAT wiring lives in a configmap a reinstall wipes.
- Don't run any leg of the bench locally. It filled a laptop disk once. The box only.
- Don't trust a grader you have not fed wrong, negated and "unknown" answers. A grader is validated before its output is a result.
- Don't write an ADR on unverified evidence. Reproduce every number and behavioural claim first.
