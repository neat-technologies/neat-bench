#!/usr/bin/env node
// parse-claude-stream — normalize `claude -p --output-format stream-json` output
// into the objective metrics the arm needs. Built to the verified schema
// (system/init, stream_event{content_block_start|delta|stop, message_start},
// final result{subtype,result,usage,total_cost_usd}).
//
//   node harness/arms/parse-claude-stream.mjs <claude-stream.jsonl> [--neat-tools a,b,c]
//     -> prints a metrics JSON object to stdout.
//
// MCP tool names appear PLAIN in the stream (e.g. get_divergences, not
// mcp__neat__...), so we tally "neat" calls by membership in the NEAT tool set.

import { readFileSync } from 'node:fs'

// Known NEAT MCP tools (plain names). Extendable via --neat-tools.
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
const blocks = new Map()      // content-block index -> {name,id,input}
const toolCalls = []
let model = null, mcpLoaded = false, subtype = null, answer = ''
let inTok = 0, outTok = 0, cost = 0, turns = 0

const finalizeBlock = (idx) => {
  const b = blocks.get(idx); if (!b) return
  let input = {}
  try { input = b.input ? JSON.parse(b.input) : {} } catch {}
  toolCalls.push({ name: b.name, input })
  blocks.delete(idx)
}

for (const line of lines) {
  let o; try { o = JSON.parse(line) } catch { continue }
  if (o.type === 'system' && o.subtype === 'init') {
    model = o.model ?? model
    mcpLoaded = Array.isArray(o.mcp_servers) && o.mcp_servers.some((s) => s.status === 'ready')
  } else if (o.type === 'stream_event') {
    const ev = o.event ?? {}
    if (ev.type === 'message_start') turns++
    else if (ev.type === 'content_block_start' && ev.content_block?.type === 'tool_use')
      blocks.set(ev.index, { name: ev.content_block.name, id: ev.content_block.id, input: '' })
    else if (ev.type === 'content_block_delta' && ev.delta?.type === 'input_json_delta') {
      const b = blocks.get(ev.index); if (b) b.input += ev.delta.partial_json ?? ''
    } else if (ev.type === 'content_block_stop') finalizeBlock(ev.index)
  } else if (o.type === 'assistant' && o.message?.content) {
    // fallback for bundled (non-partial) mode
    turns++
    for (const c of o.message.content) if (c.type === 'tool_use') toolCalls.push({ name: c.name, input: c.input ?? {} })
  } else if (o.type === 'result') {
    subtype = o.subtype ?? subtype
    answer = typeof o.result === 'string' ? o.result : answer
    inTok = o.usage?.input_tokens ?? inTok
    outTok = o.usage?.output_tokens ?? outTok
    cost = o.total_cost_usd ?? cost
  }
}
for (const idx of [...blocks.keys()]) finalizeBlock(idx)

const neat = toolCalls.filter((t) => NEAT_TOOLS.has(t.name))
const other = toolCalls.filter((t) => !NEAT_TOOLS.has(t.name))
const filesOpened = [...new Set(
  toolCalls.filter((t) => FILE_TOOLS.has(t.name) && t.input?.file_path).map((t) => t.input.file_path),
)]

console.log(JSON.stringify({
  model, mcp_loaded: mcpLoaded, subtype, success: subtype === 'success',
  input_tokens: inTok, output_tokens: outTok, total_cost_usd: cost,
  num_turns: turns || undefined,
  tool_calls_total: toolCalls.length, neat_calls: neat.length, other_calls: other.length,
  files_opened: filesOpened,
  tool_names: toolCalls.map((t) => t.name),
  answer,
}, null, 2))
