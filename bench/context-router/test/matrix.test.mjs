import assert from 'node:assert/strict'
import { test } from 'node:test'
import { armOrder, plan } from '../arms/run-matrix.mjs'
import { summarizeRuns } from '../summarize-runs.mjs'

const ARMS = ['bare', 'full', 'lean-full', 'oracle', 'jev']

test('arm order rotates by task and trial', () => {
  assert.deepEqual(armOrder(ARMS, 0, 0), ARMS)
  assert.deepEqual(armOrder(ARMS, 1, 0), ['full', 'lean-full', 'oracle', 'jev', 'bare'])
  assert.deepEqual(armOrder(ARMS, 0, 1), armOrder(ARMS, 1, 0))
})

test('every arm runs once per task and trial, and takes every slot equally often', () => {
  const tasks = Array.from({ length: 10 }, (_, i) => `t${i}`)
  const runs = plan(tasks, ARMS, 3)
  assert.equal(runs.length, 10 * ARMS.length * 3)
  for (const t of tasks) for (let trial = 1; trial <= 3; trial++) {
    const arms = runs.filter((r) => r.task === t && r.trial === trial).map((r) => r.arm).sort()
    assert.deepEqual(arms, [...ARMS].sort())
  }
  for (const arm of ARMS) {
    const slots = new Map()
    for (const r of runs.filter((x) => x.arm === arm)) slots.set(r.slot, (slots.get(r.slot) ?? 0) + 1)
    assert.deepEqual([...new Set(slots.values())], [6], `${arm} slots ${[...slots]}`)
  }
})

test('the summary keeps cache writes, reads and turns apart and prices passes', () => {
  const row = (arm, pass, cost, write, read, turns) => ({
    size: 'small', arm, oracle_pass: pass, cost_usd: cost, turns, wall_s: 30,
    cache: { write, read, uncached_input: 10, output: 900 }, warmup: { cache_write: 15000, cache_read: 0, cost_usd: 0.05 },
  })
  const [bare, full] = summarizeRuns([
    row('full', true, 0.18, 1500, 200000, 5),
    row('full', false, 0.2, 1600, 210000, 7),
    row('full', null, 0.19, 1550, 205000, 6),
    row('bare', true, 0.06, 1400, 120000, 4),
  ])
  assert.equal(full.arm, 'full')
  assert.equal(full.runs, 3)
  assert.equal(full.verified, 2)
  assert.equal(full.passRate, 0.5)
  assert.equal(full.medianTurns, 6)
  assert.equal(full.medianCacheWrite, 1550)
  assert.equal(full.medianCacheRead, 205000)
  assert.equal(full.medianWarmupCacheWrite, 15000)
  assert.equal(full.costPerPassUsd, 0.57)
  assert.equal(bare.passRate, 1)
})
