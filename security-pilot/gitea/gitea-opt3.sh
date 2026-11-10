#!/usr/bin/env bash
# ADR-A Option 3 (the working variant): stock otelc v1.2.0 + a GOWORK sidecar module
# OUTSIDE the Gitea tree. The sidecar's go.mod puts otelc's hook modules in the build
# list (go.work replaces every otelc module to the pinned clone); the rules go in
# explicitly with --rules, scoped to the modules the sidecar requires. A tool file in
# the sidecar is NOT discovered by otelc (only modules being built are scanned), so the
# otel.instrumentation.go below just documents the set. No edit to Gitea's files.
set -uo pipefail
T=$HOME/neat-bench/security-pilot/gitea
O=$T/otelc
W=$T/neat-otelc-ws
export PATH=$T/toolchain/go/bin:$PATH GOPATH=$T/gopath GOCACHE=$T/gocache GOMODCACHE=$T/gopath/pkg/mod GOTOOLCHAIN=local GOFLAGS=-modcacherw
rm -rf $W; mkdir -p $W/rules
cd $W
cat > go.mod <<GOMOD
module neat.local/otelcws

go 1.27
GOMOD
cat > rules/stub.go <<'GO'
// Package rules carries NEAT's otelc rules (otelc.yaml beside this file).
package rules
GO
sed -e "s|__ROOT__|$T/src|g" -e "s|__SKIP__|/modules/web/|g" -e "s#__DBSKIP__#/models/db/#g" $T/neat.otelc.yaml.tmpl > rules/otelc.yaml
IMPORTS="net/http/server net/http/client database/sql go.opentelemetry.io/otel/sdk/trace go.opentelemetry.io/otel go.opentelemetry.io/otel/trace go.opentelemetry.io/otel/init runtime log log/slog"
{
  echo "//go:build tools"; echo; echo "package tools"; echo; echo "import ("
  for i in $IMPORTS; do echo "	_ \"go.opentelemetry.io/otelc/instrumentation/$i\""; done
  echo "	_ \"neat.local/otelcws/rules\""; echo ")"
} > otel.instrumentation.go
# Every otelc module, replaced to the pinned local clone (member-module replaces are ignored in workspace mode).
{
  echo "go 1.27.3"; echo; echo "use ("; echo "	$T/src"; echo "	$W"; echo ")"; echo
  find $O -name go.mod -not -path "*/test/*" -not -path "*/demo/*" -not -path "*/.otelc-build/*" | while read f; do
    m=$(grep -m1 "^module " $f | cut -d" " -f2); echo "replace $m => $(dirname $f)"
  done
} > go.work
for i in $IMPORTS; do echo "require go.opentelemetry.io/otelc/instrumentation/$i v0.0.0" >> go.mod; done
grep -c "^replace" go.work
cd $T/src
start=$(date +%s)
RULES=""; for i in $IMPORTS; do RULES="$RULES$O/instrumentation/$i/,"; done; RULES="$RULES$W/rules/otelc.yaml"
GOWORK=$W/go.work $O/otelc --rules "$RULES" go build -tags 'sqlite sqlite_unlock_notify' -o $T/bin/gitea-opt3 . > $T/logs/build-opt3.log 2>&1; rc=$?
echo "opt3 build rc=$rc in $(( $(date +%s) - start ))s"
[ $rc = 0 ] || tail -30 $T/logs/build-opt3.log
git status --short | head -5
grep -o "neat_[a-z_]*" $T/src/.otelc-build/matched.json 2>/dev/null | sort | uniq -c
