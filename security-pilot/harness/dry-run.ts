// DRY plumbing test — NO real agent, NO API spend. Proves the machinery on ONE app (nodegoat)
// against an existing live neat-ba daemon (:8202) + the running app (:4102): checkout (reused),
// app + NEAT daemon reachable, EVERY tool answers, grader returns a verdict with evidence,
// run.json + artifacts written, and the RAM/parallel logic holds. A stub agent emits a canned
// tool-call sequence hitting every tool once; it does NOT fix anything, so vuln-gone is expected
// to be false — the point is the plumbing, not a PASS.
import { promises as fs } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { ARMS, type Arm } from './arms.js'
import type { AgentResult, ToolDef } from './agent.js'
import type { TrialContext } from './context.js'
import { getCorpusItem, type BenchCorpusItem } from './corpus.js'
import { LiveReuseProvisioner, runTrial } from './trial.js'
import { availableGi, waitForRam } from './runner.js'

const NEAT_BASE = process.env.DRY_NEAT_BASE ?? 'http://localhost:8202'
const APP_BASE = process.env.DRY_APP_BASE ?? 'http://127.0.0.1:4102'
const TREE = process.env.DRY_TREE ?? '$HOME/neat-bench/security-pilot/nodegoat/src'

// Fill a tool's args with sensible canned values so every tool actually answers. Fills required
// props plus a few known-interesting optional ones (dep/cve/claim/against/a/b/direction), respects
// declared types, and picks a valid enum value when one is declared (e.g. direction up|down).
const INTERESTING = new Set(['dep', 'cve', 'claim', 'against', 'a', 'b', 'direction', 'query', 'question', 'base', 'node', 'target'])
function cannedArgs(tool: ToolDef): any {
  const schema: any = tool.input_schema || {}
  const req: string[] = schema.required || []
  const props: Record<string, any> = schema.properties || {}
  const args: any = {}
  const hint = (name: string): any => {
    const n = name.toLowerCase()
    if (n === 'command') return 'ls -la'
    if (n === 'path') return 'package.json'
    if (n === 'content') return 'dry-run scratch note'
    if (n === 'dep' || n === 'package' || n === 'name') return 'underscore'
    if (n === 'cve' || n === 'advisory') return 'CVE-2021-23358'
    if (n === 'against') return 'self'
    if (n === 'a') return 'service:nodegoat'
    if (n === 'b') return 'database:127.0.0.1'
    if (n === 'base') return 'HEAD'
    if (n === 'claim') return 'underscore is reachable'
    if (n === 'query' || n === 'question') return 'which services are failing?'
    return 'service:nodegoat' // target / node / id / service / from / start / center / etc.
  }
  for (const [name, spec] of Object.entries(props)) {
    if (!req.includes(name) && !INTERESTING.has(name.toLowerCase())) continue
    const t = spec?.type
    if (Array.isArray(spec?.enum) && spec.enum.length) args[name] = spec.enum[spec.enum.length - 1] // e.g. 'down'
    else if (t === 'number' || t === 'integer') args[name] = 2
    else if (t === 'boolean') args[name] = false
    else args[name] = hint(name)
  }
  return args
}

// The stub: call every tool once, record each answer, return a zero-cost AgentResult.
async function stubAgent(arm: Arm, tools: ToolDef[], ctx: TrialContext): Promise<AgentResult> {
  const toolCalls: Record<string, number> = {}
  const report: { name: string; isError: boolean; preview: string }[] = []
  for (const t of tools) {
    const args = cannedArgs(t)
    // write_file goes to a per-arm scratch path so concurrent arms don't collide.
    if (t.name === 'write_file') args.path = `.bench-dry-${arm.id}.txt`
    toolCalls[t.name] = (toolCalls[t.name] ?? 0) + 1
    try {
      const r = await t.run(args)
      report.push({ name: t.name, isError: !!r.isError, preview: r.content.slice(0, 200).replace(/\n/g, ' ') })
    } catch (e) {
      report.push({ name: t.name, isError: true, preview: `THREW: ${String(e).slice(0, 180)}` })
    }
  }
  await fs.writeFile(path.join(ctx.artifactsDir, 'dry-tools.json'), JSON.stringify(report, null, 2), 'utf8')
  return {
    stopReason: 'end_turn',
    turns: 1,
    usage: { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 },
    costUsd: 0,
    toolCalls,
    wallMs: 0,
    transcript: [{ role: 'user', content: '[dry-run stub: canned tool sweep, no model call]' }],
  }
}

