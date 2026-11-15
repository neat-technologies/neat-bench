#!/usr/bin/env bash
# My own uptime-kuma bring-up for the security pilot (written from the shared design).
# Isolated: everything under $ROOT, target manifest untouched, NEAT in a sidecar dir.
set -uo pipefail
# NEAT needs Node 20.x; box node is v22, npm only via nvm. Load it.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use 20 >/dev/null 2>&1 || true
ROOT="$HOME/neat-bench/security-pilot/uptime-kuma"
APP="$ROOT/app"
SIDE="$ROOT/sidecar"
mkdir -p "$ROOT"
LOG() { echo "[$(date +%T)] $*"; }

LOG "=== install neat.is@0.11.0 globally (for the CLI/daemon) ==="
npm i -g neat.is@0.11.0 >"$ROOT/neat-global-install.log" 2>&1 \
  && LOG "neat.is installed: $(neat --version 2>/dev/null || echo '?')" \
  || LOG "neat.is global install FAILED (see neat-global-install.log)"

LOG "=== clone uptime-kuma (pin 2.5.9, fall back to default branch) ==="
if [ ! -d "$APP/.git" ]; then
  git clone --depth 1 --branch 2.5.9 https://github.com/louislam/uptime-kuma "$APP" 2>/dev/null \
    || git clone --depth 1 https://github.com/louislam/uptime-kuma "$APP"
fi
LOG "kuma at: $(cd "$APP" && (git describe --tags 2>/dev/null || git rev-parse --short HEAD))"

LOG "=== npm install uptime-kuma (runs postinstall; external code, isolated) ==="
cd "$APP"
( npm ci --no-audit --no-fund || npm install --no-audit --no-fund ) >"$ROOT/npm-install.log" 2>&1
LOG "npm install rc=$? (see npm-install.log)"

LOG "=== build frontend ==="
npm run build >"$ROOT/build.log" 2>&1 && LOG "build ok" || LOG "build skipped/failed (see build.log)"

LOG "=== sidecar: @neat.is/core + @neat.is/otel-node @0.11.0 (manifest untouched) ==="
mkdir -p "$SIDE"; cd "$SIDE"
[ -f package.json ] || npm init -y >/dev/null 2>&1
npm install @neat.is/core@0.11.0 @neat.is/otel-node@0.11.0 --no-audit --no-fund >"$ROOT/sidecar-install.log" 2>&1 \
  && LOG "sidecar installed" || LOG "sidecar install FAILED (see sidecar-install.log)"

LOG "=== neat --help (learn the daemon invocation) ==="
neat --help 2>&1 | head -60

LOG "=== SETUP_COMPLETE ==="
