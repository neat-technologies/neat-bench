#!/usr/bin/env python3
"""Summarise what survives on the spans of a captured service: attribute keys by span kind.

Answers the ingest question for an application whose SDK is not OTLP-native (Jaeger or
opentracing clients converted by the collector): do semconv keys such as http.*, rpc.*,
net.peer.*, server.address or peer.service arrive, or only opentracing tags? That decides
whether a fusion gap is a join rule (NEAT side) or an ingest floor (nothing to join on).

Usage:
  python3 ops/sregym-span-keys.py <capture-dir>/by-service/<service>.json [more.json ...]
"""
import collections
import json
import sys

KINDS = {0: "UNSPECIFIED", 1: "INTERNAL", 2: "SERVER", 3: "CLIENT", 4: "PRODUCER", 5: "CONSUMER"}


def kind_of(sp) -> str:
    k = sp.get("kind", 0)
    if isinstance(k, str):
        return k.replace("SPAN_KIND_", "")
    return KINDS.get(k, str(k))


def main() -> int:
    for path in sys.argv[1:]:
        doc = json.load(open(path))
        keys: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
        names: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
        resource_keys: collections.Counter = collections.Counter()
        scopes: collections.Counter = collections.Counter()
        total = 0
        for rs in doc.get("resourceSpans", []):
            for a in rs.get("resource", {}).get("attributes", []):
                resource_keys[a["key"]] += 1
            for ss in rs.get("scopeSpans", []):
                scopes[(ss.get("scope") or {}).get("name", "?")] += 1
                for sp in ss.get("spans", []):
                    total += 1
                    k = kind_of(sp)
                    names[k][sp.get("name", "")] += 1
                    for a in sp.get("attributes", []):
                        keys[k][a["key"]] += 1
        print(f"== {path}: {total} spans; scopes: {dict(scopes.most_common(4))}")
        print(f"   resource keys: {sorted(resource_keys)}")
        for k in sorted(keys):
            print(f"   {k} ({sum(names[k].values())} spans): names={[n for n, _ in names[k].most_common(5)]}")
            print(f"      keys={[f'{key}×{c}' for key, c in keys[k].most_common(40)]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
