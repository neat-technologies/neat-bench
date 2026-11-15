// Validate the card verify-after-apply lever on kuma: one uptime-kuma trial (neat-sonnet-full) with
// the lever + real test-backend.mjs. Does the agent now run the feature test after the jsonata bump
// and catch/handle the json-query break instead of shipping a blind degenerate?
import path from 'node:path'
import { ARMS } from './arms.js'
import { runMatrix } from './runner.js'

async function main() {
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'kuma-check-k1-' + new Date().toISOString().replace(/[:.]/g, '-')
  const arms = ARMS.filter((a) => a.id === 'neat-sonnet-full')
  console.error(`=== KUMA CHECK === runLabel=${runLabel} arms=${arms.map((a) => a.id).join(',')}`)
  const rs = await runMatrix({ runsRoot, runLabel, apps: ['uptime-kuma'], arms, k: 1, concurrency: 1, ramFloorGi: Number(process.env.RAM_FLOOR_GI ?? '6') })
  console.error('\n=== KUMA CHECK COMPLETE ===')
  for (const r of rs) {
    console.error(`${r.app}/${r.arm} pass=${r.pass} verdict=${r.grade?.verdict ?? '-'}${r.error ? ' ERROR: ' + r.error.split('\n')[0] : ''}`)
    if (r.grade) for (const c of r.grade.criteria) console.error(`   [${c.verdict.toUpperCase().padEnd(5)}] ${c.name}: ${String(c.detail).slice(0, 170)}`)
    const m: any = r.metrics ?? {}
    if (m.cost) console.error(`   cost=$${(m.cost.usd ?? 0).toFixed(4)} turns=${m.effort?.turns}`)
    if (m.effort?.toolCalls) console.error(`   toolCalls=${JSON.stringify(m.effort.toolCalls)}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}
main().catch((e) => { console.error('[kuma-check] fatal', e); process.exit(1) })
