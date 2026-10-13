#!/usr/bin/env bash
# run-flagfix.sh <arm> <scenario> <flagKey> [model] — flag-fault RESOLVE. The agent
# DIAGNOSES then REMEDIATES by calling the scoped `fix-flag.sh` tool. arm=neat (MCP
# graph) or arm=code (source-only baseline). The driver injects before + verifies after.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
set -a; . "$HOME/.bench-key" 2>/dev/null; set +a
ARM="${1:?arm}"; SCEN="${2:?scen}"; FLAG="${3:?flagKey}"; MODEL="${4:-${NEAT_BENCH_MODEL:-opus}}"
MAX_TURNS="${NEAT_BENCH_MAX_TURNS:-40}"
RUN_DIR="${ARM_RUN_DIR:-$HOME/praxis/runs/itbres-$SCEN/$ARM-$MODEL}"; SRC="$RUN_DIR/src"
SRC_ROOT="$HOME/opentelemetry-demo"
CLAUDE_BIN="$(command -v claude || true)"; NEAT_BIN="$(command -v neat || true)"; NVM_BIN="$(dirname "$NEAT_BIN")"
[ -n "$CLAUDE_BIN" ] || { echo "no claude" >&2; exit 42; }
rm -rf "$RUN_DIR"; mkdir -p "$SRC"
echo "[$(date +%H:%M:%S)] flagfix — scen $SCEN arm $ARM flag $FLAG (model=$MODEL)"

read -r -d '' PROMPT <<PROMPT || true
You are an on-call engineer for the OpenTelemetry Demo storefront. A fault is active
in production RIGHT NOW and you must RESOLVE it.

SYMPTOM: Users report failures on the storefront (errors on product, cart, checkout,
ad, or payment paths). Exactly one fault is active.

Your job: DIAGNOSE the faulty service and root cause, THEN REMEDIATE it so the fault
clears. One common fault class is a feature flag being served in a state that differs
from what the code commits (e.g. a *Failure flag turned on in production). When that is
the cause, remediate by running this tool in Bash:

    fix-flag.sh <flagKey> <committedVariant>

The committed/correct variant of a fault-injection flag is its non-failing value —
almost always "off". Example: fix-flag.sh cartFailure off

Diagnose first, then APPLY the fix (actually run fix-flag.sh — do not just describe it).
End with EXACTLY:
DIAGNOSIS:
SERVICE: <the one faulty service>
ROOT CAUSE: <the flag/defect and where>
FIX APPLIED: <the exact fix-flag.sh command you ran, or "none">
PROMPT

if [ "$ARM" = neat ]; then
  export NEAT_CORE_URL="${NEAT_CORE_URL:-http://localhost:8098}"
  export NEAT_AUTH_TOKEN="${NEAT_AUTH_TOKEN:-benchops-neat-token}"
  export NEAT_CORE_TOKEN="${NEAT_CORE_TOKEN:-benchops-neat-token}"
  cp -r "$SRC_ROOT/src/recommendation/." "$SRC/" 2>/dev/null || true
  ( cd "$SRC" && NEAT_CORE_URL="$NEAT_CORE_URL" neat claude install >/dev/null 2>&1 ) || true
  GLOBAL_MCP="$(npm root -g)/@neat.is/mcp"
  MCP_CFG="$RUN_DIR/mcp.json"
  cat > "$MCP_CFG" <<JSON
{"mcpServers":{"neat":{"type":"stdio","command":"node","args":["$GLOBAL_MCP/dist/index.cjs"],"env":{"NEAT_CORE_URL":"$NEAT_CORE_URL","NEAT_AUTH_TOKEN":"$NEAT_AUTH_TOKEN","NEAT_CORE_TOKEN":"$NEAT_CORE_TOKEN"}}}}
JSON
  # PATH: harness (fix-flag.sh) + nvm + local bin. fix-flag runs its own kubectl.
  ARM_PATH="$HERE:$NVM_BIN:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
  ( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" \
      NEAT_CORE_URL="$NEAT_CORE_URL" NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" NEAT_CORE_TOKEN="$NEAT_CORE_TOKEN" ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
      "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --max-turns "$MAX_TURNS" \
      --allowedTools "Read,Grep,Glob,Bash,mcp__neat__*" --mcp-config "$MCP_CFG" \
      --strict-mcp-config --dangerously-skip-permissions \
      --output-format stream-json --verbose ) > "$RUN_DIR/stream.jsonl" 2> "$RUN_DIR/err" || true
else
  # code: source-only. fix-flag.sh reachable (scoped tool) but NO neat, NO direct kubectl.
  cp -r "$SRC_ROOT/src/." "$SRC/" 2>/dev/null || true
  ARM_PATH="$HERE:/usr/local/bin:/usr/bin:/bin"
  APPEND="You are the code arm: raw SOURCE only, no runtime signal and no graph, no neat. You may remediate with fix-flag.sh if you can determine the fault from source."
  ( cd "$SRC" && env -u NODE_OPTIONS PATH="$ARM_PATH" ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
      "$CLAUDE_BIN" -p "$PROMPT" --model "$MODEL" --max-turns "$MAX_TURNS" \
      --allowedTools "Read,Grep,Glob,Bash" --append-system-prompt "$APPEND" \
      --strict-mcp-config --dangerously-skip-permissions \
      --output-format stream-json --verbose ) > "$RUN_DIR/stream.jsonl" 2> "$RUN_DIR/err" || true
fi

# record final answer + whether fix-flag was called
python3 - "$RUN_DIR/stream.jsonl" > "$RUN_DIR/answer.txt" 2>/dev/null <<'PY' || true
import sys, json
ans = ""; last = ""
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except: continue
    if o.get("type") == "result" and isinstance(o.get("result"), str): ans = o["result"]
    if o.get("type") == "assistant":
        for c in (o.get("message", {}).get("content") or []):
            if isinstance(c, dict) and c.get("type") == "text" and c.get("text", "").strip(): last = c["text"]
print(ans or last)
PY
# token/cost from the terminal result message
python3 - "$RUN_DIR/stream.jsonl" > "$RUN_DIR/usage.json" 2>/dev/null <<'PY' || true
import sys, json
u = {"total_tokens": 0, "cost_usd": 0}
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except: continue
    if o.get("type") == "result":
        us = o.get("usage", {}) or {}
        u["total_tokens"] = sum(us.get(k, 0) or 0 for k in ("input_tokens","output_tokens","cache_read_input_tokens","cache_creation_input_tokens"))
        u["cost_usd"] = round(o.get("total_cost_usd", 0) or 0, 4)
print(json.dumps(u))
PY
grep -qE "fix-flag\.sh +$FLAG" "$RUN_DIR/stream.jsonl" 2>/dev/null && echo "CALLED_FIXFLAG=YES" > "$RUN_DIR/acted" || echo "CALLED_FIXFLAG=NO" > "$RUN_DIR/acted"
cat "$RUN_DIR/acted"
