#!/usr/bin/env bash
# Parameterized per-trial standup for paperless-ngx (adapted from paperless-run.sh).
# ===========================================================================================
# UNVALIDATED (per the task's ADAPTATIONS note). Corpus pins v2.15.3 (the recipe targeted 3.4.2),
# a DIFFERENT base image. Adaptations applied here vs the recipe:
#   - base image => paperless-ngx:2.15.3; per-trial postgres/redis on FRESH host ports (no fixed
#     5433/6380); app on $APP_PORT; OTLP => the harness-owned endpoint.
#   - site-packages path is DERIVED at build (via /neat-otel-autopath), NOT hard-coded to python3.14.
#   - the FRESH checkout source is bind-mounted over /usr/src/paperless/src so a dep fix is reflected.
# Open items to debug before trusting it:
#   1. ghcr.io/paperless-ngx/paperless-ngx:2.15.3 base layout (granian vs gunicorn s6 webserver;
#      sitecustomize must cover whichever ships). 2. templating path src/documents/templating/filepath.py
#      at 2.15.3. 3. that the bind-mounted source does not break the image's prebuilt venv.
# NOT run end-to-end by the dry test (nodegoat was the validated target).
# ===========================================================================================
# Env contract: ARM SRC WORK APP_PORT OTLP_TRACES_ENDPOINT OTLP_PROTOCOL APP_DIR NODE_BIN
#   PG_PORT REDIS_PORT PG_NAME REDIS_NAME  (fresh per-trial, allocated by the harness; see note)
set -uo pipefail
step() { echo "[$(date +%T)] [paperless-fresh] $*"; }
export PATH="$NODE_BIN:$PATH"
mkdir -p "$WORK/logs" "$WORK/run/data" "$WORK/run/media" "$WORK/run/consume" "$WORK/run/export"

# The harness allocates PG_PORT + REDIS_PORT (both OS-assigned, fresh) and PG_NAME/REDIS_NAME and
# passes them through the env contract. Fallbacks kept only for a hand-run.
PG_PORT="${PG_PORT:-${MONGO_PORT:-5433}}"
REDIS_PORT="${REDIS_PORT:-$((PG_PORT + 1))}"
PG_NAME="${PG_NAME:-${MONGO_NAME:-sec-pilot-fresh-pg}-pg}"
REDIS_NAME="${REDIS_NAME:-${MONGO_NAME:-sec-pilot-fresh}-redis}"
IMG="sec-pilot/paperless-neat:2.15.3-$$"

# 1. derived image (adds neat-otel + instrumentations; site-packages derived, not hard-coded).
step "docker build $IMG"
cp "$APP_DIR/paperless-fresh.Dockerfile" "$APP_DIR/build/Dockerfile"
docker build -q -t "$IMG" "$APP_DIR/build" > "$WORK/logs/image.log" 2>&1 || { step "BUILD FAILED"; tail -20 "$WORK/logs/image.log"; exit 4; }
AUTOPATH="$(docker run --rm --entrypoint cat "$IMG" /neat-otel-autopath 2>/dev/null)"
[ -n "$AUTOPATH" ] || { step "FATAL: could not derive auto_instrumentation path"; exit 4; }
step "autopath=$AUTOPATH"

# 2. per-trial postgres + redis on fresh ports.
step "postgres :$PG_PORT + redis :$REDIS_PORT"
docker inspect "$PG_NAME" >/dev/null 2>&1 || docker run -d --name "$PG_NAME" -p "127.0.0.1:$PG_PORT:5432" \
  -e POSTGRES_DB=paperless -e POSTGRES_USER=paperless -e POSTGRES_PASSWORD=paperless postgres:16 >/dev/null 2>&1
docker inspect "$REDIS_NAME" >/dev/null 2>&1 || docker run -d --name "$REDIS_NAME" -p "127.0.0.1:$REDIS_PORT:6379" redis:7-alpine >/dev/null 2>&1
docker start "$PG_NAME" "$REDIS_NAME" >/dev/null 2>&1
echo "$PG_NAME" >> "$WORK/docker-containers"
echo "$REDIS_NAME" >> "$WORK/docker-containers"
sleep 5

