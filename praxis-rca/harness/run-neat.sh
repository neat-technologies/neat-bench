#!/usr/bin/env bash
# run-neat.sh — the NEAT arm runner for PRAXIS Code-Cloud-RCA (±NEAT bench).
# ─────────────────────────────────────────────────────────────────────────────
# neat = THE JOIN: one fresh headless Claude Opus with raw SOURCE access AND
#   NEAT's full fused graph arsenal against the LIVE `neat watch` daemon —
#   divergences, blast-radius, observed-dependencies, root-cause, incidents,
#   search, stale-edges, diff, dependencies — the same code + runtime signals
#   obscode gets, but FUSED into one queryable graph. Same model + budget.
#
# Writes the fix to ~/praxis/runs/<scenario>/neat[/trial-N]/src/recommendation_server.py.
#
#   run-neat.sh <scenario> [trial] ["symptom text"]
#
# ISOLATION: the neat CLI is on PATH (it is the arm's tool); the daemon endpoint
# comes from ~/.neat/daemons/default.json. No kubectl (the graph subsumes cluster
# inspection). VALIDATE the arsenal is reachable with a --max-turns 3 dry-run.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCEN="${1:?usage: run-neat.sh <scenario> [trial] [\"symptom\"]}"
TRIAL="${2:-1}"
SYMPTOM="${3:-Users report errors on the product / recommendation path: the storefront intermittently fails to load recommendations and the frontend returns errors. Diagnose the failing service and fix the root cause in source.}"

SRC_ROOT="${NEAT_SRC_ROOT:-$HOME/opentelemetry-demo}"
REC_SRC="$SRC_ROOT/src/recommendation"
RUN_DIR="$HOME/praxis/runs/${SCEN}/neat$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"
MODEL="${NEAT_BENCH_MODEL:-opus}"
MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"
NEAT_PROJECT="${NEAT_BENCH_PROJECT:-default}"
export NEAT_AUTH_TOKEN="${NEAT_AUTH_TOKEN:-benchops-neat-token}"

CLAUDE_BIN="$(command -v claude || true)"
NEAT_BIN="$(command -v neat || true)"
NVM_BIN="$(dirname "$NEAT_BIN")"
[ -n "$CLAUDE_BIN" ] || { echo "run-neat: claude CLI not found on PATH" >&2; exit 42; }
[ -n "$NEAT_BIN" ] || { echo "run-neat: neat CLI not found on PATH" >&2; exit 43; }
[ -d "$REC_SRC" ] || { echo "run-neat: recommendation source not found at $REC_SRC" >&2; exit 1; }

# sanity: the live daemon must answer before we spend a run against it
if ! neat ask "ping" --project "$NEAT_PROJECT" >/dev/null 2>&1; then
  if ! curl -s -m5 -H "Authorization: Bearer $NEAT_AUTH_TOKEN" http://localhost:8098/health >/dev/null 2>&1; then
    echo "run-neat: WARNING — live neat daemon on :8098 not answering; the neat arm needs it (restand first)" >&2
  fi
fi

echo "[$(date +%H:%M:%S)] neat arm — scenario $SCEN trial $TRIAL (model=$MODEL, turns=$MAX_TURNS, project=$NEAT_PROJECT)"

rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$REC_SRC/." "$SRC/"
cp "$SRC/recommendation_server.py" "$SRC/recommendation_server.py.orig"

PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are debugging a live microservice system: the OpenTelemetry Demo (an online
storefront). Something is broken in production right now.

SYMPTOM: $SYMPTOM

You have TWO things, and NEAT has already FUSED them into one queryable graph of
the running system — static code (EXTRACTED) and live runtime behaviour
(OBSERVED) joined on the same nodes, with provenance on every edge.

1) SOURCE CODE. Read the whole app (read-only reference) at:
     $SRC_ROOT/src
   The recommendation service — the ONE you EDIT and must PATCH — is your working
   copy at this ABSOLUTE path:
     $SRC
   Edit files there by absolute path, e.g. $SRC/recommendation_server.py. Do NOT
   edit anything under $SRC_ROOT — that tree is read-only reference only.

