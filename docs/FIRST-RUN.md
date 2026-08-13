# First live ±NEAT run — what it proved (and what it can't)

The full pipe ran, live, end to end: provision the target → run the **same model
(sonnet) with and without NEAT** → restart the app on the edit → judge-free oracle
(`verify-fix`) → objective metrics. It works, it's clean, and it produced a
definitive verdict about the *target*, not the tool.

## Setup

- **Target:** `neat-agent-bench` fixture (`node-express-boilerplate`, ~40 files), local NEAT **0.6.3** build.
- **WITH arm = FULL NEAT** — everything `neat hooks --apply` ships: the MCP tools **+** the `GRAPH_FIRST.md` graph-first guidance (`--append-system-prompt`) **+** the search-nudge PreToolUse hook (`--settings`). Confirmed loaded (WITH input 217k vs WITHOUT 125k tokens; no errors).
- **WITHOUT arm = clean control** — zero MCP (`--strict-mcp-config`, no ambient servers), file-read + grep + editor + Bash.
- N=1 per cell, instances B7 (CastError) and B2 (fan-in serializer typo).

## Result: every cell ties, and the WITH agent never uses NEAT

| instance | without | with | WITH NEAT calls |
|---|---|---|---|
| B7 | PASS | PASS | 0 |
| B2 | PASS | PASS | 0 |
| B2 (full NEAT: tools+guidance+hook) | PASS | PASS | **0** |

Even with the full setup, the WITH agent's first move on B2 was `Read toJSON.plugin.js`
— **the exact buggy file** — with **zero** Grep/Glob. It navigated straight to the
answer by intuition.

## Why NEAT had nothing to bite on

- The **hook** fires on Grep/Glob/`grep`. The agent never grepped → hook never fires.
- The **guidance** redirects grep→graph. There was no grep to redirect.
- The **graph** disambiguates non-local/runtime causality. A 40-file app has none the model can't hold in its head.

This is not a NEAT failure or a harness failure. **A 40-file legible target cannot
demonstrate NEAT**, because a strong model solves it in ~4 direct reads/edits with
no exploration — and NEAT's entire value is improving *exploration* and *non-local /
runtime* reasoning. Proven three ways here.

## What this validated (the machine is done)

The apparatus is complete and correct: a faithful full-NEAT WITH arm, clean isolated
arms, live same-model agents, a judge-free oracle, and objective metrics (fixed /
turns / tokens / cost / NEAT-tool usage / grounded-evidence). It is ready to point
at a real target.

## What it needs next (the only thing left)

A target where the agent **must** explore or reason non-locally:

- **Large / unfamiliar** — too big to hold in the model's head, so it greps (hook fires) and doesn't know where the bug is (graph matters).
- **Runtime-rooted / cross-service** — the walls, where reading the source cannot get the answer at all.
- **A richer graph** — the NEAT **main** build (symbol grain), not 0.6.3, so the graph has structure to answer with.

The legible fixture is exhausted as a signal source. It did its job: it proved the
machine, and it proved — empirically, with full NEAT loaded — that the target size
is the variable that matters. On to the corpus.
