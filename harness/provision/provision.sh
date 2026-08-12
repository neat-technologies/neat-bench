#!/usr/bin/env bash
# harness/provision/provision.sh
# ─────────────────────────────────────────────────────────────────────────────
# Generic, target-descriptor-driven provisioner for neat-bench.
#
#   harness/provision/provision.sh <target-descriptor.json>
#   # e.g. harness/provision/provision.sh targets/queue-app.json
#
# Runs the reusable NEAT orchestration spine generically, driven entirely by the
# descriptor (no target-specific logic lives here). It is the direct generalization
# of neat-agent-bench/reproduce.sh — each step cites the reproduce.sh section it
# came from. The one deliberate change: TRAFFIC IS THE TARGET'S OWN TEST SUITE
# (span-driven), not a bespoke HTTP driver. NO CONNECTORS — OTel spans only.
#
# Steps:
#   0. preflight (docker/git/jq/curl/node, NEAT_REPO present, build core if needed)
#   1. datastores up + wait               [reproduce.sh §1]
#   2. clone + pin, write .env, install   [reproduce.sh §2]
#   3. neat init --apply, install, commit [reproduce.sh §3]
#   4. scoped daemon on isolated NEAT_HOME + non-default ports  [reproduce.sh §4]
#   5. (optional) start instrumented app if the descriptor defines start_cmd
#   6. drive traffic = run the target's own test suite (preload otel-init)
#   7. snapshot /graph + /graph/divergences → results/<target>.graph.json  [§5]
#
# Idempotent-ish: reuses datastore containers; re-clones the target fresh at the
# pinned commit each run for determinism [reproduce.sh header].
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DESCRIPTOR_ARG="${1:?usage: provision.sh <target-descriptor.json>}"
# accept either a path or a bare target id (targets/<id>.json)
if [ -f "$DESCRIPTOR_ARG" ]; then
  DESCRIPTOR_PATH="$DESCRIPTOR_ARG"
elif [ -f "$REPO_ROOT/targets/$DESCRIPTOR_ARG.json" ]; then
  DESCRIPTOR_PATH="$REPO_ROOT/targets/$DESCRIPTOR_ARG.json"
else
  die "descriptor not found: $DESCRIPTOR_ARG (tried it as a path and as targets/$DESCRIPTOR_ARG.json)"
fi

load_descriptor "$DESCRIPTOR_PATH"

echo "════════════════════════════════════════════════════════════════════"
echo " provisioning target: $TARGET_ID"
echo " repo:    $REPO_URL @ ${COMMIT:0:12}${SUBDIR:+  (subdir: $SUBDIR)}"
echo " NEAT:    $NEAT_REPO  (REST $REST / OTLP $OTLP / web $WEB)"
echo " node:    target=$NODE_TARGET  daemon=$(command -v node)"
echo " service: $SVC"
echo "════════════════════════════════════════════════════════════════════"

# ── 0. preflight ─────────────────────────────────────────────────────────────
preflight

# ── 1. datastores ────────────────────────────────────────────────────────────
datastores_up

# ── 2. clone + pin + env + install ───────────────────────────────────────────
clone_target
write_env
install_target

# ── 3. instrument with NEAT ──────────────────────────────────────────────────
instrument_target

# ── 4. scoped daemon (clean OBSERVED state) ──────────────────────────────────
step "starting scoped daemon '$PROJECT' (REST $REST / OTLP $OTLP / web $WEB, isolated NEAT_HOME)"
daemon_reset

# ── 5. optional live app (only if a wall needs HTTP probes; suite is default) ─
app_start

# ── 6. drive traffic = the target's own test suite (span-driven) ─────────────
drive_traffic

# ── 7. snapshot the graph ────────────────────────────────────────────────────
capture_graph

echo
echo "════════════════════════════════════════════════════════════════════"
echo " Provisioned.  Target dir: $APP_DIR"
echo " Daemon REST/MCP: $D   (project $PROJECT)"
echo " Snapshot: $GRAPH_OUT"
echo "           $DIVERGENCES_OUT"
echo
echo " Next:  ./run.sh $TARGET_ID <wall> [N]   (runs both agent arms + scorers)"
echo "════════════════════════════════════════════════════════════════════"
