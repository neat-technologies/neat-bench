# ops

Box-side scripts, governed by `docs/contracts/environment.md` and `docs/contracts/run-validity.md`. Each is streamed to a box and run from there; none runs on a laptop.

- `audit-vs-chart.sh` — read-only. Renders the pinned chart with the release's values and diffs every live `otel-demo` Deployment against it (init containers, probe ports, memory limits, images, node selectors, replicas, env count), and prints the field-manager owners of the suspect fields. The launch gate of run-validity rule 1.
- `fix-kind-bridge.sh` — idempotent. Re-adds the kind docker network's IPv4 gateway to the bridge when a reboot drops it (environment rule 9).
- `recover-20261016.sh` — the 16 October recovery: strips the injector-owned fields with a JSON patch, recycles the pods stuck in Unknown, purges the duplicate demo in `default`, installs the bridge guard, then prints the settled state. Kept as the worked example of a reset that removes what an injector added (ADR-003); `standup-box.sh` and the worker supersede it.
