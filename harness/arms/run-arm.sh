#!/usr/bin/env bash
# harness/arms/run-arm.sh
# ─────────────────────────────────────────────────────────────────────────────
# Run ONE agent arm against ONE wall task on an already-provisioned target.
#
#   run-arm.sh <target-id> <wall-id> <with|without> <trial-n> [out-dir]
#
# Two arms, SAME model, changing exactly one thing: whether the agent can see the
# NEAT graph. [protocol from neat-agent-bench/harness/arms.md]
#   with     → gets the NEAT MCP server (regenerated from with-neat.mcp.json),
#              pointed at the scoped bench daemon on :$REST.
#   without  → control: file-read + grep + editor only, NO MCP server.
# Everything else is held identical: same target tree, same symptom prompt, same
# cwd, same turn budget.
#
# This scaffold does everything AROUND the model call for real — arm setup, tree
# reset via `git checkout` [arms.md §protocol step 2], prompt construction,
# per-arm logging, and capturing the final edit as a diff. The single
# environment-specific seam — actually invoking a live agent — is the `run_agent`
# shell function, a documented TODO(live) stub. Wire your agent runner there.
#
# Outputs (per arm) written to <out-dir>:
#   prompt.txt        the exact identical prompt both arms receive
#   with-neat.mcp.json  (WITH arm only) the concrete MCP config handed to the agent
#   transcript.jsonl  one JSON object per line: messages + tool calls (run_agent writes this)
#   edit.diff         `git diff` of src after the run — the final edit the scorers grade
#   tool-calls.log    tool-call log (neat/* vs read/grep tallies) [arms.md §what to log]
#   arm.json          machine-readable summary of this arm run
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Reuse the provisioner's descriptor loader + path/port globals so an arm knows
# where the target tree, the daemon, and the NEAT bins are. [shared spine]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../provision" && pwd)/lib.sh"

TARGET_ID="${1:?usage: run-arm.sh <target-id> <wall-id> <with|without> <trial-n> [out-dir]}"
WALL_ID="${2:?missing <wall-id>}"
ARM="${3:?missing arm: with|without}"
TRIAL="${4:?missing <trial-n>}"
OUT_DIR="${5:-$RESULTS/$TARGET_ID/$WALL_ID/trial-$TRIAL/$ARM}"

case "$ARM" in with|without) : ;; *) die "arm must be 'with' or 'without', got: $ARM" ;; esac

DESCRIPTOR_PATH="$REPO_ROOT/targets/$TARGET_ID.json"
load_descriptor "$DESCRIPTOR_PATH"     # sets TARGET, APP_DIR, SVC, D, NEAT_MCP_BIN, REST, …

# Wall definition lives in walls/<wall>.json (owned/authored elsewhere). We only
# read from it. Expected fields (best-effort, with fallbacks):
#   .prompt   full task prompt (optional; if absent we build the standard one)
#   .symptom  the symptom string shown to the agent (never the cause) [arms.md]
#   .description  short target description for the prompt (optional)
WALL_FILE="$REPO_ROOT/walls/$WALL_ID.json"
[ -f "$WALL_FILE" ] || die "wall not found: $WALL_FILE (walls are authored outside this scaffold; create walls/$WALL_ID.json with at least a .symptom)"

mkdir -p "$OUT_DIR"

# ── build the identical prompt [verbatim shape from arms.md §The prompt] ──────
build_prompt() {
  local custom symptom desc
  custom="$(jq -r '.prompt // empty' "$WALL_FILE")"
  if [ -n "$custom" ]; then printf '%s\n' "$custom"; return; fi
  symptom="$(jq -r '.symptom // "(no symptom in wall file)"' "$WALL_FILE")"
  desc="$(jq -r '.description // empty' "$WALL_FILE")"
  [ -n "$desc" ] || desc="$(jq -r '.description // empty' "$DESCRIPTOR_PATH")"
  [ -n "$desc" ] || desc="a service"
  cat <<PROMPT
The service in ./ ($desc) has a bug.

Symptom: $symptom

Find the root cause and fix it. Change as little as possible. Do not change tests.
When done, state the file and line you changed and why.
PROMPT
}
build_prompt > "$OUT_DIR/prompt.txt"

