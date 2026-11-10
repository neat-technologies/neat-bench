#!/usr/bin/env bash
# Stop one run's processes by pid file. Usage: gitea-stop.sh [otelc|plain]
R=$HOME/neat-bench/security-pilot/gitea/run-${1:-otelc}
for p in gitea sink neatd; do [ -f $R/$p.pid ] && kill $(cat $R/$p.pid) 2>/dev/null && echo "stopped $p"; rm -f $R/$p.pid; done
