#!/usr/bin/env node
// Summarize the arm.json files the runs wrote, by task size and arm.
//
//   node summarize-runs.mjs [--results <dir>]
//
// Cache writes, cache reads, uncached input, output and turns are kept apart,
// not folded into dollars: whether a NEAT arm costs more because its setup
// started cold or because the agent did more work are different findings.
// Cost per passing run is reported beside cost, per the claims contract. This is
// a development summary (medians, k=3); the scored analysis is pre-registered.

import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'

const median = (xs) => {
  const v = xs.filter((x) => typeof x === 'number' && Number.isFinite(x)).sort((a, b) => a - b)
  if (v.length === 0) return null
  const m = Math.floor(v.length / 2)
  return v.length % 2 ? v[m] : (v[m - 1] + v[m]) / 2
}
const round = (x, d = 4) => (x === null ? null : Math.round(x * 10 ** d) / 10 ** d)

/** Pure: arm.json rows → one summary row per size × arm. */
export function summarizeRuns(rows) {
  const groups = new Map()
  for (const r of rows) {
    const key = `${r.size}\u0000${r.arm}`
    if (!groups.has(key)) groups.set(key, [])
    groups.get(key).push(r)
  }
  return [...groups.values()]
    .map((g) => {
      const verified = g.filter((r) => r.oracle_pass === true || r.oracle_pass === false)
      const passes = verified.filter((r) => r.oracle_pass === true)
      const cost = g.map((r) => r.cost_usd).filter((x) => typeof x === 'number')
      return {
        size: g[0].size,
        arm: g[0].arm,
        runs: g.length,
        verified: verified.length,
        passRate: verified.length ? round(passes.length / verified.length, 3) : null,
        medianTurns: median(g.map((r) => r.turns)),
        medianCacheWrite: median(g.map((r) => r.cache?.write)),
        medianCacheRead: median(g.map((r) => r.cache?.read)),
        medianUncachedInput: median(g.map((r) => r.cache?.uncached_input)),
        medianOutput: median(g.map((r) => r.cache?.output)),
        medianWarmupCacheWrite: median(g.map((r) => r.warmup?.cache_write)),
        medianCostUsd: round(median(cost)),
        costPerPassUsd: passes.length ? round(cost.reduce((a, b) => a + b, 0) / passes.length) : null,
        medianWallS: median(g.map((r) => r.wall_s)),
      }
    })
    .sort((a, b) => a.size.localeCompare(b.size) || a.arm.localeCompare(b.arm))
}

function findArmJson(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) findArmJson(p, out)
    else if (name === 'arm.json') out.push(p)
  }
  return out
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { values } = parseArgs({
    options: { results: { type: 'string', default: fileURLToPath(new URL('../../results/context-router/', import.meta.url)) } },
  })
  const rows = findArmJson(values.results).map((p) => JSON.parse(readFileSync(p, 'utf8')))
  console.table(summarizeRuns(rows))
}
