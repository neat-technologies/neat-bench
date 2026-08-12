#!/usr/bin/env bash
# run.sh — one-command neat-bench orchestrator.
# ─────────────────────────────────────────────────────────────────────────────
#   ./run.sh <target> <wall> [N]
#     <target>  a descriptor id under targets/ (e.g. queue-app → targets/queue-app.json)
#     <wall>    a wall-task id under walls/     (e.g. walls/<wall>.json, authored elsewhere)
#     [N]       trials per arm (default 5) — average over model nondeterminism [arms.md §protocol step 6]
#
# Pipeline:
#   1. provision the target if not already provisioned (no results/<target>.graph.json)
#   2. classify the graph once (claim-classifier.mjs) — static-blindness context
#   3. CERTIFY the wall once (wall-certificate.mjs) — is it a genuine wall (answer
#      absent from source, present as a BLIND observed edge)? A loud gate, not a hard stop.
#   4. for N trials: run BOTH arms (with-NEAT, without-NEAT), randomizing arm order
#      per trial [arms.md §protocol step 2]
#   5. score each arm with grounded-evidence.mjs (the keystone metric — % of the
#      agent's load-bearing claims that trace to something real, + sufficiency)
#   6. aggregate into results/<target>/<wall>/summary.json
#
# Scorers are called BY PATH under harness/ (claim-classifier.mjs ships here;
# grounded-evidence.mjs + wall-certificate.mjs are authored separately). Their real
# CLIs (confirmed from the files):
#   claim-classifier.mjs   <graph.json>
#   wall-certificate.mjs   <wall.json> <graph.json> [--source-dir <dir>]
#   grounded-evidence.mjs  <graph.json> <claims.json> [--require <wall.json>]
# These emit human-readable text + an exit code (they are library-first: the JSON
# lives in their exported functions). We capture full output to files, use exit
# codes, and parse the one headline line for the summary.
#   TODO(live): for richer machine aggregation, import the exported functions
#   (certifyWall / scoreGroundedEvidence) via a small node evaluator to get JSON.
#
# Fails LOUD (never fakes a result) if: NEAT_REPO unset/missing, a scorer missing,
# the descriptor missing, or the agent is not wired (run_agent stub → sentinel 42).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$REPO_ROOT/harness"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "▶ $*"; }

TGT="${1:-}"; WALL="${2:-}"; N="${3:-5}"
[ -n "$TGT" ] && [ -n "$WALL" ] || die "usage: ./run.sh <target> <wall> [N]"
for bin in node jq curl git; do command -v "$bin" >/dev/null || die "missing required binary: $bin"; done

DESCRIPTOR="$REPO_ROOT/targets/$TGT.json"
[ -f "$DESCRIPTOR" ] || die "no target descriptor at $DESCRIPTOR"
WALL_FILE="$REPO_ROOT/walls/$WALL.json"
[ -f "$WALL_FILE" ] || die "no wall at $WALL_FILE (walls are authored outside this scaffold)"

# ── fail loud: NEAT checkout under test ──────────────────────────────────────
# The version under test is a LOCAL Neat checkout (published npm under-instruments).
NEAT_REPO="${NEAT_REPO:-}"
[ -n "$NEAT_REPO" ] || die "\$NEAT_REPO is unset. neat-bench measures a LOCAL Neat checkout at HEAD (the published npm build under-instruments — no file:line OBSERVED edges). Re-run with:  NEAT_REPO=/path/to/Neat ./run.sh $TGT $WALL ${N}"
[ -d "$NEAT_REPO" ] || die "\$NEAT_REPO ($NEAT_REPO) is not a directory."
export NEAT_REPO

# ── fail loud: scorers must exist (called by path; authored separately) ───────
GROUNDED="$HARNESS/grounded-evidence.mjs"
CERTIFICATE="$HARNESS/wall-certificate.mjs"
CLASSIFIER="$HARNESS/claim-classifier.mjs"
for s in "$GROUNDED" "$CERTIFICATE" "$CLASSIFIER"; do
  [ -f "$s" ] || die "scorer missing: $s
       run.sh calls the scorers by path; they live under harness/. claim-classifier.mjs
       ships here, but grounded-evidence.mjs and wall-certificate.mjs are authored
       separately. Add them (or symlink them) before running trials."
done

# Reuse the provisioner's descriptor loader for the single source of truth on
# paths (APP_DIR, GRAPH_OUT, SVC, D). It defines its own die/step (same semantics).
source "$HARNESS/provision/lib.sh"
load_descriptor "$DESCRIPTOR"
GRAPH="$GRAPH_OUT"

# ── 1. provision if needed ───────────────────────────────────────────────────
if [ ! -f "$GRAPH" ]; then
  step "provisioning $TGT (no snapshot at $GRAPH yet)"
  "$HARNESS/provision/provision.sh" "$DESCRIPTOR"
else
  echo "▶ reusing existing snapshot $GRAPH (delete it to force re-provision)"
fi
[ -f "$GRAPH" ] || die "provisioning did not produce $GRAPH"

WALL_DIR="$RESULTS/$TGT/$WALL"
mkdir -p "$WALL_DIR"

