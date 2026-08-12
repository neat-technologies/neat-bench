#!/usr/bin/env bash
# run.sh — one-command neat-bench orchestrator.
# ─────────────────────────────────────────────────────────────────────────────
#   ./run.sh <target> <wall> [N]
#     <target>  a descriptor id under targets/ (e.g. queue-app → targets/queue-app.json)
#     <wall>    a wall-task id under walls/     (e.g. walls/<wall>.json, authored elsewhere)
#     [N]       trials per arm (default 5) — average over model nondeterminism [arms.md §protocol step 6]
#
# Pipeline:
#   1. provision the target if it has not been provisioned (no results/<target>.graph.json)
#   2. for N trials: run BOTH arms (with-NEAT, without-NEAT) on the wall,
#      randomizing arm order per trial [arms.md §protocol step 2]
#   3. score each arm run with the scorers (by path — they are authored separately):
#        harness/grounded-evidence.mjs   — grades asserted claims against the graph
#        harness/wall-certificate.mjs    — objective PASS/FAIL oracle for the wall
#        harness/claim-classifier.mjs    — graph-level static-blindness classification (exists)
#   4. aggregate into results/<target>/<wall>/summary.json
#
# Fails LOUD (never fakes a result) if: NEAT_REPO is unset/missing, a required
# scorer is missing, the target descriptor is missing, or the agent is not wired.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$REPO_ROOT/harness"
RESULTS="${RESULTS:-$REPO_ROOT/results}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "▶ $*"; }

TARGET="${1:-}"; WALL="${2:-}"; N="${3:-5}"
[ -n "$TARGET" ] && [ -n "$WALL" ] || die "usage: ./run.sh <target> <wall> [N]"

DESCRIPTOR="$REPO_ROOT/targets/$TARGET.json"
[ -f "$DESCRIPTOR" ] || die "no target descriptor at $DESCRIPTOR"

# ── fail loud: NEAT checkout under test ──────────────────────────────────────
# The version under test is a LOCAL Neat checkout (published npm under-instruments).
NEAT_REPO="${NEAT_REPO:-}"
[ -n "$NEAT_REPO" ] || die "\$NEAT_REPO is unset. neat-bench measures a LOCAL Neat checkout at HEAD (the published npm build under-instruments — no file:line OBSERVED edges). Re-run with:  NEAT_REPO=/path/to/Neat ./run.sh $TARGET $WALL ${N}"
[ -d "$NEAT_REPO" ] || die "\$NEAT_REPO ($NEAT_REPO) is not a directory."
export NEAT_REPO

# ── fail loud: scorers must exist (they are authored separately) ──────────────
# Called by path per the task. claim-classifier.mjs exists in this repo already;
# grounded-evidence.mjs + wall-certificate.mjs are being written by someone else.
GROUNDED="$HARNESS/grounded-evidence.mjs"
CERTIFICATE="$HARNESS/wall-certificate.mjs"
CLASSIFIER="$HARNESS/claim-classifier.mjs"
for s in "$GROUNDED" "$CERTIFICATE" "$CLASSIFIER"; do
  [ -f "$s" ] || die "scorer missing: $s
       run.sh calls the scorers by path; they live under harness/. claim-classifier.mjs
       ships here, but grounded-evidence.mjs and wall-certificate.mjs are authored
       separately. Add them (or symlink them) before running trials."
done

# ── 1. provision if needed ───────────────────────────────────────────────────
GRAPH="$RESULTS/$TARGET.graph.json"
if [ ! -f "$GRAPH" ]; then
  step "provisioning $TARGET (no snapshot at $GRAPH yet)"
  "$HARNESS/provision/provision.sh" "$DESCRIPTOR"
else
  echo "▶ reusing existing snapshot $GRAPH (delete it to force re-provision)"
fi
[ -f "$GRAPH" ] || die "provisioning did not produce $GRAPH"

# graph-level static-blindness classification (context for the whole run) [exists]
step "graph-level classification (claim-classifier.mjs)"
node "$CLASSIFIER" "$GRAPH" | sed 's/^/    /'

# ── 2+3. trials × arms, scored ───────────────────────────────────────────────
WALL_DIR="$RESULTS/$TARGET/$WALL"
mkdir -p "$WALL_DIR"
ARM_JSONS=()   # collect arm.json paths for aggregation

