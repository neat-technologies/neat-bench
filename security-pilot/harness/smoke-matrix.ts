// Task 6: the FULL 12-config no-$ stub smoke (3 arms x 4 targets) + the per-app vulnPathTest id-match.
// Serial (concurrency 1), RAM-gated, stub agent only (NO API). For each config: stand the app up
// FRESH (FreshProvisioner), peek the graph (neat: observed edges + divergences) or the bare capture
// (bytes), run a stub trial (every tool swept once) through the grader to a 4-criterion verdict +
// run.json. On the FIRST config of each app, additionally run the app's REAL testCmd through
// runTests() and compare the produced id set to the corpus vulnPathTests (the SMOKE-VERIFY).
// The grade uses a SMOKE testCmd (plumbing gate: the grader must EMIT a verdict with evidence; the
// real test-suite behavior is validated separately by the id-match). vuln-gone runs the REAL,
// NEAT-independent oracle (OSV + ecosystem scanner / pip-audit-in-container).
import { promises as fs } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { ARMS, type Arm } from './arms.js'
import type { AgentResult, ToolDef } from './agent.js'
import type { TrialContext } from './context.js'
import { getCorpusItem, type BenchCorpusItem } from './corpus.js'
import { FreshProvisioner, LiveReuseProvisioner, runTrial } from './trial.js'
import { availableGi, waitForRam } from './runner.js'
import { runTests } from './grader-impl.js'
import { fetchGraph, fetchDivergences, observedFromService } from '../recon/verifier.js'

const SMOKE = `node -e "console.log('ok 1 - smoke')"`
const APPS = ['nodegoat', 'uptime-kuma', 'gitea', 'paperless-ngx']
// neat-opus first per app so the graph peek + id-match land on a NEAT standup.
const ARM_ORDER: Arm[] = ['neat-opus', 'bare-opus', 'neat-sonnet'].map((id) => ARMS.find((a) => a.id === id)!)

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
    if (n === 'a') return 'service:app'
    if (n === 'b') return 'database:127.0.0.1'
    if (n === 'base') return 'HEAD'
    if (n === 'claim') return 'the dep is reachable'
    if (n === 'query' || n === 'question') return 'which services are failing?'
    return 'service:app'
  }
  for (const [name, spec] of Object.entries(props)) {
    if (!req.includes(name) && !INTERESTING.has(name.toLowerCase())) continue
    const t = (spec as any)?.type
    if (Array.isArray((spec as any)?.enum) && (spec as any).enum.length) args[name] = (spec as any).enum[(spec as any).enum.length - 1]
    else if (t === 'number' || t === 'integer') args[name] = 2
    else if (t === 'boolean') args[name] = false
    else args[name] = hint(name)
  }
  return args
}

async function stubAgent(arm: Arm, tools: ToolDef[], ctx: TrialContext): Promise<AgentResult> {
  const toolCalls: Record<string, number> = {}
  const report: { name: string; isError: boolean; preview: string }[] = []
  for (const t of tools) {
    const args = cannedArgs(t)
    if (t.name === 'write_file') args.path = `.bench-dry-${arm.id}.txt`
    toolCalls[t.name] = (toolCalls[t.name] ?? 0) + 1
    try {
      const r = await t.run(args)
      report.push({ name: t.name, isError: !!r.isError, preview: r.content.slice(0, 160).replace(/\n/g, ' ') })
    } catch (e) {
      report.push({ name: t.name, isError: true, preview: `THREW: ${String(e).slice(0, 160)}` })
    }
  }
  await fs.writeFile(path.join(ctx.artifactsDir, 'dry-tools.json'), JSON.stringify(report, null, 2), 'utf8').catch(() => {})
  return { stopReason: 'end_turn', turns: 1, usage: { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 }, costUsd: 0, toolCalls, wallMs: 0, transcript: [{ role: 'user', content: '[smoke stub]' }] }
}

function smokeItem(app: string): BenchCorpusItem {
  const base = getCorpusItem(app)
  const advisories = app === 'nodegoat' ? [base.advisories.find((a) => a.dep === 'underscore')!] : base.advisories
  return { ...base, advisories, testCmd: SMOKE }
}

interface Row {
  app: string
  arm: string
  pass: boolean | null
  criteria: { name: string; pass: boolean; detail: string }[]
  toolsAnswered: string
  observedEdges?: number
  divergences?: number
  captureBytes?: number
  nodeTypes?: Record<string, number>
  error?: string
}

