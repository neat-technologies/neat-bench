// Shared fixtures: daemon responses shaped exactly like the daemon's /graph/ask
// (AskResultSchema) and /search routes, built from the real express graph
// snapshot in fixtures/ so node attributes are the ones a daemon returns.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const REPO = fileURLToPath(new URL('../../../', import.meta.url))
export const GRAPH = JSON.parse(readFileSync(`${REPO}fixtures/express-mongoose.graph.json`, 'utf8'))
export const nodeById = (id) => GRAPH.nodes.find((n) => n.id === id)

const SVC = 'create-nodejs-express-app'
export const fileId = (path) => `file:${SVC}:${path}`

/** An /search response: full node attributes plus a score, as the daemon spreads them. */
export function searchResponse(ids, scores = []) {
  return {
    query: 'q',
    provider: 'embedding',
    matches: ids.map((id, i) => ({ ...nodeById(id), score: scores[i] ?? 0.5 })),
  }
}

/** An /graph/ask response. */
export function askResponse({ intent = 'overview', matched = [], sections = [], answer = 'summary' } = {}) {
  return {
    question: 'q',
    intent,
    matched: matched.map(([nodeId, score, via = 'token']) => ({ nodeId, label: nodeId, via, score })),
    ...(matched[0] ? { primaryNode: matched[0][0], scope: 'node' } : {}),
    sections,
    answer,
    provenance: ['EXTRACTED'],
  }
}

/** A fake fetch serving /graph/ask and /search, recording every call. */
export function fakeDaemon({ ask, search, status = 200 }) {
  const calls = []
  const fetchImpl = async (url, init) => {
    calls.push({ url, headers: init?.headers ?? {} })
    const body = url.includes('/graph/ask') ? ask : search
    return { ok: status < 300, status, json: async () => body }
  }
  return { fetchImpl, calls }
}

/** A fake Jev client returning a fixed answer, or behaving badly on request. */
export function fakeJev({ tier = 'small', confidence = 0.9, needsRuntime = 0.1, mode = 'ok', delayMs = 0 } = {}) {
  const requests = []
  return {
    requests,
    systemOne: (req, options) => {
      requests.push({ req, options })
      if (mode === 'throw') return Promise.reject(Object.assign(new Error('boom'), { name: 'APIConnectionError' }))
      if (mode === 'hang') return new Promise(() => {})
      const res = {
        model: 'jev-1.13.0',
        answers: {
          tier: { type: 'choice', choice: tier, confidence, probabilities: { small: 0, medium: 0, full: 0, [tier]: confidence } },
          needs_runtime: { type: 'noul', noul: needsRuntime },
        },
        usage: { input_tokens: 120, output_tokens: 0 },
      }
      return delayMs ? new Promise((r) => setTimeout(() => r(res), delayMs)) : Promise.resolve(res)
    },
  }
}
