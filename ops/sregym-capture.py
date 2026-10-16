#!/usr/bin/env python3
"""Pull the span capture from SREGym's collector, split it per service, and record what NEAT fused.

Produces the deliverable Instrumentation files language-coverage gaps against:
  <out>/<app>/<timestamp>/
    collector-config.yaml       the collector config as deployed (token redacted)
    spans-all.json              the raw capture (OTLP JSON, one ExportTraceServiceRequest per line)
    services.tsv                service, language, source dir, span count, distinct span names
    by-service/<service>.json   that service's resource spans only
    neat-fusion.tsv             per service: does NEAT hold a ServiceNode for it, how many OBSERVED
                                edges touch it, and how many of its observed targets landed on a
                                FRONTIER node (seen at runtime, matched to nothing static)

Language is detected from the service's source directory in the application checkout
(manifest files, then file extensions), so it is a fact about the checkout, not a guess.

The collector image is built from scratch (no shell, no tar), so the file is read through an
ephemeral busybox debug container sharing the collector's process namespace.

Usage (on a bench box, kube context on the SREGym cluster, NEAT daemon on :8098):
  python3 ops/sregym-capture.py astronomy-shop ~/SREGym/SREGym-applications/astronomy-shop/src ~/sregym-captures
"""
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
CAPTURE = "/var/lib/otel/sregym-spans.json"
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


def read_capture() -> str:
    pod = sh("kubectl -n observe get pod -l app-name=otel-collector -o jsonpath='{.items[0].metadata.name}'").strip()
    return sh(
        f"kubectl -n observe debug -q -i {pod} --image=busybox:1.36 --target=otel-collector "
        f"-- cat /proc/1/root{CAPTURE}", timeout=300,
    )


def neat_graph() -> dict:
    req = urllib.request.Request(f"{NEAT_URL}/graph", headers={"Authorization": f"Bearer {NEAT_TOKEN}"} if NEAT_TOKEN else {})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    app, src_root, out_root = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    out = out_root / app / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    (out / "by-service").mkdir(parents=True)

    cfg = sh("kubectl -n observe get configmap otel-collector-config -o jsonpath='{.data.config\\.yaml}'")
    (out / "collector-config.yaml").write_text(cfg.replace(f"Bearer {NEAT_TOKEN}", "Bearer <redacted>") if NEAT_TOKEN else cfg)
    raw = read_capture()
    (out / "spans-all.json").write_text(raw)

    per_service: dict[str, list] = collections.defaultdict(list)
    span_names: dict[str, set] = collections.defaultdict(set)
    span_count: collections.Counter = collections.Counter()
    bad = 0
    for line in raw.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            bad += 1  # a line the collector was still writing, or debug-attach noise
            continue
        for rs in req.get("resourceSpans", []):
            attrs = {a["key"]: a.get("value", {}) for a in rs.get("resource", {}).get("attributes", [])}
            svc = attrs.get("service.name", {}).get("stringValue", "unknown")
            per_service[svc].append(rs)
            for ss in rs.get("scopeSpans", []):
                for sp in ss.get("spans", []):
                    span_names[svc].add(sp.get("name", ""))
                    span_count[svc] += 1

    with (out / "services.tsv").open("w") as f:
        f.write("service\tlanguage\tsource_dir\tspans\tdistinct_span_names\n")
        for svc in sorted(per_service):
            (out / "by-service" / f"{svc}.json").write_text(json.dumps({"resourceSpans": per_service[svc]}))
            d = src_root / svc
            f.write(f"{svc}\t{detect_language(d)}\t{d if d.is_dir() else '-'}\t{span_count[svc]}\t{len(span_names[svc])}\n")

    # What NEAT made of it.
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
            for svc in sorted(per_service):
                f.write(f"{svc}\t{'yes' if f'service:{svc}' in service_ids else 'no'}\t{touch[svc]}\t{frontier[svc]}\n")
        print(f"neat: nodes={len(nodes)} observed_edges={len(obs)} frontier_nodes={sum(1 for i in nodes if i.startswith('frontier:'))}")
    except Exception as exc:  # the capture is still valid without the fusion view
        print(f"neat graph not read: {exc}", file=sys.stderr)

    print(f"capture at {out} (unparseable lines skipped: {bad})")
    for line in (out / "services.tsv").read_text().splitlines()[1:]:
        print("  " + line.replace("\t", "  "))
    return 0


if __name__ == "__main__":
    sys.exit(main())
