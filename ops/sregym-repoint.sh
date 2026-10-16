#!/usr/bin/env bash
# sregym-repoint.sh — move the bench daemon to a published NEAT version and re-capture every
# deployed SREGym application, so a night's core merges are checked against real spans.
#
# Usage (on a bench box): NEAT_AUTH_TOKEN=... bash ops/sregym-repoint.sh <version>
#   <version> is an npm dist-tag or exact version of @neat.is/core (e.g. nightly, 0.10.7).
# Captures land under ~/sregym-captures/<app>/<timestamp>/ as sregym-capture.py writes them;
# the last line per app prints the fusion delta against the previous capture of that app.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
VER="${1:?version or dist-tag}"
SRC="$HOME/sregym-src"
OPS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${NEAT_AUTH_TOKEN:-}" ] || { echo "NEAT_AUTH_TOKEN not set" >&2; exit 1; }
kubectl config use-context kind-kind >/dev/null

echo "== install @neat.is/core@$VER + @neat.is/mcp@$VER"
npm i -g "@neat.is/core@$VER" "@neat.is/mcp@$VER" >/dev/null 2>&1 || { echo "npm install failed" >&2; exit 1; }
echo "neat $(neat --version 2>/dev/null)"

echo "== restart daemon over $SRC"
P=$(ss -ltnp 2>/dev/null | awk '/:8098 /{print $NF}' | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2)
[ -n "$P" ] && kill "$P" && sleep 3
( cd "$SRC" && neat init . >/dev/null 2>&1 )
( cd "$SRC" && NEAT_AUTH_TOKEN="$NEAT_AUTH_TOKEN" NEAT_OTEL_TOKEN="$NEAT_AUTH_TOKEN" NEAT_WEB_DISABLED=1 HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 setsid nohup neat watch . > "$HOME/sregym-neat.log" 2>&1 & )
for i in $(seq 1 90); do curl -s -m 3 http://localhost:8098/health 2>/dev/null | grep -q '"ok":true' && break; sleep 10; done
curl -s -m 5 http://localhost:8098/health | head -c 200; echo
echo "== let traffic accumulate"; sleep 240

capture() { # app src-root origin
  local app=$1 src=$2 origin=$3 prev cur
  prev=$(ls -dt "$HOME/sregym-captures/$app"/*/ 2>/dev/null | head -1)
  python3 "$OPS/sregym-capture.py" "$app" "$src" "$HOME/sregym-captures" --origin "$origin" > "$HOME/sregym-capture-$app.log" 2>&1
  cur=$(ls -dt "$HOME/sregym-captures/$app"/*/ | head -1)
  echo "== $app: $(grep -E '^neat:' "$HOME/sregym-capture-$app.log")"
  if [ -n "$prev" ] && [ -f "$prev/neat-fusion.tsv" ]; then
    echo "   fusion delta (service: before -> after, edges touching / frontier targets):"
    join -t $'\t' <(sort "$prev/neat-fusion.tsv") <(sort "$cur/neat-fusion.tsv") | awk -F'\t' 'NR>0 && $1!="service" && ($3!=$6 || $4!=$7 || $2!=$5){printf "   %-24s %s/%s/%s -> %s/%s/%s\n",$1,$2,$3,$4,$5,$6,$7}'
  fi
}
capture astronomy-shop "$SRC/astronomy-shop/src" otlp
capture hotel-reservation "$SRC/DeathStarBench/hotelReservation/cmd" jaeger
capture social-network "$SRC/DeathStarBench/socialNetwork/src" jaeger
echo "== frontier nodes"
curl -s -m 90 -H "Authorization: Bearer $NEAT_AUTH_TOKEN" http://localhost:8098/graph | python3 -c '
import json,sys; g=json.load(sys.stdin); fr=sorted(n["id"] for n in g["nodes"] if n["id"].startswith("frontier:")); print(len(fr), fr[:20]); print("observed", sum(1 for e in g["edges"] if e.get("provenance")=="OBSERVED"))'
