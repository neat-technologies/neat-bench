#!/usr/bin/env bash
# card-run.sh — one card-accuracy pass: no agent, NEAT's own card submitted to SREGym's judge
# (ops/neat-card-agent.py) on every problem in a list file, diagnosis stage only.
#
#   Usage on a bench box: bash ops/card-run.sh <problem-list-file> [label]
# The box's PATH and NEAT token come from the box-local env line the other launchers use.
set -uo pipefail
OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${1:?problem list file}"; LABEL="${2:-card}"
eval "$(grep -m1 '^export PATH=' "$OPS/lite-start.sh")"
# SREGym calls `helm list --all`, which helm 4 rejects; bench runs use a helm 3 kept in ~/helm3.
[ -x "$HOME/helm3/helm" ] && export PATH="$HOME/helm3:$PATH"
[ -n "${NEAT_AUTH_TOKEN:-}" ] || { echo "no NEAT token in the box env line"; exit 1; }
export ONLY="$(grep -vE '^\s*(#|$)' "$LIST" | awk '{print $1}' | tr '\n' ' ')"
export ARMS=neat-card MODELS=claude-opus-5-5 K=1 STAGES=diagnosis
export BASELINE="${BASELINE:-60}" PROPAGATION="${PROPAGATION:-30}"
export NEAT_VERSION="$(neat --version 2>/dev/null)"
echo "card-run $LABEL: $(echo $ONLY | wc -w) problems, neat $NEAT_VERSION"
exec bash "$OPS/sregym-overnight.sh"
