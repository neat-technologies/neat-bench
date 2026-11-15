// Gap-1 + fix-action re-measure: the two NEAT arms only (bare-opus already PASSed the canary,
// so re-spending on the control is waste). Serial, RAM-gated. Needs NEAT_BIN + BENCH_NEAT_CLI
// pointed at the fixed build so BOTH the security tools (NEAT_BIN) and the daemon (BENCH_NEAT_CLI)
// see the Go dependency tree.
import path from 'node:path'
import { ARMS } from './arms.js'
import { runMatrix } from './runner.js'

async function main() {
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'gitea-neat-k1-' + new Date().toISOString().replace(/[:.]/g, '-')
  const arms = ARMS.filter((a) => a.neat)
  console.error(`=== GITEA NEAT k=1 === runLabel=${runLabel} arms=${arms.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({
    runsRoot,
    runLabel,
    apps: ['gitea'],
    arms,
    k: 1,
    concurrency: 1,
    ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '6'),
  })
  console.error('\n=== GITEA NEAT k=1 COMPLETE ===')
  for (const r of rs) {
    console.error(
      `${r.arm} ${r.app} pass=${r.pass} verdict=${r.grade?.verdict ?? '-'}` +
        `${r.grade?.unverified?.length ? ` unverified=[${r.grade.unverified.join(',')}]` : ''}` +
        `${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`,
    )
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.verdict.toUpperCase().padEnd(5)}] ${c.name}: ${String(c.detail).slice(0, 180)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(4)} turns=${m.effort?.turns} stop=${m.effort?.stopReason}`)
    if (m.effort?.toolCalls) console.error(`   toolCalls=${JSON.stringify(m.effort.toolCalls)}`)
    if (m.neatUsage) console.error(`   neatUsage=${JSON.stringify(m.neatUsage)}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => {
  console.error('[gitea-neat] fatal', e)
  process.exit(1)
})
