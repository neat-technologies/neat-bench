#!/usr/bin/env python3
"""Aggregate an overnight SREGym run: outcomes, wall time, tokens and cost per problem and arm.

Reads <run>/timing.tsv (written by sregym-overnight.sh), each attempt's SREGym results CSV and
the claudecode_results_*.json usage file under <sregym-results-root>, and writes
<run>/summary.tsv (one row per problem x arm) and <run>/totals.json. Prints the totals.

Cost: pass PRICE_IN, PRICE_OUT, PRICE_CACHE_READ, PRICE_CACHE_WRITE (USD per million tokens)
in the environment for the model used; without them cost is reported as null, never guessed.

Usage: python3 ops/sregym-aggregate.py <run-dir> <sregym-results-root>
"""
import csv
import glob
import json
import os
import pathlib
import sys


def price(name: str):
    v = os.environ.get(name)
    return float(v) if v else None


def find_attempt(results_root: pathlib.Path, results_dir: str, arm: str, pid: str):
    base = pathlib.Path(results_dir) if results_dir and results_dir != "-" else None
    cands = []
    if base and base.exists():
        cands = sorted(base.glob(f"{arm}/{pid}/run_*"))
    if not cands:
        cands = sorted(results_root.glob(f"*/{arm}/{pid}/run_*"))
    return cands[-1] if cands else None


def read_outcome(run_dir: pathlib.Path) -> dict:
    out = {}
    for f in sorted(run_dir.glob("*_results.csv")):
        with open(f, newline="") as fh:
            rows = list(csv.DictReader(fh))
        if rows:
            out.update(rows[-1])
    return out


def read_usage(run_dir: pathlib.Path) -> dict:
    files = sorted(run_dir.glob("**/claudecode_results_*.json"))
    if not files:
        return {}
    try:
        return json.load(open(files[-1])).get("usage_metrics", {}) or {}
    except Exception:
        return {}


