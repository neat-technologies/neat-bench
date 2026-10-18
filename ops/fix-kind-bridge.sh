#!/usr/bin/env bash
# fix-kind-bridge.sh — after a reboot the kind docker bridge has come up without its IPv4
# gateway address (seen 2026-10-16: host could not reach the API server, pods had no egress).
# Re-adds the address docker declares for the network. Safe to run repeatedly.
set -uo pipefail
fix() { # network-name bridge-interface
  local net=$1 br=$2 gw
  gw=$(docker network inspect "$net" -f '{{range .IPAM.Config}}{{if .Gateway}}{{.Gateway}} {{end}}{{end}}' 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9.]+$' | head -1)
  [ -n "$gw" ] && [ -e "/sys/class/net/$br" ] || { echo "$net: network or bridge $br not found"; return 1; }
  if ip -4 addr show "$br" | grep -q "inet $gw/"; then echo "$br has $gw: ok"; else sudo -n ip addr add "$gw/16" dev "$br" && echo "$br: added $gw/16"; fi
  sudo -n ip link set "$br" up
}
# The kind cluster network, and the default bridge every `docker run` lands on (the judge and
# agent containers): on 2026-10-17 docker0 was DOWN with no address, so those containers had
# neither DNS nor egress.
fix kind "br-$(docker network inspect kind -f '{{.Id}}' 2>/dev/null | cut -c1-12)"
fix bridge docker0
