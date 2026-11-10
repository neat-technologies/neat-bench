#!/usr/bin/env bash
# uptime-kuma 2.5.3 (the corpus pick) observed by NEAT, separate from the :8201 setup.
# NEAT 0.11.0 daemon 127.0.0.1:8205/4405 (own NEAT_HOME); kuma 127.0.0.1:3105 with
# @neat.is/otel-node from main@c2aaa93 in a sidecar (socket.io #1597). Manifest untouched.
set -uo pipefail
T=$HOME/neat-bench/security-pilot/uptime-kuma/obs
export PATH=$HOME/.nvm/versions/node/v20.20.2/bin:$PATH
mkdir -p $T/logs $T/attach $T/neat-home
step() { echo "[$(date +%T)] $*"; }
[ -d $T/src/.git ] || git clone -q --depth 1 --branch 2.5.3 https://github.com/louislam/uptime-kuma.git $T/src
git -C $T/src rev-parse --short HEAD
if [ ! -d $T/src/node_modules ]; then
  step "npm ci"; (cd $T/src && npm ci --no-audit --no-fund > $T/logs/npm-ci.log 2>&1) || { tail -20 $T/logs/npm-ci.log; exit 1; }
fi
[ -f $T/src/dist/index.html ] || (cd $T/src && npm run download-dist > $T/logs/dist.log 2>&1) || { tail -10 $T/logs/dist.log; }
mkdir -p $T/src/data; [ -f $T/src/data/db-config.json ] || echo '{"type":"sqlite"}' > $T/src/data/db-config.json
if [ ! -d $T/attach/node_modules/@neat.is/otel-node ]; then
  (cd $T/attach && npm init -y >/dev/null && npm i --no-audit --no-fund $HOME/neat-bench/security-pilot/nodegoat/otel-node-main-c2aaa93.tgz > $T/logs/attach.log 2>&1) || { tail -10 $T/logs/attach.log; exit 1; }
fi
step "neat daemon"
NEAT_HOME=$T/neat-home NEAT_WEB_DISABLED=1 PORT=8205 OTEL_PORT=4405 HOST=127.0.0.1 nohup neat watch $T/src > $T/logs/neatd.log 2>&1 < /dev/null &
echo $! > $T/neatd.pid
for i in $(seq 1 90); do curl -sf http://127.0.0.1:8205/health >/dev/null 2>&1 && break; sleep 2; done
step "daemon: $(curl -s http://127.0.0.1:8205/health | head -c 160)"
step "kuma"
cd $T/src
OTEL_SERVICE_NAME=uptime-kuma OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:4405/v1/traces OTEL_EXPORTER_OTLP_PROTOCOL=http/json \
OTEL_BSP_SCHEDULE_DELAY=1000 NODE_OPTIONS="--require $T/attach/node_modules/@neat.is/otel-node/register.cjs" \
UPTIME_KUMA_PORT=3105 UPTIME_KUMA_HOST=127.0.0.1 nohup node server/server.js > $T/logs/kuma.log 2>&1 < /dev/null &
echo $! > $T/kuma.pid
for i in $(seq 1 90); do curl -sf -o /dev/null http://127.0.0.1:3105/ && break; sleep 2; done
step "kuma http: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3105/)"
node $T/../kuma-drive.cjs $T/src 3105 45
step done
