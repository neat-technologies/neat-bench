#!/usr/bin/env node
// How much NEAT put into the agent's context during a run, read from the
// `claude -p --output-format stream-json` stream: the bytes of every NEAT tool
// result and of every hook's output. The bytes NEAT injected at the start (the
// appended system prompt and settings) come from arm-config.mjs; this covers
// what arrived while the agent worked. The frozen harness parser records
// neither, which is why this exists.
//
//   node arms/neat-bytes.mjs <claude-stream.jsonl>

import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'

const isNeatTool = (name) => typeof name === 'string' && name.startsWith('mcp__neat__')

const contentBytes = (content) => {
  if (typeof content === 'string') return Buffer.byteLength(content, 'utf8')
  if (Array.isArray(content)) {
    return content.reduce((n, part) => n + (typeof part?.text === 'string' ? Buffer.byteLength(part.text, 'utf8') : 0), 0)
  }
  return 0
}

export function neatBytes(lines) {
  const nameById = new Map()
  const out = { neat_tool_results: 0, neat_tool_result_bytes: 0, hook_responses: 0, hook_output_bytes: 0 }
  const seenResults = new Set()
  for (const line of lines) {
    let ev
    try {
      ev = JSON.parse(line)
    } catch {
      continue
    }
    // tool_use appears in assistant messages and in stream_event content blocks.
    const block = ev.type === 'stream_event' ? ev.event?.content_block : null
    if (block?.type === 'tool_use') nameById.set(block.id, block.name)
    if (ev.type === 'assistant') for (const c of ev.message?.content ?? []) if (c.type === 'tool_use') nameById.set(c.id, c.name)
    if (ev.type === 'user') {
      for (const c of ev.message?.content ?? []) {
        if (c.type !== 'tool_result' || seenResults.has(c.tool_use_id)) continue
        seenResults.add(c.tool_use_id)
        if (isNeatTool(nameById.get(c.tool_use_id))) {
          out.neat_tool_results += 1
          out.neat_tool_result_bytes += contentBytes(c.content)
        }
      }
    }
    if (ev.type === 'system' && ev.subtype === 'hook_response') {
      out.hook_responses += 1
      out.hook_output_bytes += Buffer.byteLength(String(ev.output ?? ev.stdout ?? ''), 'utf8')
    }
  }
  return out
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const path = process.argv[2]
  if (!path) {
    console.error('usage: node arms/neat-bytes.mjs <claude-stream.jsonl>')
    process.exit(2)
  }
  const lines = readFileSync(path, 'utf8').split('\n').filter((l) => l.trim())
  process.stdout.write(JSON.stringify(neatBytes(lines)) + '\n')
}
