#!/usr/bin/env bash
T=$HOME/neat-bench/security-pilot/paperless-ngx
[ -f $T/neatd.pid ] && kill $(cat $T/neatd.pid) 2>/dev/null && echo "stopped neatd"; rm -f $T/neatd.pid
docker stop sec-pilot-paperless sec-pilot-paperless-db sec-pilot-paperless-redis >/dev/null 2>&1 && echo "stopped containers"
