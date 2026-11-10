// Recon verifier: a generalized e2e/brief/assertions.ts. Reads the live NEAT graph over the
// daemon REST and asserts the OBSERVED tier for an arbitrary service id (not hard-coded
// brief-api), plus a divergence-delta helper for the "no NEW drift the fix introduced" check.
// The watch daemon serves a single "default" project at flat routes: GET /graph and
// GET /graph/divergences (verified against the live box daemons).

export interface GraphEdge {
  id: string
  source: string
  target: string
  type: string
  provenance: string
  lastObserved?: string
  signal?: { spanCount?: number; errorCount?: number; lastObservedAgeMs?: number }
  confidence?: number
}
export interface Graph {
  nodes: { id: string; type: string; name?: string }[]
  edges: GraphEdge[]
}
export interface Divergence {
  type: string
  source: string
  target: string
  confidence?: number
  reason?: string
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

// A busy daemon re-extracting a large tree (e.g. gitea, 20k+ nodes, when a build/install touches the
// watched checkout) briefly resets connections mid-response. Retry fetch+parse on transient failures
// (ECONNRESET, aborted body, 5xx) with backoff; the daemon IS serving, it is just momentarily busy.
async function fetchJsonRetry(url: string, attempts = 6, perAttemptMs = 120_000): Promise<any> {
  let last: unknown
  for (let i = 0; i < attempts; i++) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(perAttemptMs) })
      if (!r.ok) throw new Error(`GET ${url} -> ${r.status}`)
      return await r.json()
    } catch (e) {
      last = e
      await sleep(1500 * (i + 1))
    }
  }
  throw new Error(`GET ${url} failed after ${attempts} attempts: ${String(last)}`)
}

export async function fetchGraph(neatBase: string): Promise<Graph> {
  return (await fetchJsonRetry(`${neatBase}/graph`)) as Graph
}

export async function fetchDivergences(neatBase: string): Promise<Divergence[]> {
  const j = (await fetchJsonRetry(`${neatBase}/graph/divergences`)) as { divergences?: Divergence[] }
  return j.divergences ?? []
}

export const divergenceKey = (d: Divergence) => `${d.type}:${d.source}->${d.target}`

// Divergences present AFTER that were absent BEFORE = drift the change introduced.
export function newDivergences(before: Divergence[], after: Divergence[]): string[] {
  const had = new Set(before.map(divergenceKey))
  return after.filter((d) => !had.has(divergenceKey(d))).map(divergenceKey)
}

// OBSERVED edges that originate from the service — the service node id, one of its files
// (file-first call-site attribution, assertions.ts §3b), or one of its symbols (symbol-grained
// OBSERVED, e.g. paperless carries symbol:<svc>: edges). All three are "from the service".
export function observedFromService(graph: Graph, serviceId: string): GraphEdge[] {
  const svc = `service:${serviceId}`
  const filePrefix = `file:${serviceId}:`
  const symbolPrefix = `symbol:${serviceId}:`
  return graph.edges.filter(
    (e) => e.provenance === 'OBSERVED' && (e.source === svc || e.source.startsWith(filePrefix) || e.source.startsWith(symbolPrefix)),
  )
}

export interface ObservedVerdict {
  ok: boolean
  nodePresent: boolean
  observedCount: number
  freshCount: number
  message: string
}

// Poll until the service shows a fresh OBSERVED edge (spanCount>0, lastObserved within window),
// the same shape assertions.ts enforces. Generalized to any service id.
export async function assertObserved(
  neatBase: string,
  serviceId: string,
  opts: { timeoutMs?: number; freshnessMs?: number; pollMs?: number } = {},
): Promise<ObservedVerdict> {
  const timeoutMs = opts.timeoutMs ?? 30_000
  const freshnessMs = opts.freshnessMs ?? 60_000
  const pollMs = opts.pollMs ?? 1000
  const deadline = Date.now() + timeoutMs
  let graph: Graph | null = null
  let observed: GraphEdge[] = []

  while (Date.now() < deadline) {
    try {
      graph = await fetchGraph(neatBase)
      observed = observedFromService(graph, serviceId)
      if (observed.length > 0) break
    } catch {
      /* retry */
    }
    await sleep(pollMs)
  }

  if (!graph) return { ok: false, nodePresent: false, observedCount: 0, freshCount: 0, message: `graph unreachable at ${neatBase} within ${timeoutMs}ms` }
  const nodePresent = graph.nodes.some((n) => n.id === `service:${serviceId}`)
  const now = Date.now()
  const fresh = observed.filter((e) => {
    const spanCount = e.signal?.spanCount ?? 0
    if (spanCount <= 0 || !e.lastObserved) return false
    const age = now - Date.parse(e.lastObserved)
    return Number.isFinite(age) && age >= 0 && age <= freshnessMs
  })
  const ok = nodePresent && fresh.length > 0
  return {
    ok,
    nodePresent,
    observedCount: observed.length,
    freshCount: fresh.length,
    message: ok
      ? `service:${serviceId} present; ${observed.length} OBSERVED edge(s), ${fresh.length} fresh`
      : !nodePresent
        ? `service:${serviceId} node absent from graph`
        : observed.length === 0
          ? `no OBSERVED edges from service:${serviceId} within ${timeoutMs}ms (OTLP path silent)`
          : `OBSERVED edges exist but none fresh (spanCount>0, <=${freshnessMs}ms)`,
  }
}
