#!/usr/bin/env bash
# Wait for the running smoke to finish, then smoke uptime-kuma with the working MQTT broker.
cd "$HOME/neat-bench/security-pilot"
while pgrep -f "harness/run-smoke.ts" >/dev/null; do sleep 20; done
exec bash ./smoke-launch.sh uptime-kuma,nodegoat,paperless-ngx,gitea neat-sonnet-full > runs/smoke5.out 2>&1
