# Resume — 405 pilot (after the power outage)

State when the box dropped: infra was green, both arms had signals, the four run
scripts are now written (this dir). What the outage killed vs. what persists, and
the exact steps to resume.

## What the outage killed vs. persists
| thing | survives a box reboot? | action on resume |
|---|---|---|
| KinD cluster `kind-dev` (docker containers) | usually yes (docker restarts them) | verify `kubectl get nodes` Ready; if not, the cluster may need recreation |
| otel-demo deployments (incl. my changes) | yes — k8s objects on disk | verify pods Running |
| Prometheus 1Gi limit | yes (deployment spec) | verify `kubectl get deploy prometheus -o jsonpath=...resources` = 1Gi |
| collector traces-pipeline dedupe | yes (ConfigMap) | verify `otlphttp/neat` appears once in traces exporters |
| neo4j-productdb + recommendation on neo4j-serving image | yes | verify recommendation image = `...neo4j-serving-recommendation` |
| checkout seeded with neo4j variant (`~/opentelemetry-demo/src/recommendation`) | yes (disk) | verify `grep -c neo4j .../recommendation_server.py` > 0 |
| `seeds/405/faulted/` | yes (disk) | — |
| neat 0.9.6 global install | yes (npm global) | verify `neat --version` |
| **neat watch daemon** (host node process) | **NO** — killed | **restand** (below) |
| port-forwards | NO — ephemeral | re-established by the driver |

## Resume steps (box back)
1. **Health check the cluster + carried-over fixes**
   ```
   ssh deniz@192.168.0.37 'bash -lc "export KUBECONFIG=\$HOME/.kube/config;
     kubectl get nodes; kubectl get pods -n otel-demo | grep -vE Running\|Completed | head;
     kubectl get deploy recommendation -n otel-demo -o jsonpath={.spec.template.spec.containers[0].image}; echo;
     kubectl get cm otel-collector -n otel-demo -o jsonpath={.data.relay} | grep -c otlphttp/neat"'
   ```
   (Prometheus may crashloop again if the outage corrupted its TSDB WAL — if so,
   `kubectl delete pod -l app=prometheus -n otel-demo` for a clean restart; the 1Gi
   limit persists.)
2. **Restand neat on 0.9.6** (idempotent collector patch now — safe):
   `ssh … 'nvm use 20; npm i -g neat.is@0.9.6; setsid bash ~/praxis/neat-restand.sh > ~/praxis/restand.log 2>&1 &'`
   Wait for `DONE restand`. If the traces pipeline is silent, the outage may have
   re-wedged the collector — restart it: `kubectl rollout restart deploy/otel-collector -n otel-demo`.
3. **Deploy the run scripts to the box** (from this repo): copy `run-code.sh`,
   `run-neat.sh`, `verify-405.sh`, `run-pilot-405.sh`, `_arm-extract.sh` into
   `~/praxis/harness/`, and the updated `obscode/run-obscode.sh`. `chmod +x`.
4. **Verify OBSERVED flows**: drive a burst (port-forward frontend-proxy:18080,
   curl `/api/products` ×20 + `/api/recommendations` ×6), then confirm
   `neat incidents service:recommendation` shows the DEADLINE_EXCEEDED and
   `neat observed-dependencies service:frontend` is populated.
5. **DRY-RUN each arm** (prove isolation before spending real runs):
   `NEAT_BENCH_MAX_TURNS=3 bash ~/praxis/harness/run-code.sh 405 0` — then check
   `runs/405/code/trial-0/arm.json`: `neat_tool_hits`+`obs_helper_hits`+`kubectl_hits`
   must all be 0 for code; obscode must have obs>0 & neat=0; neat must have neat>0.
   (The extractor prints `!! ISOLATION BREACH` if a PATH restriction failed.)
6. **Smoke the oracle**: `bash ~/praxis/harness/verify-405.sh ~/praxis/seeds/405/faulted/recommendation_server.py`
   — MUST print `RESOLVED_405=NO` (the unfixed seed doesn't fix the hang) and revert
   to the faulted image cleanly. This proves the oracle discriminates.
7. **Launch the pilot**: `setsid bash ~/praxis/harness/run-pilot-405.sh > ~/praxis/harness/pilot.log 2>&1 &`
   then poll `pilot.log` + `runs/405/pilot-results.tsv`. ~30-45 min for 6 runs.

## Read the result honestly
`RESOLVED@2 per arm`. The load-bearing line is **neat vs obscode** (isolates
fusion). Watch for: neat's raw `root-cause` on 405 is degenerate (RCI — a gRPC
deadline has no stacktrace), so a neat WIN depends on the *arm* using
divergence/blast-radius/observed-deps to reach line 129. If neat can't, that is a
filed NEAT weakness → fix → re-run (CONTRACT rule 1), not a quiet loss.

## Known caveats to validate live
- The neo4j hang may emit few *completed* recommendation spans (the outbound call
  blocks); the observed signal is the caller-side DEADLINE_EXCEEDED + the 504. Confirm
  neat/obscode actually see enough to localize.
- The isolation via restricted PATH assumes claude's Bash tool does NOT source a
  login profile (which would re-add nvm/.local to PATH). The dry-run in step 5 is
  the proof; if a breach shows, switch to a symlink-only codebin per arm.
- `verify-405` needs docker + kind + a ~2-5 min image build per run (12 builds for
  the pilot). If docker isn't present, fall back to `kubectl cp` the fixed file into
  the running pod + restart the process (less clean; note it).