2) NEAT — the fused graph, via the \`neat\` CLI (run with Bash). ALWAYS pass
   --project $NEAT_PROJECT. LEAD WITH THE GRAPH, do not just eyeball one error:
     neat-card.sh <svc>                                       # composed WORK-ORDER for the latest incident on <svc>: root cause + causal chain (per-hop provenance) + code locus (file:line) + blast radius — read this first
     neat root-cause service:<svc> --project $NEAT_PROJECT     # localized root cause + traversal
     neat divergences --project $NEAT_PROJECT                  # declared(EXTRACTED) vs observed(OBSERVED) mismatch, down to symbol/field
     neat blast-radius <node> --project $NEAT_PROJECT          # what an observed failure reaches, transitively
     neat observed-dependencies service:<svc> --project $NEAT_PROJECT   # live runtime edges + error/latency per edge
     neat incidents service:<svc> --project $NEAT_PROJECT      # recorded runtime failures (fused to code where known)
     neat stale-edges --project $NEAT_PROJECT                  # dependencies that went silent
     neat search "<term>" --project $NEAT_PROJECT              # semantic search over the fused graph (find the code node)
     neat dependencies service:<svc> --project $NEAT_PROJECT   # transitive declared edges
     neat diff --against healthy --project $NEAT_PROJECT       # TIME-TRAVEL: what changed vs the healthy baseline snapshot
     neat policies --project $NEAT_PROJECT                     # policy violations across the fused graph
   Provenance tells you how much to trust each claim: OBSERVED (seen via OTel),
   EXTRACTED (from source), INFERRED (stitched), STALE (went quiet).

YOUR TASK — diagnose AND fix:
  a) Reason OVER THE GRAPH: find the failing service + the code-grain root cause
     and its blast radius. A runtime failure joined to the declared code access
     is the point — use divergence / observed-deps / blast-radius, not just a
     root-cause error string. Then read the SOURCE at the located file:line.
  b) Edit the recommendation source at $SRC/recommendation_server.py (this ABSOLUTE
     path — not a relative ./ path, since you may cd elsewhere to run neat) to fix
     the root cause. Change as little as possible. No tests, no artificial
     workarounds — fix the real defect.
  c) State plainly: the faulty SERVICE, the FILE and LINE you changed, WHY, and
     which graph queries + provenance led you there.
  d) End with a fenced block of the fused facts you relied on, neutral terms:

\`\`\`neat-evidence
[{"from":"recommendation_server.py","to":"product-catalog","kind":"calls"}]
\`\`\`
PROMPT

# ── PATH: nvm bin (for neat + claude self-launch) + system. No ~/.local/bin
#    (no kubectl) — the graph is the neat arm's runtime lens, not the cluster. ──
chmod +x "$HERE/neat-card.sh" 2>/dev/null || true
ARM_PATH="$HERE:$NVM_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

APPEND_SYS="You are the neat arm of an RCA benchmark: raw source PLUS NEAT's fused code+runtime graph. Lead with graph reasoning (neat divergences / blast-radius / observed-dependencies / root-cause) to localize the code-grain root cause; trust claims by provenance. The graph fuses what code-only and obs-only agents must stitch by hand."

echo "[$(date +%H:%M:%S)] launching headless claude (neat, full arsenal) …"
( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Grep,Glob,Edit,Bash" \
    --append-system-prompt "$APPEND_SYS" \
    --strict-mcp-config \
    --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"

source "$HERE/_arm-extract.sh" "$RUN_DIR" "neat" "$SCEN" "$TRIAL" "$MODEL" "$MAX_TURNS"
# neat arm should actually USE neat — flag if it never called the arsenal
_NHITS=$(grep -icE '(^|[^a-z])neat ' "$RUN_DIR/tool-calls.log" 2>/dev/null || echo 0)
[ "${_NHITS:-0}" -gt 0 ] || echo "  NOTE: neat arm made no neat CLI calls — under-used arsenal, run may be invalid (CONTRACT rule 6)"
