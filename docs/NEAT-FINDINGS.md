# NEAT findings the meter surfaced

Building the benchmark is a prove-machine pointed at NEAT itself. Each item below is a NEAT behaviour the benchmark's honesty depends on; each is filed as an issue on `NEAT-Technologies/Neat` and joins the wall-driven hardening list ("perfect NEAT → run at walls"). Several were predicted by the provenance audit and then confirmed in real snapshot data.

| # | finding | issue | benchmark impact | worked around today? |
|---|---|---|---|---|
| 1 | DB identity split — `database:mongodb` (declared) vs `database:127.0.0.1` (observed) never fuse | [neat#979](https://github.com/neat-technologies/neat/issues/979) | inflates static-blindness ~100 pts on the very first fixture | yes — classifier quarantines as `IDENTITY_SUSPECT` |
| 2 | STALE edges parse back as OBSERVED → invisible to divergence | [neat#980](https://github.com/neat-technologies/neat/issues/980) | can't tell "went quiet" from "never ran"; no time axis | not yet — avoid STALE-dependent walls |
| 3 | `missing-extracted` has no FrontierNode guard | [neat#981](https://github.com/neat-technologies/neat/issues/981) | unresolved peers read as "static missed it" | classifier only counts BLIND, not raw divergence |
| 4 | INFERRED/STALE divergence buckets are write-only | [neat#982](https://github.com/neat-technologies/neat/issues/982) | inference doesn't suppress a contradictory `missing-observed` | metrics don't use raw divergence counts |
| 5 | confidence is a producer tier, not calibrated; two functions disagree | [neat#983](https://github.com/neat-technologies/neat/issues/983) | can't trust the float as P(correct) | metrics key on provenance tier + the join, never the float |
| 6 | no graph-completeness signal at query time | [neat#984](https://github.com/neat-technologies/neat/issues/984) | no denominator to normalize; language recall gaps hidden | coverage stated as a hard rule (`HONESTY.md` §2–3) |
| 7 | symbol-attribution grain (leaf vs handler-frame floor) is unmarked | [neat#985](https://github.com/neat-technologies/neat/issues/985) | can't read leaf vs ancestor off the graph | scored on the on-the-true-stack bar |

## The loop

These aren't blockers on the benchmark — they're the *output* of building it. #979 is the most load-bearing for the data axis (the first wall target), so it leads the hardening. Fixing it also makes an eventual NEAT-vs-NEAT ablation honest, because today NEAT's own static is too weak to be the "static" baseline.
