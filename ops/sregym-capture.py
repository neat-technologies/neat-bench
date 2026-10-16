#!/usr/bin/env python3
"""Pull the span capture from SREGym's collector and split it per service.

Produces the deliverable Instrumentation files language-coverage gaps against:
  <out>/<app>/<timestamp>/
    collector-config.yaml       the collector config as deployed (from the ConfigMap)
    spans-all.json              the raw capture (OTLP JSON, one ExportTraceServiceRequest per line)
    services.tsv                service, language, source dir, span count, distinct span names
    by-service/<service>.json   that service's resource spans only

Language is detected from the service's source directory in the application checkout
(manifest files, then file extensions), so it is a fact about the checkout, not a guess.

Usage (on a bench box, kube context already on the SREGym cluster):
  python3 ops/sregym-capture.py astronomy-shop ~/SREGym/SREGym-applications/astronomy-shop/src ~/sregym-captures
"""
import collections
import json
import pathlib
import subprocess
import sys
import time

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


def detect_language(svc_dir: pathlib.Path) -> str:
    if not svc_dir.is_dir():
        return "-"
    for name, lang in MANIFESTS.items():
        if (svc_dir / name).exists():
            if lang == "javascript" and (svc_dir / "tsconfig.json").exists():
                return "typescript"
            if (svc_dir / "*.csproj") or list(svc_dir.glob("*.csproj")):
                return "csharp"
            return lang
    counts = collections.Counter()
    for p in svc_dir.rglob("*"):
        if p.is_file() and p.suffix in EXTS and "node_modules" not in p.parts:
            counts[EXTS[p.suffix]] += 1
    return counts.most_common(1)[0][0] if counts else "-"


def sh(cmd: str) -> str:
    return subprocess.run(cmd, shell=True, check=True, capture_output=True, text=True).stdout


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    app, src_root, out_root = sys.argv[1], pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
    out = out_root / app / time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    (out / "by-service").mkdir(parents=True)

    (out / "collector-config.yaml").write_text(
        sh("kubectl -n observe get configmap otel-collector-config -o jsonpath='{.data.config\\.yaml}'")
        .replace("Bearer benchops", "Bearer <redacted>")
    )
    raw = sh("kubectl -n observe exec deploy/otel-collector -- cat /var/lib/otel/sregym-spans.json")
    (out / "spans-all.json").write_text(raw)

    per_service: dict[str, list] = collections.defaultdict(list)
    span_names: dict[str, set] = collections.defaultdict(set)
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        for rs in req.get("resourceSpans", []):
            attrs = {a["key"]: a.get("value", {}) for a in rs.get("resource", {}).get("attributes", [])}
            svc = attrs.get("service.name", {}).get("stringValue", "unknown")
            per_service[svc].append(rs)
            for ss in rs.get("scopeSpans", []):
                for sp in ss.get("spans", []):
                    span_names[svc].add(sp.get("name", ""))

    rows = []
    for svc in sorted(per_service):
        (out / "by-service" / f"{svc}.json").write_text(json.dumps({"resourceSpans": per_service[svc]}))
        svc_dir = src_root / svc
        n = sum(len(sp) for rs in per_service[svc] for ss in rs.get("scopeSpans", []) for sp in [ss.get("spans", [])])
        rows.append((svc, detect_language(svc_dir), str(svc_dir) if svc_dir.is_dir() else "-", n, len(span_names[svc])))
    with (out / "services.tsv").open("w") as f:
        f.write("service\tlanguage\tsource_dir\tspans\tdistinct_span_names\n")
        for r in rows:
            f.write("\t".join(map(str, r)) + "\n")
    print(f"capture at {out}")
    for r in rows:
        print("  %-22s %-11s spans=%-6s names=%s" % (r[0], r[1], r[3], r[4]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
