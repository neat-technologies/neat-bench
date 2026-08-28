#!/usr/bin/env bash
# run-neat-detect.sh — NEAT arm for the DETECTION bench (diagnose only, no fix).
# Full fused-graph arsenal against the live daemon; the prompt LEADS with
# `neat divergences`. Source readable; no kubectl (the graph is the runtime lens).
#   run-neat-detect.sh <scenario> [trial] ["symptom"]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN="${1:?scenario}"; TRIAL="${2:-1}"
SYMPTOM="${3:-Users report intermittent failures across the storefront: product pages, product recommendations, and/or ad banners fail to load or error out. Exactly one service is at fault.}"
SRC_ROOT="${NEAT_SRC_ROOT:-$HOME/opentelemetry-demo}"
RUN_DIR="$HOME/praxis/divruns/${SCEN}/neat$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"; MODEL="${NEAT_BENCH_MODEL:-opus}"; MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"
NEAT_PROJECT="${NEAT_BENCH_PROJECT:-default}"; export NEAT_AUTH_TOKEN="${NEAT_AUTH_TOKEN:-benchops-neat-token}"
CLAUDE_BIN="$(command -v claude || true)"; NEAT_BIN="$(command -v neat || true)"; NVM_BIN="$(dirname "$NEAT_BIN")"
[ -n "$CLAUDE_BIN" ] || { echo "no claude" >&2; exit 42; }
[ -n "$NEAT_BIN" ] || { echo "no neat" >&2; exit 43; }

echo "[$(date +%H:%M:%S)] neat-detect — scenario $SCEN trial $TRIAL (model=$MODEL, project=$NEAT_PROJECT)"
rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$SRC_ROOT/src/recommendation/." "$SRC/" 2>/dev/null || true
cp "$SRC/recommendation_server.py" "$SRC/recommendation_server.py.orig" 2>/dev/null || true

PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are diagnosing a live microservice system: the OpenTelemetry Demo storefront.
Something is broken in production right now.

SYMPTOM: $SYMPTOM

NEAT has FUSED static code (EXTRACTED) and live runtime behaviour (OBSERVED) into
one queryable graph of the running system, with provenance on every edge. Query it
with the \`neat\` CLI via Bash. ALWAYS pass --project $NEAT_PROJECT. The graph is your
PRIMARY lens — match the query to the symptom, do NOT fixate on one verb:

    neat observed-dependencies service:<svc> --project $NEAT_PROJECT   # live edges + error-rate/latency per edge — a FAILING dependency shows here
    neat incidents service:<svc> --project $NEAT_PROJECT               # runtime failures (ECONNREFUSED / timeout / deadline / 5xx), fused to code
    neat stale-edges --project $NEAT_PROJECT                           # a service/dependency that STOPPED being observed (silent / scaled away)
    neat root-cause service:<svc> --project $NEAT_PROJECT              # localized root cause + traversal
    neat divergences --project $NEAT_PROJECT                           # declared(EXTRACTED) vs observed(OBSERVED) mismatch — best for FIELD / HOST / CONTRACT faults
    neat blast-radius <node> --project $NEAT_PROJECT                   # what an observed failure reaches
    neat dependencies service:<svc> / neat search "<term>" --project $NEAT_PROJECT
Provenance tells you how much to trust each claim: OBSERVED / EXTRACTED / INFERRED /
STALE. The full app source is readable at $SRC_ROOT/src if you need to confirm a
code-grain detail the graph points you to — but the graph, not source-reading, is
how you localize.

YOUR TASK — DIAGNOSE ONLY (do NOT write a fix):
  Find the ONE faulty service and its precise root cause. As SOON as the graph has
  localized the faulty service and the nature of the fault, STOP querying/reading and
  write the diagnosis — do not keep reading source to over-confirm. End with EXACTLY
  this block:

DIAGNOSIS:
SERVICE: <the one faulty service>
ROOT CAUSE: <the specific defect and where — file/symbol, config/field/host, or the wrong/silent dependency — and which graph query surfaced it>
PROMPT

ARM_PATH="$NVM_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
APPEND_SYS="You are the neat arm of a DETECTION benchmark: lead with 'neat divergences' to surface the declared-vs-observed fault, then corroborate with root-cause / blast-radius / observed-dependencies / stale-edges / incidents. Trust claims by provenance. You are diagnosing, not fixing."
echo "[$(date +%H:%M:%S)] launching headless claude (neat-detect, full arsenal) …"
( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" --allowedTools "Read,Grep,Glob,Bash" \
    --append-system-prompt "$APPEND_SYS" --strict-mcp-config --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"
source "$HERE/_arm-extract.sh" "$RUN_DIR" "neat" "$SCEN" "$TRIAL" "$MODEL" "$MAX_TURNS"
