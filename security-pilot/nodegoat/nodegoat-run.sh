#!/usr/bin/env bash
# Security pilot: NodeGoat (c5cb68a) observed by NEAT.
# mongo:4.0 on 127.0.0.1:27027, NEAT 0.11.0 daemon 127.0.0.1:8202/4402 (own NEAT_HOME),
# NodeGoat on 127.0.0.1:4102 with @neat.is/otel-node from main@c2aaa93 (sidecar, not
# a publish; carries the mongodb-core instrumentation #1599). Target manifest untouched.
set -uo pipefail
T=$HOME/neat-bench/security-pilot/nodegoat
export PATH=$HOME/.nvm/versions/node/v20.20.2/bin:$PATH
mkdir -p $T/logs $T/attach $T/neat-home
step() { echo "[$(date +%T)] $*"; }

if [ ! -d $T/src/.git ]; then
  git clone -q https://github.com/OWASP/NodeGoat.git $T/src && git -C $T/src checkout -q c5cb68a7084e4ae7dcc60e6a98768720a81841e8
fi
git -C $T/src rev-parse --short HEAD
if [ ! -d $T/src/node_modules ]; then
  step "npm ci (node $(node -v))"
  (cd $T/src && CYPRESS_INSTALL_BINARY=0 npm ci --no-audit --no-fund > $T/logs/npm-ci.log 2>&1) || { step "npm ci FAILED"; tail -25 $T/logs/npm-ci.log; exit 1; }
fi
if [ ! -d $T/attach/node_modules/@neat.is/otel-node ]; then
  (cd $T/attach && npm init -y >/dev/null && npm i --no-audit --no-fund $T/otel-node-main-c2aaa93.tgz > $T/logs/attach.log 2>&1) || { tail -20 $T/logs/attach.log; exit 1; }
fi

step "mongo:4.0"
docker inspect sec-pilot-nodegoat-mongo >/dev/null 2>&1 || docker run -d --name sec-pilot-nodegoat-mongo -p 127.0.0.1:27027:27017 mongo:4.0 >/dev/null
docker start sec-pilot-nodegoat-mongo >/dev/null
for i in $(seq 1 30); do docker exec sec-pilot-nodegoat-mongo mongo --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && break; sleep 1; done
export MONGODB_URI=mongodb://127.0.0.1:27027/nodegoat
step "seed"
(cd $T/src && NODE_ENV=test node artifacts/db-reset.js > $T/logs/seed.log 2>&1) || { tail -15 $T/logs/seed.log; }

step "neat daemon"
NEAT_HOME=$T/neat-home NEAT_WEB_DISABLED=1 PORT=8202 OTEL_PORT=4402 HOST=127.0.0.1 \
  nohup neat watch $T/src > $T/logs/neatd.log 2>&1 < /dev/null &
echo $! > $T/neatd.pid
for i in $(seq 1 90); do curl -sf http://127.0.0.1:8202/health >/dev/null 2>&1 && break; sleep 2; done
step "daemon: $(curl -s http://127.0.0.1:8202/health | head -c 160)"

step "nodegoat"
cd $T/src
PORT=4102 OTEL_SERVICE_NAME=nodegoat OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:4402/v1/traces \
OTEL_EXPORTER_OTLP_PROTOCOL=http/json OTEL_BSP_SCHEDULE_DELAY=1000 \
NODE_OPTIONS="--require $T/attach/node_modules/@neat.is/otel-node/register.cjs" \
  nohup node server.js > $T/logs/nodegoat.log 2>&1 < /dev/null &
echo $! > $T/nodegoat.pid
for i in $(seq 1 30); do curl -s -o /dev/null http://127.0.0.1:4102/login && break; sleep 1; done
step "login page: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:4102/login)"

# Traffic: log in as a seeded user, walk the app (reads + writes), hit research (outbound).
J=$T/cookies.txt; rm -f $J
C="curl -s -o /dev/null -b $J -c $J -w %{http_code}"
echo "login $($C -X POST -d 'userName=user1&password=<redacted>' http://127.0.0.1:4102/login)"
for p in /dashboard /profile /contributions /allocations/2 /memos /learn /benefits; do echo "GET $p $($C http://127.0.0.1:4102$p)"; done
echo "POST /contributions $($C -X POST -d 'preTax=2&afterTax=2&roth=2' http://127.0.0.1:4102/contributions)"
echo "POST /memos $($C -X POST -d 'memo=hello' http://127.0.0.1:4102/memos)"
echo "POST /profile $($C -X POST -d 'firstName=User&lastName=One&ssn=123&dob=2000-01-01&bankAcc=1&bankRouting=1%23&address=x' http://127.0.0.1:4102/profile)"
echo "GET /research $($C 'http://127.0.0.1:4102/research?url=http://example.com/&symbol=')"
sleep 4
step done
