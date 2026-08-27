#!/usr/bin/env bash
# _arm-extract.sh — shared post-run capture for every arm runner (code/obscode/neat).
# sourced as: source _arm-extract.sh <RUN_DIR> <arm> <scenario> <trial> <model> <max_turns>
# Reads <RUN_DIR>/claude-stream.jsonl; writes answer.txt, tool-calls.log,
# patch.diff, arm.json; echoes a one-line summary. Never a metric — tool count is
# a neutral note per SCORING.md §5.
_RD="${1:?RUN_DIR}"; _ARM="${2:?arm}"; _SCEN="${3:?scenario}"; _TRIAL="${4:-1}"; _MODEL="${5:-opus}"; _MT="${6:-40}"

# final assistant answer (terminal {"type":"result"}; fall back to last text on truncation)
python3 - "$_RD/claude-stream.jsonl" > "$_RD/answer.txt" 2>/dev/null <<'PY' || true
import sys,json
ans=""; last_asst=""
for line in open(sys.argv[1]):
    line=line.strip()
    if not line: continue
    try: o=json.loads(line)
    except: continue
    if o.get("type")=="result" and isinstance(o.get("result"),str): ans=o["result"]
    if o.get("type")=="assistant":
        for c in (o.get("message",{}).get("content") or []):
            if isinstance(c,dict) and c.get("type")=="text" and c.get("text","").strip():
                last_asst=c["text"]
print(ans if ans else last_asst)
PY

# tool-call tally with a hint of each call (command / file / pattern / tool name)
python3 - "$_RD/claude-stream.jsonl" > "$_RD/tool-calls.log" 2>/dev/null <<'PY' || true
import sys,json
for line in open(sys.argv[1]):
    try: o=json.loads(line)
    except: continue
    if o.get("type")=="assistant":
        for c in (o.get("message",{}).get("content") or []):
            if isinstance(c,dict) and c.get("type")=="tool_use":
                inp=c.get("input",{})
                hint=inp.get("command") or inp.get("file_path") or inp.get("pattern") or ""
                print(f'{c.get("name")}\t{str(hint)[:140]}')
PY
_NCALLS=$(wc -l < "$_RD/tool-calls.log" 2>/dev/null | tr -d ' ')
# cross-contamination guard: did an arm touch a tool it must not have?
_NEAT_HITS=$(grep -icE '(^|[^a-z])neat( |_|-|$)|mcp__neat' "$_RD/tool-calls.log" 2>/dev/null | head -1 || true)
_OBS_HITS=$(grep -cE 'obscode-(traces|metrics|logs)' "$_RD/tool-calls.log" 2>/dev/null | head -1 || true)
_KUBECTL_HITS=$(grep -cE '(^|[^a-z])kubectl( |$)' "$_RD/tool-calls.log" 2>/dev/null | head -1 || true)

# per-run token usage + cost from the terminal result message (stream-json)
python3 - "$_RD/claude-stream.jsonl" > "$_RD/usage.json" 2>/dev/null <<'PY' || true
import sys,json
u={"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"thinking_tokens":0,"total_tokens":0,"cost_usd":0,"num_turns":0,"duration_ms":0}
for line in open(sys.argv[1]):
    try: o=json.loads(line)
    except: continue
    if o.get("type")=="result":
        us=o.get("usage",{}) or {}
        for k in ("input_tokens","output_tokens","cache_read_input_tokens","cache_creation_input_tokens"):
            u[k]=us.get(k,0) or 0
        u["thinking_tokens"]=((us.get("output_tokens_details") or {}).get("thinking_tokens",0)) or 0
        u["cost_usd"]=o.get("total_cost_usd",0) or 0
        u["num_turns"]=o.get("num_turns",0) or 0
        u["duration_ms"]=o.get("duration_ms",0) or 0
u["total_tokens"]=u["input_tokens"]+u["output_tokens"]+u["cache_read_input_tokens"]+u["cache_creation_input_tokens"]
print(json.dumps(u))
PY
_TOKENS=$(python3 -c "import json;print(json.load(open('$_RD/usage.json'))['total_tokens'])" 2>/dev/null || echo 0)
_COST=$(python3 -c "import json;print(round(json.load(open('$_RD/usage.json'))['cost_usd'],4))" 2>/dev/null || echo 0)
_OUTTOK=$(python3 -c "import json;print(json.load(open('$_RD/usage.json'))['output_tokens'])" 2>/dev/null || echo 0)

# patch record + whether the agent actually edited the graded file
diff -u "$_RD/src/recommendation_server.py.orig" "$_RD/src/recommendation_server.py" > "$_RD/patch.diff" 2>/dev/null
_EDITED=$([ -s "$_RD/patch.diff" ] && echo true || echo false)

cat > "$_RD/arm.json" <<JSON
{
  "arm": "$_ARM",
  "scenario": "$_SCEN",
  "trial": $_TRIAL,
  "model": "$_MODEL",
  "max_turns": $_MT,
  "edited_recommendation": $_EDITED,
  "tool_calls_total": ${_NCALLS:-0},
  "neat_tool_hits": ${_NEAT_HITS:-0},
  "obs_helper_hits": ${_OBS_HITS:-0},
  "kubectl_hits": ${_KUBECTL_HITS:-0},
  "total_tokens": ${_TOKENS:-0},
  "output_tokens": ${_OUTTOK:-0},
  "cost_usd": ${_COST:-0},
  "graded_file": "$_RD/src/recommendation_server.py"
}
JSON

echo "[$(date +%H:%M:%S)] $_ARM done → $_RD"
echo "  edited=$_EDITED  tool_calls=${_NCALLS:-0}  neat_hits=${_NEAT_HITS:-0}  obs_hits=${_OBS_HITS:-0}  kubectl_hits=${_KUBECTL_HITS:-0}  tokens=${_TOKENS:-0}  cost=\$${_COST:-0}"
[ "$_EDITED" = true ] || echo "  NOTE: agent produced no source edit — inspect answer.txt / claude.err"
# isolation red flags (for the operator; the driver also checks these)
if [ "$_ARM" = "code" ] && { [ "${_NEAT_HITS:-0}" -gt 0 ] || [ "${_OBS_HITS:-0}" -gt 0 ] || [ "${_KUBECTL_HITS:-0}" -gt 0 ]; }; then
  echo "  !! ISOLATION BREACH: code arm reached neat/obs/kubectl — PATH restriction failed, invalidate this run" >&2
fi
if [ "$_ARM" = "obscode" ] && [ "${_NEAT_HITS:-0}" -gt 0 ]; then
  echo "  !! ISOLATION BREACH: obscode arm reached neat — invalidate this run" >&2
fi
