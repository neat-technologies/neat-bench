// DRY end-to-end test of the FreshProvisioner on ONE validated app (nodegoat c5cb68a). NO real
// agent, NO API spend: a stub agent sweeps every tool once. This exercises the REAL per-trial
// standup (fresh checkout -> deps -> mongo+seed -> instrumented app -> MAIN-build `neat watch`
// daemon / bare otelcol-contrib -> baseline traffic), reports the OBSERVED edge count + that
// /graph/divergences answers (NEAT arm) and that the bare collector wrote capture files (BARE arm),
// then runs a stub trial through to a grade + run.json over the live standup (LiveReuse, no second
// standup). Arms run sequentially to protect the shared box's RAM. Blocks are reported, never faked.
import { promises as fs } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { ARMS, type Arm } from './arms.js'
import type { AgentResult, ToolDef } from './agent.js'
import type { TrialContext } from './context.js'
import { getCorpusItem, type BenchCorpusItem } from './corpus.js'
import { FreshProvisioner, LiveReuseProvisioner, runTrial } from './trial.js'
import { availableGi } from './runner.js'
import { fetchGraph, fetchDivergences, observedFromService } from '../recon/verifier.js'

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
    return 'service:nodegoat'
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
    transcript: [{ role: 'user', content: '[dry-fresh stub: canned tool sweep, no model call]' }],
  }
}

function trimmedNodegoat(): BenchCorpusItem {
  const base = getCorpusItem('nodegoat')
  return {
    ...base,
    advisories: [base.advisories.find((a) => a.dep === 'underscore')!],
    testCmd: `node -e "console.log('ok 1 - smoke')"`,
    notes: [...base.notes, 'DRY-FRESH: trimmed to 1 advisory (underscore) + smoke testCmd for plumbing only.'],
  }
}

async function main() {
  const app = process.env.DRY_APP ?? 'nodegoat'
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const runLabel = 'dryfresh-' + new Date().toISOString().replace(/[:.]/g, '-')
  const workRoot = path.join(runsRoot, runLabel, '_trees')
  await fs.mkdir(workRoot, { recursive: true })
  console.error('=== NEAT security-bench DRY FreshProvisioner test ===')
  console.error(`box=${os.hostname()} node=${process.version} app=${app} avail=${(await availableGi()).toFixed(1)}Gi`)

  const item = app === 'nodegoat' ? trimmedNodegoat() : getCorpusItem(app)
  const neatArm = ARMS.find((a) => a.id === 'neat-opus')!
  const bareArm = ARMS.find((a) => a.id === 'bare-opus')!

  // ---- NEAT arm: fresh standup + MAIN-build daemon observes it ----
  console.error('\n########## NEAT arm (fresh standup + main-build daemon) ##########')
  const neatProv = new FreshProvisioner({ workRoot })
  const neatStandup = await neatProv.provision(item, neatArm)
  try {
    console.error(`[neat] treePath=${neatStandup.treePath}`)
    console.error(`[neat] neatBase=${neatStandup.neatBase} appBase=${neatStandup.appBase}`)
    // Direct observed-edge + divergence read against the main-build daemon.
    const graph = await fetchGraph(neatStandup.neatBase!)
    const observed = observedFromService(graph, (item as any).service ?? 'nodegoat')
    const divs = await fetchDivergences(neatStandup.neatBase!)
    console.error(`[neat] graph: ${graph.nodes.length} nodes, ${graph.edges.length} edges`)
    console.error(`[neat] OBSERVED edges from service:${(item as any).service}: ${observed.length}`)
    console.error(`[neat] /graph/divergences answered: ${divs.length} divergence(s)`)
    await dumpGraphDetail(graph, (item as any).service ?? app, runsRoot, runLabel)
    // Stub trial over the live standup (no second standup) -> grade + run.json.
    const live = new LiveReuseProvisioner({ treePath: neatStandup.treePath, neatBase: neatStandup.neatBase, appBase: neatStandup.appBase })
    const rec = await runTrial(neatArm, item, live, { runsRoot, runLabel, seed: 0, stubAgent })
    reportRec('neat-opus', rec, observed.length, divs.length)
  } finally {
    await neatStandup.teardown()
    console.error('[neat] torn down')
  }

  // ---- BARE arm: fresh standup + otelcol-contrib capture to files ----
  console.error('\n########## BARE arm (fresh standup + otelcol-contrib capture) ##########')
  const bareProv = new FreshProvisioner({ workRoot })
  const bareStandup = await bareProv.provision(item, bareArm)
  try {
    console.error(`[bare] treePath=${bareStandup.treePath}`)
    console.error(`[bare] appBase=${bareStandup.appBase} otelCaptureDir=${bareStandup.otelCaptureDir}`)
    const capFiles = await fs.readdir(bareStandup.otelCaptureDir!).catch(() => [] as string[])
    for (const f of capFiles) {
      const st = await fs.stat(path.join(bareStandup.otelCaptureDir!, f)).catch(() => null)
      console.error(`[bare] capture file ${f}: ${st ? st.size : '?'} bytes`)
    }
    const live = new LiveReuseProvisioner({ treePath: bareStandup.treePath, appBase: bareStandup.appBase, otelCaptureDir: bareStandup.otelCaptureDir })
    const rec = await runTrial(bareArm, item, live, { runsRoot, runLabel, seed: 0, stubAgent })
    reportRec('bare-opus', rec, undefined, undefined)
  } finally {
    await bareStandup.teardown()
    console.error('[bare] torn down')
  }

  console.error('\n=== DRY FreshProvisioner test complete ===')
  console.error(`runs under: ${path.join(runsRoot, runLabel)}`)
}

