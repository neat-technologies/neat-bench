#!/usr/bin/env bash
# grade.sh — model-free RCI + RCR grader for the PRAXIS ±NEAT suite (SCORING.md §1).
# ─────────────────────────────────────────────────────────────────────────────
#   grade.sh <scenario> <answer.txt> <patch.diff>
#   → prints:  RCI=YES|NO  RCR=YES|NO
#
# RCI — did the arm name `recommendation` as the faulty/root-cause SERVICE (not a
#       dependency like product-catalog / neo4j / frontend). Ground-truth RCI for
#       all four scenarios is service:recommendation.
# RCR — did the arm's PATCH touch the scenario's ground-truth code location. These
#       are string/AST-ish greps over the unified diff; RESOLVED (grade + verified
#       app recovery) remains the load-bearing gate — RCR is the localization half.
# No LLM judge (SCORING.md §1). Test files are not in play (single-file fix).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
SCEN="${1:?usage: grade.sh <scen> <answer.txt> <patch.diff>}"
ANS="${2:?answer.txt}"; PATCH="${3:?patch.diff}"
[ -f "$ANS" ]   || ANS=/dev/null
[ -f "$PATCH" ] || PATCH=/dev/null

# added / removed lines of the unified diff
ADD() { grep -E '^\+' "$PATCH" 2>/dev/null | grep -v '^+++'; }
DEL() { grep -E '^-' "$PATCH" 2>/dev/null | grep -v '^---'; }

# ── RCI: recommendation named as the faulty service, not blamed on a dependency ──
# The symptom is dependency-shaped (neo4j / product-catalog upstream), so a lazy
# agent can misattribute root cause to the dependency. Credit RCI only when the
# answer names recommendation as the faulty/failing/root-cause service.
rci_grade () {
  grep -iqE '(faulty|failing|root[ -]?cause|culprit|the (bug|defect|problem) is in|responsible)[^.]{0,60}recommendation|recommendation[^.]{0,60}(service (is|has)|is the (faulty|failing|root|culprit)|is at fault|contains the (bug|defect))' "$ANS" && { echo YES; return; }
  # fallback: names recommendation_server.py as the file it fixed (the fix locus IS recommendation)
  grep -iqE 'recommendation_server\.py' "$ANS" && { echo YES; return; }
  echo NO
}

# ── RCR: patch touches the scenario's ground-truth code location ────────────────
rcr_grade () {
  local area fix
  case "$SCEN" in
    401)  # products_list -> products  (~85/96)
      # removed a products_list access AND added a .products (non-_list) access
      local rem_pl add_p
      rem_pl=$(DEL | grep -icE 'products_list' || true)
      add_p=$(ADD | grep -E '\.products\b' | grep -icv 'products_list' || true)
      { [ "$rem_pl" -gt 0 ] && [ "$add_p" -gt 0 ]; } && echo YES || echo NO ;;
    405)  # add timeout/retry to the neo4j requests.get in get_additional_product_from_database (~129)
      fix=$(ADD | grep -icE 'timeout *=|Timeout|retr(y|ies)|backoff|max_retries|Session\(\)|HTTPAdapter|raise_for_status' || true)
      area=$(grep -icE 'get_additional_product_from_database|neo4jdb_addr|neo4j|requests\.get' "$PATCH" || true)
      { [ "$fix" -gt 0 ] && [ "$area" -gt 0 ]; } && echo YES || echo NO ;;
    410)  # bound the `while True` neo4j socket retry loop (~143): retry cap / timeout / break condition
      local bounded rem_while
      bounded=$(ADD | grep -icE 'range\(|max_retr|max_attempt|attempts|settimeout|timeout|deadline|time\.(time|monotonic)|elapsed|for [a-z_]+ in range|MAX_|_MAX|break|raise|return' || true)
      rem_while=$(DEL | grep -icE 'while True' || true)
      area=$(grep -icE 'get_additional_product_from_database|neo4j|socket|connect|while' "$PATCH" || true)
      { [ "$area" -gt 0 ] && { [ "$bounded" -gt 0 ] || [ "$rem_while" -gt 0 ]; }; } && echo YES || echo NO ;;
    412)  # reimplement recursive LCS with DP/memo in compare_product_compatibility (~157)
      area=$(grep -icE 'compare_product_compatibility|LCS|compatibility' "$PATCH" || true)
      fix=$(ADD | grep -icE 'dp\b|dp\[|memo|lru_cache|@cache|functools|range\(|\[\[|table|matrix|\[0\] *\*|for [a-z_]+ in range' || true)
      { [ "$area" -gt 0 ] && [ "$fix" -gt 0 ]; } && echo YES || echo NO ;;
    *) echo NO ;;
  esac
}

echo "RCI=$(rci_grade)  RCR=$(rcr_grade)"
