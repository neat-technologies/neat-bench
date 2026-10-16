# ops

Box-side scripts, governed by `docs/contracts/environment.md` and `docs/contracts/run-validity.md`. Each is streamed to a box and run from there; none runs on a laptop.

- `audit-vs-chart.sh` — read-only. Renders the pinned chart with the release's values and diffs every live `otel-demo` Deployment against it (init containers, probe ports, memory limits, images, node selectors, replicas, env count), and prints the field-manager owners of the suspect fields. The launch gate of run-validity rule 1.
- `fix-kind-bridge.sh` — idempotent. Re-adds the kind docker network's IPv4 gateway to the bridge when a reboot drops it (environment rule 9).
- `recover-20261016.sh` — the 16 October recovery: strips the injector-owned fields with a JSON patch, recycles the pods stuck in Unknown, purges the duplicate demo in `default`, installs the bridge guard, then prints the settled state. Kept as the worked example of a reset that removes what an injector added (ADR-003); `standup-box.sh` and the worker supersede it.
- `standup-sregym.sh` — stands SREGym up on a bench box in phases (`deps`, `wire`, `cluster`, `daemon`, `all`): clone with the applications submodule, `uv sync`, inotify sysctls, the collector patch below, SREGym's own 4-node kind cluster (refuses without 16 GiB free and load under the core count), and a live NEAT daemon over the applications checkout. ADR-006, ADR-007.
- `sregym-collector-neat.py` — patches SREGym's single collector (namespace `observe`, which receives Jaeger and OTLP from every application) to also export to the NEAT daemon and to a capture file. Idempotent; refuses if the upstream file's shape changed.
- `sregym-smoke-deploy.py` — runs SREGym's own Conductor up to `deploy_app()` for the application a problem id names: observability stack, the patched collector, the application and its default workload. No agent, no fault, no oracle. The smoke path, never a bench run.
- `sregym-capture.py` — pulls the collector's span capture and splits it per service with the language detected from the application checkout: the deliverable Instrumentation files coverage gaps against.
