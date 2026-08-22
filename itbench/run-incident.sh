#!/usr/bin/env bash
# itbench/run-incident.sh — run one arm of the ITBench RCA ladder on one scenario.
#   run-incident.sh <neat|obscode|obs> <scenario-dir> <root-cause-regex>
#
# Arms mirror PRAXIS's baselines:
#   neat    = otel-demo source (cwd) + NEAT fused graph over MCP + graph-first guidance
#   obscode = otel-demo source (cwd) + raw snapshot observability files (--add-dir), NO graph  [PRAXIS SRE-Agent+CT]
#   obs     = raw snapshot files only, no source                                              [PRAXIS SRE-Agent]
# Same model. Scored RCI Pass@1: did the final "ROOT CAUSE:" name the ground-truth entity.
set -uo pipefail
ARM="${1:?arm: neat|obscode|obs}"; SCEN="${2:?scenario dir}"; RC_REGEX="${3:?root-cause regex e.g. load.?gener}"
NEAT="${NEAT_DIR:-$HOME/Documents/GitHub/Untitled/Neat}"; SRC="$HOME/Documents/GitHub/otel-demo-target"; NB="$HOME/Documents/GitHub/neat-bench"
DAEMON="${NEAT_ITBENCH_DAEMON:-http://127.0.0.1:8091}"
MODEL="${NEAT_BENCH_MODEL:-sonnet}"; MAXT="${NEAT_BENCH_MAX_TURNS:-40}"
# `ask` leads — it's the front door GRAPH_FIRST.md tells the agent to reach for first (ADR-198).
NEAT_TOOLS="ask,get_root_cause,get_blast_radius,get_observed_dependencies,get_dependencies,get_incident_history,get_divergences,semantic_search,get_graph_diff,get_recent_stale_edges,check_policies"
OUT="$NB/results/itbench-$(basename "$SCEN")-$ARM"; rm -rf "$OUT"; mkdir -p "$OUT"

PROMPT="You are an SRE investigating an incident in the OpenTelemetry Demo (\"otel-demo\") microservices system. Its source code is in the current directory (./).

Alerts firing: the \`frontend-proxy\` service has RequestErrorRate and RequestLatency above threshold — elevated error rate and latency.

Investigate and determine the ROOT-CAUSE service or entity (the single thing whose fault is causing these alerts) and briefly explain the cause. End your answer with exactly one line:
ROOT CAUSE: <service-or-entity-name>"

# Per-scenario symptom override (default above is Scenario-1's overload alert).
PROMPT="${NEAT_INCIDENT_PROMPT:-$PROMPT}"

allow="Read,Grep,Glob,Bash"; extra=()
case "$ARM" in
  neat)
    allow="$allow,$NEAT_TOOLS"
    MCP="$OUT/neat.mcp.json"
    printf '{"mcpServers":{"neat":{"type":"stdio","command":"node","args":["%s/packages/mcp/dist/index.cjs"],"env":{"NEAT_CORE_URL":"%s"}}}}' "$NEAT" "$DAEMON" > "$MCP"
    extra=(--mcp-config "$MCP" --append-system-prompt "$(cat "$NEAT/packages/claude-skill/GRAPH_FIRST.md")")
    WD="$SRC" ;;
  obscode) extra=(--add-dir "$SCEN"); WD="$SRC" ;;   # code + raw observability, no graph
  obs)     WD="$SCEN" ;;                              # observability only
esac

( cd "$WD" && claude -p "$PROMPT" --model "$MODEL" --max-turns "$MAXT" \
    --allowedTools "$allow" "${extra[@]}" --strict-mcp-config --dangerously-skip-permissions \
    --output-format stream-json --verbose --include-partial-messages ) > "$OUT/stream.jsonl" 2> "$OUT/err"

node "$NB/harness/arms/parse-claude-stream.mjs" "$OUT/stream.jsonl" --neat-tools "$NEAT_TOOLS" > "$OUT/metrics.json" 2>/dev/null || echo '{}' > "$OUT/metrics.json"
ANS="$(jq -r '.answer // ""' "$OUT/metrics.json")"; printf '%s' "$ANS" > "$OUT/answer.txt"
RCLINE="$(printf '%s' "$ANS" | grep -i 'ROOT CAUSE' | tail -1)"
RCI=$(printf '%s' "$RCLINE" | grep -qiE "$RC_REGEX" && echo PASS || echo FAIL)
printf 'arm=%-8s RCI=%s neat_calls=%s turns=%s out_tok=%s cost=%s\n' "$ARM" "$RCI" \
  "$(jq -r '.neat_calls' "$OUT/metrics.json")" "$(jq -r '.num_turns' "$OUT/metrics.json")" \
  "$(jq -r '.tokens.output' "$OUT/metrics.json")" "$(jq -r '.total_cost_usd' "$OUT/metrics.json")"
echo "  $RCLINE"
