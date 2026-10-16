---
name: Results records
description: The record every run leaves behind: the TSV schema, the run manifest, what is published, and how a narrative total must reproduce.
governs:
  - "bench/results/*"
  - "*/results/*"
  - "results/*"
  - "*/results/*.tsv"
  - "*/manifest.json"
  - "*/run.json"
status: Accepted
---

# Results records

Status: **Accepted** (Deniz, 2026-10-16). The schema below is the minimum; columns may be added, never removed or renamed without an ADR.

## Rules

1. **One row per run, every run.** Every attempt writes a row, including VOID rows and the control arms. Nothing is deleted; corrections are new rows or a `regrade_reason`.
2. **The TSV schema.** Required columns:
   `run_id`, `bench_tag`, `target`, `scen`, `fault_box` (strict-code | strict-runtime | both | fusion), `obs_class`, `strength`, `mode` (detect | resolve), `arm`, `model` (snapshot id), `seed`, `k_index`, `rci`, `rcr`, `caught`, `symptom_cleared`, `f2p`, `no_regression`, `safety`, `resolved`, `void`, `void_reason`, `tokens_in`, `tokens_out`, `tokens_cache_read`, `tokens_cache_write`, `turns`, `cost_usd`, `wall_s`, `t_answer_s`, `t_verified_s`, `neat_hits`, `obs_hits`, `grader_version`, `regrade_reason`, `held_out`, `confounds`.
   `arm` is one of `code`, `obscode`, `neat`, `oracle`, `trivial-unknown`, `trivial-common`, or `competitor:<name>`. `resolved=YES` with `rcr=NO` is rejected at write time (ADR-005); `resolved=YES` requires `symptom_cleared`, `f2p`, `no_regression` and `safety` all YES. `wall_s` is measured from a stamp taken before the agent launches to the moment its final artifact lands, and the clock's contents are stated in the manifest (claims contract, rule 3). The legacy `robust` column of the October TSVs corresponds to `resolved` here; the legacy `resolved` column is "symptom cleared with localisation".
3. **The run manifest.** Every run directory holds `manifest.json`: bench tag and commit, analysis-plan commit hash, chart version and collector patch version, image digests, NEAT version and its language table (`compat.json` at that version), model snapshot ids, scaffold commit, temperature, turn and token caps, k, seeds, the scenario list and the held-out slice, the `machine` id and its hardware line (`nproc`, memory, disk), the load-generator setting, the audit and preflight file names, start and end timestamps. A run without a manifest is VOID.
4. **Published with every result**: the TSV, the manifests, every arm's answer and trajectory, the grader version and its negative-control suite result, the verifier outputs, and the analysis script that recomputes every headline from the TSV. The repository carries a canary string so leakage into training data can be detected.
5. **A narrative total reproduces** from the committed TSV by the committed script, or it is removed (claims contract, rule 6). Regrades keep the old row and add the new one with `grader_version` and `regrade_reason`; the published before-and-after is computed from the rows, not typed.
6. **Legacy TSVs are not edited.** The audited result directories under `praxis-rca/results/` and `competitive-rca/` are evidence at the audited commit (ADR-001, proposed layout). Re-summing under a corrected definition writes a new file beside them with the derivation. Ground-truth and catalog tables (`ground-truth.tsv`, `divergence-ground-truth.tsv`, `fullsuite-catalog.tsv`) are instruments governed by the scoring and scenario contracts, not records.

## Why

The audit found narrative totals that did not reproduce, manual regrades layered in prose, RESOLVED rows contradicting their definition, and no duration ever recorded, so a published "17% faster" on the homepage had no source. Every bench the research pass found trustworthy publishes a per-instance record, the logs, and a script; SWE-bench's `results.json` plus per-instance `report.json`, `test_output.txt` and `patch.diff` is the layout to copy.