async function idMatch(app: string, treePath: string): Promise<any> {
  const real = getCorpusItem(app)
  const want = real.advisories.flatMap((a) => a.vulnPathTests)
  let ids: string[] = []
  let err: string | undefined
  try {
    ids = [...(await runTests(real.testCmd, treePath))]
  } catch (e) {
    err = String(e).slice(0, 300)
  }
  const idSet = new Set(ids)
  const matched = want.filter((t) => idSet.has(t))
  const missing = want.filter((t) => !idSet.has(t))
  // substring heuristic: does the corpus (often bare) name appear as a suffix/substring of a real id?
  const substringHit = missing.filter((t) => ids.some((id) => id.includes(t)))
  return {
    app,
    testCmd: real.testCmd,
    wantCount: want.length,
    producedIdCount: ids.length,
    sampleIds: ids.slice(0, 6),
    matchedExact: matched,
    missingExact: missing,
    missingButSubstringPresent: substringHit,
    runError: err,
  }
}

async function main() {
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'smoke12-' + new Date().toISOString().replace(/[:.]/g, '-')
  const workRoot = path.join(runsRoot, runLabel, '_trees')
  await fs.mkdir(workRoot, { recursive: true })
  const ramFloor = Number(process.env.RAM_FLOOR_GI ?? '4')
  const onlyApps = (process.env.SMOKE_APPS ?? APPS.join(',')).split(',').map((s) => s.trim()).filter(Boolean)
  console.error(`=== 12-config stub smoke + id-match === box=${os.hostname()} node=${process.version} apps=${onlyApps.join(',')}`)

  const rows: Row[] = []
  const idMatches: any[] = []

  // Configs to record as BLOCKED without running (e.g. a known diagnosed blocker). Format: "arm/app".
  const skip = new Set((process.env.SKIP_CONFIGS ?? '').split(',').map((s) => s.trim()).filter(Boolean))
  const blockReason = process.env.BLOCK_REASON ?? 'BLOCKED (see diagnosis)'

  for (const app of onlyApps) {
    let idMatchDone = false
    for (const arm of ARM_ORDER) {
      if (skip.has(`${arm.id}/${app}`)) {
        console.error(`\n----- ${arm.id} / ${app} SKIPPED (blocked) -----`)
        rows.push({ app, arm: arm.id, pass: null, criteria: [], toolsAnswered: 'n/a', error: blockReason })
        await fs.writeFile(path.join(runsRoot, runLabel, 'matrix-rows.json'), JSON.stringify(rows, null, 2), 'utf8').catch(() => {})
        continue
      }
      await waitForRam(ramFloor, `${arm.id}/${app}`)
      console.error(`\n----- ${arm.id} / ${app} (avail ${(await availableGi()).toFixed(1)}Gi) -----`)
      const item = smokeItem(app)
      const prov = new FreshProvisioner({ workRoot })
      const row: Row = { app, arm: arm.id, pass: null, criteria: [], toolsAnswered: '0/0' }
      let st: any
      try {
        st = await prov.provision(item, arm)
        // peek
        if (arm.neat && st.neatBase) {
          try {
            const g = await fetchGraph(st.neatBase)
            const divs = await fetchDivergences(st.neatBase)
            row.observedEdges = observedFromService(g, item.service).length
            row.divergences = divs.length
            const bt: Record<string, number> = {}
            for (const n of g.nodes) bt[n.type] = (bt[n.type] ?? 0) + 1
            row.nodeTypes = bt
            // detail (so the matrix doubles as per-app observe-verify): db nodes, observed routes,
            // socket.io topics + symbol-grain OBSERVED edges.
            const obs = g.edges.filter((e: any) => e.provenance === 'OBSERVED')
            const dbs = g.nodes.filter((n: any) => n.id.startsWith('database:'))
            const obsIds = new Set<string>(); for (const e of obs) { obsIds.add(e.source); obsIds.add(e.target) }
            const obsRoutes = g.nodes.filter((n: any) => n.id.startsWith('route:') && obsIds.has(n.id))
            const sioTopics = [...new Set(obs.flatMap((e: any) => [e.source, e.target]).filter((id: string) => id.startsWith('infra:socket.io-topic:')))]
            const symObs = obs.filter((e: any) => String(e.source).startsWith('symbol:') || String(e.target).startsWith('symbol:'))
            console.error(`  [detail] types=${JSON.stringify(bt)}`)
            console.error(`  [detail] dbNodes=${JSON.stringify(dbs.map((n: any) => n.id))}`)
            console.error(`  [detail] observedRoutes=${obsRoutes.length} socketioTopics=${sioTopics.length} symbolGrainObsEdges=${symObs.length}`)
            if (sioTopics.length) console.error(`  [detail] sioTopics=${JSON.stringify(sioTopics.slice(0, 12))}`)
            for (const e of symObs.slice(0, 6)) console.error(`  [detail] symObs: (${e.type}) ${e.source} -> ${e.target}`)
            await fs.writeFile(path.join(runsRoot, runLabel, `graph-${app}.json`), JSON.stringify(g, null, 1), 'utf8').catch(() => {})
          } catch (e) {
            console.error(`  peek(graph) failed: ${String(e).slice(0, 160)}`)
          }
        }
        if (!arm.neat && st.otelCaptureDir) {
          let total = 0
          for (const f of await fs.readdir(st.otelCaptureDir).catch(() => [])) {
            const s = await fs.stat(path.join(st.otelCaptureDir, f)).catch(() => null)
            total += s ? s.size : 0
          }
          row.captureBytes = total
        }
        // id-match once per app (on the first, neat, config): real testCmd through runTests()
        if (!idMatchDone) {
          idMatchDone = true
          const m = await idMatch(app, st.treePath)
          idMatches.push(m)
          console.error(`  id-match ${app}: produced=${m.producedIdCount} matchedExact=${m.matchedExact.length}/${m.wantCount} substringHits=${m.missingButSubstringPresent.length}${m.runError ? ' RUN_ERROR' : ''}`)
        }
        // stub trial (grade) over the live standup
        const live = arm.neat
          ? new LiveReuseProvisioner({ treePath: st.treePath, neatBase: st.neatBase, appBase: st.appBase })
          : new LiveReuseProvisioner({ treePath: st.treePath, appBase: st.appBase, otelCaptureDir: st.otelCaptureDir })
        const rec = await runTrial(arm, item, live, { runsRoot, runLabel, seed: 0, stubAgent })
        row.pass = rec.pass
        row.criteria = (rec.grade?.criteria ?? []).map((c: any) => ({ name: c.name, pass: c.pass, detail: String(c.detail).slice(0, 160) }))
        const surf = (rec.metrics?.toolSurface as string[]) ?? []
        const tools = await fs.readFile(path.join(rec.artifactsDir, 'dry-tools.json'), 'utf8').then(JSON.parse).catch(() => [])
        const ok = tools.filter((t: any) => !t.isError).length
        row.toolsAnswered = `${ok}/${tools.length}`
        if (rec.error) row.error = rec.error.split('\n')[0]
        console.error(`  pass=${row.pass} tools=${row.toolsAnswered} criteria=${row.criteria.map((c) => `${c.name}:${c.pass}`).join(',')}`)
      } catch (e) {
        row.error = String((e as Error).message ?? e).slice(0, 400)
        console.error(`  CONFIG ERROR: ${row.error}`)
      } finally {
        if (st?.teardown) await st.teardown().catch(() => {})
      }
      rows.push(row)
      await fs.writeFile(path.join(runsRoot, runLabel, 'matrix-rows.json'), JSON.stringify(rows, null, 2), 'utf8').catch(() => {})
      await fs.writeFile(path.join(runsRoot, runLabel, 'idmatch.json'), JSON.stringify(idMatches, null, 2), 'utf8').catch(() => {})
    }
  }

  console.error('\n================= 12-CONFIG MATRIX =================')
  for (const r of rows) {
    const crit = r.criteria.map((c) => `${c.name}=${c.pass ? 'P' : 'F'}`).join(' ')
    const extra = r.arm.startsWith('neat') ? `obs=${r.observedEdges ?? '-'} div=${r.divergences ?? '-'}` : `cap=${r.captureBytes ?? '-'}B`
    console.error(`${r.pass === null ? 'ERR ' : r.pass ? 'PASS' : 'fail'} ${r.arm.padEnd(12)} ${r.app.padEnd(14)} tools=${r.toolsAnswered} ${extra} | ${crit}${r.error ? ' | ERROR: ' + r.error : ''}`)
  }
  console.error('\n================= ID-MATCH =================')
  for (const m of idMatches) {
    console.error(`${m.app}: testCmd="${m.testCmd}" produced=${m.producedIdCount} exact=${m.matchedExact.length}/${m.wantCount} substring=${m.missingButSubstringPresent.length}${m.runError ? ' RUN_ERROR=' + m.runError : ''}`)
    console.error(`   sampleIds=${JSON.stringify(m.sampleIds)}`)
    if (m.missingExact.length) console.error(`   missingExact=${JSON.stringify(m.missingExact)}`)
  }
  console.error(`\nartifacts: ${path.join(runsRoot, runLabel)}`)
}

main().catch((e) => {
  console.error('[smoke-matrix] fatal', e)
  process.exit(1)
})
