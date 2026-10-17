#!/usr/bin/env bash
# iterate.sh — the 4-to-6-hour iteration run (Deniz, 2026-10-17: "run and iterate over and over").
# Two arms (vanilla vs NEAT; the source-only base arm is the publication control, not needed to
# iterate), shorter waits (baseline 90 s, propagation 30 s), k=1, on the problems that
# discriminate: those where a plain agent fails or NEAT's capability record was partial, listed
# one per line in ops/iterate-set.txt. About 14 minutes a problem on one box.
#
# Usage on a bench box: NEAT_AUTH_TOKEN=... bash ops/iterate.sh [problem-list-file]
# Env overrides pass through to sregym-overnight.sh (MODELS, K, ARMS, BASELINE, PROPAGATION).
set -uo pipefail
OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="${1:-$OPS/iterate-set.txt}"
[ -s "$LIST" ] || { echo "no problems in $LIST" >&2; exit 1; }
ONLY="$(grep -vE '^\s*(#|$)' "$LIST" | awk '{print $1}' | tr '\n' ' ')"
export ONLY
export ARMS="${ARMS:-claudecode-vanilla claudecode-neat}"
export BASELINE="${BASELINE:-90}" PROPAGATION="${PROPAGATION:-30}"
export NEAT_VERSION="${NEAT_VERSION:-$(neat --version 2>/dev/null)}"
exec bash "$OPS/sregym-overnight.sh"
