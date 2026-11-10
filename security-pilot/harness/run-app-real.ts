// REAL k=1 for ONE app (REAL_APP env; default gitea), serial, RAM-gated. Real agent + real testCmd.
// Runs with the fixed grader (scanGo findings-scoping, scanNpm/scanPyPI findings-scoped, attributability
// divergence gate) so grades are correct live — no offline re-grade needed. SKIP_ARMS (comma list) can
// omit arms (e.g. blocked paperless-neat). Per-trial run.json carries the full metric set.
import path from 'node:path'
import { ARMS } from './arms.js'
import { CORPUS } from './corpus.js'
import { runMatrix } from './runner.js'

async function main() {
  const app = process.env.REAL_APP ?? 'gitea'
  const skip = new Set((process.env.SKIP_ARMS ?? '').split(',').map((s) => s.trim()).filter(Boolean))
  const arms = ARMS.filter((a) => !skip.has(a.id))
  // Scope the testCmd to something that RUNS in the bench env (e.g. a smoke) when the native suite
  // can't run here (cypress/hivemq/pytest-infra) — so the agent doesn't thrash on broken tests and
  // no-regression/not-degenerate are reported UNVERIFIED-infra rather than false fails. Clean signal
  // (vuln-gone + actually-works + cost/precision) is unaffected.
  if (process.env.BENCH_TESTCMD) {
    CORPUS[app].testCmd = process.env.BENCH_TESTCMD
    console.error(`[app-real] testCmd overridden -> ${process.env.BENCH_TESTCMD} (native suite UNVERIFIED-infra)`)
  }
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = `${app}-real-k1-` + new Date().toISOString().replace(/[:.]/g, '-')
  console.error(`=== ${app} REAL k=1 === runLabel=${runLabel} arms=${arms.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({
    runsRoot,
    runLabel,
    apps: [app],
    arms,
    k: 1,
    concurrency: 1,
    ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '4'),
  })
  console.error(`\n=== ${app} REAL k=1 COMPLETE ===`)
  for (const r of rs) {
    console.error(`${r.arm} ${r.app} pass=${r.pass}${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`)
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.pass ? 'PASS' : 'FAIL'}] ${c.name}: ${String(c.detail).slice(0, 160)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(3)} in=${m.cost.usage?.input} out=${m.cost.usage?.output} turns=${m.effort?.turns} stop=${m.effort?.stopReason}`)
    if (m.time) console.error(`   totalMs=${m.time.totalMs} phase=${JSON.stringify(m.time.phase)}`)
    if (m.neatUsage && Object.keys(m.neatUsage).length) console.error(`   neatUsage=${JSON.stringify(m.neatUsage)}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => {
  console.error('[app-real] fatal', e)
  process.exit(1)
})
