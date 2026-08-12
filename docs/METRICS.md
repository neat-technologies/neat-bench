# The metric dashboard

One rig, seven groups. `MF` = near model-free (audits a graph fact / the agent's context, not the model's outcome — the skeptic-proof ones). `ABL` = needs the ±NEAT ablation at N≥5 or a skeptic waves it off as model noise. Every metric comes from the same apparatus.

## Grounded evidence (the keystone)

| metric | definition | oracle | tag |
|---|---|---|---|
| **Grounded-Evidence Rate** | % of the agent's load-bearing facts that are observation-grounded (tier 3) vs declared-only (2) vs unbacked (1) | `grounded-evidence.mjs` classifies each claim against the fused graph | **MF** |
| **Sufficiency** | % of tasks where the agent had *enough* grounded evidence to solve it (guards "assert less, score higher") | required key facts present as grounded claims | MF |
| **Confidently-wrong rate ↓** | % of agent claims contradicted by ground truth | claim classified UNSUPPORTED/FABRICATED | MF |

## Accuracy — fix it right

| metric | definition | oracle | tag |
|---|---|---|---|
| **First-pass fix accuracy** | % bugs fixed correctly first try | behavioural probe (verify-fix pattern) | ABL |
| **Root-cause hit rate** | % root causes correctly identified (not just symptom) | diff ∩ ground-truth root-cause file/line/symbol | ABL |
| **Localization accuracy** | % edits landing in the right service/file/symbol | diff vs ground truth | ABL |

## Safety — don't break prod

| metric | definition | oracle | tag |
|---|---|---|---|
| **No-prod-break rate** | % fixes with zero regressions | full probe suite re-run | ABL |
| **Blast-radius recall** | % of real downstream consumers found before a change (vs static) | agent's named consumers ∩ OBSERVED consumers | **MF** |
| **Phantom-fix avoidance** | % of edits to dead/diverged code avoided (northsea class) | edit target vs divergence set | ABL |

## Efficiency — tokens / time / money

| metric | definition | oracle | tag |
|---|---|---|---|
| **Tokens saved** | % fewer tokens to first correct fix | token log | ABL |
| **Detour reduction** | % fewer wrong-path edits later reverted | tool-call log | ABL |
| **Context saved** | % less context window burned | transcript | ABL |
| **Time-to-green / $-per-task** | wall-clock and cost to resolution | run log | ABL |

## Autonomy — less human in the loop

| metric | definition | oracle | tag |
|---|---|---|---|
| **Autonomous-resolution rate** | % tasks completed with zero human intervention | run log | ABL |
| **Hand-holding reduction** | % fewer clarification round-trips | transcript | ABL |
| **Task-length ceiling** | % of longer multi-step tasks finished | run log | ABL |
| **Safe edit surface** | % of the repo an agent can operate in without breaking something | blast-radius-bounded | ABL |

## Concurrency — more agents at once

| metric | definition | oracle | tag |
|---|---|---|---|
| **Parallel-agent capacity** | % more agents concurrently without collision | fleet run | ABL |
| **Conflict reduction** | % fewer cross-agent contradictory edits | merge log | ABL |
| **Fleet throughput** | % of a whole feature-set a swarm delivers | run log | ABL |
| **Coordination overhead ↓** | % of redundant re-derivation eliminated | transcript | ABL |

## Reach — tasks possible at all (the walls)

| metric | definition | oracle | tag |
|---|---|---|---|
| **Walls cleared** | % of tasks the without-NEAT arm can't finish, period | verify-fix on both arms | ABL |
| **Task-class coverage** | % of the runtime-only taxonomy unlocked | certified walls per axis | MF |
| **Cold-start accuracy** | % of context correct on an unfamiliar repo before writing a line | claims vs graph | MF |
| **Full-stack completion** | % of cross-service/cross-language tasks completed | verify-fix | ABL |

## Trust — a human can ship it

| metric | definition | oracle | tag |
|---|---|---|---|
| **Mergeable-without-rework** | % of PRs shippable without a human fixing them | review pass | ABL |
| **Explanation accuracy** | % of fixes with a correct causal "why" | explanation vs root cause | ABL |
| **Review-time ↓** | % reduction in human review time | timer | ABL |

**Headline set:** Grounded-Evidence Rate (MF anchor) · first-pass fix accuracy · no-prod-break rate · autonomous-resolution rate · walls-cleared. Anchor the story on the MF numbers; back the ABL numbers with N≥5 and spread.
