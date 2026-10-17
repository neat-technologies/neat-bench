#!/usr/bin/env bash
# lite-start.sh <odd|even>: stop whatever bench job runs here, install the staged harness, and run
# this box's half of SREGym-Lite: vanilla vs NEAT, Opus 5.5, k=3, baseline 90 s, propagation 30 s.
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"; export NEAT_AUTH_TOKEN=benchops-neat-token
HALF="$1"; ME=$$
for pat in "bash $HOME/neat-bench-ops/restart-v2.sh" "bash $HOME/neat-bench-ops/box2-run1.sh" "bash $HOME/neat-bench-ops/sregym-overnight.sh" "main.py --problem"; do
  for p in $(pgrep -f "$pat"); do [ "$p" != "$ME" ] && kill "$p" 2>/dev/null; done
done
sleep 5
[ -d "$HOME/neat-bench-ops/next" ] && cp "$HOME/neat-bench-ops/next/"* "$HOME/neat-bench-ops/"
cd "$HOME/SREGym" && LITE=$(.venv/bin/python -c 'from sregym.conductor.problem_sets import PROBLEM_SETS; print("\n".join(PROBLEM_SETS["sregym-lite"]))')
if [ "$HALF" = "odd" ]; then MINE=$(echo "$LITE" | awk 'NR%2==1' | tr '\n' ' '); else MINE=$(echo "$LITE" | awk 'NR%2==0' | tr '\n' ' '); fi
echo "$(date -u +%H:%M:%SZ) $(hostname) half=$HALF neat=$(neat --version) problems: $MINE"
NEAT_VERSION="$(neat --version)" MODELS=claude-opus-5-5 K=3 ARMS="claudecode-vanilla claudecode-neat" BASELINE=90 PROPAGATION=30 ONLY="$MINE" bash "$HOME/neat-bench-ops/sregym-overnight.sh"
