#!/usr/bin/env node
// aggregate — roll up per-(wall x arm x trial) results into the dashboard.
//
//   node harness/aggregate.mjs <result.json...>
//
// Each result file is one trial: { wall, arm: "neat"|"baseline", trial, metrics:{...} }
// Numeric metrics -> mean/min/max/spread. Boolean metrics -> rate. Then the +-NEAT
// DELTA per metric (neat vs baseline) — the number is the ablation, held to N trials.
// The pilot ran N=1 and could not average nondeterminism (PILOT-RESULTS.md); this
// exists so N>=5 is a roll-up, not a hand-written table.

import { readFileSync } from 'node:fs'

const files = process.argv.slice(2)
if (files.length === 0) { console.error('usage: node harness/aggregate.mjs <result.json...>'); process.exit(1) }

const trials = files.map((f) => JSON.parse(readFileSync(f, 'utf8')))
const arms = [...new Set(trials.map((t) => t.arm))]
const metricNames = [...new Set(trials.flatMap((t) => Object.keys(t.metrics ?? {})))]

const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length
const std = (xs) => { const m = mean(xs); return Math.sqrt(mean(xs.map((x) => (x - m) ** 2))) }
const isBool = (v) => typeof v === 'boolean'

function summarize(rows, metric) {
  const vals = rows.map((r) => r.metrics?.[metric]).filter((v) => v !== undefined)
  if (vals.length === 0) return null
  if (isBool(vals[0])) {
    const rate = vals.filter(Boolean).length / vals.length
    return { kind: 'rate', n: vals.length, rate }
  }
  return { kind: 'num', n: vals.length, mean: mean(vals), min: Math.min(...vals), max: Math.max(...vals), spread: std(vals) }
}

const byArm = Object.fromEntries(arms.map((a) => [a, trials.filter((t) => t.arm === a)]))
const wall = trials[0]?.wall ?? '(mixed)'

console.log(`wall: ${wall}   arms: ${arms.join(', ')}   trials: ${trials.length}`)
console.log('')
const fmt = (s) => s == null ? '   -   ' : s.kind === 'rate' ? `${(s.rate * 100).toFixed(0)}%` : `${s.mean.toFixed(1)}±${s.spread.toFixed(1)}`
const pad = (x, n) => String(x).padEnd(n)
console.log(pad('metric', 26) + arms.map((a) => pad(a, 16)).join('') + 'delta(neat-baseline)')
for (const m of metricNames) {
  const cells = arms.map((a) => summarize(byArm[a], m))
  const neat = cells[arms.indexOf('neat')]
  const base = cells[arms.indexOf('baseline')]
  let delta = '-'
  if (neat && base) {
    if (neat.kind === 'rate') delta = `${((neat.rate - base.rate) * 100).toFixed(0)} pts`
    else delta = (neat.mean - base.mean).toFixed(1)
  }
  console.log(pad(m, 26) + cells.map((c) => pad(fmt(c), 16)).join('') + delta)
}
console.log('')
console.log('NOTE: a number only counts once N>=5 and the wall is CERTIFIED. Report spread, never a single run.')
