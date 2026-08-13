#!/usr/bin/env node
// parse-claude-stream — normalize `claude -p --output-format stream-json` output
// into objective metrics. Validated against REAL Claude Code 2.1.231 output, which
// differs from the docs summary in three ways this handles:
//   1. tool_use appears in BOTH `assistant` message events AND `stream_event`
//      content blocks — so we DEDUPE by tool_use id (else every call double-counts).
//   2. the result event carries `num_turns` directly (don't count message events).
//   3. `usage.input_tokens` is only the final uncached turn; the real input is
//      input + cache_read + cache_creation — we report the full breakdown.
//
//   node harness/arms/parse-claude-stream.mjs <claude-stream.jsonl> [--neat-tools a,b]
//
// MCP tool names appear PLAIN (get_divergences, not mcp__neat__...), tallied by
// membership in the NEAT tool set.

import { readFileSync } from 'node:fs'

const NEAT_TOOLS = new Set([
  'get_graph', 'get_divergences', 'get_root_cause', 'get_blast_radius',
  'get_observed_dependencies', 'get_dependencies', 'get_incident_history',
  'get_graph_diff', 'get_recent_stale_edges', 'semantic_search', 'check_policies',
  'neat_list_uninstrumented', 'neat_describe_project_instrumentation',
  'neat_lookup_instrumentation', 'neat_dry_run_extension', 'neat_apply_extension',
  'neat_rollback_extension',
])
const FILE_TOOLS = new Set(['Read', 'Edit', 'Write', 'NotebookEdit'])

const args = process.argv.slice(2)
const streamPath = args.find((a) => !a.startsWith('--'))
const nt = args.indexOf('--neat-tools')
if (nt !== -1) for (const t of (args[nt + 1] ?? '').split(',')) if (t) NEAT_TOOLS.add(t)
if (!streamPath) { console.error('usage: node parse-claude-stream.mjs <claude-stream.jsonl> [--neat-tools a,b]'); process.exit(1) }

const lines = readFileSync(streamPath, 'utf8').split('\n').filter((l) => l.trim())
const openBlocks = new Map()   // stream content-block index -> {id,name,input}
const toolById = new Map()     // tool_use id -> {name, input}  (dedup across both event shapes)
let model = null, mcpLoaded = false, subtype = null, isError = false, answer = ''
let usage = {}, cost = 0, numTurns

const mergeTool = (id, name, input) => {
  if (!id) { toolById.set(`anon-${toolById.size}`, { name, input: input ?? {} }); return }
  const cur = toolById.get(id)
  if (!cur) toolById.set(id, { name, input: input ?? {} })
  else if ((!cur.input || Object.keys(cur.input).length === 0) && input) cur.input = input
}

for (const line of lines) {
  let o; try { o = JSON.parse(line) } catch { continue }
  if (o.type === 'system' && o.subtype === 'init') {
    model = o.model ?? model
    mcpLoaded = Array.isArray(o.mcp_servers) && o.mcp_servers.some((s) => s.status === 'ready')
  } else if (o.type === 'stream_event') {
    const ev = o.event ?? {}
    if (ev.type === 'content_block_start' && ev.content_block?.type === 'tool_use')
      openBlocks.set(ev.index, { id: ev.content_block.id, name: ev.content_block.name, input: '' })
    else if (ev.type === 'content_block_delta' && ev.delta?.type === 'input_json_delta') {
      const b = openBlocks.get(ev.index); if (b) b.input += ev.delta.partial_json ?? ''
    } else if (ev.type === 'content_block_stop') {
      const b = openBlocks.get(ev.index)
      if (b) { let inp = {}; try { inp = b.input ? JSON.parse(b.input) : {} } catch {} ; mergeTool(b.id, b.name, inp); openBlocks.delete(ev.index) }
    }
  } else if (o.type === 'assistant' && o.message?.content) {
    for (const c of o.message.content) if (c.type === 'tool_use') mergeTool(c.id, c.name, c.input ?? {})
  } else if (o.type === 'result') {
    subtype = o.subtype ?? subtype
    isError = Boolean(o.is_error)
    answer = typeof o.result === 'string' ? o.result : answer
    usage = o.usage ?? usage
    cost = o.total_cost_usd ?? cost
    numTurns = o.num_turns ?? numTurns
  }
}

const toolCalls = [...toolById.values()]
const neat = toolCalls.filter((t) => NEAT_TOOLS.has(t.name))
const other = toolCalls.filter((t) => !NEAT_TOOLS.has(t.name))
const filesOpened = [...new Set(
  toolCalls.filter((t) => FILE_TOOLS.has(t.name) && t.input?.file_path).map((t) => t.input.file_path),
)]
const inp = usage.input_tokens ?? 0
const cacheR = usage.cache_read_input_tokens ?? 0
const cacheC = usage.cache_creation_input_tokens ?? 0

console.log(JSON.stringify({
  model, mcp_loaded: mcpLoaded, subtype, success: subtype === 'success' && !isError,
  tokens: { input: inp, output: usage.output_tokens ?? 0, cache_read: cacheR, cache_creation: cacheC, input_total: inp + cacheR + cacheC },
  total_cost_usd: cost, num_turns: numTurns,
  tool_calls_total: toolCalls.length, neat_calls: neat.length, other_calls: other.length,
  files_opened: filesOpened,
  tool_names: toolCalls.map((t) => t.name),
  answer,
}, null, 2))
