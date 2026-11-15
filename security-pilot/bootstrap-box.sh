#!/usr/bin/env bash
# Prepare a fresh Linux box to run the security bench.
#
# Run it from a checkout of this repo placed at $HOME/neat-bench:
#
#   git clone https://github.com/neat-technologies/neat-bench "$HOME/neat-bench"
#   cd "$HOME/neat-bench/security-pilot" && ./bootstrap-box.sh
#
# It installs the pinned toolchains, the shared per-app pieces the trials build against, and one
# NEAT build per commit named in NEAT_COMMITS. It is safe to run again: each step skips what is
# already in place. It does not start a run and does not touch any API key; see REPRODUCE.md.
#
# The versions below are the ones on the box that produced the 2026-11-15 runs (Ubuntu 26.04,
# x86_64, 16 cores, 29 GB RAM). This script was written from that box's state. It has not been
# run end to end on a fresh machine, so treat the first run on a new box as the test of it and
# read REPRODUCE.md "Check the box" before spending API money.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
[ "$ROOT" = "$HOME/neat-bench/security-pilot" ] || {
  echo "This checkout is at $ROOT. The launch scripts expect \$HOME/neat-bench/security-pilot." >&2
  exit 1
}

NODE_VERSION=20.20.2
GO_SYSTEM_VERSION=1.27.0          # /usr/local/go: runs govulncheck and the agent's own go commands
GO_GITEA_VERSION=1.27.3           # gitea/toolchain/go: builds the instrumented gitea binary
OSV_SCANNER_VERSION=v1.9.2
GOVULNCHECK_VERSION=v1.9.0
UV_VERSION=0.13.8
OTELCOL_VERSION=0.111.0
OTELC_REPO=https://github.com/open-telemetry/opentelemetry-go-compile-instrumentation
OTELC_COMMIT=70b4fe8              # tag v1.2.0
NEAT_REPO=https://github.com/neat-technologies/neat
# One build per commit. b1e6654 is what the k=3 and bare-sonnet runs used; bf8c29a is what the
# paperless supplement used. Override to build others: NEAT_COMMITS="abc1234 def5678" ./bootstrap-box.sh
NEAT_COMMITS="${NEAT_COMMITS:-b1e6654 bf8c29a}"

