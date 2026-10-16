#!/usr/bin/env python3
"""Patch SREGym's OpenTelemetry collector so every application's traces also reach NEAT.

SREGym deploys one collector in namespace `observe` (sregym/observer/otel_collector/
otel-collector.yaml) that receives Jaeger (thrift-compact, thrift-http, grpc) and OTLP from
every application namespace and exports to its Jaeger backend. This script adds, to the two
trace pipelines, an `otlphttp/neat` exporter pointed at the NEAT daemon on the host, and a
`file` exporter that writes every span to a capture file (the ground truth Instrumentation
needs per service). SREGym applies the file on deploy, so the patch is a file edit in the
checkout, never a kubectl edit on the cluster.

Idempotent: running it twice leaves one copy of each exporter. Pure text insertion on the
known shape of the file; it refuses to run if the shape changed.

Usage (on a bench box):
  python3 ops/sregym-collector-neat.py ~/SREGym \
      --neat-endpoint http://172.18.0.1:4319 --neat-token "$NEAT_AUTH_TOKEN" \
      --capture-path /var/lib/otel/sregym-spans.json

The capture path is inside the collector pod; mount a hostPath or copy with `kubectl cp` to
read it. The token is passed on the command line only; never echo it.
"""
import argparse
import pathlib
import re
import sys

NEAT_EXPORTER = """      otlphttp/neat:
        endpoint: "{endpoint}"
        headers:
          authorization: "Bearer {token}"
        tls:
          insecure: true
      file/capture:
        path: "{capture}"
        format: json
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sregym_root", type=pathlib.Path)
    ap.add_argument("--neat-endpoint", required=True)
    ap.add_argument("--neat-token", required=True)
    ap.add_argument("--capture-path", default="/var/lib/otel/sregym-spans.json")
    args = ap.parse_args()

    path = args.sregym_root / "sregym/observer/otel_collector/otel-collector.yaml"
    text = path.read_text()

    if "otlphttp/neat" in text:
        print(f"{path}: already patched")
        return 0

    anchor = '      prometheus/otlp:\n        endpoint: "0.0.0.0:8890"\n'
    if anchor not in text:
        print(f"{path}: exporter block not where expected; refusing to patch", file=sys.stderr)
        return 2
    block = NEAT_EXPORTER.format(endpoint=args.neat_endpoint, token=args.neat_token, capture=args.capture_path)
    text = text.replace(anchor, anchor + block, 1)

    pipelines = {
        "          receivers: [jaeger]\n          exporters: [otlp, spanmetrics]\n":
        "          receivers: [jaeger]\n          exporters: [otlp, spanmetrics, otlphttp/neat, file/capture]\n",
        "          receivers: [otlp]\n          exporters: [otlp, spanmetrics/otlp]\n":
        "          receivers: [otlp]\n          exporters: [otlp, spanmetrics/otlp, otlphttp/neat, file/capture]\n",
    }
    for old, new in pipelines.items():
        if old not in text:
            print(f"{path}: trace pipeline not where expected; refusing to patch", file=sys.stderr)
            return 2
        text = text.replace(old, new, 1)

    path.write_text(text)
    redacted = re.sub(r"Bearer \S+", "Bearer <redacted>", block)
    print(f"{path}: patched\n{redacted}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
