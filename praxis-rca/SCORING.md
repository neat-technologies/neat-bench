# Scoring — determinism of find **and** fix

The headline is **`RESOLVED@k` — how reliably the agent lands a correct, regression-free fix across independent runs.** Not steps, not speed. NEAT's thesis is *determinism*: the answer is a graph lookup, not an LLM hunt, so the agent resolves the bug run after run. Command/tool count is **NOT a metric** (§5).

## 1. FIND (localization) — model-free
Per run, against PRAXIS ground truth:
- **RCI** — faulty *service* named. Exact match to the `root_cause:true` entity.
- **RCR** — faulty *statement/function/config* named. Match to the ground-truth code location (file + function/symbol, or config key). AST/string match, canonicalized, test files excluded. No LLM judge for the headline.

`find_RCI ∈ {0,1}`, `find_RCR ∈ {0,1}`.

## 2. FIX (resolution + no regression) — verified by the app recovering
The agent emits a patch to an isolated source copy. Verify (gold path):
1. Apply → rebuild the affected image → `kind load` → redeploy.
2. Drive the same user-flow load that reproduced the fault.
3. **Symptom cleared:** the scenario's fault-signal (its Prometheus alert / the recommendation error signature) returns to the fixed-baseline and stays down for a full window. `symptom_cleared ∈ {0,1}`.
4. **No regression:** the *other* core flows (frontend, cart, checkout, product-catalog) introduce **no new errors**, and the fix doesn't retain artificial behaviour absent from the faultfree reference. `no_regression ∈ {0,1}`. (Guards the "clears-the-symptom-but-subtly-wrong" fix — e.g. keeping an injected validation the reference removes.)
5. Anti-cheat: deployment runs a *newly built* image digest, replicas≥1; no scale-to-0, no revert-to-stock-image.

`fix_ok = symptom_cleared AND no_regression`.

## 3. RESOLVED (per run)
`RESOLVED = find_RCR AND fix_ok` — correct code-grain localization AND a verified, regression-free fix. (Also track `RESOLVED_service = find_RCI AND fix_ok`.) Record `SYMPTOM_CLEARED` separately so a "cleared but dirty/mislocalized" run is visible, never silently credited.

## 4. DETERMINISM protocol (the point)
Run **each arm k≥5 times per scenario, independently** (fresh agent, identical injected state, same model + budget). Then per arm per scenario:
- **`RESOLVED@k`** = (# runs RESOLVED) / k. The headline.
- **consistency** = is it 5/5 (deterministic) or 3/5 (flaky)? Report the distribution, not just the mean.
- **failure modes** across the k runs (wrong RCR / wrong fix / regression / didn't resolve) — where the flakiness lives.

## 5. Headline outputs (per scenario + aggregate)
- **`RESOLVED@k` per arm** — code / obs+graphify / opus+neat — with the distribution. The claim NEAT must earn: **higher and more consistent RESOLVED@k** than code-alone and obs+graphify. That is "the graph makes the fix deterministic; code-alone is hit-or-miss."
- **Grain/provenance quality** (supporting): did it land at the exact file:line with fused evidence (symbol-join, blast-radius, divergence) vs a lucky grep. Never step-count.
- Anchor against PRAXIS's published runtime-only=0% / fused=61.5% RCR as external reference points (with the "our grader ≠ their held-out grader" caveat).

**Command/tool count is NOT reported as a win/loss.** NEAT is *expected* to use more queries; that's fine. If we ever cite it, it's a neutral note ("neat ran the full arsenal; code read one file"), never a score.

## 6. Controls
Identical injected state + model + budget across arms; only tooling differs. Randomize arm order. The fix oracle + each scenario's symptom signal are **pre-registered and frozen** before the first run. Healthy graph snapshot captured per scenario (for the neat arm's `neat diff` time-travel).

## 7. Honesty rules
- A pass requires the app to actually recover AND not regress. No "looks fixed."
- Every NEAT weakness (a query that 500s, a grain gap, a misdirection) is **filed as an issue + fixed to `latest`** (CONTRACT rule 1) — recorded, never smoothed over.
- The neat arm uses NEAT's **full arsenal** (CONTRACT rule 6), not just root-cause/incidents; a run where NEAT was under-used is invalid, not a NEAT loss.
- Report the funnel + failure modes; a flaky arm's variance is the finding, not something to average away.
