# Context routing experiment

Refs neat-technologies/neat-bench#23. A development experiment, not a result. Nothing here may be cited until a pre-registered scored run exists (`docs/contracts/claims.md`, `docs/contracts/experiment-design.md`). It lives under `bench/`, the layout ADR-001 proposes, which is not yet ruled.

## The question

NEAT loads the same context into every session whatever the task: 28 tool descriptions, the graph-first directive, and the search nudge on every grep. The working premise from Deniz and the CTO is that this makes the agent slow on small fixes. It starts at the library entrance with a 30-floor map when the book is in the next room.

The one clean pair we have agrees on cost. On express B2 (`results/express-B2`), both arms made the same one-line fix in the same file. The NEAT arm cost $0.185 against $0.059 and made zero NEAT calls. Cache creation was 17,968 tokens against 1,415: the difference is context loaded at the start, not anything NEAT answered. That's one run per arm, so it's a hint, not evidence.

The idea under test: read the developer's request and use the graph to see which files it points at. Then let Jev, TypeSafe's calibrated classifier, pick how much context to give the agent. Jev decides how much; the graph decides which files.

## Arms

All four arms run the same model, prompt, turn budget, built-in tools and permissions.

| Arm | NEAT MCP tools | `GRAPH_FIRST.md` + search-nudge hook | "Start here" note |
|---|---|---|---|
| `bare` | no | no | no. The reference arm: no NEAT at all. |
| `full` | yes | yes | no. Today: byte-for-byte what `harness/arms/run-arm.sh` gives its WITH arm (tested). |
| `oracle` | yes | no | Names the files the real fix touched: the best any router could do. |
| `jev` | yes | only when routed `full` | The router's files (and briefing, for medium). Identical to `full` when routed `full` (tested). |

The note reads the same whoever chose the files, so `oracle` and `jev` differ only in which files they name. NEAT's tools stay available in every NEAT arm. A wrong guess means the agent has to look further, not that it's stuck.

## The router

`router/`, called once per task before the agent starts:

1. **Features** (`features.mjs`): the daemon's own `/graph/ask` (entity resolution: exact id, token overlap, embeddings) and `/search?limit=8`. These are merged into ranked matches, distinct files and services, `ask`'s intent, and an incident signal. It uses REST only and imports nothing from the engine.
2. **Jev** (`jev.mjs`): one `systemOne` call with two questions, using the official SDK `@typesafe-ai/sdk` 0.7.0.
   - `tier` is a choice of small, medium or full, with the rubric below as criteria.
   - `needs_runtime` is a yes/no.
   - The model is pinned to `jev-1.13.0`. There are no retries and a 2 s timeout.
3. **Decision** (`route.mjs`): small gets the top 2 files; medium gets the top 5 plus `ask`'s answer as a briefing. Anything uncertain falls back to `full`:
   - confidence below 0.7,
   - `needs_runtime` at or above 0.5,
   - Jev errors or is too slow,
   - the daemon is unreadable,
   - no files matched.

**What reaches TypeSafe:** the request text plus an allowlisted graph summary: node ids, types, services, paths, scores, counts, intent and the incident flag. No file contents, no other node attributes, and not the `ask` briefing. `test/jev.test.mjs` checks this against real node attributes from `fixtures/express-mongoose.graph.json`.

### Size rubric

Size labels in `tasks/` and Jev's criteria both come from `router/rubric.mjs`:

- **small:** the fix touches one or two files, and the request names or clearly points at the place (an endpoint, a field, an error message, a file). Reading those files is enough.
- **medium:** the fix touches up to about five files, or the cause sits one step from where the symptom shows (shared helper, middleware, plugin, config, validation). Reading the code is enough once you find it.
- **big:** the cause isn't clear from the request. It spans many files or services, or depends on runtime behaviour (incidents, production config, traffic). The router's tier for this is `full`.

## NEAT rules this experiment sets aside

These are deliberate and scoped to the bench. Nothing here ships to the product or lands in the core repo.

| Rule | What it says | How this breaks it | Making it permanent needs |
|---|---|---|---|
| No model calls: `docs/contracts/llm-policy.md` (ADR-084/086), README "method, not model", `docs/direction.md` | No NEAT process makes an LLM or model call | The router calls Jev, a hosted model, for every task | An ADR amending llm-policy, or keeping the router hosted-only (Sniper already runs Jev server-side) |
| Graph first: `docs/direction.md` rule 3 | Ask NEAT every time, then grep | The small and medium tiers drop the directive and the nudge | An ADR making rule 3 depend on task size |
| The request stays local (implicit today) | Nothing NEAT does sends the developer's prompt off the machine | The request and graph summary go to TypeSafe | An egress disclosure like the one hosted Sniper carries, plus a no-retention agreement |

