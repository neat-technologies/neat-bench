#!/usr/bin/env bash
# smoke-card.sh — after a core fix lands in a nightly: install it, then run the NEAT arm once
# (k=1, Opus) on a few Lite problems that cover each card fix, and print the card NEAT built at
# the start of every attempt next to SREGym's ground truth. A smoke, not a scored run.
#
#   Usage on a bench box: NEAT_AUTH_TOKEN=... bash ops/smoke-card.sh <npm-version> [problem ...]
set -uo pipefail
OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VER="${1:?npm version, e.g. 0.10.9-dev.20261018}"; shift
# One problem per fix by default: quota (Events / ReplicaSet), Service spec, selector ambiguity,
# chronic-noise ranking.
PROBS="${*:-namespace_memory_limit internal_traffic_policy_local_astronomy_shop service_wrong_pod_selection_hotel_reservation kafka_poison_pill_hol_block}"

# VER is an npm version, or a directory of `npm pack` tarballs built from main (the stop-gap when
# the day's nightly slot is already taken): every *.tgz in it is installed globally in one go.
if [ -d "$VER" ]; then
  npm i -g "$VER"/*.tgz >/dev/null 2>&1 || { echo "install from $VER failed"; exit 1; }
  VER="pack:$(neat --version 2>/dev/null)"
  echo "installed $VER from tarballs"
else
  for i in 1 2 3 4 5; do
    npm i -g "neat.is@$VER" >/dev/null 2>&1 && break
    echo "install of neat.is@$VER failed (try $i); retrying in 60s"; sleep 60
  done
  got=$(neat --version 2>/dev/null)
  [ "$got" = "$VER" ] || { echo "installed '$got', wanted $VER; stopping"; exit 1; }
fi

export ONLY="$PROBS" ARMS="${ARMS:-claudecode-neat}" MODELS="${MODELS:-claude-opus-5-5}" K=1
export BASELINE="${BASELINE:-90}" PROPAGATION="${PROPAGATION:-30}" NEAT_VERSION="$VER"
bash "$OPS/sregym-overnight.sh"

RUN=$(ls -dt "$HOME"/sregym-bench/*/ | head -1)
python3 "$OPS/card-vs-truth.py" "$HOME/SREGym/results" "$(head -2 "$RUN/timing.tsv" | tail -1 | cut -f6)" | tee "$RUN/cards.txt"
