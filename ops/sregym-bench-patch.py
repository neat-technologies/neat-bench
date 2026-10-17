#!/usr/bin/env python3
"""Patch a SREGym checkout so its Claude Code agent runs as the bench's two arms.

Apply to a CLEAN copy of the two files (`git checkout agents.yaml clients/claudecode/claudecode_agent.py`
first); every insertion is checked by a marker, and it refuses if an anchor moved upstream.

  agents.yaml   `claudecode-base` (NEAT_MCP=0) and `claudecode-neat` (NEAT_MCP=1), both without
                container isolation so the box's Claude login and the host's NEAT daemon work.
  claudecode_agent.py
    - the agent runs in its arm's tree: AGENT_CWD_NEAT (the app repo after `npx neat.is`-style
      install: `neat init` + `neat claude install`) or AGENT_CWD_BASE (pristine copy, no NEAT);
      the task instruction is IDENTICAL for both arms; nothing in the prompt mentions NEAT;
    - neat arm: NEAT's MCP server with the daemon URL and token, and the FULL mcp__neat__* surface
      allowed; the agent finds NEAT through the product's own surfaces (the ## neat CLAUDE.md
      directive, the server instructions, the tool descriptions);
    - before the agent starts (both arms): an incident record, `ask` "what is failing right now
      and why?" through the same MCP server, saved as neat-incident-record.json; for the neat arm
      an unreachable or erroring NEAT makes the attempt VOID (neat-preflight-void.json, rc 2);
    - a fresh `--append-system-prompt bench-attempt:<uuid>` per attempt, so prompt caching never
      carries between repeats while it still works inside a session;
    - the host's Claude credentials seeded into the per-attempt session dir and copied back.

Usage: python3 ops/sregym-bench-patch.py ~/SREGym
"""
import pathlib
import sys

AGENTS = """  - name: claudecode-vanilla
    kickoff_command: python -m clients.claudecode.driver
    kickoff_workdir: .
    kickoff_env:
      NEAT_MCP: "0"
      BENCH_ARM: vanilla
    install_script: null
    agent_version: null
    container_isolation: false
  - name: claudecode-base
    kickoff_command: python -m clients.claudecode.driver
    kickoff_workdir: .
    kickoff_env:
      NEAT_MCP: "0"
    install_script: null
    agent_version: null
    container_isolation: false
  - name: claudecode-neat
    kickoff_command: python -m clients.claudecode.driver
    kickoff_workdir: .
    kickoff_env:
      NEAT_MCP: "1"
    install_script: null
    agent_version: null
    container_isolation: false
"""

PRE = '''        # neat-bench: arm tree, incident record, preflight
        arm_neat = os.environ.get("NEAT_MCP") == "1"
        arm_cwd = None if os.environ.get("BENCH_ARM") == "vanilla" else (os.environ.get("AGENT_CWD_NEAT" if arm_neat else "AGENT_CWD_BASE") or None)
        neat_env = dict(os.environ, NEAT_CORE_URL=os.environ.get("NEAT_CORE_URL", "http://localhost:8098"),
                        NEAT_AUTH_TOKEN=os.environ.get("NEAT_AUTH_TOKEN", ""))
        rec_script = os.environ.get("NEAT_RECORD", str(Path.home() / "neat-bench-ops" / "neat-record.py"))
        rec = subprocess.run(["python3", rec_script, os.environ.get("NEAT_SNAPSHOT", "")],
                             capture_output=True, text=True, env=neat_env, cwd=arm_cwd, timeout=420)
        (self.logs_dir / "neat-incident-record.json").write_text(json.dumps({"rc": rec.returncode, "out": rec.stdout[-60000:], "arm": "neat" if arm_neat else os.environ.get("BENCH_ARM", "base"), "cwd": arm_cwd}))
        if arm_neat and rec.returncode != 0:
            (self.logs_dir / "neat-preflight-void.json").write_text(json.dumps({"void_reason": "NEAT unreachable or erroring through MCP at agent start", "rc": rec.returncode, "out": rec.stdout[-2000:]}))
            logger.error("neat-bench: NEAT preflight failed; attempt VOID")
            return 2
'''