# ── reset the working tree so both arms start from the identical clean, ───────
#    instrumented state [arms.md §protocol step 2: `git checkout -- src`] ──────
reset_tree() {
  step "[$ARM] resetting target tree to clean instrumented state"
  # `-- .` (not just src) so any subdir layout resets; instrumentation was
  # committed by instrument_target, so this restores instrumented-clean, not
  # bare upstream. [reproduce.sh §3 commit rationale]
  git -C "$TARGET" checkout -- . >/dev/null 2>&1 || true
  git -C "$TARGET" clean -fd -e node_modules -e .env >/dev/null 2>&1 || true
}
reset_tree

# ── WITH arm: regenerate the concrete MCP config for THIS machine ─────────────
#    [reproduce.sh regenerates with-neat.mcp.json per run] ──────────────────────
MCP_CONFIG=""
if [ "$ARM" = with ]; then
  [ -f "$NEAT_MCP_BIN" ] || die "NEAT MCP bin not found: $NEAT_MCP_BIN — build @neat.is/mcp in \$NEAT_REPO, or set NEAT_MCP_BIN"
  curl -sf "$D/health" >/dev/null 2>&1 || die "scoped daemon not healthy at $D — run ./run.sh (provision) first"
  MCP_CONFIG="$OUT_DIR/with-neat.mcp.json"
  sed -e "s#<NEAT_MCP_BIN>#$NEAT_MCP_BIN#g" -e "s#<REST>#$REST#g" \
      "$(dirname "${BASH_SOURCE[0]}")/with-neat.mcp.json" > "$MCP_CONFIG"
  echo "  WITH arm: NEAT MCP → $NEAT_MCP_BIN (NEAT_CORE_URL=$D)"
else
  echo "  WITHOUT arm: control — no MCP server, file-read + grep + editor only"
fi

# ── the one environment-specific seam ────────────────────────────────────────
# TODO(live): implement run_agent to invoke your actual coding agent.
#   CONTRACT
#     inputs:
#       $1 prompt_file  — path to prompt.txt (identical for both arms)
#       $2 cwd          — the target working dir the agent edits ($APP_DIR)
#       $3 mcp_config   — path to an MCP config JSON for the WITH arm, or "" (empty)
#                         for the control arm (which must get NO NEAT tools)
#       $4 out_dir      — where to write outputs
#     outputs (run_agent MUST write both, or the scorers have nothing to grade):
#       $out_dir/transcript.jsonl — one JSON object per line. Recommended shape:
#           {"role":"assistant","content":"…"} | {"role":"user","content":"…"}
#           {"type":"tool_call","name":"mcp__neat__get_divergences","args":{…}}
#           {"type":"tool_result","name":"…","ok":true}
#         The grounded-evidence scorer reads asserted claims + neat/* calls from here.
#       $out_dir/tool-calls.log   — human-readable tool-call log (see tally below).
#     side effect: the agent edits files under $cwd in place; we snapshot the diff
#       afterwards, so run_agent must NOT reset the tree itself.
#   The control arm MUST NOT be able to reach the daemon or any neat tool — pass
#   mcp_config="" and ensure your runner adds no NEAT server in that case.
run_agent() {
  local prompt_file="$1" cwd="$2" mcp_config="$3" out_dir="$4"
  echo "  TODO(live): run_agent is a stub — no model was invoked." >&2
  echo "  Wire your agent runner here (e.g. \`claude -p\`, an SDK loop, aider, etc.)." >&2
  echo "  It must consume: prompt=$prompt_file cwd=$cwd mcp=${mcp_config:-<none>}" >&2
  echo "  and produce: $out_dir/transcript.jsonl and $out_dir/tool-calls.log" >&2
  # Write empty, well-formed artifacts so downstream steps have real (not faked)
  # files to operate on. These are EMPTY BY DESIGN until run_agent is implemented.
  : > "$out_dir/transcript.jsonl"
  : > "$out_dir/tool-calls.log"
  return 42   # sentinel: "agent not wired" — run.sh treats this as a skip, not a pass
}

