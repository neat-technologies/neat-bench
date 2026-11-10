// Recon: the agentic QA stack for the NEAT arms. Three agent-facing tools (recon_qa,
// recon_flush, recon_probe) plus the deterministic ReconQA oracle the grader calls. Grounded
// in NEAT's OBSERVED-e2e harness (e2e/brief) and the retired propose->assess->gate->WATCH loop.
// The bare arm does NOT get these (it gets the raw OTel capture instead) — fairness: NEAT + Recon
// are the single variable.
import type { ToolDef } from '../harness/agent.js'
import type { TrialContext } from '../harness/context.js'
import type { ReconQA as ReconQAInterface } from '../harness/grader.js'
import { assertObserved, fetchDivergences, newDivergences, divergenceKey, type Divergence } from './verifier.js'
import { getSuite, driveJourneys } from './journeys/index.js'
import { flush as doFlush } from './flush.js'

// Shared, trial-scoped state. trial.ts captures the baseline divergence set after standup +
// baseline traffic (pre-fix) and hands it in; recon_flush refreshes the "current" view.
export interface ReconState {
  baselineDivergences: Divergence[]
  // Files in the fix's blast radius (changed-dep importers + agent-edited files). A NEW divergence
  // counts against actually-works ONLY if it references one (fix-attributable); an ambient divergence
  // on code the fix never touched is dropped. Unset/empty => count all (back-compat). Set at grade
  // time by trial.ts. NEAT-arm-only gate, so a false divergence must not penalize NEAT alone.
  attributableFiles?: string[]
}

export interface ReconAssessment {
  works: boolean
  testFailures: string[]
  journeyFailures: string[]
  newDivergences: string[]
  observedOk: boolean
  detail: string
}

// Core correctness read: drive journeys, confirm OBSERVED still materializes for the exercised
// routes, confirm no NEW divergence the fix introduced. (Native-framework tests are the grader's
// own gate; recon_qa reports them only when asked to run them.)
export async function reconAssess(ctx: TrialContext, state: ReconState, opts: { runTests?: () => Promise<string[]> } = {}): Promise<ReconAssessment> {
  const suite = getSuite(ctx.app)

  let journeyFailures: string[] = []
  if (ctx.appBase) {
    const driven = await driveJourneys(suite, ctx.appBase, 3)
    journeyFailures = driven.failures
  } else {
    journeyFailures = ['app base URL not set — journeys not driven']
  }

  // NEAT arms: also confirm OBSERVED still materializes + no NEW divergence (needs the graph).
  // Bare arm: "actually-works" is journeys-only (README: criterion 4 run for bare via journeys),
  // since it has no graph — no OBSERVED/divergence rigor available to it.
  let observedOk = true
  let newDivs: string[] = []
  let graphDetail = 'bare arm: journeys-only (no NEAT graph)'
  if (ctx.neatBase) {
    const observed = await assertObserved(ctx.neatBase, suite.serviceId, { timeoutMs: 30_000 })
    observedOk = observed.ok
    const after = await fetchDivergences(ctx.neatBase)
    newDivs = newDivergences(state.baselineDivergences, after)
    graphDetail = observed.message
  }

  const testFailures = opts.runTests ? await opts.runTests() : []
  // Scope NEW divergences to fix-ATTRIBUTABLE ones; drop ambient divergences on code the fix never
  // touched (bare's actually-works is journeys-only, so a false divergence would penalize NEAT alone).
  const attributable = state.attributableFiles ?? []
  const attributableNewDivs = attributable.length ? newDivs.filter((d) => attributable.some((f) => d.includes(f))) : newDivs
  const droppedDivs = attributable.length ? newDivs.filter((d) => !attributableNewDivs.includes(d)) : []
  const works = journeyFailures.length === 0 && observedOk && attributableNewDivs.length === 0 && testFailures.length === 0
  return {
    works,
    testFailures,
    journeyFailures,
    newDivergences: attributableNewDivs,
    observedOk,
    detail: `${graphDetail}; journeys ${journeyFailures.length === 0 ? 'ok' : 'failed'}; newDivergences=${attributableNewDivs.length}${droppedDivs.length ? ` (dropped ${droppedDivs.length} ambient)` : ''}`,
  }
}

// The oracle the grader calls (grader.ts ReconQA): journeys + observed + divergence delta.
export class ReconQA implements ReconQAInterface {
  constructor(
    private ctx: TrialContext,
    private state: ReconState,
  ) {}
  async qa(_app: string, _treePath: string): Promise<{ works: boolean; journeyFailures: string[]; newDivergences: string[] }> {
    const a = await reconAssess(this.ctx, this.state)
    return { works: a.works, journeyFailures: a.journeyFailures, newDivergences: a.newDivergences }
  }
}

// The three agent-facing tools (NEAT arms only).
export function buildReconToolDefs(ctx: TrialContext, state: ReconState): ToolDef[] {
  return [
    {
      name: 'recon_qa',
      description:
        "Post-change QA: drive the app's real usage journeys and confirm it still works AND the OBSERVED layer still materializes for the exercised routes AND no NEW declared-vs-observed divergence was introduced. Use after a fix to verify it actually works, not just that unit tests pass.",
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const a = await reconAssess(ctx, state)
        return { content: JSON.stringify({ works: a.works, testFailures: a.testFailures, journeyFailures: a.journeyFailures, newDivergences: a.newDivergences, observedOk: a.observedOk }, null, 1) }
      },
    },
    {
      name: 'recon_flush',
      description:
        'Force a fresh observation window: re-drive the journeys, poll the graph until OBSERVED edges update (fresh lastObserved, spanCount>0), then re-read divergences. Use so you never read stale graph state after a change.',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const f = await doFlush(ctx, state.baselineDivergences)
        return { content: JSON.stringify({ freshAsOf: f.freshAsOf, observed: f.observed, newDivergences: f.newDivergences, journeyFailures: f.journeyFailures }, null, 1) }
      },
    },
    {
      name: 'recon_probe',
      description:
        "Challenge a NEAT claim by observation. Give a claim like 'CVE-X is reachable' or a dep name; recon flushes, drives the path, and reports whether the OBSERVED edge materializes (observed), stays dark (unobserved), or the graph shows divergence (diverged), with evidence.",
      input_schema: { type: 'object', properties: { claim: { type: 'string', description: 'the claim to verify, e.g. "jsonata is reachable"' } }, required: ['claim'], additionalProperties: false },
      run: async (input: any) => {
        const claim = String(input?.claim ?? '')
        const f = await doFlush(ctx, state.baselineDivergences)
        const divHit = f.divergences.find((d) => claim.toLowerCase().includes(d.target.toLowerCase()) || claim.toLowerCase().includes(d.source.toLowerCase()))
        const verdict = divHit ? 'diverged' : f.observed.ok ? 'observed' : 'unobserved'
        return {
          content: JSON.stringify(
            {
              claim,
              verdict,
              evidence: {
                observed: f.observed,
                divergenceHit: divHit ? divergenceKey(divHit) : null,
                journeyFailures: f.journeyFailures,
              },
            },
            null,
            1,
          ),
        }
      },
    },
  ]
}
