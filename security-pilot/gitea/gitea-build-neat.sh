#!/usr/bin/env bash
# ADR-A step 2: build Gitea with otelc's own rule tree plus NEAT's rules
# (call-site stamp + chi handler attribution), all through --rules.
set -uo pipefail
T=$HOME/neat-bench/security-pilot/gitea
export PATH=$T/toolchain/go/bin:$PATH GOPATH=$T/gopath GOCACHE=$T/gocache GOMODCACHE=$T/gopath/pkg/mod GOTOOLCHAIN=local GOFLAGS=-modcacherw
sed -e "s|__ROOT__|$T/src|g" -e "s|__SKIP__|/modules/web/|g" $T/neat.otelc.yaml.tmpl > $T/neat.otelc.yaml
cd $T/src
start=$(date +%s)
$T/otelc/otelc --rules $T/otelc/instrumentation/,$T/neat.otelc.yaml go build -tags 'sqlite sqlite_unlock_notify' -o $T/bin/gitea-neat . > $T/logs/build-neat.log 2>&1; rc=$?
echo "neat build rc=$rc in $(( $(date +%s) - start ))s"
[ $rc = 0 ] || tail -40 $T/logs/build-neat.log
git status --short | head
