#!/usr/bin/env bash
# harness/provision/lib.sh
# ─────────────────────────────────────────────────────────────────────────────
# Generic, descriptor-driven spine helpers for neat-bench.
#
# This is the target-neutral extraction of the reusable orchestration spine from
# the fixture harness at ../neat-agent-bench. Where that repo hardcoded the
# Express+Mongoose app, everything here reads from a target descriptor (jq) so
# the same steps work for any target: clone+pin a repo, stand up datastores,
# build @neat.is/core from a LOCAL Neat checkout ($NEAT_REPO), `neat init --apply`
# to instrument, run a scoped daemon on an isolated NEAT_HOME + non-default ports,
# drive traffic, then capture /graph + /graph/divergences over REST.
#
# Reused patterns are cited inline as:  [from neat-agent-bench/<file>].
#
# Sourced by provision.sh. Not meant to be executed directly.
# set -euo pipefail is set by the caller; we only add nounset-safe guards here.
# ─────────────────────────────────────────────────────────────────────────────

# ── path resolution [from neat-agent-bench/harness/lib.sh §resolve paths] ─────
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/../.." && pwd)"          # neat-bench repo root
HARNESS_DIR="$REPO_ROOT/harness"

# WORK holds per-target clones, logs, and the isolated NEAT_HOME. Gitignored.
WORK="${WORK:-$REPO_ROOT/work}"
RESULTS="${RESULTS:-$REPO_ROOT/results}"

# ── NEAT checkout under test [from neat-agent-bench/harness/lib.sh §NEAT_REPO] ─
# neat-bench measures the code being shipped at HEAD. The published npm build
# under-instruments (its `neat init` omits the call-site span processor, so no
# file:line OBSERVED edges), so the version under test is a LOCAL Neat checkout.
NEAT_REPO="${NEAT_REPO:-$HOME/Documents/GitHub/Untitled/Neat}"
NEAT_CLI="${NEAT_CLI:-$NEAT_REPO/packages/core/dist/cli.cjs}"
NEAT_D="${NEAT_D:-$NEAT_REPO/packages/core/dist/neatd.cjs}"
NEAT_MCP_BIN="${NEAT_MCP_BIN:-$NEAT_REPO/packages/mcp/dist/index.cjs}"

# ── non-default ports [from neat-agent-bench/harness/lib.sh §ports] ───────────
# Non-default so we never collide with a stock daemon on 8080/4318/6338.
REST="${REST:-8090}"; OTLP="${OTLP:-4328}"; WEB="${WEB:-6338}"
D="http://127.0.0.1:$REST"

