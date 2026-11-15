// What the request points at, read from a running NEAT daemon over its public
// REST routes. Nothing here imports the engine: the daemon's own `ask` route
// does the entity resolution (exact id, token overlap, embeddings) and `/search`
// widens it with the search index when one exists.
//
// Every field that leaves this module is on an allowlist. Graph nodes carry
// other attributes (package dependencies, owners, connection targets, and on
// richer graphs source-derived detail); none of that is copied. The router only
// ever sees node ids, types, services, paths and scores.

export const SEARCH_LIMIT = 8
export const MAX_MATCHES = 5

const enc = encodeURIComponent

/**
 * Parse a NEAT node id into its kind, service and path where the id carries
 * them: `file:<service>:<relPath>`, `symbol:<service>:<relPath>#<qualname>`,
 * `service:<name>`. Anything else keeps only its kind.
 */
export function parseNodeId(id) {
  const kind = id.includes(':') ? id.slice(0, id.indexOf(':')) : 'unknown'
  const rest = id.slice(kind.length + 1)
  if (kind === 'file' || kind === 'symbol') {
    const sep = rest.indexOf(':')
    if (sep === -1) return { kind }
    const service = rest.slice(0, sep)
    const tail = rest.slice(sep + 1)
    const path = kind === 'symbol' ? tail.split('#')[0] : tail
    return { kind, service, path }
  }
  if (kind === 'service') return { kind, service: rest }
  return { kind }
}

function pick(node) {
  const parsed = parseNodeId(String(node.id))
  const out = { id: String(node.id), type: typeof node.type === 'string' ? node.type : parsed.kind }
  const service = typeof node.service === 'string' ? node.service : parsed.service
  const path = typeof node.path === 'string' && node.path ? node.path : parsed.path
  if (service) out.service = service
  if (path) out.path = path
  out.score = Number.isFinite(node.score) ? Math.round(node.score * 1000) / 1000 : 0
  if (node.via) out.via = String(node.via)
  return out
}

/** Merge ask's resolved entities and search matches into one ranked, deduped list. */
export function mergeMatches(ask, search) {
  const byId = new Map()
  const add = (node) => {
    if (!node || node.id === undefined) return
    const m = pick(node)
    const prev = byId.get(m.id)
    if (!prev || m.score > prev.score) byId.set(m.id, { ...prev, ...m })
  }
  for (const m of ask?.matched ?? []) add({ id: m.nodeId, score: m.score, via: m.via })
  for (const m of search?.matches ?? []) add(m)
  return [...byId.values()].sort((a, b) => b.score - a.score)
}

/** Distinct values in rank order. */
const distinct = (xs) => [...new Set(xs.filter(Boolean))]

/**
 * Whether the graph has a live incident signal for this request. `ask` adds an
 * incidents or root-cause section with facts when the incident store has
 * something on the matched node; that's the signal. It is a heuristic and the
 * README says so.
 */
export function incidentSignal(ask) {
  return (ask?.sections ?? []).some(
    (s) => /incident|root cause/i.test(s.heading ?? '') && (s.facts ?? []).length > 0,
  )
}

/** A short plain-text briefing from `ask`'s answer, for the medium tier only. */
export function briefingFrom(ask, maxFacts = 6) {
  if (!ask?.answer) return null
  const lines = [ask.answer]
  const first = (ask.sections ?? []).find((s) => (s.facts ?? []).length > 0)
  if (first) {
    lines.push(`${first.heading}:`)
    for (const f of first.facts.slice(0, maxFacts)) lines.push(`- ${f.text}`)
  }
  return lines.join('\n')
}

/** Pure: turn the two daemon responses into the router's features. */
export function extractFeatures({ prompt, ask, search }) {
  const all = mergeMatches(ask, search)
  const matches = all.slice(0, MAX_MATCHES)
  const files = distinct(all.map((m) => m.path))
  return {
    prompt,
    intent: typeof ask?.intent === 'string' ? ask.intent : null,
    matches,
    files,
    distinctFiles: files.length,
    distinctServices: distinct(all.map((m) => m.service)).length,
    incidentSignal: incidentSignal(ask),
    briefing: briefingFrom(ask),
  }
}

/**
 * Read the daemon. `project` selects the `/projects/:project` mount; `token`
 * is the daemon bearer if it has one. Throws on any non-2xx so the caller can
 * fall back to full.
 */
export async function fetchFeatures({
  prompt,
  daemonUrl,
  project,
  token,
  fetchImpl = globalThis.fetch,
  timeoutMs = 3000,
}) {
  const base = daemonUrl.replace(/\/+$/, '') + (project ? `/projects/${enc(project)}` : '')
  const headers = token ? { authorization: `Bearer ${token}` } : {}
  const getJson = async (url) => {
    const res = await fetchImpl(url, { headers, signal: AbortSignal.timeout(timeoutMs) })
    if (!res.ok) throw new Error(`daemon ${res.status} for ${url.replace(base, '')}`)
    return res.json()
  }
  const [ask, search] = await Promise.all([
    getJson(`${base}/graph/ask?q=${enc(prompt)}`),
    getJson(`${base}/search?q=${enc(prompt)}&limit=${SEARCH_LIMIT}`),
  ])
  return extractFeatures({ prompt, ask, search })
}
