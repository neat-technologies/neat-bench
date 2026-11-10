# Security bench harness (bench-internal)

Runs on the box only. TypeScript, @anthropic-ai/sdk tool-runner. Three arms (arms.ts).
Measures whether NEAT lets an agent actually fix reachable CVEs in real apps, vs the model alone.

## Per-trial flow (one app, one arm, one seed)
1. Fresh isolated checkout of the app at its pinned vulnerable commit (arms never share a tree).
2. NEAT arms only: start the app instrumented (true-neat, every inch), drive baseline traffic so
   the OBSERVED layer materializes, start the NEAT daemon on the tree (EXTRACTED + OBSERVED fused).
   Bare arm: capture the same OTel (traces + logs) to files via a plain collector, hand them over.
3. Run the agent loop (tool-runner) with the arm's tool set and the task prompt, under EFFORT +
   MAX_TURNS + TASK_BUDGET.
4. Grade (independent oracle, below).
5. Record result + transcript + usage; tear the tree down.

## Task (identical both arms)
"Remove the reachable vulnerabilities from this app without breaking it or violating its policies."

## Tools
Baseline (all arms): run_shell (sandboxed, in the checkout), read_file, write_file, run_tests.
Bare arm adds: npm audit / pip-audit / osv-scanner; the raw OTel capture files (traces + logs).
NEAT arms add: the NEAT MCP suite (investigate, get_incident_card, get_root_cause,
get_blast_radius, get_dependencies, get_divergences, check_policies, get_reachable_cves,
is_reachable, scan_diff, security fix) + Recon (recon_qa, recon_flush, recon_probe).

## Grader (deterministic, NEAT-independent; see recon spec for recon_qa)
PASS iff all hold after the patch:
1. VULN GONE (primary, independent authority, NOT NEAT's scanner): resolve the post-patch tree,
   check the vulnerable package against the advisory via OSV data + the ecosystem scanner
   (npm audit / pip-audit / govulncheck). Cleared iff resolved version is outside the affected
   range, or the package is gone.
2. NO REGRESSION (gate): the app's baseline-green tests (native framework) still green.
3. NOT DEGENERATE (guard): the tests exercising the vulnerable path still exist and pass.
4. ACTUALLY WORKS (Recon QA, NEAT arms' correctness signal, also run for bare via journeys):
   the usage journeys return correct responses AND the OBSERVED layer still materializes for the
   exercised routes AND get_divergences shows no NEW drift the fix introduced.

## Metrics captured (leave nothing on the table)
Every trial records the full set; the headline numbers are derived from it.
- Outcome: pass + each criterion (vuln-gone / no-regression / not-degenerate / actually-works) with evidence.
- Cost ($): input / output / cache-read / cache-creation tokens, and $ = tokens x the pinned model
  price (opus-5-5 $4/$20, sonnet-5-5 $2/$10 per MTok). Per trial, per arm, per app. cost-per-PASS.
- Time: wall-clock total + per phase (setup / agent-loop / grade); API-latency vs box-side tool-exec
  split; time-to-first-edit; time-to-PASS. (Timing is load-sensitive - see the box caveat below.)
- Effort: agent turns (loop iterations); tool-call count by type (shell / file / test / scanner /
  each NEAT MCP tool / each Recon tool).
- NEAT usage (NEAT arms): which NEAT tools were actually called and how often (investigate,
  get_incident_card, get_root_cause, get_blast_radius, get_dependencies, get_divergences,
  check_policies, get_reachable_cves, scan_diff, recon_qa/flush/probe) - evidence NEAT was used and
  which tools drove the fix.
- Precision (NEAT arms): reachable-CVE precision vs ground truth (of CVEs NEAT called reachable, how
  many truly were).
- Scoping / over-fix: deps changed vs deps that needed changing; unnecessary-change rate (edits to
  non-reachable deps); the bare arm's over-fix of the audit-noise tree (the key contrast).
- Fix quality: correct fix target (right version / correct remove-replace); diff size (files + lines).
- Regression detail: which baseline-green tests went red, and count.
- Self-correction: re-verify cycles (scan_diff / recon_flush then re-fix); wasted-work tokens
  (reverted dead-end edits).
- Derived headlines (paired): fix-rate, regression-rate, $/PASS, tokens/PASS, time/PASS - NEAT+Opus
  vs Opus, and NEAT+Sonnet vs Opus (the cost-wedge: cheaper model + NEAT matching bare Opus).

## Box caveat (shared gaming rig)
The bench box doubles as Deniz's gaming rig. Correctness (pass/fail) and cost ($/tokens, API-side) are
load-independent and valid under any box load. TIME metrics are NOT: box-side tool-exec (app start,
tests, daemon) contends with the game. The headline TIMED run must be on an UNLOADED box; a run under
gaming load records time as advisory-only. RAM budget protects the game: measure real `available`,
subtract a game-protection buffer, then bound concurrency under what remains.

## Fairness invariants
Same task, same EFFORT, same MAX_TURNS/budget, same baseline tools, same raw telemetry available.
NEAT is the only variable (the graph + MCP suite + Recon). No outward numbers until the grader +
per-app ground truth hold.

## Reproducibility (VC-grade, no fudging)
Every trial is fully pinned and fully recorded so a third party can re-run and get the same verdict:
- Pins captured in a per-run manifest (run.json): model id, app repo+commit (corpus), NEAT version
  (0.11.0 + the instrumentation commit), the resolved dependency tree (lockfile hash), otelc + tool
  versions, effort, budgets, seed, box + node version.
- Per-trial artifacts under runs/<ts>/<arm>/<app>/: full agent transcript (messages + tool calls),
  token/turn usage, pre- and post-patch dependency tree, the independent scanner output, the test
  output, the Recon QA output, and the grader's per-criterion verdict WITH its evidence string.
- Deterministic, NEAT-independent oracle (OSV + ecosystem scanner); no LLM in grading.
- One command re-runs the whole matrix from the pins. Methodology = this README.
- NO outward/VC number until the per-app ground truth is hand-verified AND a clean re-run reproduces
  it. A result that can't be reproduced is not a result.

## Validation gate (every round works before the full run)
Before the full matrix, run ONE trial per (arm x target) config as a smoke and assert: the agent loop
runs to completion, every tool answers, the app comes up and is observed (NEAT arms), the grader
emits a verdict with evidence, and all artifacts are written. A config that can't cleanly produce a
gradeable trial is a bug fixed FIRST. Only when all 12 configs pass the smoke do we run for real.

## Parallelism + RAM budget
Trials run concurrently on the box, bounded by a RAM floor that leaves a few GB leeway (box 29Gi
total; keep >= ~3-4Gi free). A semaphore caps concurrency and the runner checks free RAM before
launching each trial, holding if under the floor. Concurrency must not change results: each trial is
fully isolated (own checkout, own daemon, own ports), so parallel == serial verdicts.

## Run matrix
3 arms x 4 targets x k=1 = 12 trials (pilot). Runs after the code (instrumentation + harness + Recon
+ the two ingest bugs) lands and all 12 configs pass the validation smoke. k=5 later for variance.

## Modules (to build)
arms.ts (done) · trial.ts (checkout+isolate+run+grade+teardown) · agent.ts (tool-runner loop) ·
tools/ (shell,file,test,scanners,neat-mcp,recon) · grader.ts (the 4 criteria) · corpus/ (per-app
pinned commit + CVE ground truth) · recon/ (the QA stack, separate spec).
