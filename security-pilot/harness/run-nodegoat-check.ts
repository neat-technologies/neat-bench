// Validate the grader --omit=dev fix: one nodegoat trial (neat-sonnet-full) on dist-fixed + fixed
// grader. Expect vuln-gone PASS now that the dev-only transitive underscore noise is out of scope.
import path from 'node:path'
import { ARMS } from './arms.js'
import { CORPUS } from './corpus.js'
import { runMatrix } from './runner.js'

const SMOKE = `node -e "console.log('ok 1 - smoke')"`

async function main() {
  CORPUS['nodegoat'].testCmd = SMOKE
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'nodegoat-check-k1-' + new Date().toISOString().replace(/[:.]/g, '-')
  const arms = ARMS.filter((a) => a.id === 'neat-sonnet-full')
  console.error(`=== NODEGOAT CHECK === runLabel=${runLabel} arms=${arms.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({ runsRoot, runLabel, apps: ['nodegoat'], arms, k: 1, concurrency: 1, ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '6') })
  console.error('\n=== NODEGOAT CHECK COMPLETE ===')
  for (const r of rs) {
    console.error(`${r.app}/${r.arm} pass=${r.pass} verdict=${r.grade?.verdict ?? '-'}${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`)
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.verdict.toUpperCase().padEnd(5)}] ${c.name}: ${String(c.detail).slice(0, 180)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(4)} turns=${m.effort?.turns}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => {
  console.error('[nodegoat-check] fatal', e)
  process.exit(1)
})
