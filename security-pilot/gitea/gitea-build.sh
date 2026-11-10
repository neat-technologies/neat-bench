#!/usr/bin/env bash
# ADR-A research gate: build Gitea v28.3.0 with OTel's compile-time tool (otelc
# v1.2.0) and as a plain control build. Everything lives under $T; no system
# installs, no edits to the Gitea tree (checked at the end).
set -uo pipefail
T=$HOME/neat-bench/security-pilot/gitea
mkdir -p $T/toolchain $T/logs $T/bin
export PATH=$T/toolchain/go/bin:$PATH GOPATH=$T/gopath GOCACHE=$T/gocache GOMODCACHE=$T/gopath/pkg/mod GOTOOLCHAIN=local GOFLAGS=-modcacherw
step() { echo "[$(date +%T)] $*"; }

if [ ! -x $T/toolchain/go/bin/go ]; then
  step "go 1.27.3"; curl -sSL https://go.dev/dl/go1.27.3.linux-amd64.tar.gz | tar -C $T/toolchain -xz
fi
go version

if [ ! -x $T/otelc/otelc ]; then
  step "otelc v1.2.0"
  [ -d $T/otelc/.git ] || git clone -q --depth 1 --branch v1.2.0 https://github.com/open-telemetry/opentelemetry-go-compile-instrumentation $T/otelc
  (cd $T/otelc && make build > $T/logs/otelc-build.log 2>&1) || { step "otelc build FAILED"; tail -20 $T/logs/otelc-build.log; exit 1; }
fi
$T/otelc/otelc version 2>/dev/null || $T/otelc/otelc --help 2>&1 | head -3

[ -d $T/src/.git ] || { step "clone gitea v28.3.0"; git clone -q --depth 1 --branch v28.3.0 https://github.com/go-gitea/gitea $T/src; }
cd $T/src
git rev-parse HEAD
TAGS='sqlite sqlite_unlock_notify'

step "plain build"
start=$(date +%s); go build -tags "$TAGS" -o $T/bin/gitea-plain . > $T/logs/build-plain.log 2>&1; rc=$?
step "plain build rc=$rc in $(( $(date +%s) - start ))s"; [ $rc = 0 ] || tail -20 $T/logs/build-plain.log

step "otelc build"
start=$(date +%s); $T/otelc/otelc go build -tags "$TAGS" -o $T/bin/gitea-otelc . > $T/logs/build-otelc.log 2>&1; rc=$?
step "otelc build rc=$rc in $(( $(date +%s) - start ))s"; [ $rc = 0 ] || tail -30 $T/logs/build-otelc.log

ls -la $T/bin
step "gitea tree after builds (expect clean):"; git status --short | head -20
file $T/bin/gitea-otelc 2>/dev/null
step done
