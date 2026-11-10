#!/usr/bin/env bash
# Parameterized per-trial standup for NodeGoat (adapted from nodegoat-run.sh for FreshProvisioner).
# The checkout is already done by the provisioner (SRC). This installs deps + sidecar, stands up
# mongo + the instrumented app pointed at OTLP_TRACES_ENDPOINT, and drives baseline traffic so the
# OBSERVED layer materializes (NEAT arm) or the bare collector captures it (BARE arm). It does NOT
# start the NEAT daemon or the collector; the harness owns those (so teardown is clean via pid files).
# Env contract (all required unless noted):
#   ARM                  neat | bare
#   SRC                  fresh checkout dir (source present, node_modules may be absent)
#   WORK                 per-trial work dir (logs + pid files land here)
#   APP_PORT             app http port
#   OTLP_TRACES_ENDPOINT e.g. http://127.0.0.1:4402/v1/traces (daemon OTEL_PORT, or collector http)
#   OTLP_ENDPOINT        base, e.g. http://127.0.0.1:4402 (logs derive /v1/logs from here)
#   OTLP_PROTOCOL        http/json
#   SIDECAR              abs path to @neat.is/otel-node/register.cjs
#   MONGO_PORT           host port for the per-trial mongo:4.0
#   MONGO_NAME           per-trial docker container name
#   APP_DIR              ~/neat-bench/security-pilot/nodegoat (holds the otel-node tgz + shared attach)
#   NODE_BIN             dir to prepend to PATH (node 20)
set -uo pipefail
step() { echo "[$(date +%T)] [nodegoat-fresh] $*"; }
export PATH="$NODE_BIN:$PATH"
mkdir -p "$WORK/logs"

# 1. shared sidecar (read-only at runtime; install once into APP_DIR/attach).
if [ ! -d "$APP_DIR/attach/node_modules/@neat.is/otel-node" ]; then
  step "install sidecar"
  mkdir -p "$APP_DIR/attach"
  TGZ="${OTEL_NODE_TGZ:-$(ls -1 "$APP_DIR"/otel-node-main-*.tgz 2>/dev/null | head -1)}"
  [ -n "$TGZ" ] || { step "FATAL: no otel-node tgz in $APP_DIR"; exit 3; }
  (cd "$APP_DIR/attach" && npm init -y >/dev/null 2>&1 && npm i --no-audit --no-fund "$TGZ" > "$WORK/logs/attach.log" 2>&1) || { step "sidecar install FAILED"; tail -20 "$WORK/logs/attach.log"; exit 3; }
fi
[ -f "$SIDECAR" ] || { step "FATAL: SIDECAR missing: $SIDECAR"; exit 3; }

# 2. deps into the fresh checkout.
if [ ! -d "$SRC/node_modules" ]; then
  step "npm ci (node $(node -v))"
  if ! (cd "$SRC" && CYPRESS_INSTALL_BINARY=0 npm ci --no-audit --no-fund > "$WORK/logs/npm-ci.log" 2>&1); then
    step "npm ci failed, trying npm install"
    (cd "$SRC" && CYPRESS_INSTALL_BINARY=0 npm install --no-audit --no-fund > "$WORK/logs/npm-install.log" 2>&1) || { step "npm install FAILED"; tail -25 "$WORK/logs/npm-install.log"; exit 4; }
  fi
fi

# 3. mongo:4.0 (per-trial container, own host port). Record it for teardown.
step "mongo:4.0 $MONGO_NAME @127.0.0.1:$MONGO_PORT"
docker inspect "$MONGO_NAME" >/dev/null 2>&1 || docker run -d --name "$MONGO_NAME" -p "127.0.0.1:$MONGO_PORT:27017" mongo:4.0 >/dev/null 2>&1
docker start "$MONGO_NAME" >/dev/null 2>&1
echo "$MONGO_NAME" >> "$WORK/docker-containers"
for i in $(seq 1 40); do docker exec "$MONGO_NAME" mongo --quiet --eval 'db.runCommand({ping:1}).ok' 2>/dev/null | grep -q 1 && break; sleep 1; done

export MONGODB_URI="mongodb://127.0.0.1:$MONGO_PORT/nodegoat"
step "seed"
(cd "$SRC" && NODE_ENV=test node artifacts/db-reset.js > "$WORK/logs/seed.log" 2>&1) || { step "seed warning"; tail -10 "$WORK/logs/seed.log"; }

# 4. instrumented app -> OTLP endpoint (daemon for neat arm, collector for bare arm).
step "start app on :$APP_PORT (arm=$ARM) -> $OTLP_TRACES_ENDPOINT"
cd "$SRC"
PORT="$APP_PORT" OTEL_SERVICE_NAME=nodegoat \
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="$OTLP_TRACES_ENDPOINT" \
  OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_ENDPOINT" \
  OTEL_EXPORTER_OTLP_PROTOCOL="$OTLP_PROTOCOL" \
  OTEL_BSP_SCHEDULE_DELAY=1000 \
  NODE_OPTIONS="--require $SIDECAR" \
  nohup node server.js > "$WORK/logs/app.log" 2>&1 < /dev/null &
echo $! > "$WORK/app.pid"

for i in $(seq 1 40); do curl -s -o /dev/null "http://127.0.0.1:$APP_PORT/login" && break; sleep 1; done
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APP_PORT/login")"
step "login page: $code"
if [ "$code" = "000" ]; then step "FATAL: app did not come up"; tail -30 "$WORK/logs/app.log"; exit 5; fi

# 5. baseline traffic: login as a seeded user, walk reads + writes, hit outbound research.
J="$WORK/cookies.txt"; rm -f "$J"
C="curl -s -o /dev/null -b $J -c $J -w %{http_code}"
echo "login $($C -X POST -d 'userName=user1&password=<redacted>' http://127.0.0.1:$APP_PORT/login)"
for p in /dashboard /profile /contributions /allocations/2 /memos /learn /benefits /tutorial; do echo "GET $p $($C http://127.0.0.1:$APP_PORT$p)"; done
echo "POST /contributions $($C -X POST -d 'preTax=2&afterTax=2&roth=2' http://127.0.0.1:$APP_PORT/contributions)"
echo "POST /memos $($C -X POST -d 'memo=hello' http://127.0.0.1:$APP_PORT/memos)"
echo "POST /profile $($C -X POST -d 'firstName=User&lastName=One&ssn=123&dob=2000-01-01&bankAcc=1&bankRouting=1%23&address=x' http://127.0.0.1:$APP_PORT/profile)"
echo "GET /research $($C 'http://127.0.0.1:$APP_PORT/research?url=http://example.com/&symbol=AAPL')"
sleep 5
step "done"
