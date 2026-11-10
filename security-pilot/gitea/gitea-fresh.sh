#!/usr/bin/env bash
# Parameterized per-trial standup for Gitea (adapted from gitea-opt3.sh + gitea-run.sh).
# ===========================================================================================
# UNVALIDATED (per the task's ADAPTATIONS note: gitea v28.2.0 = go 1.27; re-check that the
# /modules/web/ router-wrapper path (__SKIP__) still holds at that tag). This script is a faithful
# parameterization of the two PROVEN recipes, built per-trial against the fresh checkout. It has
# NOT been run end-to-end by the FreshProvisioner dry test (nodegoat was the validated target).
# Debug checklist before trusting it:
#   1. go build succeeds (tail $WORK/logs/build.log); matched.json shows neat_* rules applied.
#   2. the /modules/web/ router wrapper is still matched at v28.2.0 (grep matched.json).
#   3. gitea web answers /api/v1/version; OBSERVED edges materialize on the daemon.
# ===========================================================================================
# Env contract: ARM SRC WORK APP_PORT OTLP_TRACES_ENDPOINT OTLP_PROTOCOL SIDECAR(unused) APP_DIR NODE_BIN
set -uo pipefail
step() { echo "[$(date +%T)] [gitea-fresh] $*"; }
export PATH="$NODE_BIN:$PATH"
mkdir -p "$WORK/logs" "$WORK/data" "$WORK/home"

O="$APP_DIR/otelc"                 # stock otelc clone (shared, read-only)
TC="$APP_DIR/toolchain/go/bin"     # pinned go toolchain (shared)
# GOTMPDIR -> the per-trial work dir (on the big disk, cleaned by teardown). otelc runs
# `go build -work`, which KEEPS the ~1.5G build WORK dir; without this it lands in /tmp (a 15G
# tmpfs) and accumulates across trials until the linker hits ENOSPC.
mkdir -p "$WORK/gotmp"
export PATH="$TC:$PATH" GOPATH="$APP_DIR/gopath" GOCACHE="$APP_DIR/gocache" GOMODCACHE="$APP_DIR/gopath/pkg/mod" GOTOOLCHAIN=local GOFLAGS=-modcacherw GOTMPDIR="$WORK/gotmp"
W="$WORK/neat-otelc-ws"            # per-trial GOWORK sidecar pointing at THIS checkout
rm -rf "$W"; mkdir -p "$W/rules"

# 1. GOWORK sidecar (verbatim from gitea-opt3.sh, but __ROOT__ => the fresh SRC).
cd "$W"
printf 'module neat.local/otelcws\n\ngo 1.27\n' > go.mod
printf '// Package rules carries NEAT'\''s otelc rules.\npackage rules\n' > rules/stub.go
sed -e "s|__ROOT__|$SRC|g" -e "s|__SKIP__|/modules/web/|g" -e "s#__DBSKIP__#/models/db/#g" "$APP_DIR/neat.otelc.yaml.tmpl" > rules/otelc.yaml
IMPORTS="net/http/server net/http/client database/sql go.opentelemetry.io/otel/sdk/trace go.opentelemetry.io/otel go.opentelemetry.io/otel/trace go.opentelemetry.io/otel/init runtime log log/slog"
{
  echo "//go:build tools"; echo; echo "package tools"; echo; echo "import ("
  for i in $IMPORTS; do echo "	_ \"go.opentelemetry.io/otelc/instrumentation/$i\""; done
  echo "	_ \"neat.local/otelcws/rules\""; echo ")"
} > otel.instrumentation.go
{
  echo "go 1.27.3"; echo; echo "use ("; echo "	$SRC"; echo "	$W"; echo ")"; echo
  find "$O" -name go.mod -not -path "*/test/*" -not -path "*/demo/*" -not -path "*/.otelc-build/*" | while read -r f; do
    m=$(grep -m1 "^module " "$f" | cut -d" " -f2); echo "replace $m => $(dirname "$f")"
  done
} > go.work
for i in $IMPORTS; do echo "require go.opentelemetry.io/otelc/instrumentation/$i v0.0.0" >> go.mod; done

# 2. build the instrumented binary from the fresh checkout.
step "otelc build (go $(go version 2>/dev/null | awk '{print $3}'))"
cd "$SRC"
RULES=""; for i in $IMPORTS; do RULES="$RULES$O/instrumentation/$i/,"; done; RULES="$RULES$W/rules/otelc.yaml"
GOWORK="$W/go.work" "$O/otelc" --rules "$RULES" go build -tags 'sqlite sqlite_unlock_notify' -o "$WORK/bin/gitea" . > "$WORK/logs/build.log" 2>&1 \
  || { step "BUILD FAILED"; tail -30 "$WORK/logs/build.log"; exit 4; }

