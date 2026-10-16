#!/usr/bin/env python3
"""Pull the span capture from SREGym's collector, split it per service, and record what NEAT fused.

Produces the deliverable Instrumentation files language-coverage gaps against:
  <out>/<app>/<timestamp>/
    collector-config.yaml       the collector config as deployed (token redacted)
    services.tsv                service, language, source dir, total spans seen, distinct span names
    by-service/<service>.json   up to --cap resource-span batches for that service (OTLP JSON)
    neat-fusion.tsv             per service: does NEAT hold a ServiceNode for it, how many OBSERVED
                                edges touch it, and how many of its observed targets landed on a
                                FRONTIER node (seen at runtime, matched to nothing static)

The capture file is read as a stream (it reaches gigabytes under a load generator), and only the
first --cap batches per service are kept; the counts in services.tsv cover everything seen.
Language is detected from the service's source directory in the application checkout.

Two applications can share a service name (the demo and the hotel app both have `frontend`),
so --origin selects by how the spans arrived: `jaeger` keeps resources that carry Jaeger client
attributes (opentracing apps), `otlp` keeps the rest, `all` keeps everything.

The collector image has no shell or tar and `kubectl debug -i` truncates large streams, so the
emptyDir file is read from the kind node container's kubelet volume path.

Usage (on a bench box, kube context on the SREGym cluster, NEAT daemon on :8098):
  python3 ops/sregym-capture.py hotel-reservation ~/sregym-src/DeathStarBench/hotelReservation/cmd \
      ~/sregym-captures --origin jaeger
"""
import argparse
import collections
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

MANIFESTS = {
    "go.mod": "go", "pom.xml": "java", "build.gradle": "java", "build.gradle.kts": "kotlin",
    "package.json": "javascript", "tsconfig.json": "typescript", "requirements.txt": "python",
    "pyproject.toml": "python", "Gemfile": "ruby", "composer.json": "php", "Cargo.toml": "rust",
    "CMakeLists.txt": "cpp", "Package.swift": "swift", "mix.exs": "elixir",
}
EXTS = {
    ".go": "go", ".java": "java", ".kt": "kotlin", ".ts": "typescript", ".tsx": "typescript",
    ".js": "javascript", ".py": "python", ".rb": "ruby", ".php": "php", ".rs": "rust",
    ".cpp": "cpp", ".cc": "cpp", ".cs": "csharp", ".lua": "lua",
}
CAPTURE_FILE = "sregym-spans.json"
# What the collector's Jaeger receiver puts on a resource: the client's exporter version and the
# process tags (`ip`, `host.name` = pod name). OTLP-native SDKs carry `telemetry.sdk.name` instead.
JAEGER_MARKERS = ("opencensus.exporterversion", "jaeger.version", "ip")
NEAT_URL = os.environ.get("NEAT_URL", "http://localhost:8098")
NEAT_TOKEN = os.environ.get("NEAT_AUTH_TOKEN", "")


def detect_language(svc_dir: pathlib.Path) -> str:
    if not svc_dir.is_dir():
        return "-"
    if list(svc_dir.glob("*.csproj")):
        return "csharp"
    for name, lang in MANIFESTS.items():
        if (svc_dir / name).exists():
            if lang == "javascript" and (svc_dir / "tsconfig.json").exists():
                return "typescript"
            return lang
    counts = collections.Counter()
    for p in svc_dir.rglob("*"):
        if p.is_file() and p.suffix in EXTS and "node_modules" not in p.parts:
            counts[EXTS[p.suffix]] += 1
    return counts.most_common(1)[0][0] if counts else "-"


def sh(cmd: str, timeout: int = 120) -> str:
    return subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True, timeout=timeout).stdout


def capture_stream():
    uid = sh("kubectl -n observe get pod -l app-name=otel-collector -o jsonpath='{.items[0].metadata.uid}'").strip()
    node = sh("kubectl -n observe get pod -l app-name=otel-collector -o jsonpath='{.items[0].spec.nodeName}'").strip()
    path = f"/var/lib/kubelet/pods/{uid}/volumes/kubernetes.io~empty-dir/capture/{CAPTURE_FILE}"
    proc = subprocess.Popen(["docker", "exec", node, "cat", path], stdout=subprocess.PIPE, text=True)
    assert proc.stdout is not None
    return proc, proc.stdout


