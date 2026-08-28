#!/usr/bin/env bash
# run-code.sh — the CODE arm runner for PRAXIS Code-Cloud-RCA (±NEAT bench).
# ─────────────────────────────────────────────────────────────────────────────
# code = the FLOOR: one fresh headless Claude Opus with raw SOURCE access only
#   (Read/Grep/Glob/Edit/Bash) and NOTHING else — no observability, no neat, no
#   graph. Same model + budget as every other arm; the only variable is tooling.
#
# Writes the agent's fix to  ~/praxis/runs/<scenario>/code[/trial-N]/src/recommendation_server.py
# so grade-fix.sh / verify-405.sh grade it identically to obscode / neat.
#
#   run-code.sh <scenario> [trial] ["symptom text"]
#
# ISOLATION (VALIDATE on box-return via a --max-turns 3 dry-run): the headless
# agent is launched with a restricted PATH that contains NEITHER the nvm bin
# (where `neat` lives) NOR ~/.local/bin (where `kubectl` lives). So the code
# arm's Bash genuinely cannot reach neat or the cluster — source only. `claude`
# is resolved to its absolute path BEFORE restricting so it still launches (its
# shebang re-execs node by absolute path).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCEN="${1:?usage: run-code.sh <scenario> [trial] [\"symptom\"]}"
TRIAL="${2:-1}"
SYMPTOM="${3:-Users report errors on the product / recommendation path: the storefront intermittently fails to load recommendations and the frontend returns errors. Diagnose the failing service and fix the root cause in source.}"

SRC_ROOT="${CODE_SRC_ROOT:-$HOME/opentelemetry-demo}"
REC_SRC="$SRC_ROOT/src/recommendation"
RUN_DIR="$HOME/praxis/runs/${SCEN}/code$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"
MODEL="${NEAT_BENCH_MODEL:-opus}"
MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"

CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || { echo "run-code: claude CLI not found on PATH" >&2; exit 42; }
[ -d "$REC_SRC" ] || { echo "run-code: recommendation source not found at $REC_SRC" >&2; exit 1; }

echo "[$(date +%H:%M:%S)] code arm — scenario $SCEN trial $TRIAL (model=$MODEL, turns=$MAX_TURNS)"

rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$REC_SRC/." "$SRC/"
cp "$SRC/recommendation_server.py" "$SRC/recommendation_server.py.orig"

PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are debugging a live microservice system: the OpenTelemetry Demo (an online
storefront). Something is broken in production right now.

SYMPTOM: $SYMPTOM

You have ONE signal: the SOURCE CODE of the whole app, read-only, at
    $SRC_ROOT/src
Read and grep freely across every service. The recommendation service — the ONE
you can EDIT and must PATCH — is your working copy at this ABSOLUTE path:
    $SRC
Edit files there by absolute path, e.g. $SRC/recommendation_server.py. Do NOT
edit anything under $SRC_ROOT — that tree is read-only reference only.

You have NO runtime signal — no traces, no metrics, no logs, no graph. Reason
from the code alone.

YOUR TASK — diagnose AND fix:
  a) Read the source to find the faulty service, file, and exact line, and why.
  b) Edit the recommendation source at $SRC/recommendation_server.py (this ABSOLUTE
     path) to fix the root cause. Change as little as possible. Do not change
     tests. Do not add artificial workarounds — fix the actual defect so the
     service behaves like a correct implementation.
  c) State plainly: the faulty SERVICE, the FILE and LINE you changed, and WHY.
  d) End with a fenced block of the code facts you relied on, neutral terms only:

\`\`\`neat-evidence
[{"from":"recommendation_server.py","to":"product-catalog","kind":"calls"}]
\`\`\`
PROMPT

# ── restricted PATH: system dirs only. No nvm bin (no neat), no ~/.local/bin (no
#    kubectl). python3/git/grep/etc. live in /usr/bin. VALIDATE with a dry-run. ──
ARM_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

APPEND_SYS="You are the code arm of an RCA benchmark: raw source ONLY, no runtime signal and no graph. Reason from the code. There are no observability helpers and no neat — do not attempt to call them."

echo "[$(date +%H:%M:%S)] launching headless claude (code, restricted PATH) …"
( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Grep,Glob,Edit,Bash" \
    --append-system-prompt "$APPEND_SYS" \
    --strict-mcp-config \
    --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"

# ── shared extract: answer, tool tally, patch, arm.json ───────────────────────
source "$HERE/_arm-extract.sh" "$RUN_DIR" "code" "$SCEN" "$TRIAL" "$MODEL" "$MAX_TURNS"
