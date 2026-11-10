#!/usr/bin/env node
// Run tasks × arms × trials with the arm order rotating, so no arm always takes
// the same slot: first after a quiet spell, or last when everything is warm.
// Each run still gets its own warm-up inside run.sh.
//
//   node arms/run-matrix.mjs [--tasks <dir>] [--only <id,...>] [--size small|medium|big]
//                            [--arms bare,full,lean-full,oracle,jev] [--trials 3] [--plan] [--dry-run]
//
// --plan prints the order and runs nothing. The plan is saved beside the
// results so the order a run used is part of its record.

import { spawnSync } from 'node:child_process'
import { mkdirSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { loadTasks } from '../eval-router.mjs'
import { ARMS } from './arm-config.mjs'

/** The arms rotated by task and trial: a Latin-square order over the arm list. */
export function armOrder(arms, taskIndex, trial) {
  const k = (taskIndex + trial) % arms.length
  return [...arms.slice(k), ...arms.slice(0, k)]
}

/** Every run, in the order to execute it. Trials are 1-based. */
export function plan(taskIds, arms, trials) {
  const runs = []
  for (let trial = 1; trial <= trials; trial++) {
    taskIds.forEach((task, i) => {
      armOrder(arms, i, trial - 1).forEach((arm, slot) => runs.push({ task, arm, trial, slot }))
    })
  }
  return runs
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const here = fileURLToPath(new URL('.', import.meta.url))
  const { values } = parseArgs({
    options: {
      tasks: { type: 'string', default: fileURLToPath(new URL('../tasks/', import.meta.url)) },
      only: { type: 'string' },
      size: { type: 'string' },
      arms: { type: 'string', default: ARMS.join(',') },
      trials: { type: 'string', default: '3' },
      plan: { type: 'boolean', default: false },
      'dry-run': { type: 'boolean', default: false },
    },
  })
  const arms = values.arms.split(',').filter(Boolean)
  for (const a of arms) if (!ARMS.includes(a)) throw new Error(`unknown arm: ${a}`)
  const only = values.only ? new Set(values.only.split(',')) : null
  const tasks = loadTasks(values.tasks).filter((t) => (!only || only.has(t.id)) && (!values.size || t.size === values.size))
  const runs = plan(tasks.map((t) => t.id), arms, Number(values.trials))

  if (values.plan) {
    for (const r of runs) console.log(`trial ${r.trial}  ${r.task}  slot ${r.slot}  ${r.arm}`)
    process.exit(0)
  }

  const resultsDir = fileURLToPath(new URL('../../../results/context-router/', import.meta.url))
  mkdirSync(resultsDir, { recursive: true })
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  const record = { startedAt: new Date().toISOString(), arms, trials: Number(values.trials), runs: [] }
  for (const r of runs) {
    const taskFile = join(values.tasks, `${r.task}.json`)
    const args = [join(here, 'run.sh'), taskFile, r.arm, String(r.trial), ...(values['dry-run'] ? ['--dry-run'] : [])]
    const res = spawnSync('bash', args, { stdio: 'inherit', env: process.env })
    record.runs.push({ ...r, exit: res.status })
    writeFileSync(join(resultsDir, `matrix-${stamp}.json`), JSON.stringify(record, null, 2) + '\n')
  }
}
