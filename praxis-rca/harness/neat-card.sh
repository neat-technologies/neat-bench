#!/usr/bin/env bash
# neat-card.sh — fetch the latest incident CARD from the live NEAT daemon.
# ─────────────────────────────────────────────────────────────────────────────
# The daemon composes one self-sufficient work-order per incident (ADR-221:
# rootCause + provenance-stamped causal chain + code locus + blast radius +
# policies + node divergence + a headline) and pushes it on `neat monitor --json`.
# There is no `neat card` CLI verb yet (REST + MCP + monitor only), so this wraps
# the monitor stream: it listens briefly, keeps only incident cards, and prints the
# most recent (optionally filtered to a service). This is how the neat arm reads
# NEAT's fused reasoning as a ready work-order instead of grepping for it.
#   neat-card.sh [service]        # latest card, optionally for one service
#   NEAT_CARD_WINDOW=12 neat-card.sh recommendation
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
SVC="${1:-}"
export NEAT_AUTH_TOKEN="${NEAT_AUTH_TOKEN:-benchops-neat-token}"
PROJ="${NEAT_BENCH_PROJECT:-default}"
WIN="${NEAT_CARD_WINDOW:-12}"
timeout "$WIN" neat monitor --json --project "$PROJ" 2>/dev/null \
  | python3 -c "
import sys,json
cards=[]
for l in sys.stdin:
    l=l.strip()
    if not l: continue
    try: o=json.loads(l)
    except: continue
    if isinstance(o,dict) and o.get('kind')=='incident': cards.append(o)
svc='$SVC'
if svc:
    cards=[c for c in cards if c.get('service')==svc or str(c.get('affectedNode','')).endswith(':'+svc) or ('rootCause' in c and c['rootCause'] and svc in str(c['rootCause'].get('node','')))]
if not cards:
    print('no incident card seen in the '+ '$WIN' +'s window — is live load driving the fault right now? (try again, or query neat root-cause / incidents directly)')
    sys.exit(0)
print('=== latest incident card (of %d seen) ===' % len(cards))
print(json.dumps(cards[-1], indent=2))
"
