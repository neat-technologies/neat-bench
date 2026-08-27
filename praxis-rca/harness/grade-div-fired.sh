#!/usr/bin/env bash
# grade-div-fired.sh — STRICT grader: does `neat divergences` RAW output surface the
# ACTUAL injected fault, beyond the generic structural coverage noise it always emits?
# ─────────────────────────────────────────────────────────────────────────────
#   grade-div-fired.sh <scenario> <divergences.txt>   -> prints FIRED=YES|NO
#
# `neat divergences` always lists many `missing-extracted` (tree-sitter coverage gaps)
# and `missing-observed` (edges not exercised in the window) — that is NOISE, present
# regardless of the fault. FIRED=YES only if the output carries a FAULT-SPECIFIC signal
# (the field/symbol mismatch, the wrong host, a service-specific anomaly), NOT a generic
# edge that merely happens to name the service. Deliberately conservative: a false NO is
# honest, a false YES inflates the launch claim.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
SCEN="${1:?scen}"; F="${2:?divergences.txt}"; [ -f "$F" ] || { echo "FIRED=NO"; exit 0; }
TXT="$(tr '[:upper:]' '[:lower:]' < "$F")"
has() { echo "$TXT" | grep -qE "$1"; }

FIRED=NO
case "$SCEN" in
  401) has 'products_list|has no attribute|attributeerror|symbol.*mismatch|field.*(mismatch|missing|not found)|type.?mismatch|observed-symbol' && FIRED=YES ;;
  405|406|407|408) has 'neo4j.*(timeout|deadlock|hang|no ?timeout|blocked|error|fail)|(timeout|deadlock|hang).*neo4j' && FIRED=YES ;;
  409|410) has 'livelock|neo4j.*(retry|loop|spin|hang|livelock)|(infinite|unbounded).*(retry|loop)' && FIRED=YES ;;
  413|414) has 'master-neo4j|neo4j.*(wrong|mismatch|unresolved|not found|unknown host)|(host|dns).*(neo4j|productdb)|master.*primary' && FIRED=YES ;;
  415|416) has 'num_products|num_return|index.*(out|error)|out of (range|bound)' && FIRED=YES ;;
  20) has 'product.?catalog.*(down|silent|unavailable|stale|error|image|imagepull|crash)|(image|imagepull|errimage).*product.?catalog' && FIRED=YES ;;
  32) has '(^|[^a-z])ad(service)?.*(down|silent|unavailable|stale|scaled|zero|no pods)|(stale|silent|down).*(^|[^a-z])ad(service)?' && FIRED=YES ;;
esac
echo "FIRED=$FIRED"
