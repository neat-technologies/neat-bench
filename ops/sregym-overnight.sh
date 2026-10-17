#!/usr/bin/env bash
# sregym-overnight.sh — the SREGym smoke: same agent, base arm vs NEAT arm, k=1 per call.
#
# The NEAT arm is the product as a user gets it: before EVERY attempt neat-arm-prep.sh puts a
# fresh daemon on the app's own source (`neat init` + `neat claude install`), points the k8s
# connector at its namespace, and builds the base arm's pristine copy. The agent runs in its
# arm's tree with an identical instruction; the NEAT arm gets the full mcp__neat__* surface.
# Problems: SREGym's order, restricted to apps whose source the box has, then TAKE of every
# BLOCK (Deniz: "do 2 then skip to the next block of 5"). Both arms per problem before moving on.
#
# Env: NEAT_AUTH_TOKEN (required), NEAT_VERSION (manifest), MODELS (space-separated, default
# claude-sonnet-5-5), AGENT_TIMEOUT (600), BASELINE (180: OBSERVED edges need traffic),
# PROPAGATION (60), STAGES, BLOCK (5), TAKE (2), MAX_PROBLEMS (0 = all), ONLY (problem ids).
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
: "${NEAT_AUTH_TOKEN:?NEAT_AUTH_TOKEN required}"
export NEAT_CORE_URL="${NEAT_CORE_URL:-http://localhost:8098}"
MODELS="${MODELS:-${MODEL:-claude-sonnet-5-5}}"; AGENT_TIMEOUT="${AGENT_TIMEOUT:-600}"
BASELINE="${BASELINE:-180}"; PROPAGATION="${PROPAGATION:-60}"; STAGES="${STAGES:-diagnosis mitigation}"
ARMS="${ARMS:-claudecode-vanilla claudecode-base claudecode-neat}"; BLOCK="${BLOCK:-5}"; TAKE="${TAKE:-2}"; MAX_PROBLEMS="${MAX_PROBLEMS:-0}"; ONLY="${ONLY:-}"
ROOT="$HOME/SREGym"; OPS="$HOME/neat-bench-ops"; RUN="$HOME/sregym-bench/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$RUN"
export NEAT_MCP_BIN="$(command -v neat-mcp || echo "$(npm root -g)/@neat.is/mcp/dist/index.cjs")"
export NEAT_MCP_CALL="$OPS/neat-mcp-call.py"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUN/launcher.log"; }
kubectl config use-context kind-kind >/dev/null
bash "$OPS/fix-kind-bridge.sh" >> "$RUN/launcher.log" 2>&1

cd "$ROOT"
git checkout -q agents.yaml clients/claudecode/claudecode_agent.py
python3 "$OPS/sregym-bench-patch.py" "$ROOT" | tee -a "$RUN/launcher.log"

if [ -n "$ONLY" ]; then .venv/bin/python "$OPS/sregym-problem-app.py" $ONLY > "$RUN/problem-apps.txt"
else .venv/bin/python "$OPS/sregym-problem-app.py" > "$RUN/problem-apps.txt"; fi
awk '$4 != "-"' "$RUN/problem-apps.txt" | awk -v b="$BLOCK" -v k="$TAKE" -v only="$ONLY" '{ if (only != "" || (NR-1) % b < k) print }' > "$RUN/problems.txt"
TOTAL=$(wc -l < "$RUN/problems.txt")
log "problems: $TOTAL (of $(wc -l < "$RUN/problem-apps.txt") in registry order; source-backed apps only; take $TAKE of every $BLOCK)"
cat > "$RUN/manifest.json" <<EOF
{"bench_tag":"neat-bench ops/sregym-overnight.sh","started":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","machine":"$(hostname)","hardware":"nproc=$(nproc) mem_gib=$(free -g | awk '/^Mem:/{print $2}')",
 "neat_version":"$(neat --version 2>/dev/null)","neat_version_requested":"${NEAT_VERSION:-unset}","sregym":"$(git -C "$ROOT" rev-parse --short HEAD) + ops/sregym-bench-patch.py + collector patch","models":"$MODELS","judge":"SREGym LLM judge via Claude Code (--judge-backend claudecode)",
 "arms":{"claudecode-vanilla":"SREGym as shipped: telemetry MCP + kubectl, no source","claudecode-base":"pristine copy of the app source as cwd, no NEAT","claudecode-neat":"app source after neat init + neat claude install as cwd, fresh daemon per attempt, NEAT MCP (full surface) with URL+token"},
 "instruction":"identical for both arms (SREGym's own); no NEAT text in the prompt","k":1,"stages":"$STAGES","agent_timeout_s":$AGENT_TIMEOUT,"baseline_s":$BASELINE,"propagation_s":$PROPAGATION,
 "problem_selection":"registry order, source-backed apps, take $TAKE of every $BLOCK","problems":$TOTAL,"cache":"per-attempt nonce in the system prompt; caching kept within a session",
 "exclusions":"vendor/, node_modules/, .git/ excluded from both arm trees","confounds":"k=1; agents on the host (no container) so the base arm could reach the daemon if it went looking; one cluster, arms sequential; hooks off (product default)"}
