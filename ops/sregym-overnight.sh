#!/usr/bin/env bash
# sregym-overnight.sh — the overnight smoke run on SREGym: same agent with and without NEAT,
# k=1, both arms on each problem before moving on, problems taken 2 from every block of 5 in
# SREGym's own order (Deniz, 2026-10-17). Development numbers only (claims contract rule 7).
#
# Env (all optional): NEAT_VERSION (manifest only; install first with sregym-repoint.sh),
#   MODEL (default claude-sonnet-5-5), AGENT_TIMEOUT (s, default 480), BASELINE/PROPAGATION
#   (s, default 60/60), STAGES (default "diagnosis mitigation"), BLOCK (5), TAKE (2),
#   MAX_PROBLEMS (stop after N problems), SKIP_WAIT=1 (don't wait for the repoint log),
#   KEEP_APPS=1 (don't tear down the smoke namespaces). NEAT_AUTH_TOKEN required.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
: "${NEAT_AUTH_TOKEN:?NEAT_AUTH_TOKEN required}"
MODEL="${MODEL:-claude-sonnet-5-5}"; AGENT_TIMEOUT="${AGENT_TIMEOUT:-480}"; BASELINE="${BASELINE:-60}"; PROPAGATION="${PROPAGATION:-60}"
STAGES="${STAGES:-diagnosis mitigation}"; BLOCK="${BLOCK:-5}"; TAKE="${TAKE:-2}"; MAX_PROBLEMS="${MAX_PROBLEMS:-0}"
ROOT="$HOME/SREGym"; RUN="$HOME/sregym-bench/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$RUN"
export NEAT_MCP_BIN="$(command -v neat-mcp || echo "$(npm root -g)/@neat.is/mcp/dist/index.cjs")"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUN/launcher.log"; }
kubectl config use-context kind-kind >/dev/null

if [ "${SKIP_WAIT:-0}" != "1" ]; then
  log "waiting for the nightly re-point to finish (marker in ~/sregym-repoint.log)"
  for i in $(seq 1 180); do grep -q "== frontier nodes" "$HOME/sregym-repoint.log" 2>/dev/null && break; sleep 10; done
fi
log "neat $(neat --version 2>/dev/null) daemon: $(curl -s -m 5 http://localhost:8098/health | head -c 120)"

if [ "${KEEP_APPS:-0}" != "1" ]; then
  log "tearing down smoke namespaces (SREGym deploys each problem's app itself)"
  for ns in astronomy-shop hotel-reservation social-network; do kubectl delete ns "$ns" --ignore-not-found --wait=false >/dev/null 2>&1; done
  for i in $(seq 1 60); do n=$(kubectl get ns --no-headers 2>/dev/null | grep -cE "^(astronomy-shop|hotel-reservation|social-network) "); [ "$n" -eq 0 ] && break; sleep 10; done
  log "namespaces gone: $([ "${n:-0}" -eq 0 ] && echo yes || echo "no ($n left)")"
fi

cd "$ROOT"
python3 "$HOME/neat-bench-ops/sregym-bench-patch.py" "$ROOT" | tee -a "$RUN/launcher.log"
.venv/bin/python - "$BLOCK" "$TAKE" > "$RUN/problems.txt" <<'PY'
import sys
from sregym.conductor.problems.registry import ProblemRegistry
block, take = int(sys.argv[1]), int(sys.argv[2])
ids = ProblemRegistry().get_problem_ids()
for i in range(0, len(ids), block):
    for p in ids[i:i + take]:
        print(p)
