#!/usr/bin/env node
// wall-certificate — proves a task is a genuine WALL, model-free.
//
//   node harness/wall-certificate.mjs <wall.json> <graph.json> [--source-dir <dir>]
//
// A wall is only a wall if the answer is NOT in the source and IS in the runtime
// graph. This checker refuses to rubber-stamp: it leverages claim-classifier so a
// carrying edge that static actually knew (CONFIRMED / GRAIN_REFINED) or that is a
// NEAT identity artifact (IDENTITY_SUSPECT) does NOT certify. Certification needs:
//
//   1. carrying_edge is present as OBSERVED/INFERRED AND classifies as BLIND
//      (no static edge at any grain, not a grain-refinement, not an identity twin);
//   2. (if --source-dir) the absence_predicate returns EMPTY over the pinned tree —
//      machine proof the answer is not readable from code.
//
// Both hold -> CERTIFIED. Either fails -> NOT a wall (and we say why). This is the
// honesty moat: the wall is a wall by construction, not by our say-so.

import { readFileSync } from 'node:fs'
import { execSync } from 'node:child_process'
import { classifyGraph, CALL_EDGE_TYPES } from './claim-classifier.mjs'

const triple = (e) => `${e.type} ${e.source} ${e.target}`

export function certifyWall(wall, graph, { sourceDir } = {}) {
  const g = classifyGraph(graph)
  const carrying = wall.carrying_edge
  const reasons = []
  let graphOk = false
  let bucket = 'ABSENT'

  if (!carrying) {
    reasons.push('wall has no carrying_edge')
  } else {
    for (const b of ['CONFIRMED', 'GRAIN_REFINED', 'IDENTITY_SUSPECT', 'BLIND']) {
      if (g.buckets[b].some((e) => triple(e) === triple(carrying))) { bucket = b; break }
    }
    if (!CALL_EDGE_TYPES.has(carrying.type)) reasons.push(`carrying_edge type ${carrying.type} is not a call edge`)
    if (bucket === 'ABSENT') reasons.push('carrying_edge is not an OBSERVED/STALE call edge in the graph')
    else if (bucket !== 'BLIND') reasons.push(`carrying_edge classifies as ${bucket}, not BLIND — static knew it (or it is a NEAT identity artifact), so this is not a wall`)
    else graphOk = true
  }

  // Source-absence predicate (only runnable against a real checkout).
  let sourceOk = null
  const pred = wall.absence_predicate
  if (sourceDir && pred?.cmd) {
    let out = ''
    try { out = execSync(pred.cmd, { cwd: sourceDir, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }) } catch { out = '' }
    sourceOk = out.trim() === ''
    if (!sourceOk) reasons.push(`absence_predicate returned output — the answer IS readable from source:\n${out.trim().split('\n').slice(0, 3).join('\n')}`)
  } else if (pred?.cmd) {
    reasons.push('absence_predicate NOT run (no --source-dir) — source-absence unproven')
  }

  const certified = graphOk && sourceOk === true
  return { certified, bucket, graphOk, sourceOk, reasons }
}

const isMain = import.meta.url === `file://${process.argv[1]}`
if (isMain) {
  const args = process.argv.slice(2)
  const [wallPath, graphPath] = args.filter((a) => !a.startsWith('--'))
  const sd = args.indexOf('--source-dir')
  const sourceDir = sd !== -1 ? args[sd + 1] : undefined
  if (!wallPath || !graphPath) {
    console.error('usage: node harness/wall-certificate.mjs <wall.json> <graph.json> [--source-dir <dir>]')
    process.exit(1)
  }
  const wall = JSON.parse(readFileSync(wallPath, 'utf8'))
  const graph = JSON.parse(readFileSync(graphPath, 'utf8'))
  const r = certifyWall(wall, graph, { sourceDir })
  console.log(`wall: ${wall.id}  (axis: ${wall.axis})`)
  console.log(`carrying edge bucket: ${r.bucket}   graph-ok: ${r.graphOk}   source-ok: ${r.sourceOk === null ? 'not-run' : r.sourceOk}`)
  console.log(r.certified ? 'CERTIFIED — this is a genuine wall.' : 'NOT CERTIFIED:')
  for (const why of r.reasons) console.log('  - ' + why)
  process.exit(r.certified ? 0 : 1)
}
