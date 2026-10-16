#!/usr/bin/env bash
# recover-20261016.sh — post-reboot recovery of the bench cluster.
# 1. Strip the two PRAXIS-injected fields that survived every reset (owned by field manager
#    OpenAPI-Generator; server-side apply under another manager never prunes them).
# 2. Recycle the otel-demo pods stuck in Unknown since the reboot.
# 3. Purge the ITBench leftover copy of the demo in the `default` namespace (19 deployments,
#    crash-looping for 5 days, kafka/ad at 800+ restarts, burning CPU).
# 4. Install a guard that re-adds the kind bridge gateway address if a reboot drops it again.
set -uo pipefail
export PATH="$HOME/.local/bin:$HOME/.nvm/versions/node/v20.20.2/bin:$PATH"
export KUBECONFIG="$HOME/.kube/config"
NS=otel-demo
K="kubectl --request-timeout=30s"

echo "=== 0. extra env vars live-vs-chart (read-only, for the record) ==="
for d in checkout currency payment shipping valkey-cart; do
  echo -n "  $d: "; $K -n $NS get deploy $d -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name} {end}' | tr ' ' '\n' | grep -vE '^(OTEL_|$)' | tr '\n' ' '; echo
done

echo "=== 1. strip injected fields ==="
echo -n "  email initContainers: "
$K -n $NS patch deploy email --type=json -p '[{"op":"remove","path":"/spec/template/spec/initContainers"}]' 2>&1 | tail -1
echo -n "  frontend readinessProbe: "
$K -n $NS patch deploy frontend --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/readinessProbe"}]' 2>&1 | tail -1

echo "=== 2. recycle Unknown pods ==="
for p in $($K -n $NS get pods --no-headers 2>/dev/null | awk '$3=="Unknown"{print $1}'); do
  echo -n "  $p: "; $K -n $NS delete pod "$p" --wait=false 2>&1 | tail -1
done

echo "=== 3. purge ITBench leftover demo in default ==="
$K -n default delete deploy,sts,svc,cm,sa,secret,job,pvc -l app.kubernetes.io/instance=otel-demo --ignore-not-found --wait=false 2>&1 | wc -l | xargs echo "  resources deleted:"

echo "=== 4. kind bridge guard ==="
mkdir -p "$HOME/praxis/harness"
cat > "$HOME/praxis/harness/fix-kind-bridge.sh" <<'EOF'
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
EOF
chmod +x "$HOME/praxis/harness/fix-kind-bridge.sh"
bash "$HOME/praxis/harness/fix-kind-bridge.sh"

echo "=== 5. settle 90s, then state ==="
sleep 90
$K -n $NS get pods --no-headers 2>/dev/null | grep -vE ' (Running|Completed) ' | awk '{print "  "$1, $2, $3, $4}'
echo "  otel-demo ready: $($K -n $NS get pods --no-headers 2>/dev/null | awk '{t++; split($2,a,"/"); if(a[1]==a[2] && $3=="Running") r++} END{print r"/"t}')"
echo "  default pods left: $($K -n default get pods --no-headers 2>/dev/null | wc -l)"
echo "  email init: $($K -n $NS get deploy email -o jsonpath='{.spec.template.spec.initContainers}')"
echo "  frontend ready probe: $($K -n $NS get deploy frontend -o jsonpath='{.spec.template.spec.containers[0].readinessProbe}')"
echo "  load: $(cut -d' ' -f1-3 /proc/loadavg)"
