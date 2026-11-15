// Bench smoke: exercise the grading path on chosen apps/arms. Not a headline run; the point is to
// check every criterion grades honestly (real fail = fail, infra limit = unverified, clean = pass).
// SMOKE_APPS / SMOKE_ARMS are comma lists; defaults: every app, neat-sonnet-full.
import path from 'node:path'
import { ARMS } from './arms.js'
import { CORPUS } from './corpus.js'
import { runMatrix } from './runner.js'

const SMOKE = `node -e "console.log('ok 1 - smoke')"`

async function main() {
  CORPUS['nodegoat'].testCmd = SMOKE
  CORPUS['nodegoat'].suiteUnavailable = 'Cypress e2e needs a headless browser'
  CORPUS['paperless-ngx'].testCmd = SMOKE
  CORPUS['paperless-ngx'].suiteUnavailable = 'pytest needs the app image dependencies'
  const apps = (process.env.SMOKE_APPS ?? Object.keys(CORPUS).join(',')).split(',').filter(Boolean)
  const armIds = (process.env.SMOKE_ARMS ?? 'neat-sonnet-full').split(',').filter(Boolean)
  const arms = ARMS.filter((a) => armIds.includes(a.id))
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'smoke-' + new Date().toISOString().replace(/[:.]/g, '-')
  console.error(`=== SMOKE === runLabel=${runLabel} apps=${apps.join(',')} arms=${arms.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({ runsRoot, runLabel, apps, arms, k: Number(process.env.BENCH_K ?? '1'), concurrency: 1, ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '6') })
  console.error('\n=== SMOKE COMPLETE ===')
  for (const r of rs) {
    console.error(`${r.app}/${r.arm} verdict=${r.grade?.verdict ?? '-'}${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`)
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.verdict.toUpperCase().padEnd(10)}] ${c.name}: ${String(c.detail).slice(0, 230)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(2)} turns=${m.effort?.turns} stop=${m.effort?.stopReason} tools=${JSON.stringify(m.effort?.toolCalls ?? {})}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => {
  console.error('[smoke] fatal', e)
  process.exit(1)
})
