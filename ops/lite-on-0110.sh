#!/usr/bin/env bash
# SREGym-Lite vs the public board: wait for @neat.is 0.10.10 (ADR-260 push) and for the running
# smoke + code leg, install 0.10.10 and the staged harness, then 17 Lite problems x
# {vanilla, neat} x Opus 5.5 x k=3 (the attempts per fault the board uses).
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"; export NEAT_AUTH_TOKEN=benchops-neat-token
log() { printf "%s %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }
for i in $(seq 1 1440); do npm view @neat.is/core@0.10.10 version >/dev/null 2>&1 && npm view @neat.is/mcp@0.10.10 version >/dev/null 2>&1 && break; sleep 60; done
log "0.10.10 on npm"
while pgrep -f "[r]estart-v2.sh" >/dev/null || pgrep -f "[s]regym-overnight.sh" >/dev/null; do sleep 60; done
for i in 1 2 3 4 5; do npm i -g @neat.is/core@0.10.10 @neat.is/mcp@0.10.10 >/dev/null 2>&1 && break; sleep 120; done
cp ~/neat-bench-ops/next/* ~/neat-bench-ops/
log "neat $(neat --version); starting Lite"
# Gate: one NEAT-arm attempt on the acceptance problem. Proceed only if NEAT's pushed context
# reached the agent (the session-start card or a NEAT tool result in its transcript) and the
# agent called NEAT at least once; otherwise stop and leave the evidence for review.
NEAT_VERSION=0.10.10 MODELS=claude-opus-5-5 K=1 ARMS="claudecode-neat" ONLY="update_incompatible_correlated" bash ~/neat-bench-ops/sregym-overnight.sh
G=$(ls -dt ~/sregym-bench/*/ | head -1); GL=$(ls "$G"/update_incompatible_correlated.claudecode-neat*.log | grep -v limited | head -1)
PUSHED=$(grep -cE "mongodb-reservation|NEAT sees|investigate\(" "$GL")
CALLS=$(python3 -c 'import json,sys; n=0
for l in open(sys.argv[1],errors="replace"):
    l=l.strip()
    if not l.startswith("{"): continue
    try: e=json.loads(l)
    except Exception: continue
    c=(e.get("message") or {}).get("content")
    if isinstance(c,list): n+=sum(1 for x in c if x.get("type")=="tool_use" and str(x.get("name","")).startswith("mcp__neat"))
print(n)' "$GL")
log "gate: pushed_mentions=$PUSHED neat_calls=$CALLS ($GL)"
if [ "$PUSHED" -eq 0 ] || [ "$CALLS" -eq 0 ]; then log "GATE FAILED: push did not reach or move the agent; Lite not started"; echo "{\"gate\":\"failed\",\"pushed\":$PUSHED,\"neat_calls\":$CALLS,\"log\":\"$GL\"}" > ~/sregym-lite-gate.json; exit 1; fi
log "gate passed"
cd ~/SREGym && LITE=$(.venv/bin/python -c 'from sregym.conductor.problem_sets import PROBLEM_SETS; print(" ".join(PROBLEM_SETS["sregym-lite"]))')
NEAT_VERSION=0.10.10 MODELS=claude-opus-5-5 K=3 ARMS="claudecode-vanilla claudecode-neat" ONLY="$LITE" bash ~/neat-bench-ops/sregym-overnight.sh