# Capture the otelc match evidence BEFORE the per-trial tree is torn down: the rule histogram and
# whether the /modules/web/ router-wrapper (__SKIP__) is still matched at this tag (go1.27/v28.2.0).
if [ -f "$SRC/.otelc-build/matched.json" ]; then
  cp "$SRC/.otelc-build/matched.json" "$APP_DIR/last-matched-$ARM.json" 2>/dev/null || true
  step "matched neat_* rules:"; grep -o "neat_[a-z_]*" "$SRC/.otelc-build/matched.json" 2>/dev/null | sort | uniq -c
  n_web=$(grep -o "modules/web/[^\"]*" "$SRC/.otelc-build/matched.json" 2>/dev/null | sort -u | wc -l)
  step "/modules/web/ entries in matched.json: $n_web (SKIP target; non-zero means the wrapper is being matched)"
  grep -o "modules/web/[^\"]*" "$SRC/.otelc-build/matched.json" 2>/dev/null | sort -u | head
fi

# 3. config: sqlite, install-locked, loopback only, state under $WORK. Preserve the SSH-key safety.
cat > "$WORK/app.ini" <<INI
APP_NAME = gitea-pilot
RUN_MODE = prod
WORK_PATH = $WORK/data
[server]
HTTP_ADDR = 127.0.0.1
HTTP_PORT = $APP_PORT
ROOT_URL = http://127.0.0.1:$APP_PORT/
DISABLE_SSH = true
START_SSH_SERVER = false
SSH_CREATE_AUTHORIZED_KEYS_FILE = false
SSH_CREATE_AUTHORIZED_PRINCIPALS_FILE = false
OFFLINE_MODE = true
STATIC_ROOT_PATH = $SRC
[database]
DB_TYPE = sqlite3
PATH = $WORK/data/gitea.db
[security]
INSTALL_LOCK = true
SECRET_KEY = <redacted>
[webhook]
ALLOWED_HOST_LIST = loopback
[log]
MODE = file
ROOT_PATH = $WORK/logs
INI

# Gitea writes to $HOME (ssh/git config); redirect it so it never touches ~/.ssh/authorized_keys.
export HOME="$WORK/home"
export OTEL_SERVICE_NAME=gitea \
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="$OTLP_TRACES_ENDPOINT" \
  OTEL_EXPORTER_OTLP_PROTOCOL="${OTLP_PROTOCOL:-http/protobuf}" \
  OTEL_LOGS_EXPORTER=none OTEL_METRICS_EXPORTER=none OTEL_BSP_SCHEDULE_DELAY=1000
BIN="$WORK/bin/gitea"

# webhook sink (the outbound call when a hook is tested).
SINK_PORT="${SINK_PORT:-0}"
python3 -m http.server "${GITEA_SINK_PORT:-3199}" --bind 127.0.0.1 > "$WORK/logs/sink.log" 2>&1 < /dev/null &
echo $! > "$WORK/sink.pid"; SINKPID=$!

"$BIN" migrate -c "$WORK/app.ini" > "$WORK/logs/migrate.log" 2>&1
"$BIN" admin user create --admin --username neat --password '<redacted>' --email neat@example.invalid --must-change-password=<redacted> -c "$WORK/app.ini" > "$WORK/logs/user.log" 2>&1

step "gitea web on :$APP_PORT (arm=$ARM)"
nohup "$BIN" web -c "$WORK/app.ini" > "$WORK/logs/app.log" 2>&1 < /dev/null &
echo $! > "$WORK/app.pid"
# teardown also needs the sink pid; fold it into app teardown by appending to a side pid list.
echo "$SINKPID" >> "$WORK/extra-pids"
for i in $(seq 1 60); do curl -sf "http://127.0.0.1:$APP_PORT/api/v1/version" >/dev/null 2>&1 && break; sleep 1; done
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$APP_PORT/api/v1/version")"
step "gitea version http: $code"
[ "$code" = "000" ] && { step "FATAL: app did not come up"; tail -30 "$WORK/logs/app.log"; exit 5; }

# 4. API traffic + a webhook to the local sink.
A="-s -u neat:changeme -H Content-Type:application/json"
B="http://127.0.0.1:$APP_PORT/api/v1"
curl $A -X POST $B/user/repos -d '{"name":"demo","auto_init":true}' -o /dev/null -w "create repo %{http_code}\n"
curl $A -X POST $B/repos/neat/demo/issues -d '{"title":"first issue","body":"hello"}' -o /dev/null -w "create issue %{http_code}\n"
curl $A "$B/repos/search?q=demo" -o /dev/null -w "search repos %{http_code}\n"
curl $A "$B/repos/neat/demo/issues" -o /dev/null -w "list issues %{http_code}\n"
HOOK=$(curl $A -X POST $B/repos/neat/demo/hooks -d "{\"type\":\"gitea\",\"config\":{\"url\":\"http://127.0.0.1:${GITEA_SINK_PORT:-3199}/hook\",\"content_type\":\"json\"},\"events\":[\"push\"],\"active\":true}" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
[ -n "$HOOK" ] && curl $A -X POST "$B/repos/neat/demo/hooks/$HOOK/tests" -o /dev/null -w "test hook %{http_code}\n"
sleep 6
step "done"
