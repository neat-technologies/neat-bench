#!/usr/bin/env bash
# grade-detect.sh — DETECTION grader for the divergence bench (no fix, no verify).
# ─────────────────────────────────────────────────────────────────────────────
#   grade-detect.sh <scenario> <answer.txt>
#   → prints:  RCI=YES|NO  RCR=YES|NO  CAUGHT=YES|NO   (CAUGHT = RCI AND RCR)
#
# Grades the arm's DIAGNOSIS text: did it name the right faulty SERVICE (RCI) and
# the right fault NATURE/location (RCR). Model-free keyword match over answer.txt.
# Also used to grade whether `neat divergences` RAW OUTPUT surfaces the fault
# (pass the divergences output as <answer.txt>).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
SCEN="${1:?usage: grade-detect.sh <scen> <answer.txt>}"
A="${2:?answer.txt}"; [ -f "$A" ] || A=/dev/null
low() { tr '[:upper:]' '[:lower:]' < "$A"; }
TXT="$(low)"
has() { echo "$TXT" | grep -qE "$1"; }
# For agent answers the faulty service is on the `SERVICE:` line — match RCI THERE
# (precise: stops "recommendation image" in a product-catalog root cause from
# false-crediting product-catalog, etc.). Raw query text has no SERVICE: line -> whole text.
SVCLINE="$(echo "$TXT" | grep -E '^ *service:' | tail -1)"
rci_has() { if [ -n "$SVCLINE" ]; then echo "$SVCLINE" | grep -qE "$1"; else echo "$TXT" | grep -qE "$1"; fi; }

# ── RCI: right faulty service named ────────────────────────────────────────────
rci () {
  case "$SCEN" in
    20) rci_has 'product ?-?catalog|productcatalog' && echo YES || echo NO ;;
    32) rci_has '(^|[^a-z])ad([^a-z]|service|$)|adservice' && echo YES || echo NO ;;
    *)  rci_has 'recommendation' && echo YES || echo NO ;;
  esac
}

# ── RCR: right fault nature/location named ─────────────────────────────────────
rcr () {
  case "$SCEN" in
    401) has 'products_list|\.products\b|proto(buf)? field|field (name|mismatch)|attributeerror|has no attribute|wrong field|schema|contract mismatch' && echo YES || echo NO ;;
    405|406) has 'neo4j.*(no |missing |without ).*timeout|neo4j.*(timeout|deadlock|hang|block|never (return|repl))|(timeout|deadlock|hang|blocking).*(neo4j|product ?database)|requests\.get.*(no timeout|timeout)' && echo YES || echo NO ;;
    407|408) has 'neo4j.*(timeout|deadlock|hang|block)|(timeout|deadlock).*neo4j|product ?database.*(timeout|hang|deadlock)' && echo YES || echo NO ;;
    409|410) has 'livelock|(while|retry|loop).*(neo4j|forever|unbounded|never break)|neo4j.*(retry|loop|livelock|spin)|infinite (loop|retry)' && echo YES || echo NO ;;
    413|414) has 'master-neo4j|wrong (host|hostname|endpoint|db|database|service|label)|master.*primary|primary.*master|(host|dns|name).*(resolv|nxdomain|not found|unknown)|bad (label|host)|points? (at|to) .*(wrong|master)' && echo YES || echo NO ;;
    415) has 'num_return|num_products|index (out of|error)|out of (range|bound)|list index|indexerror|sample.*(larger|exceed|more)|range.*larger|more than .*(available|catalog)' && echo YES || echo NO ;;
    416) has 'num_products|num_return|config|index|out of (range|bound)|neo4j|list index' && echo YES || echo NO ;;
    # 20/32 are DEPLOY faults. NEAT has no k8s connector here, so its honest, correct
    # diagnosis is the OBSERVABLE symptom — "service X went silent / is down / not
    # responding" — not the k8s cause (bad image / replicas=0). Credit either. The code
    # arm, blind, produces neither, so this does not leak credit to it.
    20)  has 'image|app-image|wrong (image|tag)|imagepull|pull ?(back)?off|errimagepull|cannot pull|bad image|not (running|responding|ready|starting)|is down|unavailable|crashloop|fail(ing|ed) to (start|run)|no (pods|replicas|instances)|silent|unreachable|never (started|became ready)|not (serving|observed)' && echo YES || echo NO ;;
    32)  has 'replica|scaled (to )?(0|zero|down)|0 replicas|no (pods|replicas|instances)|not running|is down|scaled? down|zero replicas|silent|stale|stopped (emitting|responding|serving|being observed)|not (responding|observed|serving)|no (longer )?(observed|traffic|spans|telemetry|data)|unavailable|unreachable|went (silent|dark|away)' && echo YES || echo NO ;;
    *) echo NO ;;
  esac
}

RCI=$(rci); RCR=$(rcr)
CAUGHT=NO; { [ "$RCI" = YES ] && [ "$RCR" = YES ]; } && CAUGHT=YES
echo "RCI=$RCI  RCR=$RCR  CAUGHT=$CAUGHT"
