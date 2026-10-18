#!/usr/bin/env python3
"""Per problem of one card pass: NEAT's verdict, its ranked candidates, the onset lead, and the
ground truth, as JSONL. The inputs for recall@3 and the selection-vs-retrieval question (#1495).

  card-fields.py <run-dir> <SREGym/results>   -> prints JSONL, writes <run>/card-fields.jsonl

Fields: problem, app, lead (ranked[0] of the graph-wide ask), verdict (root cause named),
verdict_class, grade, candidates [{node, classification, confidence}], top3 (first three distinct
nodes the submitted card names), truth {components[], text}, hits {verdict, top3, candidates3}.
"""
import csv, glob, json, pathlib, re, sys

run = pathlib.Path(sys.argv[1]); root = pathlib.Path(sys.argv[2])
GT = {}
gt_file = pathlib.Path(__file__).with_name("sregym-ground-truth.jsonl")
for line in open(gt_file):
    d = json.loads(line)
    m = re.search(r"component=([^;|]+)", str(d.get("rc", "")))
    comps = [p.strip().split("/")[-1].strip().lower() for p in (m.group(1) if m else "").split(",") if p.strip()]
    GT[d["pid"]] = {"components": comps, "text": str(d.get("rc", ""))[:300]}


def short(node):
    return node.split(":")[-1].lower()


def hit(names, comps):
    return any(n == c or n.startswith(c + "_") or n.startswith(c + ".") for n in names for c in comps)


def attempt_dir(results_dir, pid):
    base = pathlib.Path(results_dir)
    if not base.is_absolute():
        base = root.parent / base
    c = sorted(base.glob(f"neat-card/{pid}/run_*")) if base.exists() else []
    return c[-1] if c else None


out = []
for t in csv.DictReader(open(run / "timing.tsv"), delimiter="\t"):
    pid = t["problem"]
    row = {"problem": pid, "app": t["app"], "lead": None, "verdict": None, "verdict_class": None, "grade": None,
           "candidates": [], "top3": [], "truth": GT.get(pid), "hits": None, "void": t["void"]}
    d = attempt_dir(t["results_dir"], pid)
    rec = d / "neat-incident-record.json" if d else None
    if rec and rec.exists():
        try:
            o = json.loads(json.load(open(rec))["out"])
        except Exception:
            o = {}
        calls = o.get("calls", {})
        ask = calls.get("ask", {}).get("text", "")
        m = re.search(r"Start with (\S+?) —", ask)
        row["lead"] = m.group(1) if m else o.get("culprit")
        rc = calls.get("get_root_cause", {}).get("text", "")
        m = re.search(r"Root cause for \S+ is (\S+?)\.", rc)
        row["verdict"] = m.group(1) if m else None
        for m in re.finditer(r"•\s+(\S+) — ([a-z-]+) \(confidence ([0-9.]+)\)", rc):
            row["candidates"].append({"node": m.group(1), "classification": m.group(2), "confidence": float(m.group(3))})
        if row["candidates"] and row["verdict"]:
            row["verdict_class"] = next((c["classification"] for c in row["candidates"] if c["node"] == row["verdict"]), None)
        card = calls.get("investigate", {}).get("text", "")
        m = re.search(r"grade: ([0-9.]+) \((\w+)\)", card)
        row["grade"] = {"score": float(m.group(1)), "band": m.group(2)} if m else None
        sub = d / "neat-card-submission.txt"
        text = sub.read_text(errors="replace") if sub.exists() else ask + "\n" + card
        seen = []
        for m in re.finditer(r"\b(?:service|infra|database|config|file|symbol|route)(?::[A-Za-z0-9_.-]+)+", text):
            n = short(m.group(0))
            if n not in seen:
                seen.append(n)
        row["top3"] = seen[:3]
        comps = (row["truth"] or {}).get("components", [])
        row["hits"] = {
            "verdict": bool(row["verdict"]) and hit([short(row["verdict"])], comps),
            "lead": bool(row["lead"]) and hit([short(row["lead"])], comps),
            "top3": hit(row["top3"], comps),
            "candidates3": hit([short(c["node"]) for c in row["candidates"][:3]], comps),
            "candidates_any": hit([short(c["node"]) for c in row["candidates"]], comps),
        }
    out.append(row)
    print(json.dumps(row))
(run / "card-fields.jsonl").write_text("".join(json.dumps(r) + "\n" for r in out))
scored = [r for r in out if r["hits"]]
if scored:
    s = {k: sum(1 for r in scored if r["hits"][k]) for k in scored[0]["hits"]}
    print(json.dumps({"summary": {**s, "n": len(scored)}}), file=sys.stderr)
