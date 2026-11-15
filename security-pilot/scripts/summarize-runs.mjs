#!/usr/bin/env node
// Rebuild the results tables from the run artifacts, so every number in RESULTS-2026-11-15.md
// can be regenerated from what is committed under runs/.
//
// Usage: node scripts/summarize-runs.mjs runs/<run-dir> [runs/<run-dir> ...]
//
// For each trial it reads run.json (pins, cost, grade) and transcript.json (tool calls), and
// prints two Markdown tables: one row per trial, then one row per (arm, app) cell.
import { readdirSync, readFileSync, existsSync, statSync } from 'node:fs'
import path from 'node:path'

const APPS = ['uptime-kuma', 'nodegoat', 'paperless-ngx', 'gitea']

// Shell commands that read git history beyond the checked-out commit. A trial that runs one has
// looked at upstream commits made after the vulnerable one (see RESULTS-2026-11-15.md, "gitea").
const HISTORY = /cherry-pick|merge-base|git (checkout|reset|switch|rebase)\b[^|;&]*\b[0-9a-f]{7,40}\b|git log\b[^|;&]*(\.\.|--all|origin)|git show [0-9a-f]{7,40}|git tag\b|git branch -a|git (fetch|pull)\b/

function trialsOf(runDir) {
  const out = []
  for (const arm of readdirSync(runDir)) {
    const armDir = path.join(runDir, arm)
    if (!statSync(armDir).isDirectory()) continue
    for (const t of readdirSync(armDir).sort()) {
      const dir = path.join(armDir, t)
      const runFile = path.join(dir, 'run.json')
      if (!existsSync(runFile)) continue
      const run = JSON.parse(readFileSync(runFile, 'utf8'))
      const grade = run.grade ?? run.metrics?.outcome
      const usage = run.metrics.cost.usage
      let history = 0
      let commands = 0
      const tx = path.join(dir, 'transcript.json')
      if (existsSync(tx)) {
        const t = JSON.parse(readFileSync(tx, 'utf8'))
        for (const m of Array.isArray(t) ? t : (t.messages ?? [])) {
          for (const b of Array.isArray(m.content) ? m.content : []) {
            if (b.type === 'tool_use' && typeof b.input?.command === 'string') {
              commands++
              if (HISTORY.test(b.input.command)) history++
            }
          }
        }
      }
      const crit = Object.fromEntries(grade.criteria.map((c) => [c.name, c.verdict]))
      out.push({
        run: path.basename(runDir),
        arm,
        app: run.pins.app,
        trial: t,
        model: run.pins.model,
        verdict: grade.verdict,
        crit,
        // "Fixed": the vulnerability is gone and the redeployed app answers its journeys as before.
        fixed: crit['vuln-gone'] === 'pass' && crit['actually-works'] === 'pass',
        usd: run.metrics.cost.usd,
        inputTokens: usage.input,
        outputTokens: usage.output,
        cacheRead: usage.cacheRead,
        turns: run.metrics.effort?.turns,
        stop: run.metrics.effort?.stopReason,
        neatCalls: Object.entries(run.metrics.neatUsage ?? {})
          .filter(([k]) => k !== 'recon_qa')
          .reduce((n, [, v]) => n + v, 0),
        history,
        commands,
        neatCli: run.pins.neatCli ?? '',
      })
    }
  }
  return out
}

const dirs = process.argv.slice(2)
if (dirs.length === 0) {
  console.error('usage: node scripts/summarize-runs.mjs runs/<run-dir> [...]')
  process.exit(2)
}
const trials = dirs.flatMap(trialsOf)
const money = (n) => `$${n.toFixed(2)}`
const mtok = (n) => `${(n / 1e6).toFixed(2)}M`

console.log('## Every trial\n')
console.log('| Run | Arm | App | Trial | Verdict | vuln-gone | no-regression | not-degenerate | actually-works | Cost | Input tokens | Turns | Stop | NEAT calls | History commands |')
console.log('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
for (const t of trials.sort((a, b) => a.run.localeCompare(b.run) || a.arm.localeCompare(b.arm) || APPS.indexOf(a.app) - APPS.indexOf(b.app) || a.trial.localeCompare(b.trial))) {
  console.log(
    `| ${t.run} | ${t.arm} | ${t.app} | ${t.trial} | ${t.verdict} | ${t.crit['vuln-gone']} | ${t.crit['no-regression']} | ${t.crit['not-degenerate']} | ${t.crit['actually-works']} | ${money(t.usd)} | ${mtok(t.inputTokens)} | ${t.turns ?? ''} | ${t.stop ?? ''} | ${t.neatCalls} | ${t.history} |`,
  )
}

console.log('\n## Per cell\n')
console.log('| Run | Arm | App | Trials | Verdict pass | Fixed (vuln gone + app works) | Total cost | Mean cost | Input tokens (min to max) | Trials that read later git history |')
console.log('|---|---|---|---|---|---|---|---|---|---|')
const cells = new Map()
for (const t of trials) {
  const k = `${t.run}\u0000${t.arm}\u0000${t.app}`
  cells.set(k, [...(cells.get(k) ?? []), t])
}
for (const [k, ts] of [...cells].sort(([a], [b]) => a.localeCompare(b))) {
  const [run, arm, app] = k.split('\u0000')
  const usd = ts.reduce((n, t) => n + t.usd, 0)
  const toks = ts.map((t) => t.inputTokens).sort((a, b) => a - b)
  console.log(
    `| ${run} | ${arm} | ${app} | ${ts.length} | ${ts.filter((t) => t.verdict === 'pass').length} | ${ts.filter((t) => t.fixed).length} | ${money(usd)} | ${money(usd / ts.length)} | ${mtok(toks[0])} to ${mtok(toks[toks.length - 1])} | ${ts.filter((t) => t.history > 0).length} |`,
  )
}

console.log('\n## Per arm\n')
console.log('| Run | Arm | Trials | Total cost | Prompt-cache reads |')
console.log('|---|---|---|---|---|')
const arms = new Map()
for (const t of trials) {
  const k = `${t.run}\u0000${t.arm}`
  arms.set(k, [...(arms.get(k) ?? []), t])
}
for (const [k, ts] of [...arms].sort(([a], [b]) => a.localeCompare(b))) {
  const [run, arm] = k.split('\u0000')
  console.log(`| ${run} | ${arm} | ${ts.length} | ${money(ts.reduce((n, t) => n + t.usd, 0))} | ${ts.reduce((n, t) => n + t.cacheRead, 0)} |`)
}
