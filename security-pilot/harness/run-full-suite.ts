// Billed FULL k=1 suite: all 4 apps x 3 arms (bare-opus / neat-sonnet-full / neat-sonnet-lean), SERIAL
// (concurrency 1) for a reliable unattended run. Trials are fully isolated (own tree/daemon/ports) so
// serial==parallel verdicts, and cost/turns are per-agent (load-independent). $25/trial cap via
// BENCH_TRIAL_COST_CAP (agent.ts). Grades are correct live (tri-state grader + attributability gate).
//
// Per-app testCmd: gitea (pinned go1.27.3 toolchain + caches + sqlite tags, set in corpus.ts) and
// uptime-kuma (node test/test-backend.mjs; the mqtt describe self-skips without hivemq) run their REAL
// suites. nodegoat (cypress needs headless chrome, absent) and paperless (pytest needs in-container
// django deps) can't run their native suite on the host, so they get a smoke testCmd -> the agent does
// not thrash on a broken suite and no-regression/not-degenerate grade UNVERIFIED-infra (honest, not a
// false fail). vuln-gone (OSV + ecosystem scanner, NEAT-independent) + actually-works (recon) +
// cost/turns/precision are the thesis signal and are unaffected by the testCmd choice.
import path from 'node:path'
import { ARMS } from './arms.js'
import { CORPUS } from './corpus.js'
import { runMatrix } from './runner.js'

const SMOKE = `node -e "console.log('ok 1 - smoke')"`

async function main() {
  CORPUS['nodegoat'].testCmd = SMOKE
  CORPUS['paperless-ngx'].testCmd = SMOKE
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'full-k1-' + new Date().toISOString().replace(/[:.]/g, '-')
  const concurrency = Number(process.env.CONCURRENCY ?? '1')
  const apps = Object.keys(CORPUS)
  console.error(`=== FULL k=1 SUITE === runLabel=${runLabel} apps=${apps.join(',')} arms=${ARMS.map((a) => a.id).join(',')} concurrency=${concurrency}`)
  const rs = await runMatrix({ runsRoot, runLabel, apps, arms: ARMS, k: 1, concurrency, ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '6') })

  console.error('\n=== FULL k=1 SUITE COMPLETE ===')
  for (const r of rs) {
    console.error(
      `${r.app}/${r.arm} pass=${r.pass} verdict=${r.grade?.verdict ?? '-'}` +
        `${r.grade?.unverified?.length ? ` unverified=[${r.grade.unverified.join(',')}]` : ''}` +
        `${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`,
    )
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.verdict.toUpperCase().padEnd(5)}] ${c.name}: ${String(c.detail).slice(0, 150)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(3)} turns=${m.effort?.turns} stop=${m.effort?.stopReason}`)
    if (m.neatUsage && Object.keys(m.neatUsage).length) console.error(`   neatUsage=${JSON.stringify(m.neatUsage)}`)
  }
  const total = rs.reduce((s, r) => s + (((r.metrics as any)?.cost?.usd) ?? 0), 0)
  console.error(`\nTOTAL SPEND: $${total.toFixed(2)}`)
  console.error(`artifacts: ${path.join(runsRoot, runLabel)}`)
}

main().catch((e) => {
  console.error('[full-k1] fatal', e)
  process.exit(1)
})
