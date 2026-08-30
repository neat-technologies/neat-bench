#!/usr/bin/env bash
# preflight.sh — the ANTI-CONFOUND FIREWALL for neat-bench.
# ─────────────────────────────────────────────────────────────────────────────
# Enforces the operational-integrity invariants (CONTRACT.md §"Operational
# integrity") BEFORE a scored run. Each check is a scar we actually hit — a run
# that trips one is CONFOUNDED, so preflight fails it: a breach voids the run, it
# is never a data point. Run this immediately before the measurement window of
# every scenario/arm.
#
#   preflight.sh --target <deploy> --image <expected-substr> \
#                [--pristine <dir>] [--arm code|neat] [--ns otel-demo] [--proj default]
#
# env: NEAT_URL (default http://localhost:8098), NEAT_AUTH_TOKEN, KUBECONFIG
# exit 0 = clean, exit 1 = BREACH (void the run and fix the cause, do not score it).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
NS=otel-demo; PROJ=default; PRISTINE=""; ARM=""; TARGET=""; EXPECT_IMG=""
NEAT_URL="${NEAT_URL:-http://localhost:8098}"; TOK="${NEAT_AUTH_TOKEN:-benchops-neat-token}"
# Services the bench legitimately runs OFF or at variable scale, so they are NOT
# stray faults: the built-in load-generator (we drive our own controlled load) and
# the UI/observability sidecars. Extend with --allow-off "svc svc".
ALLOW_OFF="load-generator flagd-ui react-native-app grafana prometheus jaeger opensearch"
while [ $# -gt 0 ]; do case "$1" in
  --target) TARGET="$2"; shift 2;; --image) EXPECT_IMG="$2"; shift 2;;
  --pristine) PRISTINE="$2"; shift 2;; --arm) ARM="$2"; shift 2;;
  --ns) NS="$2"; shift 2;; --proj) PROJ="$2"; shift 2;;
  --allow-off) ALLOW_OFF="$ALLOW_OFF $2"; shift 2;;
  *) echo "preflight: unknown arg $1" >&2; exit 2;; esac; done
[ -n "$TARGET" ] || { echo "preflight: --target required" >&2; exit 2; }

FAIL=0
ok(){   echo "  [preflight] OK   $*"; }
warn(){ echo "  [preflight] WARN $*"; }
breach(){ echo "  [preflight] BREACH $*" >&2; FAIL=1; }

# ── O1  MEASURE ONLY REAL TELEMETRY ──────────────────────────────────────────
# The daemon must be live AND fed by spans the app actually emitted — never a
# synthetic/hand-crafted incident. SCAR: #1114's fix passed synthetic unit tests
# but was inert on the real Envoy 504; a synthetic score is a lie.
if curl -s -m5 -H "Authorization: Bearer $TOK" "$NEAT_URL/health" 2>/dev/null | grep -q '"ok":true'; then
  ok "O1 daemon live at $NEAT_URL"
else
  breach "O1 daemon not healthy at $NEAT_URL — no live graph to measure"
fi
if neat observed-dependencies "service:$TARGET" --project "$PROJ" 2>/dev/null | grep -qiE 'OBSERVED|runtime dependenc'; then
  ok "O1 real OTel ingested (service:$TARGET has OBSERVED edges)"
else
  warn "O1 service:$TARGET has no OBSERVED edges yet — warm the daemon with live load before you score (a hang legitimately emits nothing; a healthy service should not)"
fi

# ── O2  THE NO-NEAT ARM CANNOT READ NEAT'S OUTPUT ────────────────────────────
# The daemon writes the whole fused graph to neat-out/graph.json (+ neat.patch,
# *.ndjson) on disk; a source-only arm pointed at the repo can just cat it. Arms
# read a PRISTINE tree the daemon never writes into. SCAR: 2.6MB graph.json in the
# arm's read path; the .env-omission artifact made a weak model hallucinate.
if [ -n "$PRISTINE" ]; then
  ARTS=$(find "$PRISTINE" \( -name graph.json -o -name neat.patch -o -name '*.ndjson' \
        -o -name daemon.json -o -name embeddings.json -o -name extraction-health.json \) 2>/dev/null)
  if [ -z "$ARTS" ]; then ok "O2 pristine tree carries zero NEAT artifacts"
  else breach "O2 pristine tree contains NEAT output a source-only arm could read:"$'\n'"$(echo "$ARTS" | sed 's/^/      /')"; fi
fi
if [ "$ARM" = code ]; then
  # a code arm's own PATH must not reach neat or kubectl (the runner restricts it;
  # assert the intent is documented, not that this shell is restricted)
  ok "O2 code arm declared — its runner MUST launch with a PATH excluding neat + kubectl (verify in run-*.sh)"
fi

# ── O3  ONE FAULT, CLEAN STATE, PER SCENARIO ─────────────────────────────────
# Each scenario starts from a cleared incident store, the prior fault fully
# reverted, a settled rollout, and NOTHING else faulted. SCAR: 401→405 incident
# bleed; 405→32 image bleed (rec still on 405 while testing ad); rollout-bleed
# (old 401 pod emitting products_list during the 401→405 rollout window).
if neat incidents "service:$TARGET" --project "$PROJ" 2>/dev/null | grep -qiE 'No incidents'; then
  ok "O3 incident store clean for service:$TARGET"
else
  breach "O3 incident store for service:$TARGET is NOT empty — restand (clear errors.ndjson) before the window; stale incidents poison rootCause"
fi
IMG=$(kubectl -n "$NS" get deploy/"$TARGET" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [ -n "$EXPECT_IMG" ]; then
  case "$IMG" in *"$EXPECT_IMG"*) ok "O3 target image matches (*$EXPECT_IMG*)";;
    *) breach "O3 target image mismatch: want *$EXPECT_IMG*, deployed $IMG";; esac
fi
if kubectl -n "$NS" rollout status deploy/"$TARGET" --timeout=5s >/dev/null 2>&1; then
  ok "O3 target rollout settled"
else
  warn "O3 target rollout not settled (expected for a bootstrap-crash fault; restand AFTER it stabilizes for non-bootstrap scenarios)"
fi
# no stray faults: every OTHER deployment at its baseline (ready==desired, replicas>0)
STRAY=""
while read -r dep desired ready; do
  [ -z "$dep" ] && continue
  [ "$dep" = "$TARGET" ] && continue
  case " $ALLOW_OFF " in *" $dep "*) continue;; esac   # intentionally off/variable — not a stray fault
  ready=${ready:-0}; desired=${desired:-0}
  if [ "$desired" = "0" ]; then STRAY="$STRAY $dep(scaled-to-0)"; fi
  if [ "$ready" != "$desired" ]; then STRAY="$STRAY $dep($ready/$desired)"; fi
done < <(kubectl -n "$NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.replicas}{" "}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null)
if [ -z "$STRAY" ]; then ok "O3 no stray faults — every non-target service at baseline"
else breach "O3 stray fault(s) leftover from a prior scenario:$STRAY — revert before scoring"; fi

# ── verdict ──────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" = 0 ]; then
  echo "  [preflight] PASS — operational integrity clean, safe to score"; exit 0
else
  echo "  [preflight] FAIL — this run is CONFOUNDED. Void it, fix the breach, re-run. A confounded number is worse than no number."; exit 1
fi
