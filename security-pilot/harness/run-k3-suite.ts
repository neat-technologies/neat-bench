// First clean k=3: all 4 apps x 3 arms x 3 reps = 36 trials, on dist-fixed (main = #1616 + #1617,
// NO #1619), fixed grader (--omit=dev), NEAT_BIN + BENCH_NEAT_CLI both pinned. Serial, $25/trial cap.
// nodegoat + paperless use a smoke testCmd (cypress/pytest can't run on the host -> not-deg
// UNVERIFIED-infra, honest); gitea + uptime-kuma run their real suites. The headline rests on
// vuln-gone + actually-works + cost, which are unaffected by the testCmd choice.
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
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = (process.env.BENCH_LABEL ?? 'k3') + '-' + new Date().toISOString().replace(/[:.]/g, '-')
  const k = Number(process.env.BENCH_K ?? '3')
  // BENCH_APPS / BENCH_ARMS (comma lists) narrow the matrix, e.g. to re-run one app's NEAT arms on a
  // fixed build. Unset, every app and arm runs.
  const only = (v: string | undefined) => (v ?? '').split(',').filter(Boolean)
  const apps = only(process.env.BENCH_APPS).length ? only(process.env.BENCH_APPS) : Object.keys(CORPUS)
  const arms = only(process.env.BENCH_ARMS).length ? ARMS.filter((a) => only(process.env.BENCH_ARMS).includes(a.id)) : ARMS
  for (const a of apps) if (!CORPUS[a]) throw new Error(`BENCH_APPS: unknown app ${a}`)
  if (arms.length === 0) throw new Error('BENCH_ARMS matched no arm')
  console.error(`=== k=${k} SUITE === runLabel=${runLabel} apps=${apps.join(',')} arms=${arms.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({ runsRoot, runLabel, apps, arms, k, concurrency: 1, ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '6') })
  console.error(`\n=== k=${k} SUITE COMPLETE ===`)
  for (const r of rs) {
    console.error(
      `${r.app}/${r.arm} pass=${r.pass} verdict=${r.grade?.verdict ?? '-'}` +
        `${r.grade?.unverified?.length ? ` unverified=[${r.grade.unverified.join(',')}]` : ''}` +
        `${r.error ? ' ERR: ' + r.error.split('\n')[0] : ''}`,
    )
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(3)} turns=${m.effort?.turns}`)
  }
  const total = rs.reduce((s, r) => s + (((r.metrics as any)?.cost?.usd) ?? 0), 0)
  console.error(`\nTOTAL SPEND: $${total.toFixed(2)}`)
  console.error(`artifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => {
  console.error('[k3] fatal', e)
  process.exit(1)
})