step() { echo; echo "▶ $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── descriptor accessors ─────────────────────────────────────────────────────
# All target-specific values come from the descriptor JSON via jq. Load once into
# a set of globals so the rest of the spine reads plain variables, not jq calls.
#
# Descriptor schema (see targets/queue-app.json for the annotated concrete one):
#   id, description, repo, commit, subdir?, language, node_version, service_id,
#   datastores[], env{}, install_cmd, install_cwd?, instrument{cmd,otel_init?},
#   entrypoint?, start_cmd?, healthcheck{path,port,expect_status?}?, traffic{}
load_descriptor() {
  DESCRIPTOR="$1"
  [ -f "$DESCRIPTOR" ] || die "target descriptor not found: $DESCRIPTOR"
  command -v jq >/dev/null || die "jq is required to read target descriptors"

  dq() { jq -r "$1 // empty" "$DESCRIPTOR"; }   # descriptor query, empty if null

  TARGET_ID="$(dq '.id')";               [ -n "$TARGET_ID" ]   || die "descriptor missing .id"
  REPO_URL="$(dq '.repo')";              [ -n "$REPO_URL" ]    || die "descriptor missing .repo"
  COMMIT="$(dq '.commit')";              [ -n "$COMMIT" ]      || die "descriptor missing .commit"
  SUBDIR="$(dq '.subdir')"                                          # optional: monorepo package
  NODE_VERSION="$(dq '.node_version')";  [ -n "$NODE_VERSION" ] || NODE_VERSION="20"
  SERVICE_ID="$(dq '.service_id')";      [ -n "$SERVICE_ID" ]  || die "descriptor missing .service_id"
  INSTALL_CMD="$(dq '.install_cmd')";    [ -n "$INSTALL_CMD" ] || INSTALL_CMD="npm install --no-audit --no-fund"
  INSTALL_CWD="$(dq '.install_cwd')"                                # optional: run install here (monorepo root)
  INSTRUMENT_CMD="$(dq '.instrument.cmd')"; [ -n "$INSTRUMENT_CMD" ] || INSTRUMENT_CMD="init --apply"
  OTEL_INIT_REL="$(dq '.instrument.otel_init')"                    # optional: path of generated preload

  ENTRYPOINT="$(dq '.entrypoint')"                                 # optional (only needed for the app-healthcheck arm)
  START_CMD="$(dq '.start_cmd')"                                   # optional
  HEALTH_PATH="$(dq '.healthcheck.path')"
  HEALTH_PORT="$(dq '.healthcheck.port')"
  HEALTH_EXPECT="$(dq '.healthcheck.expect_status')"; [ -n "$HEALTH_EXPECT" ] || HEALTH_EXPECT="200"

  # traffic block
  TRAFFIC_MODE="$(dq '.traffic.mode')";  [ -n "$TRAFFIC_MODE" ] || TRAFFIC_MODE="test-suite"
  TEST_CMD="$(dq '.traffic.test_cmd')"
  PRELOAD_OTEL="$(dq '.traffic.preload_otel')"; [ -n "$PRELOAD_OTEL" ] || PRELOAD_OTEL="true"
  SETTLE_SECONDS="$(dq '.traffic.settle_seconds')"; [ -n "$SETTLE_SECONDS" ] || SETTLE_SECONDS="8"

  # derived
  TARGET="$WORK/$TARGET_ID/target"                     # clone root
  APP_DIR="$TARGET${SUBDIR:+/$SUBDIR}"                 # package to instrument + run
  export NEAT_HOME="$WORK/$TARGET_ID/neat-home"        # isolated per target [from lib.sh §NEAT_HOME]
  PROJECT="$TARGET_ID"                                 # scoped daemon project name
  SVC="service:$SERVICE_ID"                            # node id for observed-dependencies [from lib.sh SVC=]
  GRAPH_OUT="$RESULTS/$TARGET_ID.graph.json"
  DIVERGENCES_OUT="$RESULTS/$TARGET_ID.divergences.json"

  # Node that RUNS THE TARGET (app + tests). The daemon runs on default `node`.
  # [from neat-agent-bench/harness/lib.sh §NODE20 split] — old target deps often
  # need an older Node; the descriptor pins node_version and we resolve a binary.
  resolve_node_target
}

# ── Node-version split [from neat-agent-bench/harness/lib.sh §NODE20] ─────────
# The daemon runs on whatever `node` is default; the target may need a specific
# major. Honor an explicit NODE_TARGET/NODE20 override, else probe a homebrew
# path for the requested major, else fall back to default node with a warning.
resolve_node_target() {
  NODE_TARGET="${NODE_TARGET:-${NODE20:-}}"
  if [ -z "$NODE_TARGET" ]; then
    local guess="/opt/homebrew/opt/node@${NODE_VERSION}/bin/node"
    [ -x "$guess" ] && NODE_TARGET="$guess"
  fi
  [ -n "$NODE_TARGET" ] && [ -x "$NODE_TARGET" ] || NODE_TARGET="$(command -v node)"
  local have; have="$("$NODE_TARGET" -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo '?')"
  if [ "$have" != "$NODE_VERSION" ]; then
    echo "WARNING: target wants Node $NODE_VERSION but NODE_TARGET is Node $have ($NODE_TARGET)." >&2
    echo "         If the target's deps break, set NODE_TARGET=/path/to/node${NODE_VERSION}." >&2
  fi
}

# ── preflight [from neat-agent-bench/reproduce.sh §0 preflight] ───────────────
preflight() {
  step "preflight"
  for bin in docker git jq curl node; do
    command -v "$bin" >/dev/null || die "missing required binary: $bin"
  done
  [ -d "$NEAT_REPO" ] || die "NEAT_REPO ($NEAT_REPO) not found. neat-bench needs a local Neat checkout (the published npm build under-instruments). Re-run with NEAT_REPO=/path/to/Neat"
  if [ ! -f "$NEAT_D" ] || [ ! -f "$NEAT_CLI" ]; then
    step "building @neat.is/core (repo bins missing) [from reproduce.sh §0]"
    ( cd "$NEAT_REPO" && npm run build --workspace @neat.is/core )
  fi
  mkdir -p "$WORK/$TARGET_ID" "$RESULTS"
}

# ── datastores [generic form of reproduce.sh §1 datastores] ──────────────────
# The fixture hardcoded Mongo + MailHog. Here every container comes from the
# descriptor's .datastores[]: name, image, ports[], env{}, ready_cmd, ready_expect.
# Containers are namespaced "<target-id>-<name>" and reused if already present.
datastores_up() {
  step "datastores (from descriptor .datastores[])"
  local n count; count="$(jq '.datastores | length' "$DESCRIPTOR")"
  for (( n=0; n<count; n++ )); do
    local name image cname
    name="$(jq -r ".datastores[$n].name" "$DESCRIPTOR")"
    image="$(jq -r ".datastores[$n].image" "$DESCRIPTOR")"
    cname="${TARGET_ID}-${name}"
    # -p flags
    local pargs=(); while IFS= read -r p; do [ -n "$p" ] && pargs+=(-p "$p"); done \
      < <(jq -r ".datastores[$n].ports[]?" "$DESCRIPTOR")
    # -e flags
    local eargs=(); while IFS= read -r kv; do [ -n "$kv" ] && eargs+=(-e "$kv"); done \
      < <(jq -r ".datastores[$n].env // {} | to_entries[] | \"\(.key)=\(.value)\"" "$DESCRIPTOR")

    if docker ps -a --format '{{.Names}}' | grep -qx "$cname"; then
      echo "  reuse $cname"; docker start "$cname" >/dev/null 2>&1 || true
    else
      echo "  run   $cname ($image)"
      docker run -d --name "$cname" "${pargs[@]}" "${eargs[@]}" "$image" >/dev/null
    fi
  done
  datastores_wait
}

# Block until each datastore answers its ready_cmd (run inside the container).
datastores_wait() {
  local n count; count="$(jq '.datastores | length' "$DESCRIPTOR")"
  for (( n=0; n<count; n++ )); do
    local name cname ready expect
    name="$(jq -r ".datastores[$n].name" "$DESCRIPTOR")"
    cname="${TARGET_ID}-${name}"
    ready="$(jq -r ".datastores[$n].ready_cmd // empty" "$DESCRIPTOR")"
    expect="$(jq -r ".datastores[$n].ready_expect // empty" "$DESCRIPTOR")"
    [ -n "$ready" ] || { echo "  (no ready_cmd for $name — skipping wait)"; continue; }
    printf '  waiting for %s' "$cname"
    local i out=""
    for i in $(seq 1 60); do
      out="$(docker exec "$cname" sh -c "$ready" 2>/dev/null || true)"
      if [ -n "$expect" ]; then
        printf '%s' "$out" | grep -q "$expect" && { echo " ok"; break; }
      else
        [ -n "$out" ] && { echo " ok"; break; }
      fi
      printf '.'; sleep 1
      [ "$i" = 60 ] && { echo; die "$cname did not become ready (ran: $ready)"; }
    done
  done
}

# ── clone + pin [from reproduce.sh §2 clone target] ──────────────────────────
clone_target() {
  step "cloning $REPO_URL @ ${COMMIT:0:12} (fresh)"
  app_stop; daemon_stop
  rm -rf "$TARGET"
  mkdir -p "$(dirname "$TARGET")"
  git clone --quiet "$REPO_URL" "$TARGET"
  git -C "$TARGET" checkout --quiet "$COMMIT" \
    || die "commit $COMMIT not checkoutable — is it a real pinned SHA? (queue-app ships a PLACEHOLDER; see targets/queue-app.json)"
}

# ── .env [from reproduce.sh §2 writing .env] ─────────────────────────────────
# The fixture hardcoded the Mongoose app's .env. Here every KEY=VALUE comes from
# the descriptor's .env{}. ConfigNodes only record file existence, so writing a
# target .env for the app to read is fine (that is the target's config, not NEAT's).
write_env() {
  local envfile="$APP_DIR/.env"
  local count; count="$(jq '.env // {} | length' "$DESCRIPTOR")"
  [ "$count" = 0 ] && { echo "  (descriptor has no .env — skipping)"; return 0; }
  step "writing $envfile ($count keys from descriptor .env)"
  jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$DESCRIPTOR" > "$envfile"
}

# ── install [from reproduce.sh §2 npm install] ───────────────────────────────
install_target() {
  local cwd="${INSTALL_CWD:+$TARGET/$INSTALL_CWD}"; cwd="${cwd:-$APP_DIR}"
  step "installing deps under Node $NODE_VERSION: $INSTALL_CMD  (cwd: $cwd)"
  # PATH-shim NODE_TARGET so `npm` in the descriptor's install_cmd uses the
  # target's Node major, not the daemon's default. [Node split, from lib.sh]
  ( cd "$cwd" && PATH="$(dirname "$NODE_TARGET"):$PATH" bash -c "$INSTALL_CMD" )
}

# ── instrument [from reproduce.sh §3 neat init --apply] ──────────────────────
# `neat init --apply` writes the otel-init preload (with NEAT's call-site span
# processor that stamps code.filepath/code.lineno) and a require() in the app's
# entrypoint, then adds OTel deps — so we install again. We commit the
# instrumented tree so a per-arm `git checkout` restores instrumentation, not
# bare upstream. [from reproduce.sh §3]
instrument_target() {
  step "neat init --apply (writes otel-init with the call-site span processor)"
  ( cd "$APP_DIR" && node "$NEAT_CLI" $INSTRUMENT_CMD . >/dev/null )

  step "install again (OTel deps added by init)"
  ( cd "$APP_DIR" && PATH="$(dirname "$NODE_TARGET"):$PATH" bash -c "$INSTALL_CMD" )

  step "committing the instrumented tree (so per-arm 'git checkout' restores instrumentation)"
  ( cd "$TARGET" && git add -A \
    && git -c user.email=bench@neat.is -c user.name=neat-bench commit -q \
       -m "Instrument with NEAT (otel-init + require + OTel deps) for neat-bench" \
    || echo "  (nothing to commit — tree already instrumented)" )

  resolve_otel_init
}

# The NODE_OPTIONS preload path for driving traffic through a test runner that
# bypasses the instrumented entrypoint (see drive_traffic). Prefer the descriptor
# value; otherwise discover the file `neat init` generated.
resolve_otel_init() {
  if [ -n "$OTEL_INIT_REL" ] && [ -f "$APP_DIR/$OTEL_INIT_REL" ]; then
    OTEL_INIT_ABS="$APP_DIR/$OTEL_INIT_REL"; return 0
  fi
  # discovery fallback — `neat init` writes an otel-init.{cjs,js,mjs} preload.
  OTEL_INIT_ABS="$(find "$APP_DIR" -maxdepth 3 -name 'otel-init.*' -not -path '*/node_modules/*' 2>/dev/null | head -1)"
  if [ -n "$OTEL_INIT_ABS" ]; then
    echo "  discovered otel-init preload: ${OTEL_INIT_ABS#$APP_DIR/}"
  else
    echo "  WARNING: could not find a generated otel-init preload under $APP_DIR." >&2
    echo "           If the test suite bypasses the instrumented entrypoint, no spans will land." >&2
    echo "           Set .instrument.otel_init in the descriptor to the generated preload path." >&2
  fi
}

# ── scoped daemon [from reproduce.sh §4 + lib.sh daemon_*] ────────────────────
daemon_stop()  { pkill -f "packages/core/dist/neatd.cjs start" 2>/dev/null || true; sleep 1; }

daemon_start() {
  ( cd "$WORK/$TARGET_ID" && NEAT_HOME="$NEAT_HOME" NEAT_PROJECT="$PROJECT" NEAT_PROJECT_PATH="$APP_DIR" \
      PORT="$REST" OTEL_PORT="$OTLP" NEAT_WEB_PORT="$WEB" \
      NEAT_DISABLE_VERSION_CHECK=1 NEAT_WEB_DISABLED=1 \
      nohup node "$NEAT_D" start --foreground > "$WORK/$TARGET_ID/daemon.log" 2>&1 & )
  local i
  for i in $(seq 1 40); do curl -sf "$D/health" >/dev/null 2>&1 && return 0; sleep 0.5; done
  die "daemon did not come up; see $WORK/$TARGET_ID/daemon.log"
}

# Wipe persisted OBSERVED state so the graph re-extracts clean. [from lib.sh daemon_reset]
daemon_reset() {
  daemon_stop
  rm -rf "$NEAT_HOME"
  rm -f "$APP_DIR/neat-out/$PROJECT.json" "$APP_DIR/neat-out/errors.$PROJECT.ndjson" \
        "$NEAT_HOME/daemons/$PROJECT.json" 2>/dev/null || true
  daemon_start && sleep 2
}

# ── app lifecycle (only used when a wall needs the live app; traffic is the ───
#    test suite by default) [from reproduce.sh §4 + lib.sh app_start] ──────────
app_stop() {
  [ -n "${ENTRYPOINT:-}" ] && pkill -f "$ENTRYPOINT" 2>/dev/null || true
  [ -n "${HEALTH_PORT:-}" ] && { lsof -ti:"$HEALTH_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true; }
  sleep 1
}

app_start() {
  [ -n "${START_CMD:-}" ] || { echo "  (no start_cmd in descriptor — skipping app start; traffic is the test suite)"; return 0; }
  step "starting instrumented app under Node $NODE_VERSION (OTLP → daemon :$OTLP)"
  ( cd "$APP_DIR" && OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://127.0.0.1:$OTLP/v1/traces" \
      OTEL_BSP_SCHEDULE_DELAY=1000 OTEL_BSP_MAX_EXPORT_BATCH_SIZE=512 \
      PATH="$(dirname "$NODE_TARGET"):$PATH" \
      nohup bash -c "$START_CMD" > "$WORK/$TARGET_ID/app.log" 2>&1 & )
  [ -n "${HEALTH_PATH:-}" ] && [ -n "${HEALTH_PORT:-}" ] || { echo "  (no healthcheck — not waiting)"; return 0; }
  local i
  for i in $(seq 1 60); do
    [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HEALTH_PORT$HEALTH_PATH" 2>/dev/null)" = "$HEALTH_EXPECT" ] && return 0
    sleep 0.5
  done
  die "app did not pass healthcheck http://127.0.0.1:$HEALTH_PORT$HEALTH_PATH (want $HEALTH_EXPECT); see $WORK/$TARGET_ID/app.log"
}

# ── traffic: RUN THE TARGET'S OWN TEST SUITE ─────────────────────────────────
# DELIBERATE DECISION (differs from neat-agent-bench, which drove bespoke HTTP in
# warm_traffic): traffic is span-driven by the target's own suite, so the OBSERVED
# layer reflects what the project itself exercises, not what we hand-craft.
#
# HARD REQUIREMENT: every span must reach the daemon. A test runner (vitest/jest/
# mocha) usually spawns its own process and NEVER loads the instrumented
# entrypoint's require('./otel-init'), so we PRELOAD it via NODE_OPTIONS and point
# the OTLP exporter at the scoped daemon. This is the "preload the generated
# otel-init if the runner bypasses the entrypoint" rule from the task.
#
# NO CONNECTORS. OTel spans only — connector-pulled OBSERVED is not a real trace.
drive_traffic() {
  case "$TRAFFIC_MODE" in
    test-suite)
      [ -n "$TEST_CMD" ] || die "traffic.mode=test-suite but descriptor has no traffic.test_cmd"
      step "driving traffic by running the target's own test suite: $TEST_CMD"
      local nodeopts="${NODE_OPTIONS:-}"
      if [ "$PRELOAD_OTEL" = "true" ] && [ -n "${OTEL_INIT_ABS:-}" ]; then
        nodeopts="--require $OTEL_INIT_ABS ${nodeopts}"
        echo "  preloading otel-init via NODE_OPTIONS so runner-spawned processes emit spans"
      elif [ "$PRELOAD_OTEL" = "true" ]; then
        echo "  WARNING: preload requested but no otel-init resolved; spans may not land." >&2
      fi
      # The suite is allowed to fail (a wall may inject a bug that reddens tests);
      # we only need it to EXERCISE the code so spans fire. [oracle is wall-certificate]
      ( cd "$APP_DIR" \
          && OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="http://127.0.0.1:$OTLP/v1/traces" \
             OTEL_BSP_SCHEDULE_DELAY=1000 OTEL_BSP_MAX_EXPORT_BATCH_SIZE=512 \
             NODE_OPTIONS="$nodeopts" \
             PATH="$(dirname "$NODE_TARGET"):$PATH" \
             bash -c "$TEST_CMD" ) > "$WORK/$TARGET_ID/traffic.log" 2>&1 \
        || echo "  (test suite exited non-zero — expected if a wall reddens it; spans still captured)"
      ;;
    none)
      echo "  (traffic.mode=none — relying on per-wall probes only)"
      ;;
    *)
      die "unknown traffic.mode: $TRAFFIC_MODE (expected test-suite|none)"
      ;;
  esac
  drive_probes
  step "settling ${SETTLE_SECONDS}s so the span batch exporter flushes to the daemon"
  sleep "$SETTLE_SECONDS"
}

