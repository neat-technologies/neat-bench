#!/usr/bin/env python3
"""Score one card-accuracy pass: SREGym's judge verdict on NEAT's own card, per problem.

  card-score.py <run-dir> <SREGym/results>   -> prints a table, writes <run>/card-score.json

A problem counts as right when the judge passes the diagnosis (its composite >= its threshold).
Void attempts (NEAT unreachable, or another app left on the cluster) are listed and excluded.
"""
import csv, glob, json, os, pathlib, re, sys

csv.field_size_limit(10**9)
run = pathlib.Path(sys.argv[1]); root = pathlib.Path(sys.argv[2])


def attempt_dir(results_dir, pid, start, end):
    base = pathlib.Path(results_dir) if results_dir and results_dir != "-" else None
    if base is not None and not base.is_absolute():
        base = root.parent / base
    c = sorted(base.glob(f"neat-card/{pid}/run_*")) if base is not None and base.exists() else []
    if not c:
        c = [p for p in sorted(root.glob(f"*/neat-card/{pid}/run_*")) if start - 5 <= p.stat().st_mtime <= end + 120]
    return c[-1] if c else None


# SREGym's ground truth per problem (ops/sregym-ground-truth.jsonl, dumped offline from each
# problem's root_cause): the faulty component names, used for recall@3 on the card's candidates.
GT = {}
gt_file = pathlib.Path(__file__).with_name("sregym-ground-truth.jsonl")
if gt_file.exists():
    for line in open(gt_file):
        d = json.loads(line)
        m = re.search(r"component=([^;|]+)", str(d.get("rc", "")))
        names = set()
        for part in (m.group(1) if m else "").split(","):
            part = part.strip().split("/")[-1].strip().lower()
            if part:
                names.add(part)
        GT[d["pid"]] = names


def candidates(text, n=3):
    """The first n distinct graph nodes the card names, in order (service:x, infra:kind:x, …)."""
    out = []
    for m in re.finditer(r"\b(?:service|infra|database|config|file|symbol|route)(?::[A-Za-z0-9_.-]+)+", text):
        name = m.group(0).split(":")[-1].lower()
        if name not in out:
            out.append(name)
        if len(out) >= n:
            break
    return out


rows = []
for t in csv.DictReader(open(run / "timing.tsv"), delimiter="\t"):
    d = attempt_dir(t["results_dir"], t["problem"], float(t["start_epoch"]), float(t["end_epoch"]))
    r = {"problem": t["problem"], "app": t["app"], "void": t["void"], "wall_s": int(t["wall_s"]),
         "pass": None, "accuracy": None, "culprit": "", "why": ""}
    if d:
        for f in d.glob("*_results.csv"):
            for row in csv.DictReader(open(f)):
                r["pass"] = row.get("Diagnosis.success") == "True"
                try:
                    r["accuracy"] = float(row.get("Diagnosis.accuracy") or 0)
                except ValueError:
                    pass
                ev = re.findall(r"'evidence': '([^']{0,200})'", row.get("Diagnosis.checklist", ""))
                r["why"] = ev[0] if ev else ""
        rec = d / "neat-incident-record.json"
        if rec.exists():
            try:
                r["culprit"] = json.loads(json.load(open(rec))["out"]).get("culprit", "")
            except Exception:
                pass
        sub = d / "neat-card-submission.txt"
        if sub.exists() and t["problem"] in GT:
            text = sub.read_text(errors="replace")
            top = candidates(text)
            gt = GT[t["problem"]]
            r["top3"] = top
            r["recall3"] = any(g == c or c.startswith(g + "_") or c.startswith(g + ".") for g in gt for c in top)
            r["mentioned"] = any(g in text.lower() for g in gt)
        if (d / "neat-preflight-void.json").exists():
            r["void"] = "neat-preflight"
    rows.append(r)

valid = [r for r in rows if r["void"] in ("no", "") and r["pass"] is not None]
right = [r for r in valid if r["pass"]]
by_app = {}
for r in valid:
    a = by_app.setdefault(r["app"], [0, 0]); a[1] += 1; a[0] += 1 if r["pass"] else 0
r3 = [r for r in valid if r.get("recall3") is not None]
out = {"run": str(run), "valid": len(valid), "right": len(right),
       "recall3": f"{sum(1 for r in r3 if r['recall3'])}/{len(r3)}",
       "mentioned_anywhere": f"{sum(1 for r in r3 if r.get('mentioned'))}/{len(r3)}",
       "accuracy_pct": round(100 * len(right) / len(valid), 1) if valid else None,
       "mean_judge_score": round(sum(r["accuracy"] or 0 for r in valid) / len(valid), 1) if valid else None,
       "by_app": {k: f"{v[0]}/{v[1]}" for k, v in sorted(by_app.items())},
       "void": [f"{r['problem']} ({r['void']})" for r in rows if r not in valid],
       "rows": rows}
json.dump(out, open(run / "card-score.json", "w"), indent=1)
print(f"card right: {out['right']}/{out['valid']} ({out['accuracy_pct']}%)  mean judge score {out['mean_judge_score']}  recall@3 {out['recall3']}  named anywhere {out['mentioned_anywhere']}  by app {out['by_app']}")
if out["void"]:
    print("void/unscored:", ", ".join(out["void"]))
for r in rows:
    mark = "RIGHT" if r["pass"] else ("wrong" if r["pass"] is False else "  -  ")
    print(f"{mark}  {r['problem'][:52]:52} {str(r['accuracy']):>5}  {r['culprit'][:28]:28} {r['why'][:90]}")
