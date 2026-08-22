#!/usr/bin/env node
// NEAT search-GATE — a Claude Code PreToolUse hook (hard-gate variant).
//
// The shipped hook (`neat-search-nudge.mjs`) is a NUDGE: it injects a "ask the
// graph first" note but always lets the search run. This is the GATE: it DENIES
// Grep / Glob / grep-family Bash until `neat ask` (the CLI verb or the
// `mcp__neat__ask` tool) has been called at least once this session — forcing the
// graph-first orientation. Once the graph's been consulted, text search is
// allowed as a fallback (we gate the orientation, not every search forever).
//
// State: a per-session marker under ~/.neat/hooks/gate/, keyed by session_id, is
// written the first time `ask` fires and read on every search. Stateless process
// per call, so the marker is how "has ask run" survives between tool calls.
//
// Built for the ±NEAT benchmark (nudge-vs-gate A/B). Reference implementation for
// folding a gate mode into @neat.is/core's NEAT_SEARCH_HOOK later. Toggle off with
// NEAT_GATE=0 (falls back to nudge-only, never denies).

import process from 'node:process'
import fs from 'node:fs'
import path from 'node:path'
import os from 'node:os'

const SEARCH_BINARY = /(?:^|[\s|;&(){}])(?:grep|egrep|fgrep|rg|ripgrep|ag|ack|find|fd)(?=\s|$)/
const ASK_BASH = /(?:^|[\s|;&(){}])neat\s+ask\b/
const GATE_ON = process.env.NEAT_GATE !== '0'

const MARKER_DIR = path.join(os.homedir(), '.neat', 'hooks', 'gate')
const markerFor = (sid) => path.join(MARKER_DIR, `ask-ran-${(sid || 'nosession').replace(/[^\w.-]/g, '_')}`)
const askHasRun = (sid) => { try { return fs.existsSync(markerFor(sid)) } catch { return false } }
const recordAskRan = (sid) => {
  try { fs.mkdirSync(MARKER_DIR, { recursive: true }); fs.writeFileSync(markerFor(sid), new Date(0).toISOString()) } catch { /* best-effort */ }
}

const readStdin = () => new Promise((resolve) => {
  let d = ''
  process.stdin.setEncoding('utf8')
  process.stdin.on('data', (c) => { d += c })
  process.stdin.on('end', () => resolve(d))
  process.stdin.on('error', () => resolve(d))
})

const raw = await readStdin()
let payload
try { payload = JSON.parse(raw) } catch { process.exit(0) }

const tool = typeof payload?.tool_name === 'string' ? payload.tool_name : ''
const input = payload?.tool_input ?? {}
const session = typeof payload?.session_id === 'string' ? payload.session_id : ''

// 1. Did the agent consult the graph? Any `ask` — the MCP tool or the CLI verb —
//    opens the gate for the rest of this session.
const isAsk =
  tool === 'mcp__neat__ask' ||
  tool === 'ask' ||
  (tool === 'Bash' && typeof input.command === 'string' && ASK_BASH.test(input.command))
if (isAsk) { recordAskRan(session); process.exit(0) }

// 2. Is this a raw text search?
let isSearch = false
if (tool === 'Grep' || tool === 'Glob') isSearch = true
else if (tool === 'Bash') isSearch = typeof input.command === 'string' && SEARCH_BINARY.test(input.command)
if (!isSearch) process.exit(0)

// 3. Search after the graph's been consulted (or gate disabled) → allow.
if (!GATE_ON || askHasRun(session)) process.exit(0)

// 4. Search before any `ask` → DENY, and tell the agent what to do instead.
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'PreToolUse',
    permissionDecision: 'deny',
    permissionDecisionReason:
      'NEAT gate: consult the graph before text search. Call `neat ask "<your question>"` ' +
      '(or the `ask` MCP tool) first — it resolves the entities in your question and answers ' +
      'with structured, provenance-tagged facts (EXTRACTED from code, OBSERVED from runtime), ' +
      'faster and with production truth that ' + (tool || 'grep') + ' cannot see. After you have ' +
      'asked the graph once this session, text search is available as a fallback for what the graph ' +
      'does not model (comments, string literals, config minutiae).',
  },
}))
process.exit(0)
