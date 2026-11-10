#!/usr/bin/env node
// Offline router check: run the router alone over every task's prompt and score
// it against the size labels. No agent runs.
//
//   node eval-router.mjs --daemon <url> [--project <name>] [--tasks <dir>] [--only <id>] [--out <file>]
//
// It reports two halves separately:
//   - how much: tier accuracy, the confusion matrix, and the costly mistake,
//     a big task sent to small (or medium);
//   - which files: whether the graph's top 2 / top 5 files contain the files
//     the real fix touched, regardless of the tier Jev picked.
// Read the daemon with the target at its base commit. Tasks whose label rests
// on a live incident need that task's bug running with traffic first (--only).

import { readdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { fetchFeatures } from './router/features.mjs'
import { createJevClient } from './router/jev.mjs'
import { route } from './router/route.mjs'
import { TIER_FOR_SIZE } from './router/rubric.mjs'

const TIERS = ['small', 'medium', 'full']
const covers = (files, gold) => gold.length > 0 && gold.every((g) => files.includes(g))

/** One scored row per task. */
export function scoreRow(task, decision) {
  const expected = TIER_FOR_SIZE[task.size]
  const candidates = decision.candidateFiles ?? []
  return {
    id: task.id,
    size: task.size,
    expected,
    tier: decision.tier,
    reason: decision.reason,
    confidence: decision.jev?.confidence ?? null,
    needsRuntime: decision.jev?.needsRuntime ?? null,
    correct: decision.tier === expected,
    demoted: expected === 'full' && decision.tier !== 'full',
    routedFilesCoverGold: decision.files.length > 0 ? covers(decision.files, task.gold_files) : null,
    graphTop2CoversGold: covers(candidates.slice(0, 2), task.gold_files),
    graphTop5CoversGold: covers(candidates.slice(0, 5), task.gold_files),
    jevLatencyMs: decision.jevLatencyMs ?? null,
  }
}

const pct = (n, d) => (d === 0 ? null : Math.round((1000 * n) / d) / 10)
const quantile = (xs, q) => {
  if (xs.length === 0) return null
  const s = [...xs].sort((a, b) => a - b)
  return s[Math.min(s.length - 1, Math.floor(q * s.length))]
}

/** Pure summary over scored rows. */
export function summarize(rows) {
  const confusion = Object.fromEntries(TIERS.map((e) => [e, Object.fromEntries(TIERS.map((t) => [t, 0]))]))
  for (const r of rows) confusion[r.expected][r.tier] += 1
  const big = rows.filter((r) => r.expected === 'full')
  const routed = rows.filter((r) => r.routedFilesCoverGold !== null)
  const reasons = {}
  for (const r of rows) reasons[r.reason] = (reasons[r.reason] ?? 0) + 1
  const lat = rows.map((r) => r.jevLatencyMs).filter((x) => x !== null)
  return {
    tasks: rows.length,
    bySize: Object.fromEntries(['small', 'medium', 'big'].map((s) => [s, rows.filter((r) => r.size === s).length])),
    tierAccuracyPct: pct(rows.filter((r) => r.correct).length, rows.length),
    confusion, // confusion[expected][routed]
    bigTasks: big.length,
    bigSentSmall: big.filter((r) => r.tier === 'small').length,
    bigSentMedium: big.filter((r) => r.tier === 'medium').length,
    smallRoutedSmallPct: pct(rows.filter((r) => r.expected === 'small' && r.tier === 'small').length, rows.filter((r) => r.expected === 'small').length),
    routedFilesCoverGoldPct: pct(routed.filter((r) => r.routedFilesCoverGold).length, routed.length),
    graphTop2CoversGoldPct: pct(rows.filter((r) => r.graphTop2CoversGold).length, rows.length),
    graphTop5CoversGoldPct: pct(rows.filter((r) => r.graphTop5CoversGold).length, rows.length),
    fallbackReasons: reasons,
    jevLatencyMs: { p50: quantile(lat, 0.5), p95: quantile(lat, 0.95) },
  }
}

export function loadTasks(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .sort()
    .map((f) => JSON.parse(readFileSync(join(dir, f), 'utf8')))
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { values } = parseArgs({
    options: {
      daemon: { type: 'string' },
      project: { type: 'string' },
      tasks: { type: 'string', default: new URL('./tasks/', import.meta.url).pathname },
      only: { type: 'string' },
      out: { type: 'string' },
    },
  })
  if (!values.daemon) {
    console.error('usage: node eval-router.mjs --daemon <url> [--project <name>] [--tasks <dir>] [--only <id>] [--out <file>]')
    process.exit(2)
  }
  let jevClient
  try {
    jevClient = await createJevClient()
  } catch {
    console.error('no TypeSafe client (TYPESAFE_API_KEY unset?): every task will fall back to full; only the file half is meaningful')
    jevClient = { systemOne: () => Promise.reject(Object.assign(new Error('no client'), { name: 'NoClient' })) }
  }
  const tasks = loadTasks(values.tasks).filter((t) => !values.only || t.id === values.only)
  const rows = []
  for (const task of tasks) {
    const decision = await route({
      prompt: task.prompt,
      getFeatures: (p) =>
        fetchFeatures({ prompt: p, daemonUrl: values.daemon, project: values.project, token: process.env.NEAT_ROUTER_DAEMON_TOKEN || undefined }),
      jevClient,
    })
    const row = scoreRow(task, decision)
    rows.push(row)
    console.error(`${row.correct ? 'ok ' : 'MISS'} ${task.id}: expected ${row.expected}, routed ${row.tier} (${row.reason})`)
  }
  const report = { summary: summarize(rows), rows }
  const json = JSON.stringify(report, null, 2) + '\n'
  if (values.out) writeFileSync(values.out, json)
  process.stdout.write(json)
}
