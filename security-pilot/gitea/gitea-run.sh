#!/usr/bin/env bash
# ADR-A research gate, run half: isolated NEAT 0.11.0 daemon (127.0.0.1:8204 REST,
# 4404 OTLP, own NEAT_HOME) on the Gitea source, then the otelc-built Gitea on
# 127.0.0.1:3104, then API traffic. Usage: gitea-run.sh [otelc|plain]
set -uo pipefail
VARIANT=${1:-otelc}
T=$HOME/neat-bench/security-pilot/gitea
export PATH=$HOME/.nvm/versions/node/v20.20.2/bin:$PATH
R=$T/run-$VARIANT; mkdir -p $R/data $R/neat-home $R/logs $R/home
step() { echo "[$(date +%T)] $*"; }

# Gitea config: sqlite, install locked, localhost only, all state under $R.
cat > $R/app.ini <<INI
APP_NAME = gitea-pilot
RUN_MODE = prod
WORK_PATH = $R/data
[server]
HTTP_ADDR = 127.0.0.1
HTTP_PORT = 3104
ROOT_URL = http://127.0.0.1:3104/
DISABLE_SSH = true
START_SSH_SERVER = false
SSH_CREATE_AUTHORIZED_KEYS_FILE = false
SSH_CREATE_AUTHORIZED_PRINCIPALS_FILE = false
OFFLINE_MODE = true
; no bindata build: templates/locale/options are read from the source tree
STATIC_ROOT_PATH = $T/src
[database]
DB_TYPE = sqlite3
PATH = $R/data/gitea.db
[security]
INSTALL_LOCK = true
SECRET_KEY = <redacted>
[webhook]
ALLOWED_HOST_LIST = loopback
[log]
MODE = file
ROOT_PATH = $R/logs
INI

step "neat daemon"
NEAT_HOME=$R/neat-home NEAT_WEB_DISABLED=1 PORT=8204 OTEL_PORT=4404 HOST=127.0.0.1 \
  nohup neat watch $T/src > $R/logs/neatd.log 2>&1 < /dev/null &
echo $! > $R/neatd.pid
for i in $(seq 1 150); do curl -sf http://127.0.0.1:8204/health >/dev/null 2>&1 && break; sleep 2; done
step "daemon health: $(curl -s http://127.0.0.1:8204/health | head -c 200)"

# Webhook sink: the outbound call Gitea makes when a hook is tested.
nohup python3 -m http.server 3199 --bind 127.0.0.1 > $R/logs/sink.log 2>&1 < /dev/null &
echo $! > $R/sink.pid

export OTEL_SERVICE_NAME=gitea
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:4404/v1/traces
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_LOGS_EXPORTER=none OTEL_METRICS_EXPORTER=none
export OTEL_BSP_SCHEDULE_DELAY=1000

# Gitea writes to $HOME (ssh files, git config); keep every such write inside $R.
export HOME=$R/home
BIN=$T/bin/gitea-$VARIANT
$BIN migrate -c $R/app.ini > $R/logs/migrate.log 2>&1
$BIN admin user create --admin --username neat --password '<redacted>' --email neat@example.invalid --must-change-password=<redacted> -c $R/app.ini > $R/logs/user.log 2>&1
step "gitea web"
nohup $BIN web -c $R/app.ini > $R/logs/gitea.log 2>&1 < /dev/null &
echo $! > $R/gitea.pid
for i in $(seq 1 60); do curl -sf http://127.0.0.1:3104/api/v1/version >/dev/null 2>&1 && break; sleep 1; done
step "gitea version: $(curl -s http://127.0.0.1:3104/api/v1/version)"

A='-s -u neat:changeme -H Content-Type:application/json'
B=http://127.0.0.1:3104/api/v1
curl $A -X POST $B/user/repos -d '{"name":"demo","auto_init":true}' -o /dev/null -w "create repo %{http_code}\n"
curl $A -X POST $B/repos/neat/demo/issues -d '{"title":"first issue","body":"hello"}' -o /dev/null -w "create issue %{http_code}\n"
curl $A "$B/repos/search?q=demo" -o /dev/null -w "search repos %{http_code}\n"
curl $A "$B/users/search?q=neat" -o /dev/null -w "search users %{http_code}\n"
curl $A "$B/repos/neat/demo/issues" -o /dev/null -w "list issues %{http_code}\n"
HOOK=$(curl $A -X POST $B/repos/neat/demo/hooks -d '{"type":"gitea","config":{"url":"http://127.0.0.1:3199/hook","content_type":"json"},"events":["push"],"active":true}' | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
curl $A -X POST "$B/repos/neat/demo/hooks/$HOOK/tests" -o /dev/null -w "test hook $HOOK %{http_code}\n"
sleep 8
step "sink saw: $(grep -c 'POST /hook' $R/logs/sink.log) webhook POSTs"
step done
