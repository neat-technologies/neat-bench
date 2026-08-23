# Scoring — find + fix, graded together

The headline metric is **RESOLVED**: the agent must both **localize** the root cause AND ship a **fix that makes the fault go away**. Localization alone is not a pass. This is what turns "agents fix bugs faster with NEAT" from a slogan into a measurement.

## 1. FIND (localization) — model-free
Graded against the PRAXIS ground truth at two grains:
- **RCI** — faulty *service* named. Exact string match to the scenario's ground-truth service.
- **RCR** — faulty *statement / function / config key* named. Match to the ground-truth code location (file + function/symbol, or the config key). AST/string match, canonicalized, test files excluded. No LLM judge for the headline.

Record `find_RCI ∈ {0,1}`, `find_RCR ∈ {0,1}`.

## 2. FIX (resolution) — verified by the app recovering, not by opinion
The agent emits a **patch** (unified diff against the repo, or a config/manifest change). Verification oracle, most-rigorous-feasible first:

**(A) Apply → redeploy → symptom-clears (gold; default).**
1. Apply the agent's patch to the buggy source/config.
2. Rebuild the affected service image (or `kubectl apply` for config/manifest fixes) and redeploy on the KinD box.
3. Drive the same user-flow load that reproduced the fault.
4. Assert the **symptom is gone**: the error/latency/behaviour that defined the scenario returns to the fixed-baseline signature in the traces/health checks. Use the scenario's own check if the artifact ships one; else a pre-registered per-scenario oracle (the specific span/error/SLI that the fault broke).
5. Assert **no new breakage**: the rest of the app's core flows still pass (guards against "fix by breaking everything else").

`fix_resolved ∈ {0,1}` = symptom cleared AND no new breakage.

**(B) Reference-patch equivalence (fallback, labeled).** Only when (A) is infeasible for a scenario (e.g., rebuild not reproducible). Compare the agent patch to the PRAXIS reference fix for semantic equivalence (touches the same location, same corrective change). Weaker; flag every instance that used it.

## 3. RESOLVED (headline, per arm per scenario)
`RESOLVED = find_RCR AND fix_resolved` (must localize at code grain **and** actually fix it). Report also the looser `RESOLVED_service = find_RCI AND fix_resolved`.

## 4. Efficiency / quality (secondary, all objective)
- **directness:** agent tool-calls, distinct files opened, wall-clock to a verified fix.
- **grain:** did it land at file:line/function, or only name a service? (where fusion beats a trace UI even when both "resolve").
- **fix size:** lines changed vs the reference fix (bloat / collateral).

## 5. Headline outputs
- **RESOLVED rate per arm** (code / obs+graphify / opus+neat), with the paired **McNemar test** on neat-vs-obs+graphify discordant outcomes — the fusion claim.
- Anchored against PRAXIS's published **runtime-only 0.0% RCR** and **fused 61.5% RCR** as external reference points.
- directness + grain deltas.

## 6. Controls
- Same model (Claude Opus), same token/step budget, identical injected scenario state per arm, randomized arm order, **≥3 seeds/scenario**, variance reported.
- The fix oracle and each scenario's symptom-cleared signal are **pre-registered and frozen** before the first run — no tuning the oracle to the result.

## 7. Honesty rules
- A pass requires the app to actually recover. No "the patch looks right" credit.
- Every fallback-(B) grade is labeled; T1/T2 fault tiers labeled.
- If NEAT's own answer is what a neat-arm fix was built on and it was wrong/misleading → that's a filed NEAT weakness (see METHOD.md sub-loop), recorded, not smoothed over.
