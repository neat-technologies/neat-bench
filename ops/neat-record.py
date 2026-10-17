#!/usr/bin/env python3
"""Record what NEAT already knows when the agent starts: one MCP session, the whole surface.

Calls, in order, through the same MCP server and environment the NEAT arm uses:
  ask "What is failing right now and why?"   graph-wide incidents and the top culprit
  investigate(<culprit>)                     the composed incident card
  get_root_cause(<culprit>)                  the cause chain with provenance
  get_blast_radius(<culprit>)                what a fix reaches
  get_graph_diff(<healthy snapshot>)         what changed since the app was healthy
  get_recent_stale_edges                     what went silent
  get_divergences                            where code and runtime disagree
The culprit is the first `service:` id in the ask answer. Writes JSON to stdout:
{"ok": bool, "culprit": str, "calls": {tool: {"is_error": bool, "text": str}}}.
Exit 0 when `ask` answered, 3 when NEAT errored, 4 when the server could not be used.

Usage: neat-record.py [healthy-snapshot-path]   (env: NEAT_MCP_BIN, NEAT_CORE_URL, NEAT_AUTH_TOKEN)
"""
import json
import os
import re
import subprocess
import sys


class Mcp:
    def __init__(self):
        self.p = subprocess.Popen([os.environ.get("NEAT_MCP_BIN", "neat-mcp")], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "neat-bench-record", "version": "1"}})
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.p.stdin.flush()

    def rpc(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.p.stdin.flush()
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("MCP server closed")
            line = line.strip()
            if line.startswith("{"):
                obj = json.loads(line)
                if obj.get("id") == self.n:
                    return obj

    def call(self, name, args):
        try:
            r = self.rpc("tools/call", {"name": name, "arguments": args}).get("result") or {}
        except Exception as exc:
            return {"is_error": True, "text": f"call failed: {exc}"}
        text = "\n".join(c.get("text", "") for c in r.get("content", []) if c.get("type") == "text")
        return {"is_error": bool(r.get("isError")) or "Error talking to neat-core" in text, "text": text[:5000]}

    def close(self):
        try:
            self.p.kill()
        except Exception:
            pass


def main() -> int:
    snap = sys.argv[1] if len(sys.argv) > 1 else ""
    out = {"ok": False, "culprit": "", "calls": {}}
    try:
        m = Mcp()
    except Exception as exc:
        out["calls"]["server"] = {"is_error": True, "text": str(exc)}
        print(json.dumps(out)); return 4
    try:
        a = m.call("ask", {"question": "What is failing right now and why?"})
        out["calls"]["ask"] = a
        if a["is_error"]:
            print(json.dumps(out)); return 3
        out["ok"] = True
        hit = re.search(r"\bservice:[A-Za-z0-9_.\-]+", a["text"])
        culprit = hit.group(0) if hit else ""
        out["culprit"] = culprit
        if culprit:
            out["calls"]["investigate"] = m.call("investigate", {"target": culprit})
            out["calls"]["get_root_cause"] = m.call("get_root_cause", {"errorNode": culprit})
            out["calls"]["get_blast_radius"] = m.call("get_blast_radius", {"nodeId": culprit})
        # The daemon diffs only against snapshots it manages (`self` or a registered project;
        # core #693), so a file-path baseline is rejected. Record the self-diff until a
        # time-based or healthy-baseline diff exists in the product.
        out["calls"]["get_graph_diff"] = m.call("get_graph_diff", {"againstSnapshot": "self"})
        out["calls"]["get_recent_stale_edges"] = m.call("get_recent_stale_edges", {"limit": 15})
        out["calls"]["get_divergences"] = m.call("get_divergences", {"minConfidence": 0.7})
        out["calls"]["check_policies"] = m.call("check_policies", {})
        print(json.dumps(out))
        return 0
    finally:
        m.close()


if __name__ == "__main__":
    sys.exit(main())
