#!/usr/bin/env node
// extract-claims — turn an agent's final answer into {source,target,type} claims
// the grounded-evidence scorer can grade, WITHOUT biasing either arm.
//
//   node harness/arms/extract-claims.mjs <graph.json> <answer.txt>   > claims.json
//
// Both arms are asked to end their answer with a fenced ```neat-evidence block of
// the dependency facts they relied on, in NEUTRAL terms (file paths + coarse
// targets like "database"/"queue") — NOT NEAT node-ids, which only the WITH arm
// could know. This module parses that block and resolves each neutral fact to a
// real graph edge, EDGE-AWARE: given a resolved source and a coarse target, it
// looks for an actual edge from that source to a target of that category and
// grounds the claim to it. Unresolvable endpoints are emitted verbatim so the
// scorer classifies them FABRICATED — honest, not dropped.

import { readFileSync } from 'node:fs'

// coarse target category -> predicate on a node id
const CATEGORY = {
  database: (id) => id.startsWith('database:') || id.startsWith('infra:sql-table:') || id.startsWith('infra:mongodb'),
  db: (id) => CATEGORY.database(id),
  table: (id) => id.startsWith('infra:sql-table:') || id.startsWith('infra:mongodb-collection:'),
  queue: (id) => id.startsWith('infra:kafka-topic:') || id.startsWith('infra:queue') || id.includes('bull'),
  topic: (id) => CATEGORY.queue(id),
  cache: (id) => id.startsWith('infra:redis') || id.includes('redis'),
  service: (id) => id.startsWith('service:'),
  route: (id) => id.startsWith('route:'),
}
const KIND_TO_TYPE = {
  connects: 'CONNECTS_TO', connect: 'CONNECTS_TO', reads: 'CONNECTS_TO', read: 'CONNECTS_TO',
  writes: 'CONNECTS_TO', write: 'CONNECTS_TO', queries: 'CONNECTS_TO', query: 'CONNECTS_TO',
  calls: 'CALLS', call: 'CALLS', invokes: 'CALLS', requests: 'CALLS',
  publishes: 'PUBLISHES_TO', publish: 'PUBLISHES_TO', emits: 'PUBLISHES_TO',
  consumes: 'CONSUMES_FROM', consume: 'CONSUMES_FROM', subscribes: 'CONSUMES_FROM',
  depends: 'DEPENDS_ON', imports: 'IMPORTS',
}

export function parseEvidenceBlock(text) {
  // Find a fenced ```neat-evidence ... ``` block; tolerate ```json labelled the same.
  const m = text.match(/```(?:neat-evidence|json)?\s*\n([\s\S]*?)\n```/i)
  const raw = m ? m[1] : null
  if (!raw) return []
  try { const arr = JSON.parse(raw); return Array.isArray(arr) ? arr : [] } catch { return [] }
}

export function resolveClaims(neutral, graph) {
  const nodes = new Set((graph.nodes ?? []).map((n) => n.id))
  const edges = graph.edges ?? []
  const isPath = (s) => typeof s === 'string' && (/[\/.]/.test(s)) && /\.(js|mjs|cjs|ts|tsx|jsx|py|go)$/.test(s)

  const resolveNode = (s) => {
    if (typeof s !== 'string') return null
    if (nodes.has(s)) return s
    if (isPath(s)) {
      const hit = [...nodes].find((id) => id.startsWith('file:') && (id.endsWith(':' + s) || id.endsWith('/' + s) || id.endsWith(s)))
      if (hit) return hit
    }
    // exact-ish match on a service/symbol/infra name segment
    const byName = [...nodes].find((id) => id.split(/[:\/]/).pop() === s)
    return byName ?? null
  }

  const out = []
  for (const c of neutral) {
    const from = c.from ?? c.source
    const to = c.to ?? c.target
    const kind = (c.kind ?? c.type ?? 'calls').toLowerCase()
    const type = KIND_TO_TYPE[kind] ?? 'CALLS'
    const srcId = resolveNode(from) ?? from
    const cat = typeof to === 'string' ? CATEGORY[to.toLowerCase()] : null
    if (cat) {
      // edge-aware: find a real edge from srcId (or a descendant file it owns) to a node of this category
      const e = edges.find((e) => e.source === srcId && cat(e.target)) ??
                edges.find((e) => cat(e.target) && e.source.startsWith('file:') && e.source.includes(String(from)))
      if (e) { out.push({ source: e.source, target: e.target, type: e.type }); continue }
      out.push({ source: srcId, target: to, type }) // coarse, unresolved -> scorer marks unbacked
      continue
    }
    const tgtId = resolveNode(to) ?? to
    out.push({ source: srcId, target: tgtId, type })
  }
  return out
}

const isMain = import.meta.url === `file://${process.argv[1]}`
if (isMain) {
  const [graphPath, answerPath] = process.argv.slice(2)
  if (!graphPath || !answerPath) { console.error('usage: node extract-claims.mjs <graph.json> <answer.txt>'); process.exit(1) }
  const graph = JSON.parse(readFileSync(graphPath, 'utf8'))
  const text = readFileSync(answerPath, 'utf8')
  const claims = resolveClaims(parseEvidenceBlock(text), graph)
  console.log(JSON.stringify(claims, null, 2))
}
