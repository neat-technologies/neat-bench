#!/usr/bin/env python3
"""Call one NEAT MCP tool over stdio, exactly as Claude Code would, and print the result.

Used by the bench as the per-attempt preflight (is NEAT reachable through the same server and
environment the arm will use?) and as the incident record (what does NEAT say about the app
right now). Exit 0 with the tool result on stdout; exit 3 if the server starts but the tool
reports an error; exit 4 if the server cannot be started or does not answer.

Usage:
  neat-mcp-call.py list
  neat-mcp-call.py call <tool> '<json-args>'
Environment: NEAT_MCP_BIN (default neat-mcp), NEAT_CORE_URL, NEAT_API_KEY passed through.
"""
import json
import os
import subprocess
import sys


def rpc(proc, msg):
    proc.stdin.write(json.dumps(msg) + "\n")
    proc.stdin.flush()
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("server closed")
        line = line.strip()
        if not line.startswith("{"):
            continue
        obj = json.loads(line)
        if obj.get("id") == msg.get("id"):
            return obj


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "list"
    env = dict(os.environ)
    try:
        proc = subprocess.Popen(
            [env.get("NEAT_MCP_BIN", "neat-mcp")], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, text=True, env=env, bufsize=1,
        )
    except OSError as exc:
        print(json.dumps({"error": f"cannot start MCP server: {exc}"}))
        return 4
    try:
        init = rpc(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "neat-bench-preflight", "version": "1"}}})
        proc.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); proc.stdin.flush()
        instructions = (init.get("result") or {}).get("instructions", "")
        if mode == "list":
            r = rpc(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
            tools = [t["name"] for t in (r.get("result") or {}).get("tools", [])]
            print(json.dumps({"tools": tools, "instructions_head": instructions[:400]}))
            return 0
        name = sys.argv[2]
        args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
        r = rpc(proc, {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": name, "arguments": args}})
        res = r.get("result") or {}
        text = "\n".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        out = {"tool": name, "is_error": bool(res.get("isError")) or "Error talking to neat-core" in text, "text": text[:4000]}
        print(json.dumps(out))
        return 3 if out["is_error"] else 0
    except Exception as exc:
        print(json.dumps({"error": str(exc)}))
        return 4
    finally:
        try:
            proc.kill()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
