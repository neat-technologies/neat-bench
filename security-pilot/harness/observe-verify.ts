// Per-app observe-verify against the MAIN-build (eb330c2) daemon. NO grade, NO API. Stands the app up
// FRESH twice (serial, RAM-gated): NEAT arm -> dump the graph (node types, DatabaseNode engine:host
// keys per ADR-276, observed-first routes per ADR-275, socket.io <ns>#<event> grain, symbol-grain
// OBSERVED) + divergences; BARE arm -> confirm otelcol capture bytes (traces + logs). DRY_APP picks.
import { promises as fs } from 'node:fs'
import path from 'node:path'
import os from 'node:os'
import { ARMS } from './arms.js'
import { getCorpusItem } from './corpus.js'
import { FreshProvisioner } from './trial.js'
import { fetchGraph, fetchDivergences, observedFromService } from '../recon/verifier.js'
import { availableGi, waitForRam } from './runner.js'

async function main() {
  const app = process.env.DRY_APP ?? 'nodegoat'
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const label = `verify-${app}-${new Date().toISOString().replace(/[:.]/g, '-')}`
  const workRoot = path.join(runsRoot, label, '_trees')
  await fs.mkdir(workRoot, { recursive: true })
  const item = getCorpusItem(app)
  const service = item.service
  const ramFloor = Number(process.env.RAM_FLOOR_GI ?? '4')
  console.error(`=== observe-verify (eb330c2) app=${app} service=${service} box=${os.hostname()} avail=${(await availableGi()).toFixed(1)}Gi ===`)

  // ---------- NEAT arm ----------
  await waitForRam(ramFloor, `${app}-neat`)
  console.error('\n######### NEAT arm #########')
  const neatProv = new FreshProvisioner({ workRoot })
  const neatSt = await neatProv.provision(item, ARMS.find((a) => a.id === 'neat-opus')!)
  try {
    const g = await fetchGraph(neatSt.neatBase!)
    const divs = await fetchDivergences(neatSt.neatBase!)
    const observed = observedFromService(g, service)
    console.error(`neatBase=${neatSt.neatBase} nodes=${g.nodes.length} edges=${g.edges.length}`)
    console.error(`OBSERVED edges from service:${service}: ${observed.length}`)
    console.error(`/graph/divergences answered: ${divs.length}`)

    const byType: Record<string, number> = {}
    for (const n of g.nodes) byType[n.type] = (byType[n.type] ?? 0) + 1
    console.error('node types:', JSON.stringify(byType))

    const dbNodes = g.nodes.filter((n) => n.id.startsWith('database:') || String(n.type).toLowerCase().includes('database'))
    console.error(`DatabaseNodes (${dbNodes.length}): ${dbNodes.map((n) => n.id).join(', ') || '(none)'}`)

    const routeNodes = g.nodes.filter((n) => n.id.startsWith('route:') || String(n.type).toLowerCase().includes('route'))
    const obs = g.edges.filter((e) => e.provenance === 'OBSERVED')
    const obsIds = new Set<string>()
    for (const e of obs) { obsIds.add(e.source); obsIds.add(e.target) }
    const obsRoutes = routeNodes.filter((n) => obsIds.has(n.id))
    console.error(`route nodes: ${routeNodes.length}; OBSERVED routes: ${obsRoutes.length}`)
    for (const n of obsRoutes.slice(0, 20)) console.error(`  OBSERVED route: ${n.id}`)

    const sioNodes = g.nodes.filter((n) => /#/.test(n.id))
    console.error(`socket.io event-grain nodes (<ns>#<event>) (${sioNodes.length}): ${sioNodes.slice(0, 15).map((n) => n.id).join(', ') || '(none)'}`)

    const symNodes = g.nodes.filter((n) => n.id.startsWith(`symbol:${service}:`) || n.id.startsWith('symbol:'))
    const symObs = obs.filter((e) => String(e.source).startsWith('symbol:') || String(e.target).startsWith('symbol:'))
    console.error(`symbol nodes: ${symNodes.length}; OBSERVED edges touching a symbol: ${symObs.length}`)
    for (const e of symObs.slice(0, 10)) console.error(`  sym OBSERVED: (${e.type}) ${e.source} -> ${e.target}`)

    const obsTypes: Record<string, number> = {}
    for (const e of obs) obsTypes[e.type] = (obsTypes[e.type] ?? 0) + 1
    console.error('OBSERVED edge types:', JSON.stringify(obsTypes))

    await fs.writeFile(path.join(runsRoot, label, `graph-${app}.json`), JSON.stringify(g, null, 1), 'utf8').catch(() => {})
    console.error(`graph dumped: ${path.join(runsRoot, label, `graph-${app}.json`)}`)
  } finally {
    await neatSt.teardown()
    console.error('[neat] torn down')
  }

  // ---------- BARE arm ----------
  await waitForRam(ramFloor, `${app}-bare`)
  console.error('\n######### BARE arm #########')
  const bareProv = new FreshProvisioner({ workRoot })
  const bareSt = await bareProv.provision(item, ARMS.find((a) => a.id === 'bare-opus')!)
  try {
    console.error(`appBase=${bareSt.appBase} otelCaptureDir=${bareSt.otelCaptureDir}`)
    const files = await fs.readdir(bareSt.otelCaptureDir!).catch(() => [] as string[])
    let total = 0
    for (const f of files) {
      const st = await fs.stat(path.join(bareSt.otelCaptureDir!, f)).catch(() => null)
      const sz = st ? st.size : 0
      total += sz
      console.error(`  capture ${f}: ${sz} bytes`)
    }
    console.error(`bare capture total: ${total} bytes across ${files.length} file(s)`)
  } finally {
    await bareSt.teardown()
    console.error('[bare] torn down')
  }
  console.error('\n=== observe-verify complete ===')
}
main().catch((e) => {
  console.error('[observe-verify] fatal', e)
  process.exit(1)
})
