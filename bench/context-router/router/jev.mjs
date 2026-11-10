// The Jev call. Jev answers two bounded questions about the request: which tier
// (small / medium / full) and whether the fix depends on runtime behaviour. It
// never picks files; the graph does that.
//
// What goes to TypeSafe is built here and nowhere else: the developer's request
// and the graph summary from features.mjs (node ids, types, services, paths,
// scores, counts, intent, incident flag). No file contents, no ask briefing.

import { RUNTIME_INSTRUCTIONS, TIER_CRITERIA, TIER_INSTRUCTIONS } from './rubric.mjs'

// Pinned so a threshold tuned against one release means the same thing later.
export const JEV_MODEL = 'jev-1.13.0'

/** Pure: the exact systemOne request body for these features. */
export function buildJevRequest(features) {
  return {
    model: JEV_MODEL,
    state: {
      request: features.prompt,
      graph: {
        intent: features.intent,
        matchedNodes: features.matches.map(({ id, type, service, path, score }) => ({
          id,
          type,
          ...(service ? { service } : {}),
          ...(path ? { path } : {}),
          score,
        })),
        distinctFiles: features.distinctFiles,
        distinctServices: features.distinctServices,
        incidentSignal: features.incidentSignal,
      },
    },
    // The same objects the SDK's choice() and noul() helpers build.
    questions: {
      tier: { type: 'choice', instructions: TIER_INSTRUCTIONS, criteria: { ...TIER_CRITERIA } },
      needs_runtime: { type: 'noul', instructions: RUNTIME_INSTRUCTIONS },
    },
  }
}

/** A TypeSafe client. The key comes from TYPESAFE_API_KEY unless passed. */
export async function createJevClient(options = {}) {
  const { TypeSafeClient } = await import('@typesafe-ai/sdk')
  return new TypeSafeClient(options)
}

/**
 * Ask Jev once, no retries: a slow answer is a fallback to full, not a wait.
 * The SDK's timeout is per attempt; with retries off it bounds the call.
 */
export async function askJev(client, request, { timeoutMs = 2000 } = {}) {
  const res = await client.systemOne(request, { timeout: timeoutMs, retry: { maxRetries: 0 } })
  const tier = res.answers.tier
  return {
    tier: tier.choice,
    confidence: tier.confidence,
    probabilities: { ...tier.probabilities },
    needsRuntime: res.answers.needs_runtime.noul,
    model: res.model,
    usage: res.usage ?? null,
  }
}
