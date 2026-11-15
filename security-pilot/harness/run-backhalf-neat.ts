// Re-confirm the two back-half findings (nodegoat INCOMPLETE, uptime-kuma DEGENERATE) on the
// CURRENT binary (dist-fixed = origin/main + #1614 + #1615), NEAT arms only. The morning suite
// produced them on the published neat.is@0.11.0 via the NEAT_BIN default, so they need a clean
// binary before the back-half lever is shaped on them. nodegoat uses the smoke testCmd (cypress
// is absent; its finding is vuln-gone/incomplete, test-independent); uptime-kuma runs its real
// test-backend.mjs so the degenerate (not-degenerate FAIL) can re-surface honestly.
import path from 'node:path'
import { ARMS } from './arms.js'
import { CORPUS } from './corpus.js'
import { runMatrix } from './runner.js'

const SMOKE = `node -e "console.log('ok 1 - smoke')"`

async function main() {
  CORPUS['nodegoat'].testCmd = SMOKE
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'backhalf-neat-k1-' + new Date().toISOString().replace(/[:.]/g, '-')
  const arms = ARMS.filter((a) => a.neat)
  const apps = ['nodegoat', 'uptime-kuma']
  console.error(`=== BACK-HALF NEAT k=1 === runLabel=${runLabel} apps=${apps.join(',')} arms=${arms.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({
    runsRoot,
    runLabel,
    apps,
    arms,
    k: 1,
    concurrency: 1,
    ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '6'),
  })
  console.error('\n=== BACK-HALF NEAT k=1 COMPLETE ===')
  for (const r of rs) {
    console.error(
      `${r.app}/${r.arm} pass=${r.pass} verdict=${r.grade?.verdict ?? '-'}` +
        `${r.grade?.unverified?.length ? ` unverified=[${r.grade.unverified.join(',')}]` : ''}` +
        `${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`,
    )
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.verdict.toUpperCase().padEnd(5)}] ${c.name}: ${String(c.detail).slice(0, 170)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(4)} turns=${m.effort?.turns} stop=${m.effort?.stopReason}`)
    if (m.effort?.toolCalls) console.error(`   toolCalls=${JSON.stringify(m.effort.toolCalls)}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => {
  console.error('[backhalf-neat] fatal', e)
  process.exit(1)
})