PY
TOTAL=$(wc -l < "$RUN/problems.txt"); log "problems: $TOTAL of $(.venv/bin/python -c 'from sregym.conductor.problems.registry import ProblemRegistry; print(len(ProblemRegistry().get_problem_ids()))') (take $TAKE of every $BLOCK)"
cat > "$RUN/manifest.json" <<EOF
{"bench_tag":"neat-bench ops/sregym-overnight.sh","started":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","machine":"$(hostname)","hardware":"nproc=$(nproc) mem_gib=$(free -g | awk '/^Mem:/{print $2}')",
 "neat_version":"$(neat --version 2>/dev/null)","neat_version_requested":"${NEAT_VERSION:-unset}","sregym":"$(git -C "$ROOT" rev-parse --short HEAD) + ops patches","model":"$MODEL","judge":"claudecode (SREGym LLM judge via the box's Claude login)",
 "arms":["claudecode-base","claudecode-neat"],"k":1,"stages":"$STAGES","agent_timeout_s":$AGENT_TIMEOUT,"baseline_s":$BASELINE,"propagation_s":$PROPAGATION,
 "problem_selection":"take $TAKE of every $BLOCK in registry order","problems":$TOTAL,"cache":"per-attempt nonce in the system prompt; caching kept within a session",
 "confounds":"k=1; one cluster so arms run sequentially per problem; agents run on the host (no container) so the base arm could reach the NEAT daemon on localhost if it went looking; one daemon over all app sources; OBSERVED edges from earlier problems go STALE between problems; apps redeployed per problem by SREGym"}
EOF
printf 'problem\tarm\tstart_epoch\tend_epoch\twall_s\trc\tresults_dir\n' > "$RUN/timing.tsv"

n=0
while read -r pid; do
  [ -z "$pid" ] && continue
  n=$((n+1)); [ "$MAX_PROBLEMS" -gt 0 ] && [ "$n" -gt "$MAX_PROBLEMS" ] && break
  for arm in claudecode-base claudecode-neat; do
    # the judge runs through Claude Code with a token; take the freshest one the host holds
    export CLAUDE_CODE_OAUTH_TOKEN="$(python3 -c 'import json,pathlib; print(json.load(open(pathlib.Path.home()/".claude/.credentials.json"))["claudeAiOauth"]["accessToken"])' 2>/dev/null)"
    before=$(ls -d results/*/ 2>/dev/null | sort | tail -1)
    log "[$n/$TOTAL] $pid $arm start"
    s=$(date +%s)
    NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" NEAT_MCP_BIN="$NEAT_MCP_BIN" timeout $((AGENT_TIMEOUT + 1500)) uv run main.py --problem "$pid" --agent "$arm" --model "$MODEL" --judge-backend claudecode --internet-access open --agent-timeout "$AGENT_TIMEOUT" --baseline "$BASELINE" --propagation "$PROPAGATION" --stages $STAGES > "$RUN/$pid.$arm.log" 2>&1
    rc=$?; e=$(date +%s)
    # Rate limit on the shared subscription (seen 2026-10-17 03:47Z: the judge pre-flight got
    # RateLimitError and the loop burned 38 problems at 19 s each). Don't advance: wait for the
    # reset and retry the same attempt, up to 12 times (6 h).
    if grep -qiE "RateLimitError|rate_limit|usage limit|Login expired|authentication_failed" "$RUN/$pid.$arm.log"; then
      tries=$((${tries:-0}+1)); log "[$n/$TOTAL] $pid $arm hit the API/usage limit (try $tries); waiting 30 min for the reset"
      mv "$RUN/$pid.$arm.log" "$RUN/$pid.$arm.limited-$tries.log"
      if [ "$tries" -le 12 ]; then sleep 1800; continue 2; fi
    fi
    tries=0
    after=$(ls -d results/*/ 2>/dev/null | sort | tail -1); [ "$after" = "$before" ] && after="-"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$arm" "$s" "$e" "$((e-s))" "$rc" "$after" >> "$RUN/timing.tsv"
    log "[$n/$TOTAL] $pid $arm done rc=$rc wall=$((e-s))s"
  done
done < "$RUN/problems.txt"

log "aggregating"
python3 "$HOME/neat-bench-ops/sregym-aggregate.py" "$RUN" "$ROOT/results" | tee -a "$RUN/launcher.log"
echo "{\"finished\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" > "$RUN/finished.json"
log "done: $RUN"