step() { printf '\n== %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

step "system packages (needs sudo)"
if ! have docker || ! have git || ! have make || ! have curl; then
  sudo apt-get update
  sudo apt-get install -y git curl make build-essential ca-certificates docker.io python3
  sudo usermod -aG docker "$USER"
  echo "Added $USER to the docker group. Log out and back in, then run this script again."
  exit 0
fi
docker ps >/dev/null 2>&1 || { echo "docker is installed but this user cannot reach it (docker group?)." >&2; exit 1; }

step "node $NODE_VERSION (nvm)"
export NVM_DIR="$HOME/.nvm"
if [ ! -s "$NVM_DIR/nvm.sh" ]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi
# shellcheck disable=SC1091
. "$NVM_DIR/nvm.sh"
nvm install "$NODE_VERSION" >/dev/null
export PATH="$NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH"
node -v

step "go $GO_SYSTEM_VERSION at /usr/local/go (needs sudo)"
if [ "$(cat /usr/local/go/VERSION 2>/dev/null | head -1)" != "go$GO_SYSTEM_VERSION" ]; then
  curl -fsSL "https://go.dev/dl/go$GO_SYSTEM_VERSION.linux-amd64.tar.gz" -o /tmp/go-system.tgz
  sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go-system.tgz
fi
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"
go version

step "scanners: osv-scanner $OSV_SCANNER_VERSION, govulncheck $GOVULNCHECK_VERSION"
[ -x "$HOME/go/bin/osv-scanner" ] || go install "github.com/google/osv-scanner/cmd/osv-scanner@$OSV_SCANNER_VERSION"
[ -x "$HOME/go/bin/govulncheck" ] || go install "golang.org/x/vuln/cmd/govulncheck@$GOVULNCHECK_VERSION"
osv-scanner --version | head -1

step "uv $UV_VERSION"
if ! "$HOME/.local/bin/uv" --version 2>/dev/null | grep -q "$UV_VERSION"; then
  curl -fsSL "https://astral.sh/uv/$UV_VERSION/install.sh" | sh
fi

step "otelcol-contrib $OTELCOL_VERSION (the bare arms' collector)"
mkdir -p "$ROOT/bin"
if ! "$ROOT/bin/otelcol-contrib" --version 2>/dev/null | grep -q "$OTELCOL_VERSION"; then
  curl -fsSL "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTELCOL_VERSION/otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.tar.gz" \
    | tar -xz -C "$ROOT/bin" otelcol-contrib
fi

step "harness dependencies"
(cd "$ROOT" && npm ci --no-audit --no-fund)

step "gitea: pinned go toolchain and the stock otelc tool"
mkdir -p "$ROOT/gitea/toolchain"
if [ "$(cat "$ROOT/gitea/toolchain/go/VERSION" 2>/dev/null | head -1)" != "go$GO_GITEA_VERSION" ]; then
  curl -fsSL "https://go.dev/dl/go$GO_GITEA_VERSION.linux-amd64.tar.gz" | tar -xz -C "$ROOT/gitea/toolchain"
fi
if [ ! -x "$ROOT/gitea/otelc/otelc" ]; then
  [ -d "$ROOT/gitea/otelc/.git" ] || git clone -q "$OTELC_REPO" "$ROOT/gitea/otelc"
  git -C "$ROOT/gitea/otelc" checkout -q "$OTELC_COMMIT"
  (cd "$ROOT/gitea/otelc" && PATH="$ROOT/gitea/toolchain/go/bin:$PATH" make build)
fi

step "nodegoat and uptime-kuma: the attach directory that carries @neat.is/otel-node"
# Both install the tarball committed at nodegoat/otel-node-main-c2aaa93.tgz (see each package.json).
(cd "$ROOT/nodegoat/attach" && npm ci --no-audit --no-fund)
(cd "$ROOT/uptime-kuma/attach" && npm ci --no-audit --no-fund)

step "container images the standup scripts pull"
for img in ghcr.io/paperless-ngx/paperless-ngx:2.15.3 postgres:16 redis:7-alpine mongo:4.4; do
  docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img"
done

step "NEAT builds: $NEAT_COMMITS"
mkdir -p "$HOME/neat-builds"
[ -d "$HOME/neat-builds/src/.git" ] || git clone -q "$NEAT_REPO" "$HOME/neat-builds/src"
git -C "$HOME/neat-builds/src" fetch -q origin
for c in $NEAT_COMMITS; do
  d="$HOME/neat-builds/$c"
  if [ ! -f "$d/packages/core/dist/cli.cjs" ] || [ ! -f "$d/packages/mcp/dist/index.cjs" ]; then
    [ -d "$d" ] || git -C "$HOME/neat-builds/src" worktree add -q --detach "$d" "$c"
    (cd "$d" && npm ci --silent && npx turbo build --filter=@neat.is/core... --filter=@neat.is/mcp...)
  fi
  echo "$c  core cli sha256 $(sha256sum "$d/packages/core/dist/cli.cjs" | cut -c1-16)  mcp sha256 $(sha256sum "$d/packages/mcp/dist/index.cjs" | cut -c1-16)"
done

step "API key file"
mkdir -p "$HOME/.neat-bench-secrets" && chmod 700 "$HOME/.neat-bench-secrets"
if [ ! -f "$HOME/.neat-bench-secrets/anthropic.env" ]; then
  printf 'export ANTHROPIC_API_KEY=\n' > "$HOME/.neat-bench-secrets/anthropic.env"
  chmod 600 "$HOME/.neat-bench-secrets/anthropic.env"
  echo "Put the key in $HOME/.neat-bench-secrets/anthropic.env (it is read by the launch scripts and never printed)."
fi

step "done"
echo "Expected for b1e6654: core cli sha256 bb183208a968a0d5, mcp sha256 7334969f2ab4ef68 (REPRODUCE.md)."
echo "Next: REPRODUCE.md, 'Check the box'."
