#!/usr/bin/env node
// grounded-evidence — the KEYSTONE metric. Model-free.
//
//   node harness/grounded-evidence.mjs <graph.json> <claims.json> [--require walls/<wall>.json]
//
// "Of the load-bearing facts the agent leaned on, what % trace back to something
// REAL vs invented or assumed." Measures the CONTEXT, not the outcome, so it is
// nearly model-free: we audit each claim's provenance against the fused graph, we
// do not grade the model's answer.
//
// Three tiers (from the design):
//   3 OBSERVATION_GROUNDED — the claimed edge is OBSERVED (or an EXTRACTED edge
//                            that also has an observed twin). Reconciled with what
//                            the system actually did.
//   2 DECLARED_ONLY        — backed by the code (EXTRACTED) but not confirmed by a
//                            trace; may be diverged (the northsea class). Includes
//                            INFERRED (a stitched guess), tagged as a sub-kind.
//   1 UNBACKED             — the agent asserted an edge that is nowhere in the graph
//                            (UNSUPPORTED: both nodes exist, no such edge) or names a
//                            node that does not exist (FABRICATED). Not real.
//
// Grounded-Evidence Rate (headline) = tier-3 / total claims.
// Backed rate (lenient)             = (tier-2 + tier-3) / total.
// SUFFICIENCY GUARD: an agent that asserts LESS looks more grounded, so we also
// check — given a wall's required key fact(s) — whether the agent actually had the
// grounded evidence needed to solve it. Groundedness AND sufficiency.
//
// A "claim" is a {source, target, type} edge the agent relied on. Extracting claims
// from a transcript is the arms-runner's job; this scorer takes them as data so it
// stays model-free and unit-testable.

import { readFileSync } from 'node:fs'
import { classifyGraph } from './claim-classifier.mjs'

const TIER = {
  OBSERVATION_GROUNDED: 3,
  DECLARED_ONLY: 2,
  INFERRED: 2,
  UNSUPPORTED: 1,
  FABRICATED: 1,
}

export function scoreGroundedEvidence(graph, claims, requiredEdges = []) {
  const g = classifyGraph(graph)
  const rows = claims.map((c) => {
    const verdict = g.classifyClaim(c)
    return { claim: c, verdict, tier: TIER[verdict] ?? 1 }
  })
  const n = rows.length
  const count = (t) => rows.filter((r) => r.tier === t).length
  const t3 = count(3)
  const t2 = count(2)
  const t1 = count(1)

  // Sufficiency: every required key fact must appear as an OBSERVATION_GROUNDED claim.
  const key = (e) => `${e.type} ${e.source} ${e.target}`
  const grounded = new Set(rows.filter((r) => r.verdict === 'OBSERVATION_GROUNDED').map((r) => key(r.claim)))
  const missing = requiredEdges.filter((e) => !grounded.has(key(e)))
  const sufficient = requiredEdges.length === 0 ? null : missing.length === 0

  return {
    total: n,
    groundedRate: n === 0 ? 0 : Math.round((t3 / n) * 1000) / 10, // headline %
    backedRate: n === 0 ? 0 : Math.round(((t2 + t3) / n) * 1000) / 10, // lenient %
    distribution: { observation_grounded: t3, declared_only: t2, unbacked: t1 },
    byVerdict: rows.reduce((a, r) => ((a[r.verdict] = (a[r.verdict] ?? 0) + 1), a), {}),
    sufficient,
    missingRequired: missing,
    rows,
  }
}

const isMain = import.meta.url === `file://${process.argv[1]}`
if (isMain) {
  const [graphPath, claimsPath] = process.argv.slice(2).filter((a) => !a.startsWith('--'))
  const reqFlag = process.argv.indexOf('--require')
  if (!graphPath || !claimsPath) {
    console.error('usage: node harness/grounded-evidence.mjs <graph.json> <claims.json> [--require walls/<wall>.json]')
    process.exit(1)
  }
  const graph = JSON.parse(readFileSync(graphPath, 'utf8'))
  const claims = JSON.parse(readFileSync(claimsPath, 'utf8'))
  let required = []
  if (reqFlag !== -1 && process.argv[reqFlag + 1]) {
    const wall = JSON.parse(readFileSync(process.argv[reqFlag + 1], 'utf8'))
    required = wall.required_facts ?? (wall.carrying_edge ? [wall.carrying_edge] : [])
  }
  const r = scoreGroundedEvidence(graph, claims, required)
  console.log(`claims scored: ${r.total}`)
  console.log(`  observation-grounded (tier 3): ${r.distribution.observation_grounded}`)
  console.log(`  declared-only        (tier 2): ${r.distribution.declared_only}`)
  console.log(`  unbacked             (tier 1): ${r.distribution.unbacked}`)
  console.log(`GROUNDED-EVIDENCE RATE (headline): ${r.groundedRate}%   backed-any: ${r.backedRate}%`)
  if (r.sufficient !== null) {
    console.log(`SUFFICIENCY: ${r.sufficient ? 'PASS — had every required fact, grounded' : 'FAIL — missing grounded facts:'}`)
    for (const m of r.missingRequired) console.log(`    missing: ${m.type} ${m.source} -> ${m.target}`)
  }
}