def must(t: str, anchor: str, what: str) -> None:
    if anchor not in t:
        print(f"anchor not found: {what}", file=sys.stderr)
        sys.exit(2)


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")

    p = root / "agents.yaml"
    t = p.read_text()
    if "claudecode-neat" not in t:
        p.write_text(t.rstrip("\n") + "\n" + AGENTS)
    print("agents.yaml: ok")

    p = root / "clients/claudecode/claudecode_agent.py"
    t = p.read_text()
    if "neat-bench:" in t:
        print("claudecode_agent.py: already patched (restore it with git checkout first)")
        return 0

    a = "import logging\n"; must(t, a, "imports")
    t = t.replace(a, "import json  # neat-bench\nimport logging\n", 1)

    a = '        model = self.model_name.split("/")[-1]\n'; must(t, a, "run() start")
    t = t.replace(a, PRE + a, 1)

    a = "        self._setup_sessions_structure()\n"; must(t, a, "sessions setup")
    t = t.replace(a, a +
        "        # neat-bench: seed the host's Claude login into this attempt's session dir\n"
        "        host_creds = Path.home() / \".claude\" / \".credentials.json\"\n"
        "        sess_creds = self.sessions_dir / \".credentials.json\"\n"
        "        if host_creds.exists() and not os.environ.get(\"ANTHROPIC_API_KEY\"):\n"
        "            shutil.copy2(host_creds, sess_creds)\n", 1)

    a = "        if not api_key and not oauth_token:\n"; must(t, a, "auth check")
    t = t.replace(a, "        if sess_creds.exists():  # neat-bench: the seeded login is the auth\n            oauth_token = \"\"\n"
                     "        if not api_key and not oauth_token and not sess_creds.exists():\n", 1)

    a = '        command.extend(["--allowedTools", *self.allowed_tools()])\n'; must(t, a, "allowedTools")
    t = t.replace(a,
        "        # neat-bench: cache nonce per attempt; NEAT MCP with the full surface for the neat arm\n"
        "        import uuid as _uuid\n"
        "        tools = self.allowed_tools()\n"
        "        if arm_neat:\n"
        "            mcp_cfg = self.logs_dir / \"neat-mcp.json\"\n"
        "            mcp_cfg.write_text(json.dumps({\"mcpServers\": {\"neat\": {\"type\": \"stdio\", \"command\": os.environ.get(\"NEAT_MCP_BIN\", \"neat-mcp\"), \"args\": [],\n"
        "                \"env\": {\"NEAT_CORE_URL\": neat_env[\"NEAT_CORE_URL\"], \"NEAT_AUTH_TOKEN\": neat_env[\"NEAT_AUTH_TOKEN\"]}}}}))\n"
        "            command.extend([\"--mcp-config\", str(mcp_cfg), \"--strict-mcp-config\"])\n"
        "            tools = tools + [\"mcp__neat__*\"]\n"
        "        command.extend([\"--append-system-prompt\", f\"bench-attempt:{_uuid.uuid4()}\"])\n"
        "        command.extend([\"--allowedTools\", *tools])\n"
        "        # neat-bench: hide every answer key from the agent process (bubblewrap): SREGym's\n"
        "        # problems/oracles/injectors, other attempts' results and judge logs, the bench's own\n"
        "        # logs and scripts, snapshots, captures, the original sources, and the other arm's tree.\n"
        "        home = Path.home()\n"
        "        hide = [home / 'SREGym' / d for d in ('sregym', 'clients', 'llm_backend', 'docs', 'logs', 'results', 'tests', 'scripts')]\n"
        "        hide += [home / d for d in ('sregym-bench', 'neat-bench-ops', 'neat-snapshots', 'sregym-captures', 'sregym-src', 'praxis', 'ITBench', 'benchops-baseline', 'otel-demo-2.2.0', 'otel-pristine')]\n"
        "        hide += [home / ('base-arm' if arm_neat else 'neat-arm')]\n"
        "        if not arm_neat:\n"
        "            hide += [home / '.neat']\n"
        "        if shutil.which('bwrap') and os.environ.get('NEAT_BENCH_NO_MASK') != '1':\n"
        "            wrap = ['bwrap', '--dev-bind', '/', '/']\n"
        "            for h in hide:\n"
        "                if h.exists():\n"
        "                    wrap += ['--tmpfs', str(h)]\n"
        "            for keep in (self.logs_dir, self.sessions_dir):\n"
        "                wrap += ['--bind', str(keep), str(keep)]\n"
        "            command = wrap + command\n"
        "            logger.info('neat-bench: agent masked from %d paths', len(hide))\n", 1)

    a = "                    stdin=subprocess.DEVNULL,\n"; must(t, a, "Popen stdin")
    t = t.replace(a, a + "                    cwd=arm_cwd,  # neat-bench: the arm's tree\n", 1)

    a = "                process.wait()\n"; must(t, a, "process.wait")
    t = t.replace(a, a +
        "                # neat-bench: keep refreshed tokens for the next attempt\n"
        "                if sess_creds.exists() and host_creds.exists() and sess_creds.stat().st_mtime > host_creds.stat().st_mtime:\n"
        "                    shutil.copy2(sess_creds, host_creds)\n", 1)

    p.write_text(t)
    print("claudecode_agent.py: patched")

    # conductor.py: SREGym swaps each app namespace's `jaeger` Service to an ExternalName pointing
    # at its collector only AFTER the app is deployed. Clients that resolve the agent address once
    # at start (DeathStarBench Go and C++ services) keep sending spans to the old ClusterIP, so the
    # collector, the agents' trace tools and NEAT never see them. Restart the application
    # deployments right after the swap, before the baseline window, identically for every arm.
    p = root / "sregym/conductor/conductor.py"
    t = p.read_text()
    if "neat-bench: re-resolve jaeger" not in t:
        a = ("        if not is_train_ticket:\n"
             "            for ns in app_namespaces:\n"
             "                self.jaeger.create_external_name_service(ns)\n")
        must(t, a, "jaeger swap after deploy")
        t = t.replace(a, a +
            "            # neat-bench: re-resolve jaeger after the swap (see ops/sregym-bench-patch.py)\n"
            "            for ns in app_namespaces:\n"
            "                self.kubectl.exec_command(\n"
            "                    f\"for d in $(kubectl -n {ns} get deploy -o name | grep -vE 'mongodb|memcached|redis|consul|jaeger|postgres|kafka|valkey'); \"\n"
            "                    f\"do kubectl -n {ns} rollout restart $d; done; \"\n"
            "                    f\"for d in $(kubectl -n {ns} get deploy -o name); do kubectl -n {ns} rollout status $d --timeout=180s; done\"\n"
            "                )\n"
            "            self.logger.info('[DEPLOY] neat-bench: restarted app deployments so tracing clients re-resolve the collector')\n", 1)
        p.write_text(t)
        print("conductor.py: patched")
    else:
        print("conductor.py: already patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