step "[$ARM] running agent (trial $TRIAL, wall $WALL_ID)"
set +e
run_agent "$OUT_DIR/prompt.txt" "$APP_DIR" "$MCP_CONFIG" "$OUT_DIR"
AGENT_RC=$?
set -e

# ── capture the final edit as a diff — this is what the scorers grade ─────────
step "[$ARM] capturing final edit → edit.diff"
git -C "$TARGET" add -A >/dev/null 2>&1 || true
# diff against the committed instrumented-clean tree (HEAD), excluding vendored dirs.
git -C "$TARGET" diff --cached -- . ':(exclude)node_modules' > "$OUT_DIR/edit.diff" 2>/dev/null || true
git -C "$TARGET" reset -q >/dev/null 2>&1 || true   # unstage; leave working edits for the oracle

# ── extract the CLAIMS the agent leaned on → claims.json ─────────────────────
# grounded-evidence.mjs (the keystone scorer) takes claims as DATA: its own header
# says "Extracting claims from a transcript is the arms-runner's job; this scorer
# takes them as data so it stays model-free." A claim is a {source,target,type}
# graph edge the agent relied on. run.sh feeds this file to grounded-evidence.mjs.
#
# TODO(live): implement real claim extraction from transcript.jsonl — map each
#   mcp__neat__* result the agent cited, and every edge it asserted in prose, to a
#   {source,target,type} using node/edge ids from the graph. CONTRACT: emit a JSON
#   array of {source,target,type}. Empty until run_agent + this extractor are wired.
# Passthrough today: if the transcript already carries {"type":"claim","claim":{…}}
# lines, forward them; otherwise emit [].
CLAIMS="$OUT_DIR/claims.json"
if [ -s "$OUT_DIR/transcript.jsonl" ]; then
  jq -s '[ .[] | select(.type=="claim") | .claim | {source,target,type} ]' \
     "$OUT_DIR/transcript.jsonl" > "$CLAIMS" 2>/dev/null || echo '[]' > "$CLAIMS"
else
  echo '[]' > "$CLAIMS"
fi

# ── tally tool calls [arms.md §what to log: neat/* vs read/grep] ──────────────
NEAT_CALLS=0; OTHER_CALLS=0
if [ -s "$OUT_DIR/transcript.jsonl" ]; then
  NEAT_CALLS="$(jq -r 'select(.type=="tool_call") | .name' "$OUT_DIR/transcript.jsonl" 2>/dev/null | grep -c 'neat' || true)"
  OTHER_CALLS="$(jq -r 'select(.type=="tool_call") | .name' "$OUT_DIR/transcript.jsonl" 2>/dev/null | grep -cv 'neat' || true)"
fi

# ── machine-readable arm summary ─────────────────────────────────────────────
DIFF_LINES="$(wc -l < "$OUT_DIR/edit.diff" | tr -d ' ')"
AGENT_WIRED=$([ "$AGENT_RC" = 42 ] && echo false || echo true)
jq -n \
  --arg target "$TARGET_ID" --arg wall "$WALL_ID" --arg arm "$ARM" \
  --argjson trial "$TRIAL" --argjson rc "$AGENT_RC" \
  --argjson agent_wired "$AGENT_WIRED" \
  --argjson neat_calls "${NEAT_CALLS:-0}" --argjson other_calls "${OTHER_CALLS:-0}" \
  --argjson diff_lines "${DIFF_LINES:-0}" \
  --arg mcp "${MCP_CONFIG:-none}" \
  '{target:$target, wall:$wall, arm:$arm, trial:$trial,
    agent_wired:$agent_wired, agent_rc:$rc, mcp_config:$mcp,
    tool_calls:{neat:$neat_calls, other:$other_calls},
    edit_diff_lines:$diff_lines}' > "$OUT_DIR/arm.json"

echo "  [$ARM] done → $OUT_DIR   (agent_wired=$AGENT_WIRED, edit.diff ${DIFF_LINES} lines, neat_calls=$NEAT_CALLS)"
# Propagate the not-wired sentinel so run.sh can distinguish "agent skipped" from a real run.
exit "$AGENT_RC"
