#!/usr/bin/env bash
# restart-on-tag.sh — wait for @neat.is/core latest >= 0.10.7 (the v0.10.7 tag), install it,
# restart the daemon over ~/sregym-src, then start the smoke from problem 1 on the tag.
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"; export KUBECONFIG="$HOME/.kube/config"
export NEAT_AUTH_TOKEN=benchops-neat-token
log() { printf "%s %s\n" "$(date -u +%H:%M:%SZ)" "$*"; }
v=""
for i in $(seq 1 180); do v=$(npm view @neat.is/core version 2>/dev/null); case "$v" in 0.10.7|0.10.7.*|0.10.[89]*|0.1[1-9]*) break;; esac; v=""; sleep 60; done
[ -n "$v" ] || { log "no tag after 3 h; not starting"; exit 1; }
log "tag published: $v"
for i in 1 2 3 4 5; do npm i -g "@neat.is/core@$v" "@neat.is/mcp@$v" >/dev/null 2>&1 && break; log "npm install retry $i (propagation)"; sleep 120; done
log "neat $(neat --version)"
P=$(ss -ltnp 2>/dev/null | awk "/:8098 /{print \$NF}" | grep -oE "pid=[0-9]+" | head -1 | cut -d= -f2); [ -n "$P" ] && kill "$P" && sleep 3
cd ~/sregym-src && (setsid nohup bash -c "neat init . >/dev/null 2>&1; NEAT_AUTH_TOKEN=$NEAT_AUTH_TOKEN NEAT_OTEL_TOKEN=$NEAT_AUTH_TOKEN NEAT_WEB_DISABLED=1 HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 exec neat watch ." > ~/sregym-neat.log 2>&1 &)
for i in $(seq 1 90); do curl -s -m 3 http://localhost:8098/health 2>/dev/null | grep -q "\"ok\":true" && break; sleep 10; done
log "daemon: $(curl -s -m 3 http://localhost:8098/health | head -c 120)"
bash ~/neat-bench-ops/fix-kind-bridge.sh
NEAT_VERSION="$v" SKIP_WAIT=1 KEEP_APPS=1 bash ~/neat-bench-ops/sregym-overnight.sh