# ── 2. graph-level static-blindness classification (context) [exists] ─────────
step "graph-level classification (claim-classifier.mjs)"
node "$CLASSIFIER" "$GRAPH" | tee "$WALL_DIR/classification.txt" | sed 's/^/    /'

# ── 3. certify the wall once (is it a genuine wall?) ─────────────────────────
step "certifying the wall (wall-certificate.mjs) against the graph + pinned source"
set +e
node "$CERTIFICATE" "$WALL_FILE" "$GRAPH" --source-dir "$APP_DIR" | tee "$WALL_DIR/certificate.txt"
CERT_RC=${PIPESTATUS[0]}
set -e
CERTIFIED=$([ "$CERT_RC" = 0 ] && echo true || echo false)
if [ "$CERTIFIED" != true ]; then
  echo "  WARNING: wall '$WALL' is NOT certified as a genuine wall (see above)." >&2
  echo "           Trials will still run, but the arms may not separate on it." >&2
fi

# ── 4+5. trials × arms, each scored with grounded-evidence ───────────────────
: > "$WALL_DIR/.rows.jsonl"
for (( t=1; t<=N; t++ )); do
  step "trial $t/$N"
  # randomize arm order per trial (coin flip) [arms.md §protocol step 2]
  if [ $(( RANDOM % 2 )) -eq 0 ]; then ORDER=(with without); else ORDER=(without with); fi
  echo "    arm order: ${ORDER[*]}"

  for arm in "${ORDER[@]}"; do
    OUT="$WALL_DIR/trial-$t/$arm"
    # run-arm.sh resets the tree, builds the identical prompt, runs the agent
    # (TODO(live) stub today), and captures transcript.jsonl, claims.json, edit.diff.
    set +e
    "$HARNESS/arms/run-arm.sh" "$TGT" "$WALL" "$arm" "$t" "$OUT"
    rc=$?
    set -e
    if [ "$rc" = 42 ]; then
      die "agent is not wired (run_agent is a TODO(live) stub in harness/arms/run-arm.sh).
       No trial can be scored until run_agent invokes a real model and writes
       transcript.jsonl + claims.json + edit.diff. Implement it, then re-run.
       (Refusing to fabricate a result — see the task's 'do not fake outputs' rule.)"
    fi
    [ "$rc" = 0 ] || die "run-arm.sh ($TGT/$WALL/$arm trial $t) exited $rc"

    # grounded-evidence: % of the arm's load-bearing claims that trace to something
    # real, plus sufficiency against the wall's required facts. [keystone metric]
    set +e
    node "$GROUNDED" "$GRAPH" "$OUT/claims.json" --require "$WALL_FILE" \
      | tee "$OUT/grounded.txt"
    GRD_RC=${PIPESTATUS[0]}
    set -e
    [ "$GRD_RC" = 0 ] || echo "    (grounded-evidence.mjs exited $GRD_RC for $arm — see $OUT/grounded.txt)"

    # parse the two headline facts from the scorer's text output (documented above).
    RATE="$(grep -o 'GROUNDED-EVIDENCE RATE (headline): [0-9.]*' "$OUT/grounded.txt" 2>/dev/null | grep -o '[0-9.]*$' | head -1)"; RATE="${RATE:-0}"
    if   grep -q 'SUFFICIENCY: PASS' "$OUT/grounded.txt" 2>/dev/null; then SUFF=true
    elif grep -q 'SUFFICIENCY: FAIL' "$OUT/grounded.txt" 2>/dev/null; then SUFF=false
    else SUFF=null; fi

    NEAT_CALLS="$(jq -r '.tool_calls.neat // 0' "$OUT/arm.json")"
    WIRED="$(jq -r '.agent_wired' "$OUT/arm.json")"
    jq -n --arg arm "$arm" --argjson trial "$t" --argjson rate "$RATE" \
          --argjson suff "$SUFF" --argjson neat "$NEAT_CALLS" --argjson wired "$WIRED" \
      '{arm:$arm, trial:$trial, grounded_rate:$rate, sufficient:$suff, neat_calls:$neat, agent_wired:$wired}' \
      >> "$WALL_DIR/.rows.jsonl"
  done
done

# ── 6. aggregate ─────────────────────────────────────────────────────────────
step "aggregating $N trials → $WALL_DIR/summary.json"
jq -s --arg target "$TGT" --arg wall "$WALL" --argjson certified "$CERTIFIED" '{
  target: $target,
  wall: $wall,
  wall_certified: $certified,
  trials: (map(.trial) | unique | length),
  runs: .,
  by_arm: (group_by(.arm) | map({
    key: .[0].arm,
    value: {
      n: length,
      grounded_rate_mean: ((map(.grounded_rate) | add // 0) / length),
      sufficiency_pass: (map(select(.sufficient == true)) | length),
      neat_calls_mean: ((map(.neat_calls) | add // 0) / length)
    }
  }) | from_entries)
}' "$WALL_DIR/.rows.jsonl" > "$WALL_DIR/summary.json"
rm -f "$WALL_DIR/.rows.jsonl"

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Done: $TGT / $WALL, $N trials × 2 arms   (wall_certified=$CERTIFIED)"
echo " Summary: $WALL_DIR/summary.json"
echo "════════════════════════════════════════════════════════════════════"
jq '{wall_certified, by_arm}' "$WALL_DIR/summary.json" 2>/dev/null || true
