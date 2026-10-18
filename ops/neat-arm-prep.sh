#!/usr/bin/env bash
# neat-arm-prep.sh <app-key> <namespace> <source-dir>
#
# Before every attempt (either arm), put NEAT in the state a user gets from `npx neat.is` in the
# application's own repository, fresh, and build the base arm's pristine copy of the same code.
#   ~/neat-arm/<app>   the app source + `neat init` + `neat claude install` (## neat in CLAUDE.md);
#                      a fresh daemon watches it (neat-out wiped: no graph, incidents or OBSERVED
#                      edges carried from an earlier attempt, CONTRACT.md O3)
#   ~/base-arm/<app>   the same source, no NEAT artifacts at all (O2)
# The k8s connector is pointed at the app's namespace. Vendored third-party code and
# node_modules are excluded from both trees (recorded in the run manifest).
# Prints `AGENT_CWD_NEAT=... AGENT_CWD_BASE=...` on the last line for the launcher.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"
APP="$1"; NS="$2"; SRC="$3"
: "${NEAT_AUTH_TOKEN:?NEAT_AUTH_TOKEN required}"
NEAT_DIR="$HOME/neat-arm/$APP"; BASE_DIR="$HOME/base-arm/$APP"
EXCL=(--exclude .git --exclude vendor --exclude node_modules --exclude neat-out --exclude CLAUDE.md --exclude policy.json)

P=$(ss -ltnp 2>/dev/null | awk '/:8098 /{print $NF}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
[ -n "$P" ] && kill "$P" && sleep 2
mkdir -p "$NEAT_DIR" "$BASE_DIR"
rsync -a --delete "${EXCL[@]}" "$SRC/" "$NEAT_DIR/"
rsync -a --delete "${EXCL[@]}" "$SRC/" "$BASE_DIR/"
rm -rf "$NEAT_DIR/neat-out"

python3 - "$NS" <<'PY'
import json, pathlib, sys
home = pathlib.Path.home()
ns = sys.argv[1]
d = {"version": 1, "deployments": [{"id": f"sregym-{ns}", "credential": {"kubeconfig": str(home / ".kube/config")}, "namespace": ns, "intervalMs": 15000}]}
(home / ".neat/k8s.json").write_text(json.dumps(d, indent=2))
# The app's flag store, when it runs one (astronomy-shop's flagd). Reached through a
# supervised port-forward to flagd's sync port, the way an operator's NEAT reaches it in-cluster.
stores = [{"id": f"{ns}-flagd", "provider": "flagd", "endpoint": "localhost:18015", "intervalMs": 5000}] if ns == "astronomy-shop" else []
(home / ".neat/flag-stores.json").write_text(json.dumps({"version": 1, "stores": stores}))
PY

# Supervised port-forward to flagd's sync port (8015); flag faults and the post-swap restart
# both restart flagd, so it reconnects. One supervisor at a time, tracked by pidfile.
PF="$HOME/neat-snapshots/flagd-pf.pid"; mkdir -p "$HOME/neat-snapshots"
if [ -f "$PF" ]; then OLD=$(cat "$PF"); pkill -P "$OLD" 2>/dev/null; kill "$OLD" 2>/dev/null; rm -f "$PF"; fi
if [ "$NS" = "astronomy-shop" ]; then
  ( echo $BASHPID > "$PF"
    for i in $(seq 1 2000); do
      kubectl --context kind-kind -n "$NS" port-forward deploy/flagd 18015:8015 >/dev/null 2>&1
      sleep 3
    done ) > /dev/null 2>&1 &
fi

cd "$NEAT_DIR"
neat init . >/dev/null 2>&1
neat claude install >/dev/null 2>&1
# The generic policy pack (ops/policy-generic-v1.json), committed before any scored attempt.
cp "$(dirname "$0")/policy-generic-v1.json" "$NEAT_DIR/policy.json" 2>/dev/null
( NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" NEAT_OTEL_TOKEN="$NEAT_AUTH_TOKEN" NEAT_WEB_DISABLED=1 HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 setsid nohup neat watch . > "$HOME/sregym-neat.log" 2>&1 & )
for i in $(seq 1 60); do curl -s -m 3 http://localhost:8098/health 2>/dev/null | grep -q '"ok":true' && break; sleep 5; done
# Healthy snapshot for get_graph_diff (the PRAXIS method): once the app's pods have been Ready
# for 90 s (SREGym's baseline traffic, before the fault), copy the daemon's graph outside the
# arm's tree. A background job, so the attempt is not delayed.
SNAP_DIR="$HOME/neat-snapshots/$APP"; mkdir -p "$SNAP_DIR"; rm -f "$SNAP_DIR/healthy.json"
( for i in $(seq 1 120); do
    nr=$(kubectl --context kind-kind -n "$NS" get pods --no-headers 2>/dev/null | grep -vcE " (Running|Completed) ")
    tot=$(kubectl --context kind-kind -n "$NS" get pods --no-headers 2>/dev/null | wc -l)
    if [ "$tot" -gt 0 ] && [ "$nr" -eq 0 ]; then sleep 90; cp "$NEAT_DIR/neat-out/graph.json" "$SNAP_DIR/healthy.json" 2>/dev/null && date -u +%FT%TZ > "$SNAP_DIR/healthy.taken"; break; fi
    sleep 10
  done ) > /dev/null 2>&1 &
H=$(curl -s -m 3 http://localhost:8098/health | head -c 160)
echo "prep $APP ns=$NS daemon=$H claude_md=$(grep -c '^## neat' "$NEAT_DIR/CLAUDE.md" 2>/dev/null || echo 0)"
echo "AGENT_CWD_NEAT=$NEAT_DIR AGENT_CWD_BASE=$BASE_DIR NEAT_SNAPSHOT=$SNAP_DIR/healthy.json"
