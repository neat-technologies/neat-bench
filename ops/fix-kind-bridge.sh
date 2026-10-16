#!/usr/bin/env bash
# fix-kind-bridge.sh — after a reboot the kind docker bridge has come up without its IPv4
# gateway address (seen 2026-10-16: host could not reach the API server, pods had no egress).
# Re-adds the address docker declares for the network. Safe to run repeatedly.
set -uo pipefail
GW=$(docker network inspect kind -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)
ID=$(docker network inspect kind -f '{{.Id}}' | cut -c1-12)
BR="br-$ID"
[ -n "$GW" ] && [ -e "/sys/class/net/$BR" ] || { echo "kind network/bridge not found"; exit 1; }
if ip -4 addr show "$BR" | grep -q "inet $GW/"; then echo "bridge $BR has $GW: ok"; exit 0; fi
sudo -n ip addr add "$GW/16" dev "$BR" && echo "bridge $BR: added $GW/16"
