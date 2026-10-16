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
    conductor.problem_id = pid
    problem = conductor.current_problem
    app = problem.app
    print(f"application: {app.__class__.__name__} namespace={getattr(app, 'namespace', '?')} (problem {pid}, fault NOT injected)")
    conductor.deploy_app()
    print("deployed; workload running; collector exporting to NEAT and to /var/lib/otel/sregym-spans.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
