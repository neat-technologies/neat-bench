#!/usr/bin/env bash
T=$HOME/neat-bench/security-pilot/nodegoat
for p in nodegoat neatd; do [ -f $T/$p.pid ] && kill $(cat $T/$p.pid) 2>/dev/null && echo "stopped $p"; rm -f $T/$p.pid; done
docker stop sec-pilot-nodegoat-mongo >/dev/null 2>&1 && echo "stopped mongo"
