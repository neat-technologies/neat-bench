#!/usr/bin/env node
// instance-validate — schema + stratum-rule check for benchmark instances.
//
//   node harness/instance-validate.mjs instances/**/*.json   (or a dir, or files)
//
// Checks well-formedness and the rules that keep the suite honest. It does NOT
// run the tests — confirming FAIL_TO_PASS actually fails at base_commit (and a
// wall certifies) is the TODO(live) execution step run via run.sh against a
// stood-up target. This validator is the fast, offline gate.

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join } from 'node:path'

const STRATA = new Set(['static-solvable', 'runtime-rooted', 'wall'])
const ORIGINS = new Set(['found', 'constructed'])

function expand(paths) {
  const out = []
  const walk = (p) => {
    const s = statSync(p)
    if (s.isDirectory()) for (const f of readdirSync(p)) walk(join(p, f))
    else if (p.endsWith('.json')) out.push(p)
  }
  for (const p of paths) walk(p)
  return out
}

function validate(inst, file) {
  const errs = []
  const req = (k) => { if (inst[k] === undefined || inst[k] === '') errs.push(`missing ${k}`) }
  ;['id', 'origin', 'stratum', 'repo', 'base_commit', 'problem_statement', 'oracle', 'runtime_dependence'].forEach(req)
  if (inst.origin && !ORIGINS.has(inst.origin)) errs.push(`origin must be found|constructed, got ${inst.origin}`)
  if (inst.stratum && !STRATA.has(inst.stratum)) errs.push(`stratum must be one of ${[...STRATA].join('|')}, got ${inst.stratum}`)

  // Oracle: tests XOR probe, and the chosen shape must be populated.
  const o = inst.oracle ?? {}
  if (o.type === 'tests') {
    if (!Array.isArray(o.fail_to_pass) || o.fail_to_pass.length === 0) errs.push('oracle.tests needs a non-empty fail_to_pass')
    if (!Array.isArray(o.pass_to_pass)) errs.push('oracle.tests needs a pass_to_pass array (regression guard)')
  } else if (o.type === 'probe') {
    if (!o.probe?.healthy || !o.probe?.buggy) errs.push('oracle.probe needs healthy and buggy')
  } else {
    errs.push(`oracle.type must be tests|probe, got ${o.type}`)
  }

  // Wall stratum MUST carry a certificate.
  if (inst.stratum === 'wall') {
    const c = inst.wall_certificate
    if (!c) errs.push('stratum=wall requires wall_certificate')
    else {
      if (!c.absence_predicate?.cmd) errs.push('wall_certificate needs absence_predicate.cmd')
      if (!c.carrying_edge?.type) errs.push('wall_certificate needs a carrying_edge')
    }
  }

  // Honesty: a static-solvable instance that claims NEAT decisiveness HIGH is suspect.
  if (inst.stratum === 'static-solvable' && inst.neat_signal?.decisiveness === 'HIGH')
    errs.push('static-solvable instance claims NEAT decisiveness HIGH — mis-stratified or rigged')

  return errs
}

const args = process.argv.slice(2)
if (args.length === 0) { console.error('usage: node harness/instance-validate.mjs <dir|file...>'); process.exit(1) }
const files = expand(args)
let bad = 0
const byStratum = {}
for (const f of files) {
  let inst
  try { inst = JSON.parse(readFileSync(f, 'utf8')) } catch (e) { console.log(`INVALID  ${f}\n    not JSON: ${e.message}`); bad++; continue }
  const errs = validate(inst, f)
  byStratum[inst.stratum] = (byStratum[inst.stratum] ?? 0) + 1
  if (errs.length) { console.log(`INVALID  ${f}`); for (const e of errs) console.log('    - ' + e); bad++ }
  else console.log(`ok       ${inst.stratum.padEnd(16)} ${inst.id}  (${inst.origin}${inst.validated?.oracle_runs ? ', oracle-run' : ', oracle TODO(live)'})`)
}
console.log(`\n${files.length} instances, ${files.length - bad} valid, ${bad} invalid`)
console.log('by stratum: ' + Object.entries(byStratum).map(([k, v]) => `${k}:${v}`).join('  '))
process.exit(bad ? 1 : 0)
