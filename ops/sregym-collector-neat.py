#!/usr/bin/env python3
"""Patch SREGym's OpenTelemetry collector so every application's traces also reach NEAT.

SREGym deploys one collector in namespace `observe` (sregym/observer/otel_collector/
otel-collector.yaml) that receives Jaeger (thrift-compact, thrift-http, grpc) and OTLP from
every application namespace and exports to its Jaeger backend. This script makes three
insertions into that file:

  1. exporters `otlphttp/neat` (the NEAT daemon on the host, bearer auth) and `file/capture`
     (every span to a JSON file: the ground truth Instrumentation needs per service);
  2. both exporters appended to the two trace pipelines;
  3. an emptyDir volume mounted at the capture directory, since the contrib image is built
     from scratch and the file exporter does not create parent directories.

SREGym applies the file on deploy, so the patch is a file edit in the checkout, never a
kubectl edit on the cluster. Each insertion is checked on its own, so the script is
idempotent and can finish a partial earlier run. It refuses if the upstream shape changed.

Usage (on a bench box):
  python3 ops/sregym-collector-neat.py ~/SREGym \
      --neat-endpoint http://172.18.0.1:4319 --neat-token "$NEAT_AUTH_TOKEN"

Read the capture with `kubectl -n observe exec deploy/otel-collector -- cat /var/lib/otel/sregym-spans.json`.
The token is passed on the command line only; never echo it.
"""
import argparse
import pathlib
import re
import sys

CAPTURE_DIR = "/var/lib/otel"
CAPTURE_FILE = f"{CAPTURE_DIR}/sregym-spans.json"

EXPORTER_ANCHOR = '      prometheus/otlp:\n        endpoint: "0.0.0.0:8890"\n'
EXPORTER_BLOCK = """      otlphttp/neat:
        endpoint: "{endpoint}"
        headers:
          authorization: "Bearer {token}"
        tls:
          insecure: true
      file/capture:
        path: "{capture}"
        format: json
        rotation:
          max_megabytes: 256
          max_backups: 1
"""

PIPELINES = {
    "          receivers: [jaeger]\n          exporters: [otlp, spanmetrics]\n":
    "          receivers: [jaeger]\n          exporters: [otlp, spanmetrics, otlphttp/neat, file/capture]\n",
    "          receivers: [otlp]\n          exporters: [otlp, spanmetrics/otlp]\n":
    "          receivers: [otlp]\n          exporters: [otlp, spanmetrics/otlp, otlphttp/neat, file/capture]\n",
}

MOUNT_ANCHOR = "          volumeMounts:\n            - name: config\n              mountPath: /etc/otel\n"
MOUNT_BLOCK = f"            - name: capture\n              mountPath: {CAPTURE_DIR}\n"
VOLUME_ANCHOR = "      volumes:\n        - name: config\n          configMap:\n            name: otel-collector-config\n"
VOLUME_BLOCK = "        - name: capture\n          emptyDir: {}\n"


def insert_after(text: str, anchor: str, block: str, marker: str, what: str) -> str:
    if marker in text:
        print(f"  {what}: present")
        return text
    if anchor not in text:
        print(f"  {what}: anchor not found; refusing to patch", file=sys.stderr)
        sys.exit(2)
    print(f"  {what}: inserted")
    return text.replace(anchor, anchor + block, 1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sregym_root", type=pathlib.Path)
    ap.add_argument("--neat-endpoint", required=True)
    ap.add_argument("--neat-token", required=True)
    args = ap.parse_args()

    path = args.sregym_root / "sregym/observer/otel_collector/otel-collector.yaml"
    text = path.read_text()
    print(f"{path}:")

    block = EXPORTER_BLOCK.format(endpoint=args.neat_endpoint, token=args.neat_token, capture=CAPTURE_FILE)
    text = insert_after(text, EXPORTER_ANCHOR, block, "otlphttp/neat:", "exporters")

    for old, new in PIPELINES.items():
        if new in text:
            print("  pipeline: present")
        elif old in text:
            text = text.replace(old, new, 1)
            print("  pipeline: wired")
        else:
            print("  pipeline: anchor not found; refusing to patch", file=sys.stderr)
            return 2

    text = insert_after(text, MOUNT_ANCHOR, MOUNT_BLOCK, f"mountPath: {CAPTURE_DIR}", "capture mount")
    text = insert_after(text, VOLUME_ANCHOR, VOLUME_BLOCK, "- name: capture\n          emptyDir", "capture volume")

    path.write_text(text)
    print(re.sub(r"Bearer \S+", "Bearer <redacted>", f"  neat endpoint {args.neat_endpoint}; capture {CAPTURE_FILE}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