# Optional per-target/per-wall HTTP probes that SUPPLEMENT the suite when it does
# not exercise a wall's path. Each probe: {method, path, port?, body?, headers{}}.
# Requires start_cmd/app to be up. This is the "per-wall probe" escape hatch.
drive_probes() {
  local count; count="$(jq '.traffic.probes // [] | length' "$DESCRIPTOR")"
  [ "$count" = 0 ] && return 0
  step "driving $count supplemental probe(s) [descriptor .traffic.probes]"
  local n
  for (( n=0; n<count; n++ )); do
    local m p port body; local hdr=()
    m="$(jq -r ".traffic.probes[$n].method // \"GET\"" "$DESCRIPTOR")"
    p="$(jq -r ".traffic.probes[$n].path" "$DESCRIPTOR")"
    port="$(jq -r ".traffic.probes[$n].port // \"$HEALTH_PORT\"" "$DESCRIPTOR")"
    body="$(jq -r ".traffic.probes[$n].body // empty" "$DESCRIPTOR")"
    while IFS= read -r h; do [ -n "$h" ] && hdr+=(-H "$h"); done \
      < <(jq -r ".traffic.probes[$n].headers // {} | to_entries[] | \"\(.key): \(.value)\"" "$DESCRIPTOR")
    local args=(-s -o /dev/null -w "    probe %{http_code} $m $p\n" -X "$m" "http://127.0.0.1:$port$p")
    [ ${#hdr[@]} -gt 0 ] && args+=("${hdr[@]}")
    [ -n "$body" ] && args+=(-H 'Content-Type: application/json' -d "$body")
    curl "${args[@]}" || true
  done
}

# ── capture [from neat-agent-bench/harness/lib.sh capture()] ─────────────────
# Snapshot the two surfaces the task asks for (/graph + /graph/divergences) plus
# the two the WITH arm also leans on, into results/<target>.*.json.
capture_graph() {
  step "capturing /graph + /graph/divergences → $RESULTS/$TARGET_ID.*.json"
  curl -s "$D/graph"                             | jq '.' > "$GRAPH_OUT"
  curl -s "$D/graph/divergences"                 | jq '.' > "$DIVERGENCES_OUT"
  curl -s "$D/incidents"                         | jq '.' > "$RESULTS/$TARGET_ID.incidents.json" 2>/dev/null || true
  curl -s "$D/graph/observed-dependencies/$SVC"  | jq '.' > "$RESULTS/$TARGET_ID.observed-dependencies.json" 2>/dev/null || true

  # honesty print — did any OBSERVED (real-trace) edges actually land?
  local nodes obs
  nodes="$(jq '.nodes | length' "$GRAPH_OUT" 2>/dev/null || echo '?')"
  obs="$(jq '[.edges[]?|select(.provenance=="OBSERVED")]|length' "$GRAPH_OUT" 2>/dev/null || echo '?')"
  echo "  graph: $nodes nodes, $obs OBSERVED edges"
  if [ "$obs" = 0 ]; then
    echo "  WARNING: zero OBSERVED edges — the test suite did not exercise instrumented paths," >&2
    echo "           or spans never reached the daemon (check NODE_OPTIONS preload + OTLP port)." >&2
  fi
}
