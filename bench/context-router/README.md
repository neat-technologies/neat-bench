# Context routing experiment

Refs neat-technologies/neat-bench#23. A development experiment, not a result. Nothing here may be cited until a pre-registered scored run exists (`docs/contracts/claims.md`, `docs/contracts/experiment-design.md`). It lives under `bench/`, the layout ADR-001 proposes, which is not yet ruled.

## The question

NEAT loads the same context into every session whatever the task: 28 tool descriptions, the graph-first directive, and the search nudge on every grep. The working premise from Deniz and the CTO is that this makes the agent slow on small fixes. It starts at the library entrance with a 30-floor map when the book is in the next room.

The one clean pair we have agrees on cost, though not cleanly. On express B2 (`results/express-B2`), both arms made the same one-line fix in the same file. The NEAT arm cost $0.185 against $0.059, took one more turn, and made zero NEAT calls.
- **What the gap is mostly cache writes:** 17,968 tokens against 1,415. The run without NEAT evidently found its setup already cached from an earlier run; the NEAT run's setup was new and had to be written fresh.
- **How much is NEAT's own text:** at today's sizes, a few thousand tokens. The tool descriptions, the server instructions and the directive can't account for 3x on their own.

So that pair mixes "NEAT costs more" with "this run started cold". With one run per arm it's a hint, not evidence, and it's why this experiment warms every run (see [Measuring fairly](#measuring-fairly)).

Two ideas are under test:
- **A leaner NEAT** (`lean-full`): the same NEAT with a smaller setup that's identical from session to session.
- **A router** (`jev`): read the developer's request, use the graph to see which files it points at, and let Jev, TypeSafe's calibrated classifier, pick how much context to give. Jev decides how much; the graph decides which files.

## Arms

All five arms run the same model, prompt, turn budget, built-in tools and permissions.

| Arm | NEAT MCP tools | `GRAPH_FIRST.md` + search-nudge hook | "Start here" note |
|---|---|---|---|
| `bare` | no | no | no. The reference arm: no NEAT at all. |
| `full` | yes | yes | no. Today: byte-for-byte what `harness/arms/run-arm.sh` gives its WITH arm (tested). |
| `lean-full` | yes, without the 10 extend and connector tools, and with static server instructions | a short directive (`arms/GRAPH_FIRST.lean.md`), and the nudge once per session | no. Today's NEAT made leaner, with no router. |
| `oracle` | yes | no | Names the files the real fix touched: the best any router could do. |
| `jev` | yes | only when routed `full` | The router's files (and briefing, for medium). Identical to `full` when routed `full` (tested). |

The note reads the same whoever chose the files, so `oracle` and `jev` differ only in which files they name. NEAT's tools stay available in every NEAT arm. A wrong guess means the agent has to look further, not that it's stuck.

`lean-full` relies on three opt-in switches added in neat-technologies/neat#1611: `NEAT_SESSION_LEAD=0`, `NEAT_MCP_TOOLS=core` and `NEAT_SEARCH_NUDGE_ONCE=1`. A NEAT build without them silently ignores them, so every `arm.json` records the NEAT commit it ran against. The short directive is bench text written for this arm, not product copy. It keeps NEAT for investigation but tells the agent to fix directly when the request already points at the code.

### Measuring fairly

The client caches each session's setup (instructions and tool list) by exact prefix and reuses it on later turns and sessions. The one clean express pair compared a run whose setup was already cached with one whose setup was new. Three things keep that from deciding the result:

- **Warm-up.** Before every measured run, `run.sh` does a one-turn throwaway run with the same flags in the same tree, so every measured run starts with its setup cached. Its cache numbers are recorded beside the run's (`WARMUP=0` turns it off).
- **Separate numbers.** `arm.json` keeps cache writes, cache reads, uncached input, output and turns apart, and `summarize-runs.mjs` reports them apart. "Costs more because it started cold" and "costs more because the agent did more work" are different findings.
- **Rotating order.** `arms/run-matrix.mjs` rotates the arm order by task and trial, so each arm takes each slot equally often.

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

node arms/run-matrix.mjs --size small --trials 3 --plan    # print the order first
VERIFY=1 node arms/run-matrix.mjs --size small --trials 3  # 18 tasks × 5 arms × 3, each with its warm-up
node summarize-runs.mjs                                    # by size and arm: pass rate, turns, cache writes/reads, cost
```

One run on its own: `VERIFY=1 bash arms/run.sh tasks/<id>.json <arm> <trial>`.

- **Offline eval** (`eval-router.mjs`): runs the router alone, no agent. It reports tier accuracy, the confusion matrix, and how many big tasks were sent to small. It scores whether the files the router named cover the real fix, and whether the graph's top 2 and top 5 files do, regardless of the tier Jev picked.
- **Per-task check:** `bash arms/run.sh <task> <arm> <n> --dry-run` writes the exact `claude` argv to `cmd.json` without touching the tree.
- **Per run**, `arm.json` records:
  - the routed tier, reason, confidence and latency,
  - whether the oracle passed, and wall time,
  - bytes NEAT injected at start, and bytes from NEAT tool results and hook output during the run (`arms/neat-bytes.mjs`; the frozen parser records neither),
  - tokens, cost, turns, files opened and diff size,
  - cache writes, cache reads, uncached input and output as separate numbers, the warm-up's cache numbers, and the NEAT commit under test.

## What counts as a win

Proposed, and fixed in the pre-registration before a scored run:

- **The premise:** `oracle` beats `full` on small tasks on cost and wall time, with no drop in pass rate. If it doesn't, no router can help, and we stop.
- **A leaner NEAT:** if `lean-full` gets most of `oracle`'s saving on small tasks without losing pass rate anywhere, the fix is making NEAT leaner by default (an ADR in the core repo), and a router isn't needed.
- **Jev:** `jev` recovers clearly more of `oracle`'s saving than `lean-full` does, and loses no pass rate on big tasks. In the offline check it sends no more than about 1 in 20 big tasks to small.

## Status

What's verified here:
- 36 tests pass: router fallbacks and timeouts, the TypeSafe allowlist, the real SDK offline against a fake server, every arm's dry-run argv (including `lean-full`'s switches and the warm-up), the run order, the run summary, the eval summary, and the task set's shape.

Still to do on the bench box:
- **Live calls:** the router has not yet read a live daemon or called Jev for real.
- **Oracle commands:** no task's oracle command has been run.
- **Big tasks:** the express target has no big tasks under the rubric. The premise test needs only small tasks, but checking that the router doesn't send hard tasks to small needs a second target before a scored run.
- **Coverage gaps:**
  - The `full` arm reproduces the harness: claude-skill hook on `Grep|Glob|Bash`, no monitor. The shipped plugin also matches `mcp__neat__*` and runs `neat monitor`, so `full` understates today's plugin context, if anything.
  - The incident signal is a heuristic: an incidents or root-cause section with facts in `ask`'s answer.
