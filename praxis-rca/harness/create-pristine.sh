#!/usr/bin/env bash
# create-pristine.sh — build ~/otel-pristine: a clean source tree the NEAT daemon
# NEVER writes into, so a "source-only" arm can never read the fused graph
# (neat-out/graph.json, ~2.6MB) or NEAT's install plan (neat.patch) off disk. The
# daemon keeps running on ~/opentelemetry-demo; the arms read ~/otel-pristine. Run
# once on the box; idempotent. Per-scenario recommendation faults are synced by the
# bench driver (sync_pristine_rec) — this just lays down clean stock source.
#   create-pristine.sh [src_root] [dst_root]
set -uo pipefail
SRC="${1:-$HOME/opentelemetry-demo}"
DST="${2:-$HOME/otel-pristine}"
STOCK_REC="${STOCK_REC:-$HOME/praxis/seeds/healthy-recserver-bak.py}"
echo "pristine: $SRC/src -> $DST/src (clean, no neat artifacts)"
rm -rf "$DST"; mkdir -p "$DST/src"
rsync -a \
  --exclude 'node_modules' --exclude '__pycache__' --exclude '.git' \
  --exclude 'dist' --exclude 'build' --exclude '.next' --exclude 'target' \
  --exclude 'neat-out' --exclude 'neat.patch' --exclude 'neat_otel.*' \
  "$SRC/src/" "$DST/src/"
# lay down the stock recommendation baseline (driver overwrites per scenario)
[ -f "$STOCK_REC" ] && cp "$STOCK_REC" "$DST/src/recommendation/recommendation_server.py" \
  && echo "stock recommendation_server.py <- $STOCK_REC"

# CRITICAL (O2): carry the repo-root config the app legitimately reads — the .env
# holds the service addresses the frontend gateways resolve. Omitting it made a
# weak model hallucinate an "empty addresses" fault. These are stock config (no
# injected fault), so they give correct context without leaking the answer; the
# NEAT byproducts (neat-out, neat.patch) stay excluded.
for f in .env .env.override .env.local .env.arm64; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DST/$f" && echo "config $f <- $SRC/$f"
done
echo "=== sanity: neat artifacts leaked into pristine? (want ZERO lines) ==="
find "$DST" \( -iname 'graph.json' -o -iname 'neat.patch' -o -iname '*.ndjson' \
  -o -iname 'daemon.json' -o -iname 'embeddings.json' -o -iname 'extraction-health.json' \) 2>/dev/null | head
echo "=== pristine services ==="; ls "$DST/src" | tr '\n' ' '; echo
echo "=== rec source head ==="; head -3 "$DST/src/recommendation/recommendation_server.py" 2>/dev/null
