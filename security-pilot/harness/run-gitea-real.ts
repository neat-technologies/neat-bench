// REAL k=1 for gitea only (bare-opus, neat-sonnet-full, neat-sonnet-lean), serial, RAM-gated. Real agent loop
// (ANTHROPIC_API_KEY from env) + the REAL testCmd (go test ./modules/markup/...). FreshProvisioner
// stands each arm up fresh at the vuln commit on the eb330c2 main-build daemon. run.json per trial
// carries pins + the full metric set (tokens/$/time/turns/toolCalls/neatUsage).
import path from 'node:path'
import { ARMS } from './arms.js'
import { runMatrix } from './runner.js'

async function main() {
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'gitea-real-k1-' + new Date().toISOString().replace(/[:.]/g, '-')
  console.error(`=== GITEA REAL k=1 === runLabel=${runLabel} arms=${ARMS.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({
    runsRoot,
    runLabel,
    apps: ['gitea'],
    arms: ARMS,
    k: 1,
    concurrency: 1, // serial: protect the shared box RAM
    ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '4'),
  })
  console.error('\n=== GITEA REAL k=1 COMPLETE ===')
  for (const r of rs) {
    console.error(`${r.arm} ${r.app} pass=${r.pass} verdict=${r.grade?.verdict ?? '-'}${r.grade?.unverified?.length ? ` unverified=[${r.grade.unverified.join(',')}]` : ''}${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`)
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.verdict.toUpperCase().padEnd(5)}] ${c.name}: ${String(c.detail).slice(0, 180)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(4)} usage=${JSON.stringify(m.cost.usage)} turns=${m.effort?.turns} stop=${m.effort?.stopReason}`)
    if (m.time) console.error(`   timeMs=${m.time.totalMs} phase=${JSON.stringify(m.time.phase)}`)
    if (m.neatUsage) console.error(`   neatUsage=${JSON.stringify(m.neatUsage)}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => {
  console.error('[gitea-real] fatal', e)
  process.exit(1)
})
