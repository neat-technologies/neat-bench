#!/usr/bin/env python3
"""Print the card NEAT built at the start of each NEAT-arm attempt next to SREGym's ground truth.

Reads neat-incident-record.json (written by neat-record.py before the agent starts) and the
judge's checklist from the same attempt. Grading stays a human call; this lines the two up.

  card-vs-truth.py <SREGym/results> [since-epoch]
"""
import csv, glob, json, os, re, sys

csv.field_size_limit(10**9)
root = sys.argv[1]
since = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else 0.0

for f in sorted(glob.glob(os.path.join(root, "*/claudecode-neat/*/run_*/neat-incident-record.json"))):
    if os.path.getmtime(f) < since:
        continue
    prob = f.split(os.sep)[-3]
    try:
        rec = json.loads(json.load(open(f))["out"])
    except Exception as e:  # noqa: BLE001
        print(f"## {prob}\n  record unreadable: {e}\n")
        continue
    calls = rec.get("calls", {})
    card = (calls.get("investigate") or {}).get("text", "")
    lead = (calls.get("ask") or {}).get("text", "")
    truth = ""
    for c in glob.glob(os.path.join(os.path.dirname(f), "*results.csv")):
        for row in csv.DictReader(open(c)):
            items = re.findall(r"'evidence': '([^']{0,220})'", row.get("Diagnosis.checklist", ""))
            truth = " | ".join(items[:2])
    print(f"## {prob}")
    print(f"  culprit: {rec.get('culprit')}")
    print(f"  lead:    {lead[:300]!s}".replace("\n", " "))
    print(f"  card:    {card[:500]!s}".replace("\n", " "))
    print(f"  judge:   {truth[:450]}")
    print()
