#!/usr/bin/env python3
"""Patch a SREGym checkout so its Claude Code agent can run as the bench's two arms.

What it changes, all in the checkout (SREGym applies them from disk):

  agents.yaml            adds `claudecode-base` and `claudecode-neat`, both without container
                         isolation so the box's own Claude login and NEAT's MCP server on the host
                         are reachable; `claudecode-neat` sets NEAT_MCP=1.
  clients/claudecode/claudecode_agent.py
                         - a fresh `--append-system-prompt bench-attempt:<uuid>` per attempt, so
                           prompt caching never carries between repeats of a problem while the
                           cache still works inside one session;
                         - for the neat arm, an MCP config for `neat-mcp` and `mcp__neat__*` in the
                           allowed tools, and an instruction prefix telling the agent to lead with it;
                         - the host's Claude credentials seeded into the per-attempt session dir
                           (and copied back after, so refreshed tokens survive), instead of
                           requiring an API key or a static OAuth token in the environment.

Idempotent: each insertion is checked by a marker. Refuses if an anchor moved upstream.

Usage: python3 ops/sregym-bench-patch.py ~/SREGym
"""
import pathlib
import sys

MARK = "neat-bench:"

AGENTS = """  - name: claudecode-base
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

NEAT_INSTRUCTION = '''
NEAT_DEFAULT_INSTRUCTION = (
    "You have NEAT available as MCP tools (names start with mcp__neat__). NEAT keeps a live "
    "semantic graph of this system: code, infrastructure and runtime behaviour from OpenTelemetry, "
    "fused, with provenance on every edge (EXTRACTED from source, OBSERVED at runtime, INFERRED, "
    "STALE). It is the investigation layer for this task: before running any kubectl or shell "
    "command, call NEAT first. Required order: (1) call the NEAT tools that list incidents, "
    "root causes and divergences (declared-versus-observed) for the whole system; (2) for the "
    "suspect service, call the observed-dependency, blast-radius and stale-edge tools; (3) only "
    "then use kubectl, logs and the observability endpoints to confirm and to act. Cite which "
    "NEAT findings led you to the diagnosis in your submission. A run that never queries NEAT "
    "is a failed run for this arm."
)
'''


def insert_once(text: str, anchor: str, block: str, marker: str, after: bool = True) -> str:
    if marker in text:
        return text
    if anchor not in text:
        print(f"anchor not found: {anchor!r}", file=sys.stderr)
        sys.exit(2)
    return text.replace(anchor, (anchor + block) if after else (block + anchor), 1)


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")

    # agents.yaml
    p = root / "agents.yaml"
    t = p.read_text()
    if "claudecode-neat" not in t:
        t = t.rstrip("\n") + "\n" + AGENTS
        p.write_text(t)
        print("agents.yaml: added claudecode-base, claudecode-neat")
    else:
        print("agents.yaml: present")

    # claudecode_agent.py
    p = root / "clients/claudecode/claudecode_agent.py"
    t = p.read_text()

    t = insert_once(t, "import logging\n", "import json  # neat-bench: mcp config\n", "neat-bench: mcp config", after=False)
    t = insert_once(t, "logger = logging.getLogger(\"all.claudecode.agent\")\n", NEAT_INSTRUCTION, "NEAT_DEFAULT_INSTRUCTION")

    # instruction prefix + credential seeding, at the top of run()
    t = insert_once(
        t,
        "        model = self.model_name.split(\"/\")[-1]\n",
        "        # neat-bench: NEAT arm instruction\n"
        "        if os.environ.get(\"NEAT_MCP\") == \"1\":\n"
        "            instruction = os.environ.get(\"NEAT_INSTRUCTION\", NEAT_DEFAULT_INSTRUCTION) + \"\\n\\n\" + instruction\n",
        "neat-bench: NEAT arm instruction",
        after=False,
    )
    t = insert_once(
        t,
        "        self._setup_sessions_structure()\n",
        "        # neat-bench: seed the host's Claude login into this attempt's session dir\n"
        "        host_creds = Path.home() / \".claude\" / \".credentials.json\"\n"
        "        sess_creds = self.sessions_dir / \".credentials.json\"\n"
        "        if host_creds.exists() and not os.environ.get(\"ANTHROPIC_API_KEY\"):\n"
        "            shutil.copy2(host_creds, sess_creds)\n",
        "neat-bench: seed the host",
    )
    # let the seeded file count as authentication, and keep the agent on it (self-refreshing)
    old = "        if not api_key and not oauth_token:\n"
    if "neat-bench: seeded creds count" not in t:
        if old not in t:
            print("anchor not found: auth check", file=sys.stderr)
            return 2
        t = t.replace(old, "        if sess_creds.exists():  # neat-bench: seeded creds count as auth; agent uses the file\n            oauth_token = \"\"\n        if not api_key and not oauth_token and not sess_creds.exists():\n", 1)
    # per-attempt nonce + NEAT MCP wiring at the allowedTools line
    old = "        command.extend([\"--allowedTools\", *self.allowed_tools()])\n"
    new = (
        "        # neat-bench: per-attempt cache nonce + NEAT MCP for the neat arm\n"
        "        import uuid as _uuid\n"
        "        tools = self.allowed_tools()\n"
        "        if os.environ.get(\"NEAT_MCP\") == \"1\":\n"
        "            mcp_cfg = self.logs_dir / \"neat-mcp.json\"\n"
        "            mcp_cfg.write_text(json.dumps({\"mcpServers\": {\"neat\": {\"command\": os.environ.get(\"NEAT_MCP_BIN\", \"neat-mcp\"), \"args\": [], \"env\": {\"NEAT_API_KEY\": os.environ.get(\"NEAT_AUTH_TOKEN\", \"\")}}}}))\n"
        "            command.extend([\"--mcp-config\", str(mcp_cfg), \"--strict-mcp-config\"])\n"
        "            tools = tools + [\"mcp__neat__*\"]\n"
        "        command.extend([\"--append-system-prompt\", f\"bench-attempt:{_uuid.uuid4()}\"])\n"
        "        command.extend([\"--allowedTools\", *tools])\n"
    )
    if "neat-bench: per-attempt cache nonce" not in t:
        if old not in t:
            print("anchor not found: allowedTools", file=sys.stderr)
            return 2
        t = t.replace(old, new, 1)
    # copy refreshed credentials back after the run
    t = insert_once(
        t,
        "                process.wait()\n",
        "                # neat-bench: keep refreshed tokens for the next attempt\n"
        "                if sess_creds.exists() and host_creds.exists() and sess_creds.stat().st_mtime > host_creds.stat().st_mtime:\n"
        "                    shutil.copy2(sess_creds, host_creds)\n",
        "neat-bench: keep refreshed",
    )
    p.write_text(t)
    print("claudecode_agent.py: patched")
    return 0


if __name__ == "__main__":
    sys.exit(main())
