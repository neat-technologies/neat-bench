// Recon flush: force a fresh, honest observation window so neither the agent nor the oracle
// reads stale state. Drive the journeys, poll the graph until OBSERVED edges update (fresh
// lastObserved, spanCount>0), then re-read divergences. Wraps the daemon's existing refresh
// path (OTLP push lands as the journeys run); no neat-core change.
import type { TrialContext } from '../harness/context.js'
import { assertObserved, fetchDivergences, newDivergences, type Divergence, type ObservedVerdict } from './verifier.js'
import { getSuite, driveJourneys } from './journeys/index.js'

export interface FlushResult {
  freshAsOf: string
  observed: ObservedVerdict
  divergences: Divergence[]
  newDivergences: string[]
  journeyFailures: string[]
  journeysRan: number
}

export async function flush(ctx: TrialContext, baselineDivergences: Divergence[], passes = 3): Promise<FlushResult> {
  if (!ctx.neatBase) throw new Error('flush: ctx.neatBase required')
  const suite = getSuite(ctx.app)
  let journeyFailures: string[] = []
  let journeysRan = 0
  if (ctx.appBase) {
    const driven = await driveJourneys(suite, ctx.appBase, passes)
    journeyFailures = driven.failures
    journeysRan = driven.ran
  }
  const observed = await assertObserved(ctx.neatBase, suite.serviceId, { timeoutMs: 30_000 })
  const divergences = await fetchDivergences(ctx.neatBase)
  return {
    freshAsOf: new Date().toISOString(),
    observed,
    divergences,
    newDivergences: newDivergences(baselineDivergences, divergences),
    journeyFailures,
    journeysRan,
  }
}
