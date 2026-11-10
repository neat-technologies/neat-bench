#!/usr/bin/env bash
# Parameterized per-trial standup for uptime-kuma (adapted from kuma-obs-run.sh for FreshProvisioner).
# Checkout is already done by the provisioner (SRC). Installs deps + dist + sidecar, stands up the
# instrumented app pointed at OTLP_TRACES_ENDPOINT, and drives socket.io journeys so OBSERVED
# materializes (NEAT arm) / the bare collector captures it (BARE arm). Does NOT start the daemon or
# collector (the harness owns those). Kuma renames its process title, so the pid file is the handle.
# Env contract:
#   ARM SRC WORK APP_PORT OTLP_TRACES_ENDPOINT OTLP_ENDPOINT OTLP_PROTOCOL SIDECAR APP_DIR NODE_BIN
#   OTEL_NODE_TGZ  abs path to the @neat.is/otel-node tarball (for the shared sidecar)
#   DRIVER         abs path to kuma-drive.cjs
#   DRIVE_SECS     hold seconds for the driver (default 10)
set -uo pipefail
step() { echo "[$(date +%T)] [kuma-fresh] $*"; }
export PATH="$NODE_BIN:$PATH"
mkdir -p "$WORK/logs"
DRIVE_SECS="${DRIVE_SECS:-10}"

if [ ! -d "$APP_DIR/attach/node_modules/@neat.is/otel-node" ]; then
  step "install sidecar"
  mkdir -p "$APP_DIR/attach"
  TGZ="${OTEL_NODE_TGZ:-$(ls -1 "$APP_DIR"/../nodegoat/otel-node-main-*.tgz 2>/dev/null | head -1)}"
  [ -n "$TGZ" ] || { step "FATAL: no otel-node tgz"; exit 3; }
  (cd "$APP_DIR/attach" && npm init -y >/dev/null 2>&1 && npm i --no-audit --no-fund "$TGZ" > "$WORK/logs/attach.log" 2>&1) || { step "sidecar install FAILED"; tail -20 "$WORK/logs/attach.log"; exit 3; }
fi
[ -f "$SIDECAR" ] || { step "FATAL: SIDECAR missing: $SIDECAR"; exit 3; }

if [ ! -d "$SRC/node_modules" ]; then
  step "npm ci (node $(node -v))"
  (cd "$SRC" && npm ci --no-audit --no-fund > "$WORK/logs/npm-ci.log" 2>&1) || { step "npm ci FAILED"; tail -25 "$WORK/logs/npm-ci.log"; exit 4; }
fi
if [ ! -f "$SRC/dist/index.html" ]; then
  step "download-dist"
  (cd "$SRC" && npm run download-dist > "$WORK/logs/dist.log" 2>&1) || { step "download-dist warning"; tail -10 "$WORK/logs/dist.log"; }
fi
mkdir -p "$SRC/data"; [ -f "$SRC/data/db-config.json" ] || echo '{"type":"sqlite"}' > "$SRC/data/db-config.json"

step "start app on :$APP_PORT (arm=$ARM) -> $OTLP_TRACES_ENDPOINT"
cd "$SRC"
OTEL_SERVICE_NAME=uptime-kuma \
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="$OTLP_TRACES_ENDPOINT" \
  OTEL_EXPORTER_OTLP_ENDPOINT="$OTLP_ENDPOINT" \
  OTEL_EXPORTER_OTLP_PROTOCOL="$OTLP_PROTOCOL" \
  OTEL_BSP_SCHEDULE_DELAY=1000 \
  NODE_OPTIONS="--require $SIDECAR" \
  UPTIME_KUMA_PORT="$APP_PORT" UPTIME_KUMA_HOST=127.0.0.1 \
  nohup node server/server.js > "$WORK/logs/app.log" 2>&1 < /dev/null &
echo $! > "$WORK/app.pid"

for i in $(seq 1 90); do curl -sf -o /dev/null "http://127.0.0.1:$APP_PORT/" && break; sleep 2; done
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APP_PORT/")"
step "kuma http: $code"
if [ "$code" = "000" ]; then step "FATAL: app did not come up"; tail -30 "$WORK/logs/app.log"; exit 5; fi

step "drive journeys (socket.io, ${DRIVE_SECS}s)"
node "$DRIVER" "$SRC" "$APP_PORT" "$DRIVE_SECS" > "$WORK/logs/drive.log" 2>&1 || { step "driver warning"; tail -15 "$WORK/logs/drive.log"; }
sleep 3
step "done"
