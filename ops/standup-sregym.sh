#!/usr/bin/env bash
# standup-sregym.sh — stand SREGym up on a bench box, wired to a live NEAT daemon.
#
# Governed by docs/contracts/environment.md (rule 2: a box is stood up by script) and
# docs/decisions.md ADR-006/ADR-007. Runs on the box, never a laptop. Each phase is
# idempotent; re-run after a failure.
#
# Phases (select with the first argument; default = all up to "cluster"):
#   deps     clone SREGym + its applications submodule, uv sync, inotify sysctls, hardware line
#   wire     patch SREGym's collector to export to NEAT and to a capture file (no cluster needed)
#   cluster  create SREGym's 4-node kind cluster named "kind" (REFUSES if the box lacks headroom)
#   daemon   neat init + neat watch over the applications checkout, on :8098 / OTLP :4319
#
# Env: NEAT_AUTH_TOKEN (required for wire/daemon; never echoed), NEAT_VERSION (default: the
# pinned release in docs/decisions.md ADR-007 consequences, 0.10.7), SREGYM_REF (default main).
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
PHASE="${1:-cluster}"
ROOT="$HOME/SREGym"
APPS="$ROOT/SREGym-applications"
NEAT_VERSION="${NEAT_VERSION:-0.10.7}"
OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { printf '== %s\n' "$*"; }
die() { printf 'standup-sregym: %s\n' "$*" >&2; exit 1; }

phase_deps() {
  log "hardware line"
  printf 'machine=%s nproc=%s mem_gib=%s disk=%s\n' "$(hostname)" "$(nproc)" "$(free -g | awk '/^Mem:/{print $2}')" "$(df -h / | awk 'NR==2{print $2" ("$5" used)"}')"
  for t in docker kind kubectl helm uv python3 git; do command -v "$t" >/dev/null || die "missing tool: $t"; done
  helm version --short 2>/dev/null | grep -qE '^v4' || die "SREGym needs Helm 4 (have: $(helm version --short))"
  log "inotify limits"
  sudo -n sysctl -q -w fs.inotify.max_user_instances=1024 fs.inotify.max_user_watches=1048576 || die "sudo -n failed for sysctl"
  if [ ! -d "$ROOT/.git" ]; then
    log "clone SREGym + applications"
    git clone -q --recurse-submodules https://github.com/SREGym/SREGym.git "$ROOT" || die "clone failed"
  fi
  ( cd "$ROOT" && git fetch -q origin && git checkout -q "${SREGYM_REF:-main}" && git pull -q --ff-only && git submodule update -q --init --recursive )
  log "SREGym $(git -C "$ROOT" log -1 --format='%h %cd' --date=short); apps $(git -C "$APPS" log -1 --format='%h' 2>/dev/null)"
  log "uv sync"
  ( cd "$ROOT" && uv sync -q ) || die "uv sync failed"
  log "deps ok"
}

phase_wire() {
  [ -n "${NEAT_AUTH_TOKEN:-}" ] || die "NEAT_AUTH_TOKEN not set"
  GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)
  GW="${GW:-172.18.0.1}"
  log "collector patch (NEAT at http://$GW:4319)"
  python3 "$OPS/sregym-collector-neat.py" "$ROOT" --neat-endpoint "http://$GW:4319" --neat-token "$NEAT_AUTH_TOKEN" || die "collector patch failed"
}

phase_cluster() {
  if kind get clusters 2>/dev/null | grep -qx kind; then log "kind cluster 'kind' already exists"; return 0; fi
  AVAIL=$(free -g | awk '/^Mem:/{print $7}')
  LOAD=$(cut -d' ' -f1 /proc/loadavg | cut -d. -f1)
  OTHER=$(kind get clusters 2>/dev/null | grep -vx kind | tr '\n' ' ')
  if [ "$AVAIL" -lt 16 ] || [ "$LOAD" -ge "$(nproc)" ]; then
    die "no headroom for a second cluster: available ${AVAIL}GiB (need 16), load $LOAD on $(nproc) cores, other clusters: ${OTHER:-none}. Pause the other cluster or use another box (ADR-007)."
  fi
  log "create SREGym kind cluster (4 nodes, Calico)"
  ( cd "$ROOT" && bash kind/setup_kind_cluster.sh ) || die "kind setup failed"
  kubectl --context kind-kind get nodes
}

phase_daemon() {
  [ -n "${NEAT_AUTH_TOKEN:-}" ] || die "NEAT_AUTH_TOKEN not set"
  if ! neat --version 2>/dev/null | grep -q "$NEAT_VERSION"; then
    log "install @neat.is/core@$NEAT_VERSION + @neat.is/mcp@$NEAT_VERSION"
    npm i -g "@neat.is/core@$NEAT_VERSION" "@neat.is/mcp@$NEAT_VERSION" >/dev/null 2>&1 || die "npm install failed (is $NEAT_VERSION published?)"
  fi
  log "neat init over the applications checkout"
  ( cd "$APPS" && neat init . >/dev/null 2>&1 ) || die "neat init failed"
  if curl -s -m 3 http://localhost:8098/health >/dev/null 2>&1; then log "daemon already answering on :8098"; return 0; fi
  log "neat watch (detached; log ~/sregym-neat.log)"
  ( cd "$APPS" && NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" NEAT_OTEL_TOKEN="$NEAT_AUTH_TOKEN" NEAT_WEB_DISABLED=1 HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 setsid nohup neat watch . > "$HOME/sregym-neat.log" 2>&1 & )
  sleep 5
  curl -s -m 5 http://localhost:8098/health | head -c 200; echo
}

case "$PHASE" in
  deps) phase_deps ;;
  wire) phase_deps; phase_wire ;;
  cluster) phase_deps; phase_wire; phase_cluster ;;
  daemon) phase_daemon ;;
  all) phase_deps; phase_wire; phase_cluster; phase_daemon ;;
  *) die "unknown phase $PHASE (deps|wire|cluster|daemon|all)" ;;
esac