# 3. paperless (host networking; fresh checkout bind-mounted so the agent's dep fix is reflected).
APP_CONT="${MONGO_NAME:-sec-pilot-fresh-paperless}-app"
docker rm -f "$APP_CONT" >/dev/null 2>&1 || true
step "paperless container $APP_CONT on :$APP_PORT (arm=$ARM)"
# NOTE: we do NOT bind-mount the checkout src over the image's /usr/src/paperless/src. The image
# ships collected static assets + a built frontend that whitenoise serves at startup; shadowing it
# with the raw checkout src crashes whitenoise (scantree). The paperless jinja2 CVE is LOCKFILE-ONLY
# (corpus), so the running app need not carry the checkout code for the OBSERVED layer; the GRADE
# reads the checkout lock via the /checkout mount (pip-audit) + host-side resolvePyPI(uv.lock). The
# daemon's EXTRACTED layer watches the checkout directly. (A code-level paperless fix would need a
# rebuild; out of scope for this lockfile-only target.)
docker run -d --name "$APP_CONT" --network host \
  -v "$SRC:/checkout:ro" \
  -v "$WORK/run/data:/usr/src/paperless/data" -v "$WORK/run/media:/usr/src/paperless/media" \
  -v "$WORK/run/consume:/usr/src/paperless/consume" -v "$WORK/run/export:/usr/src/paperless/export" \
  -e PYTHONPATH="/usr/src/paperless/src:$AUTOPATH" -e DJANGO_SETTINGS_MODULE=paperless.settings \
  -e PAPERLESS_DBHOST=127.0.0.1 -e PAPERLESS_DBPORT="$PG_PORT" -e PAPERLESS_REDIS="redis://127.0.0.1:$REDIS_PORT" \
  -e PAPERLESS_PORT="$APP_PORT" -e PAPERLESS_BIND_ADDR=127.0.0.1 -e PAPERLESS_ALLOWED_HOSTS=127.0.0.1,localhost \
  -e PAPERLESS_SECRET_KEY=<redacted> -e PAPERLESS_ADMIN_USER=admin -e PAPERLESS_ADMIN_PASSWORD=changeme \
  -e PAPERLESS_OCR_LANGUAGE=eng -e PAPERLESS_TASK_WORKERS=1 -e PAPERLESS_THREADS_PER_WORKER=1 -e PAPERLESS_WEBSERVER_WORKERS=1 \
  -e OTEL_SERVICE_NAME=paperless-ngx -e OTEL_TRACES_EXPORTER=otlp -e OTEL_METRICS_EXPORTER=none -e OTEL_LOGS_EXPORTER=none \
  -e OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="$OTLP_TRACES_ENDPOINT" -e OTEL_EXPORTER_OTLP_PROTOCOL="${OTLP_PROTOCOL:-http/protobuf}" \
  -e OTEL_BSP_SCHEDULE_DELAY=1000 \
  "$IMG" >/dev/null 2>&1 || { step "run FAILED"; docker logs "$APP_CONT" 2>&1 | tail -20; exit 5; }
echo "$APP_CONT" >> "$WORK/docker-containers"
# The grader's PyPI cross-check docker-exec's pip-audit into THIS container at grade time.
echo "$APP_CONT" > "$WORK/paperless-container"

for i in $(seq 1 120); do curl -sf -o /dev/null -u admin:changeme "http://127.0.0.1:$APP_PORT/api/" && break; sleep 3; done
code="$(curl -s -o /dev/null -w '%{http_code}' -u admin:changeme "http://127.0.0.1:$APP_PORT/api/")"
step "api: $code"
[ "$code" = "000" ] && { step "FATAL: app did not come up"; docker logs "$APP_CONT" 2>&1 | tail -30; exit 5; }

# 4. traffic: API reads, metadata writes, one document upload (rides celery).
A="-s -o /dev/null -w %{http_code} -u admin:changeme"
B="http://127.0.0.1:$APP_PORT/api"
for p in documents/ tags/ correspondents/ document_types/ saved_views/ tasks/ ui_settings/ statistics/; do echo "GET $p $(curl $A $B/$p)"; done
echo "POST tag $(curl $A -H Content-Type:application/json -X POST -d '{"name":"pilot"}' $B/tags/)"
echo "POST correspondent $(curl $A -H Content-Type:application/json -X POST -d '{"name":"ACME"}' $B/correspondents/)"
printf 'NEAT pilot invoice 42\nTotal 10 EUR\n' > "$WORK/run/pilot.txt"
echo "POST upload $(curl $A -F document=@$WORK/run/pilot.txt -F title=pilot-doc $B/documents/post_document/)"
sleep 20
step "done"
