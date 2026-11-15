#!/usr/bin/env bash
cd "$HOME/neat-bench/security-pilot"
while ps -eo args | grep -q "[r]un-smoke"; do sleep 15; done
exec bash smoke-launch.sh > runs/smoke3.out 2>&1
