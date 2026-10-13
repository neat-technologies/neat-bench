#!/usr/bin/env bash
# run-qodo.sh — QODO arm for the RESOLVE bench (diagnose AND fix).
# ─────────────────────────────────────────────────────────────────────────────
# Parallel to run-code.sh, but the agent's investigative signal is Qodo PR-Agent's
# AI code review of the fault-as-diff (qodo-review.sh) PLUS read-only source — then
# it PATCHES the recommendation source. Same model + budget as every other resolve
# arm; the only variable is the signal. Billed on our Anthropic (bench) key.
#
# Writes the fix to  ~/praxis/runs/<scenario>/qodo/src/recommendation_server.py
# so grade.sh + verify-scenario.sh grade it identically to code / obscode / neat.
#
#   run-qodo.sh <scenario> [trial] ["symptom text"]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/competitors/competitor-lib.sh"
load_creds; export_api_key

SCEN="${1:?usage: run-qodo.sh <scenario> [trial] [\"symptom\"]}"
TRIAL="${2:-1}"
SYMPTOM="${3:-Users report errors on the product / recommendation path: the storefront intermittently fails to load recommendations and the frontend returns errors. Diagnose the failing service and fix the root cause in source.}"

SRC_ROOT="${CODE_SRC_ROOT:-$HOME/opentelemetry-demo}"
REC_SRC="$SRC_ROOT/src/recommendation"
PRISTINE_REC="${FS_PRISTINE:-$HOME/otel-pristine}/src/recommendation"
RUN_DIR="$HOME/praxis/runs/${SCEN}/qodo$([ "$TRIAL" = 1 ] || echo "/trial-$TRIAL")"
SRC="$RUN_DIR/src"
MODEL="${NEAT_BENCH_MODEL:-opus}"
MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"

CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || { echo "run-qodo: claude CLI not found on PATH" >&2; exit 42; }
[ -d "$REC_SRC" ] || { echo "run-qodo: recommendation source not found at $REC_SRC" >&2; exit 1; }
[ -n "${ANTHROPIC_API_KEY:-}" ] || echo "run-qodo: WARNING no ANTHROPIC_API_KEY (bench key)" >&2

echo "[$(date +%H:%M:%S)] qodo arm (RESOLVE) — scenario $SCEN trial $TRIAL (model=$MODEL, turns=$MAX_TURNS)"

rm -rf "$RUN_DIR"; mkdir -p "$SRC"
cp -r "$REC_SRC/." "$SRC/"
cp "$SRC/recommendation_server.py" "$SRC/recommendation_server.py.orig"
# Clean baseline for Qodo's diff. The driver's $PRISTINE is DELIBERATELY polluted
# with the FAULTED source (so the code arms read faulted source like neat does). Qodo
# is a DIFF tool — give it the polluted pristine and it diffs faulted-vs-faulted = no
# signal. So build PRIST_REF = the faulted working copy, but with recommendation_server.py
# reverted to git HEAD (the true clean source; faults are injected uncommitted into the
# working tree). The diff Qodo then reviews is EXACTLY the injected fault — the fault-as-PR.
PRIST_REF="$RUN_DIR/pristine-ref"; mkdir -p "$PRIST_REF"
cp -r "$SRC/." "$PRIST_REF/" 2>/dev/null || true
rm -f "$PRIST_REF/recommendation_server.py.orig" 2>/dev/null || true
if git -C "$SRC_ROOT" show HEAD:src/recommendation/recommendation_server.py > "$PRIST_REF/recommendation_server.py" 2>/dev/null && [ -s "$PRIST_REF/recommendation_server.py" ]; then
  :   # clean recommendation_server.py from git HEAD
elif [ -s "${FS_STOCK_REC:-$HOME/praxis/seeds/healthy-recserver-bak.py}" ]; then
  cp "${FS_STOCK_REC:-$HOME/praxis/seeds/healthy-recserver-bak.py}" "$PRIST_REF/recommendation_server.py"
fi

PROMPT_FILE="$RUN_DIR/prompt.txt"
cat > "$PROMPT_FILE" <<PROMPT
You are debugging a live microservice system: the OpenTelemetry Demo (an online
storefront). Something is broken in production right now.

SYMPTOM: $SYMPTOM

Your signal is QODO — an AI code-review tool. It reviews the recommendation
service's current code against its baseline and reports issues (bugs, risky changes).
Run it with Bash:
    qodo-review.sh "$SRC" "$PRIST_REF"     # Qodo's review of what changed in the recommendation source
You also have the app SOURCE (read-only) across every service at $SRC_ROOT/src.
There is NO runtime signal and no graph — reason from Qodo's review plus the source.
If Qodo finds no code change, the fault is not in the recommendation code.

The recommendation service — the ONE you can EDIT and must PATCH — is your working
copy at this ABSOLUTE path:
    $SRC
Edit files there by absolute path, e.g. $SRC/recommendation_server.py. Do NOT edit
anything under $SRC_ROOT — that tree is read-only reference only.

YOUR TASK — diagnose AND fix:
  a) Use Qodo's review plus the source to find the faulty service, file, and exact
     line, and why.
  b) Edit the recommendation source at $SRC/recommendation_server.py (this ABSOLUTE
     path) to fix the root cause. Change as little as possible. Do not change tests.
     Do not add artificial workarounds — fix the actual defect so the service behaves
     like a correct implementation.
  c) State plainly: the faulty SERVICE, the FILE and LINE you changed, and WHY.
  d) End with a fenced block of the code facts you relied on, neutral terms only:

\`\`\`neat-evidence
[{"from":"recommendation_server.py","to":"product-catalog","kind":"calls"}]
\`\`\`
PROMPT

# PATH: competitors first (so qodo-review.sh resolves), then local bin + system.
# Mirrors run-qodo-detect.sh's tooling exactly (the append-system-prompt forbids
# neat/kubectl; _arm-extract logs any neat/kubectl hit for a post-hoc isolation check).
ARM_PATH="$HERE/competitors:$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
chmod +x "$HERE"/competitors/qodo-*.sh 2>/dev/null || true

APPEND_SYS="You are the qodo arm of an RCA benchmark: your signal is Qodo's AI code review (qodo-review.sh) plus read-only source. No runtime signal, no graph, no neat, no kubectl. Diagnose AND fix the recommendation source."

echo "[$(date +%H:%M:%S)] launching headless claude (qodo-resolve) …"
( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" QODO_CLAUDE_MODEL="${MODEL}" \
    "$CLAUDE_BIN" -p "$(cat "$PROMPT_FILE")" \
    --model "$MODEL" --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Grep,Glob,Edit,Bash" \
    --append-system-prompt "$APPEND_SYS" \
    --strict-mcp-config \
    --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages \
) > "$RUN_DIR/claude-stream.jsonl" 2> "$RUN_DIR/claude.err" || true
cp "$RUN_DIR/claude-stream.jsonl" "$RUN_DIR/transcript.jsonl"

# ── shared extract: answer, tool tally, patch, arm.json ───────────────────────
source "$HERE/_arm-extract.sh" "$RUN_DIR" "qodo" "$SCEN" "$TRIAL" "$MODEL" "$MAX_TURNS"