def neat_graph() -> dict:
    req = urllib.request.Request(f"{NEAT_URL}/graph", headers={"Authorization": f"Bearer {NEAT_TOKEN}"} if NEAT_TOKEN else {})
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.load(r)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("app")
    ap.add_argument("src_root", type=pathlib.Path)
    ap.add_argument("out_root", type=pathlib.Path)
    ap.add_argument("--origin", choices=["jaeger", "otlp", "all"], default="all")
    ap.add_argument("--cap", type=int, default=400, help="resource-span batches kept per service")
    args = ap.parse_args()

    out = args.out_root / args.app / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    (out / "by-service").mkdir(parents=True)

    cfg = sh("kubectl -n observe get configmap otel-collector-config -o jsonpath='{.data.config\\.yaml}'")
    (out / "collector-config.yaml").write_text(cfg.replace(f"Bearer {NEAT_TOKEN}", "Bearer <redacted>") if NEAT_TOKEN else cfg)

    kept: dict[str, list] = collections.defaultdict(list)
    span_names: dict[str, set] = collections.defaultdict(set)
    span_count: collections.Counter = collections.Counter()
    bad = lines = 0
    proc, stream = capture_stream()
    for line in stream:
        lines += 1
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        for rs in req.get("resourceSpans", []):
            attrs = {a["key"]: a.get("value", {}) for a in rs.get("resource", {}).get("attributes", [])}
            is_jaeger = any(k in attrs for k in JAEGER_MARKERS) and "telemetry.sdk.name" not in attrs
            if args.origin == "jaeger" and not is_jaeger:
                continue
            if args.origin == "otlp" and is_jaeger:
                continue
            svc = attrs.get("service.name", {}).get("stringValue", "unknown")
            n = 0
            for ss in rs.get("scopeSpans", []):
                for sp in ss.get("spans", []):
                    span_names[svc].add(sp.get("name", ""))
                    n += 1
            span_count[svc] += n
            if len(kept[svc]) < args.cap:
                kept[svc].append(rs)
    proc.wait()

    def source_dir(svc: str) -> pathlib.Path:
        # DeathStarBench names services `compose-post-service` at runtime and
        # `ComposePostService` in the tree; try the literal name, then the CamelCase form.
        for cand in (svc, "".join(p.capitalize() for p in svc.split("-"))):
            if (args.src_root / cand).is_dir():
                return args.src_root / cand
        return args.src_root / svc

    with (out / "services.tsv").open("w") as f:
        f.write("service\tlanguage\tsource_dir\tspans\tdistinct_span_names\n")
        for svc in sorted(span_count):
            (out / "by-service" / f"{svc}.json").write_text(json.dumps({"resourceSpans": kept[svc]}))
            d = source_dir(svc)
            f.write(f"{svc}\t{detect_language(d)}\t{d if d.is_dir() else '-'}\t{span_count[svc]}\t{len(span_names[svc])}\n")

    try:
        g = neat_graph()
        nodes = {n["id"]: n for n in g.get("nodes", [])}
        service_ids = {n["id"] for n in g.get("nodes", []) if n.get("type") == "ServiceNode"}
        obs = [e for e in g.get("edges", []) if e.get("provenance") == "OBSERVED"]
        touch: collections.Counter = collections.Counter()
        frontier: collections.Counter = collections.Counter()
        for e in obs:
            for end in (e.get("source"), e.get("target")):
                if isinstance(end, str) and end.startswith("service:"):
                    touch[end.split(":", 1)[1]] += 1
            if isinstance(e.get("target"), str) and e["target"].startswith("frontier:") and isinstance(e.get("source"), str):
                frontier[e["source"].split(":", 1)[1]] += 1
        with (out / "neat-fusion.tsv").open("w") as f:
            f.write("service\thas_service_node\tobserved_edges_touching\tobserved_targets_on_frontier\n")
            for svc in sorted(span_count):
                f.write(f"{svc}\t{'yes' if f'service:{svc}' in service_ids else 'no'}\t{touch[svc]}\t{frontier[svc]}\n")
        print(f"neat: nodes={len(nodes)} observed_edges={len(obs)} frontier_nodes={sum(1 for i in nodes if i.startswith('frontier:'))}")
    except Exception as exc:
        print(f"neat graph not read: {exc}", file=sys.stderr)

    print(f"capture at {out} (lines read: {lines}, unparseable: {bad}, origin={args.origin}, cap={args.cap}/service)")
    for line in (out / "services.tsv").read_text().splitlines()[1:]:
        print("  " + line.replace("\t", "  "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
