// The routing decision. Every path that isn't a confident small or medium ends
// at full, which is exactly today's behaviour: the router can only take
// context away when it is sure, never add risk when it isn't.

import { askJev, buildJevRequest } from './jev.mjs'

// Proposed values. They are fixed in the pre-registration before a scored run;
// changing them afterwards makes that run a development result.
export const DEFAULTS = Object.freeze({
  confidenceThreshold: 0.7,
  runtimeThreshold: 0.5,
  jevTimeoutMs: 2000,
  smallFiles: 2,
  mediumFiles: 5,
})

const full = (reason, extra = {}) => ({ tier: 'full', reason, files: [], briefing: null, ...extra })

/** Pure: features + Jev's answer (or null) → the tier and what it carries. */
export function decide(features, jev, opts = {}) {
  const o = { ...DEFAULTS, ...opts }
  if (!features) return full('features_unavailable')
  if (!jev) return full('jev_unavailable')
  const scores = { confidence: jev.confidence, needsRuntime: jev.needsRuntime }
  if (!(jev.needsRuntime < o.runtimeThreshold)) return full('needs_runtime', scores)
  if (!(jev.confidence >= o.confidenceThreshold)) return full('low_confidence', scores)
  if (jev.tier !== 'small' && jev.tier !== 'medium') return full('jev_full', scores)
  const files = features.files.slice(0, jev.tier === 'small' ? o.smallFiles : o.mediumFiles)
  if (files.length === 0) return full('no_files', scores)
  return {
    tier: jev.tier,
    reason: 'jev',
    files,
    briefing: jev.tier === 'medium' ? features.briefing : null,
    ...scores,
  }
}

// A backstop above the SDK's own per-attempt timeout. The timer stays referenced
// so a hung call still reaches the fallback; it is cleared once the race settles.
function withTimeout(promise, ms) {
  let timer
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(Object.assign(new Error('jev timeout'), { name: 'JevTimeout' })), ms)
  })
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer))
}

/**
 * Route one request end to end. `getFeatures` reads the daemon; `jevClient`
 * is a TypeSafe client (or a fake in tests). Never throws: any failure is a
 * route to full with the reason recorded.
 */
export async function route({ prompt, getFeatures, jevClient, opts = {} }) {
  const o = { ...DEFAULTS, ...opts }
  const t0 = performance.now()
  let features = null
  let featuresError = null
  try {
    features = await getFeatures(prompt)
  } catch (e) {
    featuresError = e?.message ?? String(e)
  }
  if (!features) {
    return { ...full('features_unavailable'), featuresError, latencyMs: Math.round(performance.now() - t0) }
  }

  const jevRequest = buildJevRequest(features)
  let jev = null
  let jevError = null
  const tj = performance.now()
  try {
    jev = await withTimeout(askJev(jevClient, jevRequest, { timeoutMs: o.jevTimeoutMs }), o.jevTimeoutMs + 250)
  } catch (e) {
    jevError = e?.name ?? 'Error'
  }
  const jevLatencyMs = Math.round(performance.now() - tj)

  return {
    ...decide(features, jev, o),
    // The graph's own ranking, whatever the tier: lets the eval score the
    // "which files" half separately from Jev's "how much" half.
    candidateFiles: features.files.slice(0, o.mediumFiles),
    jev,
    jevError,
    jevLatencyMs,
    latencyMs: Math.round(performance.now() - t0),
    thresholds: { confidence: o.confidenceThreshold, runtime: o.runtimeThreshold },
    jevRequest,
  }
}
