// NEAT wiring, hand-wired path. The committed agent.ts is a manual, box-side tool loop
// (ToolDef.run runs locally), so the Anthropic server-side MCP-connector (mcp_servers +
// mcp_toolset) can't be used: the NEAT MCP server is stdio-only (no HTTP/SSE transport),
// Anthropic's servers can't reach the box's localhost daemon, and the loop can't consume
// server-side mcp_tool_use blocks. Instead we spawn NEAT's OWN MCP server as a local stdio
// subprocess pointed at this trial's daemon and proxy each graph tool through it as a
// ToolDef. This reuses NEAT's real tool implementations (authentic schemas + answers)
// rather than re-querying the graph by hand. Security tools (get_reachable_cves,
// is_reachable, scan_diff) are not in this MCP build and come from the `neat security`
// CLI (security-cli.ts).
import { Client } from '@modelcontextprotocol/sdk/client/index.js'
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js'
import type { ToolDef } from './agent.js'
import type { TrialContext } from './context.js'

// The graph-query tools we expose to the NEAT arms, matching the README's NEAT suite.
// We deliberately DO NOT expose the neat_* connect/extension/instrumentation mutators:
// the remediation task is read-only investigation and must not mutate daemon state.
const EXPOSED = new Set([
  'investigate',
  'get_incident_card',
  'get_root_cause',
  'get_blast_radius',
  'get_dependencies',
  'get_observed_dependencies',
  'get_divergences',
  'get_graph_diff',
  'check_policies',
  'get_incident_history',
  'get_recent_stale_edges',
  'ask',
  'semantic_search',
  'expand',
  'relate',
])

export interface NeatMcp {
  toolDefs: ToolDef[]
  close: () => Promise<void>
  client: Client
  exposed: string[]
}

function textOf(result: any): { content: string; isError?: boolean } {
  const blocks: any[] = result?.content ?? []
  const text = blocks
    .map((b) => (b?.type === 'text' ? b.text : typeof b?.text === 'string' ? b.text : JSON.stringify(b)))
    .join('\n')
  return { content: text || JSON.stringify(result), isError: result?.isError === true }
}

// Spawn the NEAT MCP server bound to this trial's daemon and wrap every exposed tool.
export async function connectNeatMcp(ctx: TrialContext): Promise<NeatMcp> {
  if (!ctx.neatBase) throw new Error('connectNeatMcp: ctx.neatBase is required for NEAT arms')

  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [ctx.mcpEntry],
    env: {
      ...process.env,
      NEAT_CORE_URL: ctx.neatBase,
      NEAT_DEFAULT_PROJECT: 'default',
      NEAT_PROJECT: 'default',
      NEAT_SKIP_ENDPOINT_CHECK: '1',
    },
    stderr: 'ignore',
  })
  const client = new Client({ name: `neat-bench:${ctx.app}:${ctx.arm}`, version: '0.0.0' }, { capabilities: {} })
  await client.connect(transport)

  const listed = await client.listTools()
  const exposed = listed.tools.filter((t) => EXPOSED.has(t.name))

  const toolDefs: ToolDef[] = exposed.map((t) => ({
    name: t.name,
    description: t.description ?? `NEAT graph tool ${t.name}`,
    // MCP inputSchema is JSON Schema with type:"object" — directly usable as an Anthropic tool schema.
    input_schema: (t.inputSchema as any) ?? { type: 'object', properties: {} },
    run: async (input: any) => {
      try {
        const res = await client.callTool({ name: t.name, arguments: input ?? {} })
        return textOf(res)
      } catch (e) {
        return { content: `NEAT MCP tool ${t.name} failed: ${String(e)}`, isError: true }
      }
    },
  }))

  return {
    toolDefs,
    client,
    exposed: exposed.map((t) => t.name),
    close: async () => {
      try {
        await client.close()
      } catch {
        /* best effort */
      }
    },
  }
}
