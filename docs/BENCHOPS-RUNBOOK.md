# BenchOps Runbook — ±NEAT on live ITBench

The controlled-experiment loop: **ITBench instrumented → NEAT installed (as a package) → Claude injected (arms) → run → file issues / obtain numbers → iterate.** Everything here lives in `neat-bench`; **nothing** goes in `neat-technologies/neat` (bench-found NEAT bugs become issues there, fixes ship to `latest`, main stays pristine).

Proven end-to-end 2026-08-23 on the bench box (Ubuntu 26.04, 16c/32G, `192.168.0.37`), driven over SSH.

## Control variables (the point)

Hold constant across arms; vary ONE thing (signal access):
- Same live scenario + injected fault + cluster state (arms are **diagnose-only**, no `kubectl apply`, so state doesn't drift between arms).
- Same symptom prompt, same model (fresh Claude subagents), same SSH access to the box.
- **obs** = kubectl + observability. **obscode** = + source (`~/opentelemetry-demo`, tag-matched to deployed images). **neat** = + NEAT graph (REST `:8098`, bearer).
- Grade vs ITBench's own `groundtruth.yaml` (the k8s object). Capture per-arm answer + ssh-command count.

## 0. Box prerequisites (one-time, NOPASSWD sudo)

```bash
sudo apt-get install -y curl git ca-certificates docker.io jq build-essential python3-dev
sudo usermod -aG docker $USER   # re-login for group
# userspace tools → ~/.local/bin: kind(via go tool), kubectl, helm4, uv, yq
curl -fsSLo ~/.local/bin/kubectl "https://dl.k8s.io/release/$(curl -fsSL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
HV=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1)   # MUST be v4+ (ITBench requires Helm 4)
curl -fsSL "https://get.helm.sh/helm-${HV}-linux-amd64.tar.gz" | tar xz -C /tmp && mv /tmp/linux-amd64/helm ~/.local/bin/
curl -LsSf https://astral.sh/uv/install.sh | sh
curl -fsSLo ~/.local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 && chmod +x ~/.local/bin/*
# Go (ITBench's kind + cloud-provider-kind are `go tool` deps): tarball → /usr/local/go
# Node 20 via nvm (NOT 22 — neat.is compiles tree-sitter grammars via node-gyp; 22 has no prebuilds)
# KinD inotify fix (else chaos-mesh crash-loops "too many open files"):
sudo sysctl -w fs.inotify.max_user_watches=1048576 fs.inotify.max_user_instances=8192
printf 'fs.inotify.max_user_watches=1048576\nfs.inotify.max_user_instances=8192\n' | sudo tee /etc/sysctl.d/99-inotify.conf
```

## 1. Cluster + ITBench deploy

```bash
git clone https://github.com/itbench-hub/ITBench.git ~/ITBench && cd ~/ITBench
make deps                                                  # uv + ansible galaxy
make -C clusters/kind create-simple-cluster                # go tool kind, cluster "kind-dev"
# LoadBalancer provider (istio gateway needs an IP — run PERSISTENT, from clusters/kind):
setsid bash -c 'cd ~/ITBench/clusters/kind && go tool cloud-provider-kind --gateway-channel disabled' >~/cpkind.log 2>&1 &
cd scenarios/sre && make group-vars
SCENARIO_NUMBER=1 make start-scenario                      # deploys tools + astronomy-shop + injects fault
```
Gotchas: `make start-scenario` uses `helm --wait`; first-pull slowness can time out chaos-mesh (fixed by the inotify sysctl) — re-run is idempotent. Verify: `kubectl get pods -n otel-demo` (~23 pods), `kubectl get gateway -A` (istio-main Programmed).

## 2. NEAT as a package + fusion wiring

```bash
# source pinned to the DEPLOYED image tag (fusion joins at file:line)
TAG=$(kubectl get pods -n otel-demo -o jsonpath='{.items[0].spec.containers[0].image}' | sed -E 's#.*/demo:([0-9.]+).*#\1#')
git clone https://github.com/open-telemetry/opentelemetry-demo.git ~/opentelemetry-demo
cd ~/opentelemetry-demo && git checkout "$TAG"             # tags for 2.x have NO 'v' prefix
npm i -g neat.is@latest                                    # Node 20
neat init ~/opentelemetry-demo
NEAT_AUTH_TOKEN=benchops-neat-token NEAT_OTEL_TOKEN=benchops-neat-token \
  HOST=0.0.0.0 PORT=8098 OTEL_PORT=4319 neat watch ~/opentelemetry-demo &
# patch the demo collector to fan traces out to NEAT (172.18.0.1 = host on kind net)
kubectl get cm otel-collector -n otel-demo -o yaml > /tmp/cm.yaml
yq -i '.data.relay |= (from_yaml
  | .exporters."otlphttp/neat".endpoint="http://172.18.0.1:4319"
  | .exporters."otlphttp/neat".headers.authorization="Bearer benchops-neat-token"
  | .exporters."otlphttp/neat".tls.insecure=true
  | .service.pipelines.traces.exporters += ["otlphttp/neat"] | to_yaml)' /tmp/cm.yaml
kubectl apply -f /tmp/cm.yaml && kubectl rollout restart deploy/otel-collector -n otel-demo
```
Verify fusion: `curl -H "Authorization: Bearer benchops-neat-token" :8098/graph` → OBSERVED edges appear within seconds; `get_root_cause` from an erroring node localizes correctly. (neat.is@0.9.2 already has the gzip-receiver fix so the collector's default gzip export is accepted.)

## 3. Arms (Claude injected) + grading

Fresh Claude subagents SSH into the box, one per arm, identical symptom prompt, per-arm tool grant (see §control variables). Diagnose-only. Grade the `ROOT CAUSE:` line vs `scenarios/sre/project/roles/scenarios/files/scenario_N/groundtruth.yaml` (the k8s entity). Record answer + ssh-command count → `results/itbench-Scenario-N-<arm>/`.

**Honest metric note:** every ITBench SRE ground truth is a k8s object (ConfigMap/Deployment/Service/Pod), which NEAT does not model — so NEAT's role is **localization-assist**, not naming the object, and all arms have kubectl (which can find k8s objects directly). The number measures whether NEAT makes the agent faster/more-direct, not whether it uniquely solves. NEAT's unique-capability claim (code/dependency divergence) needs a code-level-ground-truth bench.