function trimmedNodegoat(): BenchCorpusItem {
  const base = getCorpusItem('nodegoat')
  return {
    ...base,
    // one advisory keeps the NEAT-independent vuln check fast; smoke testCmd keeps runTests fast.
    advisories: [base.advisories.find((a) => a.dep === 'underscore')!],
    testCmd: `node -e "console.log('ok 1 - smoke')"`,
    notes: [...base.notes, 'DRY: trimmed to 1 advisory (underscore) + smoke testCmd for plumbing only.'],
  }
}

async function reachable(url: string): Promise<string> {
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(6000) })
    return `HTTP ${r.status}`
  } catch (e) {
    return `UNREACHABLE (${(e as Error).message})`
  }
}

async function main() {
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'dry-' + new Date().toISOString().replace(/[:.]/g, '-')
  console.error('=== NEAT security-bench DRY plumbing test ===')
  console.error(`box=${os.hostname()} node=${process.version}`)

  // 0. reachability preflight
  const health = await reachable(`${NEAT_BASE}/health`)
  const app = await reachable(APP_BASE)
  console.error(`[preflight] NEAT daemon ${NEAT_BASE}/health -> ${health}`)
  console.error(`[preflight] app ${APP_BASE} -> ${app}`)
  console.error(`[preflight] tree ${TREE} -> ${(await fs.stat(TREE).then(() => 'exists').catch(() => 'MISSING'))}`)

  // RAM/parallel logic: print available, gate on floor, then run two arms concurrently.
  console.error(`[ram] MemAvailable=${(await availableGi()).toFixed(1)}Gi (floor via RAM_FLOOR_GI)`)
  await waitForRam(Number(process.env.RAM_FLOOR_GI ?? '7'), 'dry-run')

  const item = trimmedNodegoat()
  const otelCaptureDir = path.join(runsRoot, runLabel, '_otel-capture-stub')
  await fs.mkdir(otelCaptureDir, { recursive: true })
  await fs.writeFile(
    path.join(otelCaptureDir, 'README.txt'),
    'Raw OTel capture (traces + logs) for the BARE arm lands here in a real trial via a plain collector. Stubbed for the dry plumbing test.\n',
    'utf8',
  )

  const neatArm = ARMS.find((a) => a.id === 'neat-opus')!
  const bareArm = ARMS.find((a) => a.id === 'bare-opus')!
  const neatProv = new LiveReuseProvisioner({ treePath: TREE, neatBase: NEAT_BASE, appBase: APP_BASE })
  const bareProv = new LiveReuseProvisioner({ treePath: TREE, appBase: APP_BASE, otelCaptureDir }) // bare: no neatBase, gets OTel capture

  // Concurrent == proves parallel isolation + the shared-daemon plumbing (stub mutates nothing material).
  const [neatRec, bareRec] = await Promise.all([
    runTrial(neatArm, item, neatProv, { runsRoot, runLabel, seed: 0, stubAgent }),
    runTrial(bareArm, item, bareProv, { runsRoot, runLabel, seed: 0, stubAgent }),
  ])

  // Report
  for (const rec of [neatRec, bareRec]) {
    console.error(`\n=== arm ${rec.arm} ===`)
    if (rec.error) console.error(`  ERROR: ${rec.error.split('\n')[0]}`)
    console.error(`  pass=${rec.pass}`)
    if (rec.grade) for (const c of rec.grade.criteria) console.error(`  [${c.pass ? 'PASS' : 'FAIL'}] ${c.name}: ${c.detail.slice(0, 180)}`)
    const toolsReport = await fs.readFile(path.join(rec.artifactsDir, 'dry-tools.json'), 'utf8').then(JSON.parse).catch(() => [])
    const okCount = toolsReport.filter((t: any) => !t.isError).length
    console.error(`  tools answered: ${okCount}/${toolsReport.length} ok`)
    for (const t of toolsReport) console.error(`    ${t.isError ? 'ERR ' : 'ok  '}${t.name}: ${t.preview}`)
    console.error(`  artifacts: ${rec.artifactsDir}`)
    const files = await fs.readdir(rec.artifactsDir).catch(() => [])
    console.error(`    files: ${files.join(', ')}`)
  }
  console.error('\n=== DRY test complete ===')
}

main().catch((e) => {
  console.error('[dry] fatal', e)
  process.exit(1)
})
