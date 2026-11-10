#!/usr/bin/env bash
# Security pilot: Paperless-ngx 3.4.2 observed by NEAT. Host networking, all on
# 127.0.0.1: postgres 5433, redis 6380, paperless 8103, NEAT 0.11.0 daemon 8203/4403.
set -uo pipefail
T=$HOME/neat-bench/security-pilot/paperless-ngx
export PATH=$HOME/.nvm/versions/node/v20.20.2/bin:$PATH
mkdir -p $T/logs $T/neat-home $T/run/{data,media,consume,export}
step() { echo "[$(date +%T)] $*"; }

[ -d $T/src/.git ] || git clone -q --depth 1 --branch v3.4.2 https://github.com/paperless-ngx/paperless-ngx.git $T/src
git -C $T/src rev-parse --short HEAD

step "image"
cp $T/paperless-Dockerfile $T/build/Dockerfile
docker build -q -t sec-pilot/paperless-neat:3.4.2 $T/build > $T/logs/image.log 2>&1 || { tail -20 $T/logs/image.log; exit 1; }
docker run --rm --entrypoint cat sec-pilot/paperless-neat:3.4.2 /neat-otel-autopath

step "postgres + redis"
docker inspect sec-pilot-paperless-db >/dev/null 2>&1 || docker run -d --name sec-pilot-paperless-db -p 127.0.0.1:5433:5432 \
  -e POSTGRES_DB=paperless -e POSTGRES_USER=paperless -e POSTGRES_PASSWORD=paperless postgres:16 >/dev/null
docker inspect sec-pilot-paperless-redis >/dev/null 2>&1 || docker run -d --name sec-pilot-paperless-redis -p 127.0.0.1:6380:6379 redis:7-alpine >/dev/null
docker start sec-pilot-paperless-db sec-pilot-paperless-redis >/dev/null

step "neat daemon"
NEAT_HOME=$T/neat-home NEAT_WEB_DISABLED=1 PORT=8203 OTEL_PORT=4403 HOST=127.0.0.1 \
  nohup neat watch $T/src > $T/logs/neatd.log 2>&1 < /dev/null &
echo $! > $T/neatd.pid
for i in $(seq 1 90); do curl -sf http://127.0.0.1:8203/health >/dev/null 2>&1 && break; sleep 2; done
step "daemon: $(curl -s http://127.0.0.1:8203/health | head -c 160)"

step "paperless"
docker rm -f sec-pilot-paperless >/dev/null 2>&1
docker run -d --name sec-pilot-paperless --network host \
  -v $T/run/data:/usr/src/paperless/data -v $T/run/media:/usr/src/paperless/media \
  -v $T/run/consume:/usr/src/paperless/consume -v $T/run/export:/usr/src/paperless/export \
  -e PAPERLESS_DBHOST=127.0.0.1 -e PAPERLESS_DBPORT=5433 -e PAPERLESS_REDIS=redis://127.0.0.1:6380 \
  -e PAPERLESS_PORT=8103 -e PAPERLESS_BIND_ADDR=127.0.0.1 -e PAPERLESS_ALLOWED_HOSTS=127.0.0.1,localhost \
  -e PAPERLESS_SECRET_KEY=<redacted> -e PAPERLESS_ADMIN_USER=admin -e PAPERLESS_ADMIN_PASSWORD=changeme \
  -e PAPERLESS_OCR_LANGUAGE=eng -e PAPERLESS_TASK_WORKERS=1 -e PAPERLESS_THREADS_PER_WORKER=1 -e PAPERLESS_WEBSERVER_WORKERS=1 \
  -e OTEL_SERVICE_NAME=paperless-ngx -e OTEL_TRACES_EXPORTER=otlp -e OTEL_METRICS_EXPORTER=none -e OTEL_LOGS_EXPORTER=none \
  -e OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:4403/v1/traces -e OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
  -e OTEL_BSP_SCHEDULE_DELAY=1000 \
  sec-pilot/paperless-neat:3.4.2 >/dev/null
for i in $(seq 1 120); do curl -sf -o /dev/null http://127.0.0.1:8103/api/ -u admin:changeme && break; sleep 3; done
step "api: $(curl -s -o /dev/null -w '%{http_code}' -u admin:changeme http://127.0.0.1:8103/api/)"

# Traffic: API reads, metadata writes, one document upload (goes through celery).
A="-s -o /dev/null -w %{http_code} -u admin:changeme"
B=http://127.0.0.1:8103/api
for p in documents/ tags/ correspondents/ document_types/ saved_views/ tasks/ ui_settings/ statistics/; do echo "GET $p $(curl $A $B/$p)"; done
echo "POST tag $(curl $A -H Content-Type:application/json -X POST -d '{"name":"pilot"}' $B/tags/)"
echo "POST correspondent $(curl $A -H Content-Type:application/json -X POST -d '{"name":"ACME"}' $B/correspondents/)"
printf 'NEAT pilot invoice 42\nTotal 10 EUR\n' > $T/run/pilot.txt
echo "POST upload $(curl $A -F document=@$T/run/pilot.txt -F title=pilot-doc $B/documents/post_document/)"
sleep 20
echo "GET documents after consume: $(curl -s -u admin:changeme $B/documents/ | python3 -c 'import sys,json; print(json.load(sys.stdin).get("count"))')"
step done
