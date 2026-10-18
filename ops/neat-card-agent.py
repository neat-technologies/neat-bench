#!/usr/bin/env python3
"""neat-card: an SREGym "agent" with no model in it. It submits NEAT's own answer as the diagnosis.

When the conductor opens the diagnosis stage, it asks NEAT what is failing (neat-record.py, the
same MCP session and surface the NEAT arm gets), and submits NEAT's words verbatim: the graph-wide
lead and the incident card for the culprit NEAT names. SREGym's own LLM judge then scores it
against the problem's ground truth, exactly as it scores any agent. So the score is NEAT's card
accuracy, graded by a judge we don't control, with no agent reasoning on top.

It never touches the cluster and never submits a mitigation (run it with --stages diagnosis).

Env: API_HOSTNAME/API_PORT (conductor), AGENT_LOGS_DIR, AGENT_CWD_NEAT, NEAT_SNAPSHOT,
NEAT_AUTH_TOKEN, NEAT_CORE_URL, NEAT_RECORD.
"""
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

SERVER = f"http://{os.getenv('API_HOSTNAME', 'localhost')}:{os.getenv('API_PORT', '8000')}"
LOGS = pathlib.Path(os.getenv("AGENT_LOGS_DIR", "./logs/neat-card"))
MAX_CHARS = 6000


def get(path):
    with urllib.request.urlopen(SERVER + path, timeout=10) as r:
        return json.loads(r.read() or b"{}")


def post(path, body):
    req = urllib.request.Request(SERVER + path, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=310) as r:
        return r.status, r.read().decode(errors="replace")[:500]


def wait_stage(want, deadline_s=1800):
    end = time.time() + deadline_s
    while time.time() < end:
        try:
            st = get("/status").get("stage")
            if st in want or st == "done":
                return st
        except Exception:
            pass
        time.sleep(5)
    return None


def compose(rec):
    calls = rec.get("calls", {})
    parts = []
    lead = (calls.get("ask") or {}).get("text", "").strip()
    if lead:
        parts.append(lead)
    card = (calls.get("investigate") or {}).get("text", "").strip()
    if card:
        parts.append(card)
    if not parts:
        return "NEAT returned no answer."
    return "\n\n".join(parts)[:MAX_CHARS]


def main():
    LOGS.mkdir(parents=True, exist_ok=True)
    stage = wait_stage({"diagnosis"})
    print(f"neat-card: conductor stage {stage}", flush=True)
    if stage != "diagnosis":
        return 1
    env = dict(os.environ, NEAT_CORE_URL=os.environ.get("NEAT_CORE_URL", "http://localhost:8098"))
    script = os.environ.get("NEAT_RECORD", str(pathlib.Path.home() / "neat-bench-ops" / "neat-record.py"))
    t0 = time.time()
    r = subprocess.run(["python3", script, os.environ.get("NEAT_SNAPSHOT", "")], capture_output=True,
                       text=True, env=env, cwd=os.environ.get("AGENT_CWD_NEAT") or None, timeout=420)
    took = round(time.time() - t0, 1)
    (LOGS / "neat-incident-record.json").write_text(json.dumps({"rc": r.returncode, "out": r.stdout[-60000:], "arm": "neat-card", "cwd": os.environ.get("AGENT_CWD_NEAT"), "record_s": took}))
    try:
        rec = json.loads(r.stdout)
    except Exception:
        rec = {}
    if r.returncode != 0 or not rec.get("ok"):
        (LOGS / "neat-preflight-void.json").write_text(json.dumps({"void_reason": "NEAT unreachable or erroring through MCP", "rc": r.returncode, "out": r.stdout[-2000:]}))
        print("neat-card: NEAT preflight failed; attempt VOID", flush=True)
        return 2
    text = compose(rec)
    (LOGS / "neat-card-submission.txt").write_text(text)
    code, body = post("/submit", {"stage": "diagnosis", "solution": text})
    print(f"neat-card: submitted {len(text)} chars in {took}s -> {code} {body[:200]}", flush=True)
    # The judge runs after submission; wait for the conductor to move on so the run closes cleanly.
    wait_stage({"mitigation"}, deadline_s=900)
    return 0


if __name__ == "__main__":
    sys.exit(main())
