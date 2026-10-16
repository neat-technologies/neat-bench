---
name: Environment and box ops
description: Where the bench runs, how a box is stood up, what clean means on a cluster, what is never done to the demo, and how several boxes share the work.
governs:
  - "bench/ops/*"
  - "ops/*"
  - "*/standup*.sh"
  - "*/fix-kind-bridge*.sh"
  - "*/recover*.sh"
  - "*/worker*.sh"
  - "*/queue/*"
  - "docs/BENCHOPS-RUNBOOK.md"
  - "docs/DESIGN.md"
status: Accepted
---

# Environment and box ops

Status: **Accepted** (ADR-007 architecture; Deniz, 2026-10-16). Rule 3 follows ADR-003 (Proposed) and applies as the stricter reading until ruled. Browser traffic and budget are open choices in ADR-007.

## Rules

1. **The bench runs on the boxes, never on a laptop.** A leg started locally once filled a disk and is not repeated.
2. **A box is stood up by `standup-box.sh`, not by hand.** The script installs docker, kind, kubectl, helm, Node 20 (not 22: NEAT compiles tree-sitter grammars through node-gyp), NEAT at the pinned published version, the pinned chart rendering with the collector patch, the pristine source at the deployed tag, the fault artifacts, the inotify sysctls, the bridge guard, captures the hardware line, and disables sleep. A human installs the OS, Tailscale and SSH keys, and copies credentials. Credentials are never echoed, logged, or passed through a Claude session.
3. **Clean is the chart rendering** (pending ADR-003). The clean state of a cluster is the pinned chart rendered by `helm template` plus the versioned collector patch plus the documented deltas; a reset removes injector-owned fields (`kubectl replace` or a JSON patch), and the chart audit says clean, not a storefront probe. A snapshot of a running cluster is never the baseline.
4. **Never `helm uninstall` or reinstall the demo inside a running bench cluster.** The collector-to-NEAT export lives in the `otel-collector` configmap and a reinstall wipes it. When a reset cannot converge, the recovery is to destroy the kind cluster and recreate it from `standup-box.sh`, on Deniz's go for that incident, with the audit run before the first window.
5. **Leftovers are purged between legs, and the purge is audited.** After an ITBench leg, every workload the chart does not define is deleted (scanner and collector pods, duplicate demo copies in other namespaces, image-pull-looping relics); the next leg's audit lists zero of them. A duplicate demo found crash-looping in `default` for five days cost the box CPU and a memory-limited Prometheus.
6. **Daemon wiring is part of clean.** The NEAT daemon runs live, on its own source copy the arms cannot read, with `NEAT_WEB_DISABLED=1` where web is not installed, and the preflight proves it has ingested real OBSERVED edges before a window is scored.
7. **Several boxes share work through a pull queue.** One box holds the queue of cells; each cluster's worker claims a cell atomically, runs reset, audit, preflight, inject, arms, grade, pushes the run directory and the row back, and repeats. No session drives a run; a human watches. A box that disappears leaves its cell unclaimed.
8. **One fault per cluster at a time.** One cluster per box until the load-generator choice in ADR-007 is ruled; two lean clusters (demo plus NEAT) per 32 GB box if browser traffic is off. The ITBench stack runs one cluster per box.
9. **Boot hygiene.** Wired ethernet, sleep and hibernate off, the bridge guard on boot. On 2026-10-16 the kind bridge came up without its IPv4 gateway: the host could not reach the API server and pods had no egress while the cluster was healthy inside. `ops/fix-kind-bridge.sh` re-adds the address and is idempotent. "Up" and "reachable" are different states; the box booted at 18:23 and answered over Tailscale at 19:49.
10. **Box state changes are scripts in this repo** (`ops/`), run from the harness, logged to the run directory. Raw interactive deletes and patches are not how the cluster is operated. Scripts that still live only on a box (`~/praxis/harness/hard-reset.sh`, `verify-baseline.sh`) are retired by ADR-003 and are not run.

## Why

Every rule is a scar: a disk filled on a laptop; a hard-reset that could not remove what an injector added; a baseline check blind to the fields that carried the faults; ITBench leftovers that OOM-killed the box and broke the CNI; a reinstall that would wipe the collector wiring; a reboot that took the bridge's IPv4 address and 86 minutes of a dead Tailscale link.