def transcript_stats(run: pathlib.Path, pid: str, arm: str, model: str, k: str = "") -> dict:
    """NEAT calls, first tool, tool count and Claude Code's own cost line, from the attempt log."""
    tag = f"{pid}.{arm}.{model.split('-')[-1]}" if model else f"{pid}.{arm}"
    if k:
        tag = f"{tag}.k{k}"
    files = sorted(run.glob(f"{tag}.log")) or sorted(run.glob(f"{pid}.{arm}*.log"))
    files = [f for f in files if "limited" not in f.name]
    out = {"tools": 0, "neat_calls": 0, "first_tool": "", "first_neat_index": "", "cc_cost_usd": ""}
    if not files:
        return out
    order = []
    for line in open(files[-1], errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if ev.get("type") == "result" and ev.get("total_cost_usd") is not None:
            out["cc_cost_usd"] = f"{ev['total_cost_usd']:.4f}"
        c = (ev.get("message") or {}).get("content")
        if isinstance(c, list):
            order += [x["name"] for x in c if x.get("type") == "tool_use"]
    real = [n for n in order if n != "ToolSearch"]
    out["tools"] = len(real)
    out["neat_calls"] = sum(1 for n in real if n.startswith("mcp__neat__"))
    out["first_tool"] = real[0] if real else ""
    idx = next((i for i, n in enumerate(real) if n.startswith("mcp__neat__")), None)
    out["first_neat_index"] = "" if idx is None else idx
    return out


def main() -> int:
    run = pathlib.Path(sys.argv[1]); results_root = pathlib.Path(sys.argv[2])
    pin, pout, pcr, pcw = price("PRICE_IN"), price("PRICE_OUT"), price("PRICE_CACHE_READ"), price("PRICE_CACHE_WRITE")
    rows = []
    with open(run / "timing.tsv", newline="") as fh:
        for t in csv.DictReader(fh, delimiter="\t"):
            attempt = find_attempt(results_root, t["results_dir"], t["arm"], t["problem"])
            outcome = read_outcome(attempt) if attempt else {}
            usage = read_usage(attempt) if attempt else {}
            toks = {k: usage.get(k) for k in ("input_tokens", "output_tokens", "cached_input_tokens", "cache_creation_input_tokens", "reasoning_output_tokens")}
            cost = None
            if pin is not None and pout is not None and toks["input_tokens"] is not None:
                uncached_in = (toks["input_tokens"] or 0) - (toks["cached_input_tokens"] or 0) - (toks["cache_creation_input_tokens"] or 0)
                cost = (max(uncached_in, 0) * pin + (toks["output_tokens"] or 0) * pout
                        + (toks["cached_input_tokens"] or 0) * (pcr or 0) + (toks["cache_creation_input_tokens"] or 0) * (pcw or 0)) / 1e6
            diag = next((v for k, v in outcome.items() if "diagnosis" in k.lower() and ("result" in k.lower() or "success" in k.lower() or "pass" in k.lower())), None)
            mit = next((v for k, v in outcome.items() if "mitigation" in k.lower() and ("result" in k.lower() or "success" in k.lower() or "pass" in k.lower())), None)
            ts = transcript_stats(run, t["problem"], t["arm"], t.get("model", ""), t.get("k", ""))
            rows.append({
                "problem": t["problem"], "app": t.get("app", ""), "arm": t["arm"], "model": t.get("model", ""), "k": t.get("k", ""), "void": t.get("void", ""),
                "wall_s": t["wall_s"], "rc": t["rc"], **ts,
                "diagnosis": diag, "mitigation": mit, "ttd": outcome.get("TTD") or outcome.get("ttd"), "ttm": outcome.get("TTM") or outcome.get("ttm"),
                "run_status": outcome.get("run_status"), **{k: ("" if v is None else v) for k, v in toks.items()},
                "cost_usd": "" if cost is None else f"{cost:.4f}", "attempt_dir": str(attempt) if attempt else "-",
                "outcome_keys": ";".join(sorted(outcome.keys()))[:300],
            })
    if not rows:
        print("no attempts"); return 1
    with open(run / "summary.tsv", "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0].keys()), delimiter="\t"); w.writeheader(); w.writerows(rows)

    def truthy(v):
        return str(v).strip().lower() in ("true", "1", "yes", "pass", "passed", "success", "succeeded")
    totals = {}
    for arm in sorted({r["arm"] for r in rows}):
        rs = [r for r in rows if r["arm"] == arm]
        totals[arm] = {
            "attempts": len(rs),
            "diagnosis_pass": sum(truthy(r["diagnosis"]) for r in rs), "diagnosis_known": sum(r["diagnosis"] not in (None, "") for r in rs),
            "mitigation_pass": sum(truthy(r["mitigation"]) for r in rs), "mitigation_known": sum(r["mitigation"] not in (None, "") for r in rs),
            "wall_s": sum(int(r["wall_s"]) for r in rs),
            "input_tokens": sum(int(r["input_tokens"] or 0) for r in rs), "output_tokens": sum(int(r["output_tokens"] or 0) for r in rs),
            "cached_input_tokens": sum(int(r["cached_input_tokens"] or 0) for r in rs), "cache_creation_input_tokens": sum(int(r["cache_creation_input_tokens"] or 0) for r in rs),
            "cost_usd": (None if pin is None else round(sum(float(r["cost_usd"] or 0) for r in rs), 2)),
            "usage_missing": sum(1 for r in rs if r["input_tokens"] in ("", None)),
            "void": sum(1 for r in rs if r.get("void") == "yes"),
            "neat_calls_total": sum(int(r["neat_calls"] or 0) for r in rs),
            "attempts_with_neat_call": sum(1 for r in rs if int(r["neat_calls"] or 0) > 0),
            "attempts_neat_first": sum(1 for r in rs if str(r["first_tool"]).startswith("mcp__neat__")),
            "cc_cost_usd": round(sum(float(r["cc_cost_usd"] or 0) for r in rs), 4),
        }
    json.dump(totals, open(run / "totals.json", "w"), indent=2)
    print(json.dumps(totals, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