The bench targets are public repositories, so nothing private reaches TypeSafe in this experiment.

Bench rules this keeps:
- Agent arms and the offline eval run on the bench box.
- k=3 is development.
- Arms and thresholds are fixed before a scored run.
- No bench code goes into the core repo.

## Tasks

`tasks/*.json`, one per task, with the bug as `tasks/patches/<id>.patch`. Applying the patch to a clean checkout at `base_commit` makes the bug; reversing it is the fix. Fields:
- `prompt`: the symptom, all the agent and router see.
- `size`: from the rubric.
- `gold_files`: the files the fix touches; the `oracle` arm names them.
- `bug_patch`
- `root_cause`
- `oracle`: the repo's own failing tests and the command that runs them.
- `validated`: whether the patch applies and reverses, and whether the oracle has actually been run.

**Today's set:** 30 tasks on node-express-boilerplate at `179ae84`, 18 small and 12 medium.
- **Origin:** 4 reconstruct the existing express instances (A2, A4, B2, B7), with patches rebuilt from their `gold_patch`. 26 are constructed for this experiment.
- **Checked here:** every patch applies to a clean checkout, reverses cleanly, and changes exactly its `gold_files`. No prompt names a fix file.
- **Oracles not yet run:** each task names an existing test that its bug makes fail, but those tests need MongoDB, so no oracle has been run (`oracle_runs: false` throughout).

Close calls, decided by the rubric read literally:
- **A2 is medium.** The bug is in `getUserByEmail`, a helper shared with forgot-password, one step from where the login error is raised.
- **B7 is small.** The wrong call is in login's own service function. Its prompt keeps the instance's wording, "returns 500", though the CastError comes back as 400 outside production. The failing test is the same either way.
- **m10 lists two `gold_files`**, because the fix is the reverse of the patch. Completing the rename in one file also passes.

## Running it

```bash
cd bench/context-router
npm ci                 # one dependency: @typesafe-ai/sdk, pinned
npm test               # router, arms dry-run, eval summary; no network, no daemon
```

On the bench box, with the target provisioned and its scoped daemon running (as for `harness/arms/run-arm.sh`):

```bash
export APP_DIR=/path/to/target/checkout REST=8090 NEAT_REPO=/path/to/Neat
export TYPESAFE_API_KEY=...        # from the secret store; never committed, never pasted

node eval-router.mjs --daemon http://127.0.0.1:$REST --out ../../results/context-router/router-eval.json

for arm in bare full oracle jev; do
  VERIFY=1 bash arms/run.sh tasks/<id>.json $arm 1
done
```

- **Offline eval** (`eval-router.mjs`): runs the router alone, no agent. It reports tier accuracy, the confusion matrix, and how many big tasks were sent to small. It scores whether the files the router named cover the real fix, and whether the graph's top 2 and top 5 files do, regardless of the tier Jev picked.
- **Per-task check:** `bash arms/run.sh <task> <arm> <n> --dry-run` writes the exact `claude` argv to `cmd.json` without touching the tree.
- **Per run**, `arm.json` records:
  - the routed tier, reason, confidence and latency,
  - whether the oracle passed, and wall time,
  - bytes NEAT injected at start, and bytes from NEAT tool results and hook output during the run (`arms/neat-bytes.mjs`; the frozen parser records neither),
  - tokens, cost, turns, files opened and diff size.

## What counts as a win

Proposed, and fixed in the pre-registration before a scored run:

- **The premise:** `oracle` beats `full` on small tasks on cost and wall time, with no drop in pass rate. If it doesn't, no router can help, and we stop.
- **Jev:** `jev` recovers most of `oracle`'s saving on small tasks and loses no pass rate on big tasks. In the offline check it sends no more than about 1 in 20 big tasks to small.

## Status

What's verified here:
- 31 tests pass: router fallbacks and timeouts, the TypeSafe allowlist, the real SDK offline against a fake server, the arms' dry-run argv, the eval summary, and the task set's shape.

Still to do on the bench box:
- **Live calls:** the router has not yet read a live daemon or called Jev for real.
- **Oracle commands:** no task's oracle command has been run.
- **Big tasks:** the express target has no big tasks under the rubric. The premise test needs only small tasks, but checking that the router doesn't send hard tasks to small needs a second target before a scored run.
- **Coverage gaps:**
  - The `full` arm reproduces the harness: claude-skill hook on `Grep|Glob|Bash`, no monitor. The shipped plugin also matches `mcp__neat__*` and runs `neat monitor`, so `full` understates today's plugin context, if anything.
  - The incident signal is a heuristic: an incidents or root-cause section with facts in `ask`'s answer.