for (( t=1; t<=N; t++ )); do
  step "trial $t/$N"
  # randomize arm order per trial (coin flip) [arms.md §protocol step 2]
  if [ $(( RANDOM % 2 )) -eq 0 ]; then ORDER=(with without); else ORDER=(without with); fi
  echo "    arm order: ${ORDER[*]}"

  for arm in "${ORDER[@]}"; do
    OUT="$WALL_DIR/trial-$t/$arm"
    # run-arm.sh resets the tree, builds the identical prompt, runs the agent
    # (TODO(live) stub today), and captures edit.diff + transcript.
    set +e
    "$HARNESS/arms/run-arm.sh" "$TARGET" "$WALL" "$arm" "$t" "$OUT"
    rc=$?
    set -e
    if [ "$rc" = 42 ]; then
      die "agent is not wired (run_agent is a TODO(live) stub in harness/arms/run-arm.sh).
       No trial can be scored until run_agent invokes a real model and writes
       transcript.jsonl + edit.diff. Implement it, then re-run. (Refusing to
       fabricate a result — see the task's 'do not fake outputs' rule.)"
    fi
    [ "$rc" = 0 ] || die "run-arm.sh ($TARGET/$WALL/$arm trial $t) exited $rc"

    # ── score this arm run ───────────────────────────────────────────────────
    # NOTE: arg order below is the ASSUMED contract for the two not-yet-present
    # scorers. TODO(live): confirm/adjust once grounded-evidence.mjs and
    # wall-certificate.mjs land — align these calls with their real CLIs.
    #
    # wall-certificate.mjs — objective PASS/FAIL oracle. Assumed:
    #   node wall-certificate.mjs <walls/<wall>.json> <edit.diff> <target-app-dir>
    node "$CERTIFICATE" "$REPO_ROOT/walls/$WALL.json" "$OUT/edit.diff" "$TARGET" \
      > "$OUT/certificate.json" 2>"$OUT/certificate.err" \
      || echo "    (wall-certificate.mjs nonzero for $arm — see $OUT/certificate.err)"

    # grounded-evidence.mjs — grades the agent's asserted claims against the graph. Assumed:
    #   node grounded-evidence.mjs <graph.json> <transcript.jsonl>
    node "$GROUNDED" "$GRAPH" "$OUT/transcript.jsonl" \
      > "$OUT/grounded.json" 2>"$OUT/grounded.err" \
      || echo "    (grounded-evidence.mjs nonzero for $arm — see $OUT/grounded.err)"

    ARM_JSONS+=("$OUT/arm.json")
  done
done

# ── 4. aggregate ─────────────────────────────────────────────────────────────
step "aggregating $N trials → $WALL_DIR/summary.json"
# Merge each arm.json with its certificate/grounded scores, then group by arm.
: > "$WALL_DIR/.rows.jsonl"
for aj in "${ARM_JSONS[@]}"; do
  d="$(dirname "$aj")"
  cert="$d/certificate.json"; grd="$d/grounded.json"
  jq -s '.[0] + {certificate: (.[1] // null), grounded: (.[2] // null)}' \
     "$aj" \
     <([ -f "$cert" ] && cat "$cert" || echo null) \
     <([ -f "$grd" ]  && cat "$grd"  || echo null) \
     >> "$WALL_DIR/.rows.jsonl"
done

jq -s '{
  target: (.[0].target // null),
  wall:   (.[0].wall // null),
  trials: (map(.trial) | unique | length),
  runs: .,
  by_arm: (group_by(.arm) | map({
    key: .[0].arm,
    value: {
      n: length,
      passed: (map(select(.certificate.pass == true)) | length),
      neat_calls_mean: ((map(.tool_calls.neat) | add // 0) / (length)),
      grounded_scores: (map(.grounded))
    }
  }) | from_entries)
}' "$WALL_DIR/.rows.jsonl" > "$WALL_DIR/summary.json"
rm -f "$WALL_DIR/.rows.jsonl"

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Done: $TARGET / $WALL, $N trials × 2 arms"
echo " Summary: $WALL_DIR/summary.json"
echo "════════════════════════════════════════════════════════════════════"
jq '.by_arm' "$WALL_DIR/summary.json" 2>/dev/null || true
