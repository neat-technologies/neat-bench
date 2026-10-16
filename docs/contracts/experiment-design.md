---
name: Experiment design
description: The arms, the unit of inference, k, what is frozen per run, held-out versus developed-against, and the analysis that turns runs into a claim.
governs:
  - "bench/design/*"
  - "bench/analysis/*"
  - "*/METHOD.md"
  - "competitive-rca/README.md"
  - "*/analysis*.py"
  - "*/analysis*.mjs"
  - "*/aggregate*.mjs"
  - "*/summarize*.sh"
status: Accepted
---

# Experiment design

Status: **Accepted** (ADR-004, ADR-006; Deniz, 2026-10-16) for rules 1 and 3 to 11. Rule 2's "both models" and rule 1's "competitors separate" are the two ADR-004 items still Proposed (recommended as written); until ruled, the stricter reading applies.

## Rules

1. **Arms are defined by what they remove.** `obscode` is the baseline: the same model with source plus the raw runtime signals, unfused: traces and metrics (Jaeger, Prometheus), logs, `kubectl` and deployment state. `neat` is the same source, traces, metrics and logs fused through a live NEAT daemon using its full surface (`CONTRACT.md` clauses 3, 5, 6), plus the same `kubectl` and deployment state. `code` is source only, no `kubectl`, and is a weaker control. The naming of logs and `kubectl` as inputs both arms receive refines clause 3 under Deniz's 2026-10-16 ruling. Competitor arms are a separate comparison with their own, weaker claims and never enter the NEAT-effect analysis.
2. **Same everything but the arm.** Within a comparison: same model snapshot id, same scaffold commit, same prompts, same turn and token budget, same temperature (the API default, never tuned per arm), same injected state, same pristine source tree. The best of several NEAT configurations is never reported; the configuration is fixed before the run. Both models, each compared to itself.
3. **The scenario is the unit of inference.** Repeats within a scenario estimate within-scenario noise; they are not independent samples. Standard errors are clustered by scenario and scenario family; intervals come from a hierarchical bootstrap over target system, scenario and run; the comparison is paired per scenario.
4. **k=5 on the full battery; k=10 top-up only on comparisons whose gap lies inside its interval.** k=3 is development and smoke only. k=1 is never a result. Repeats never substitute for scenarios: the minimum detectable effect is stated before the run from the battery size (ADR-004 table), and an effect smaller than that is not promised.
5. **The battery grows before k does.** The target is at least 90 scenarios with a verified-fix signal, built per ADR-006. A claim about a 10-to-15-point effect requires that battery; a 30-scenario run calibrates variance and instruments and certifies only a large effect.
6. **Both pass@1 (with interval) and pass^k are reported**; pass@k too where it informs. RESOLVED@k's distribution per scenario is shown, not only its mean (`praxis-rca/SCORING.md` §4).
7. **Held-out is real.** A slice of the battery is never run during development; which scenarios are held out is committed before development starts; a developed-against score is labelled an upper bound (claims contract, rule 8). The contamination status of each scenario class is stated: PRAXIS code faults novel by construction; public feature-flag faults likely contaminated; SREGym and ITBench problems public.
8. **Nulls are pre-declared.** Scenario classes where runtime context cannot matter are declared before the run and reported as expected nulls; they are not removed to improve an aggregate.
9. **Cost and time are measured per run** (wall-clock, token categories, dollars) and reported with accuracy on the same line; the cost figure that stands alone is cost per successful resolution at equal-or-better RESOLVED (claims contract, rules 2 and 3).
10. **The analysis plan is pre-registered.** The scenario list, the held-out slice, the arms, k, the metrics, the exclusion rules and the analysis script are committed, with the commit hash recorded in the run manifest, before the first scored window.
11. **Determinism is the thesis** (`CONTRACT.md` clause 8). The claim NEAT must earn is a higher and more consistent RESOLVED@k than `obscode`; a flaky arm's variance is a finding and is reported, not averaged away. Command and tool counts are never a score.

## Why

The September bench changed the model and the tool at once; the October bench ran k=1. Every methodology source the research pass surveyed (Miller, Kapoor, Hochlehnert, Bjarnason, the Agentic Benchmark Checklist) says the same three things: pair by task, cluster by task, and size the battery to the effect you want to see. The research also showed that the first thing a reviewer attacks on a "with versus without tool X" claim is a crippled baseline, which is why `obscode` and not `code` is the control.
