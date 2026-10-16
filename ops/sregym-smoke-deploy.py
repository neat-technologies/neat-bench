#!/usr/bin/env python3
"""Deploy one SREGym application with SREGym's own observability stack, without a fault.

This is the smoke path, not a bench run: no agent, no fault injection, no oracle. It drives
SREGym's Conductor exactly as a problem run would up to and including `deploy_app()`
(metrics-server, OpenEBS, Prometheus, Jaeger, the patched OTel collector, Loki, the MCP
server, then the application and its default workload) and stops there. The collector,
patched by ops/sregym-collector-neat.py, then streams every span to the NEAT daemon and to
the capture file that Instrumentation needs.

Run from the SREGym checkout with its venv, on a bench box:
  cd ~/SREGym && .venv/bin/python ~/neat-bench-ops/sregym-smoke-deploy.py ad_service_failure

The problem id only selects the application; its fault is never injected here.
"""
import logging
import subprocess
import sys

from sregym.conductor.conductor import Conductor, ConductorConfig

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: sregym-smoke-deploy.py <problem-id selecting the application>", file=sys.stderr)
        return 2
    pid = sys.argv[1]
    conductor = Conductor(config=ConductorConfig(deploy_loki=True))
    ids = conductor.problems.get_problem_ids(all=True)
    if pid not in ids:
        print(f"unknown problem id {pid!r}; {len(ids)} known", file=sys.stderr)
        return 2
    # What start_problem() does before deploy, minus the submission bookkeeping and the
    # fault: load the problem instance so deploy_app() has an application to deploy.
    conductor.problem_id = pid
    conductor.problem = conductor.problems.get_problem_instance(pid)
    conductor.app = conductor.problem.app
    problem = conductor.current_problem
    app = problem.app
    print(f"application: {app.__class__.__name__} namespace={getattr(app, 'namespace', '?')} (problem {pid}, fault NOT injected)")
    conductor.deploy_app()
    print("deployed; workload running; collector exporting to NEAT and to /var/lib/otel/sregym-spans.json")

    # SREGym swaps each app namespace's `jaeger` Service for an ExternalName to its collector
    # only after the application is up. Jaeger clients that resolve the agent address once at
    # start (the DeathStarBench Go services do) keep sending UDP to the deleted ClusterIP and
    # the collector never sees them (seen 2026-10-16 on hotel-reservation: zero Jaeger spans
    # until the pods were restarted). Restart the application deployments so they re-resolve.
    for ns in getattr(app, "namespaces", None) or [app.namespace]:
        # Some SREGym images (the DeathStarBench socialNetwork build) also export OTLP gRPC to
        # the bare name otel-collector:4317, which exists in no application namespace. Give
        # them the same ExternalName SREGym gives Jaeger, so full-fidelity OTLP spans arrive.
        subprocess.run(
            f"kubectl -n {ns} get svc otel-collector >/dev/null 2>&1 || "
            f"kubectl -n {ns} create service externalname otel-collector "
            f"--external-name otel-collector.observe.svc.cluster.local",
            shell=True, check=False, capture_output=True,
        )
        # DeathStarBench ConfigMaps ship a probabilistic Jaeger sampler (0.01 in SREGym's
        # charts); the bench wants every trace, so sample everything.
        cms = subprocess.run(
            f"kubectl -n {ns} get cm -o json", shell=True, capture_output=True, text=True
        ).stdout
        try:
            import json, re
            for item in json.loads(cms or "{}").get("items", []):
                y = (item.get("data") or {}).get("jaeger-config.yml")
                if not y:
                    continue
                y2 = re.sub(r'type: *"?probabilistic"?', 'type: "const"', y)
                y2 = re.sub(r"param: *[0-9.]+", "param: 1", y2)
                if y2 != y:
                    patch = json.dumps({"data": {"jaeger-config.yml": y2}})
                    subprocess.run(
                        ["kubectl", "-n", ns, "patch", "cm", item["metadata"]["name"], "--type=merge", "-p", patch],
                        check=False, capture_output=True,
                    )
        except ValueError:
            pass
        out = subprocess.run(
            f"kubectl -n {ns} get deploy -o name", shell=True, capture_output=True, text=True
        ).stdout.split()
        for d in out:
            if any(x in d for x in ("mongodb", "memcached", "consul", "jaeger", "redis", "postgres", "kafka", "valkey")):
                continue
            subprocess.run(f"kubectl -n {ns} rollout restart {d}", shell=True, check=False, capture_output=True)
        print(f"restarted application deployments in {ns} so Jaeger clients re-resolve the collector")
    return 0


if __name__ == "__main__":
    sys.exit(main())