EOF
printf 'problem\tapp\tarm\tmodel\tstart_epoch\tend_epoch\twall_s\trc\tresults_dir\tvoid\n' > "$RUN/timing.tsv"

n=0
while read -r pid app ns src; do
  [ -z "$pid" ] && continue
  n=$((n+1)); [ "$MAX_PROBLEMS" -gt 0 ] && [ "$n" -gt "$MAX_PROBLEMS" ] && break
  for model in $MODELS; do
  for arm in $ARMS; do
    tries=0
    while :; do
      PREP=$(NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" bash "$OPS/neat-arm-prep.sh" "$app" "$ns" "$src" 2>&1)
      echo "$PREP" | head -1 | tee -a "$RUN/launcher.log" >/dev/null
      eval "$(echo "$PREP" | tail -1)"; export AGENT_CWD_NEAT AGENT_CWD_BASE
      export CLAUDE_CODE_OAUTH_TOKEN="$(python3 -c 'import json,pathlib; print(json.load(open(pathlib.Path.home()/".claude/.credentials.json"))["claudeAiOauth"]["accessToken"])' 2>/dev/null)"
      before=$(ls -d results/*/ 2>/dev/null | sort | tail -1)
      tag="$pid.$arm.${model##*-}"
      log "[$n/$TOTAL] $pid ($app) $arm $model start"
      s=$(date +%s)
      timeout $((AGENT_TIMEOUT + 1800)) uv run main.py --problem "$pid" --agent "$arm" --model "$model" --judge-backend claudecode --internet-access open --agent-timeout "$AGENT_TIMEOUT" --baseline "$BASELINE" --propagation "$PROPAGATION" --stages $STAGES > "$RUN/$tag.log" 2>&1
      rc=$?; e=$(date +%s)
      # Only the harness's own failure lines count (the demo has a flag named llmRateLimitError).
      if ! grep -q "Agent process completed" "$RUN/$tag.log" && grep -qE "litellm\.RateLimitError|Judge pre-flight check failed|\"rate_limit_error\"|Login expired|authentication_failed" "$RUN/$tag.log"; then
        tries=$((tries+1)); mv "$RUN/$tag.log" "$RUN/$tag.limited-$tries.log"
        log "[$n/$TOTAL] $pid $arm hit the API/usage limit (try $tries); waiting 30 min"
        [ "$tries" -le 12 ] && { sleep 1800; continue; }
      fi
      break
    done
    after=$(ls -d results/*/ 2>/dev/null | sort | tail -1); [ "$after" = "$before" ] && after="-"
    void=$(find "$after" -name neat-preflight-void.json 2>/dev/null | head -1); void=${void:+yes}
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$app" "$arm" "$model" "$s" "$e" "$((e-s))" "$rc" "$after" "${void:-no}" >> "$RUN/timing.tsv"
    log "[$n/$TOTAL] $pid $arm $model done rc=$rc wall=$((e-s))s void=${void:-no}"
  done
  done
done < "$RUN/problems.txt"

log "aggregating"
python3 "$OPS/sregym-aggregate.py" "$RUN" "$ROOT/results" | tee -a "$RUN/launcher.log"
echo "{\"finished\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$RUN/finished.json"
log "done: $RUN"