// Full node-type + grain breakdown for the neat arm (folds in the observe-verify detail): node-type
// histogram, DatabaseNode keys (ADR-276 engine:host), route observed-count (ADR-275), socket.io
// event-grain nodes (<namespace>#<event>), symbol-grain OBSERVED edges, and the OBSERVED edge-type mix.
async function dumpGraphDetail(g: any, service: string, runsRoot: string, runLabel: string): Promise<void> {
  const byType: Record<string, number> = {}
  for (const n of g.nodes) byType[n.type] = (byType[n.type] ?? 0) + 1
  console.error('[neat] node types:', JSON.stringify(byType))
  const dbNodes = g.nodes.filter((n: any) => n.id.startsWith('database:') || String(n.type).toLowerCase().includes('database'))
  console.error(`[neat] database nodes (${dbNodes.length}): ${dbNodes.map((n: any) => n.id).join(', ')}`)
  const routeNodes = g.nodes.filter((n: any) => n.id.startsWith('route:') || String(n.type).toLowerCase().includes('route'))
  const obs = g.edges.filter((e: any) => e.provenance === 'OBSERVED')
  const obsNodeIds = new Set<string>()
  for (const e of obs) { obsNodeIds.add(e.source); obsNodeIds.add(e.target) }
  const obsRoutes = routeNodes.filter((n: any) => obsNodeIds.has(n.id))
  console.error(`[neat] route nodes: ${routeNodes.length}; OBSERVED routes: ${obsRoutes.length}`)
  // socket.io event-grain: nodes keyed <namespace>#<event>.
  const sioNodes = g.nodes.filter((n: any) => /#/.test(n.id))
  if (sioNodes.length) console.error(`[neat] socket.io event-grain nodes (${sioNodes.length}): ${sioNodes.slice(0, 12).map((n: any) => n.id).join(', ')}`)
  // symbol-grain OBSERVED (edges from symbol:<svc>:).
  const symObs = obs.filter((e: any) => String(e.source).startsWith(`symbol:${service}:`))
  if (symObs.length) console.error(`[neat] symbol-grain OBSERVED edges (${symObs.length}): ${symObs.slice(0, 8).map((e: any) => `${e.source}->${e.target}`).join(' | ')}`)
  const obsTypes: Record<string, number> = {}
  for (const e of obs) obsTypes[e.type] = (obsTypes[e.type] ?? 0) + 1
  console.error('[neat] OBSERVED edge types:', JSON.stringify(obsTypes))
  const dump = path.join(runsRoot, runLabel, `graph-${service}.json`)
  await fs.writeFile(dump, JSON.stringify(g, null, 1), 'utf8').catch(() => {})
  console.error(`[neat] graph dumped: ${dump}`)
}

function reportRec(armId: string, rec: any, observedEdges?: number, divergences?: number): void {
  console.error(`\n=== trial ${armId} ===`)
  if (rec.error) console.error(`  ERROR: ${rec.error.split('\n')[0]}`)
  console.error(`  pass=${rec.pass}`)
  if (rec.grade) for (const c of rec.grade.criteria) console.error(`  [${c.pass ? 'PASS' : 'FAIL'}] ${c.name}: ${String(c.detail).slice(0, 200)}`)
  if (observedEdges !== undefined) console.error(`  observedEdges(service)=${observedEdges} divergences=${divergences}`)
  console.error(`  run.json: ${path.join(rec.artifactsDir, 'run.json')}`)
}

main().catch((e) => {
  console.error('[dry-fresh] fatal', e)
  process.exit(1)
})
