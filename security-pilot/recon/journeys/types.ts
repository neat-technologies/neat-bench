// Shared journey type for the Recon QA stack, generalized from e2e/brief/load.ts.
// A journey drives a real route/handler so the OBSERVED tier materializes and returns
// whether the app responded as expected (status/shape), not whether NEAT saw it.
export interface JourneyResult {
  ok: boolean
  status?: number
  detail?: string
}
export interface Journey {
  name: string
  run: (base: string) => Promise<JourneyResult>
}

export async function probe(base: string, pathname: string, init?: RequestInit, timeoutMs = 8000): Promise<Response> {
  const ctl = new AbortController()
  const t = setTimeout(() => ctl.abort(), timeoutMs)
  try {
    return await fetch(`${base}${pathname}`, { ...init, signal: ctl.signal })
  } finally {
    clearTimeout(t)
  }
}

// Lenient success, as in load.ts: a response below the given ceiling still emitted a span
// (the point is span-shape coverage, not asserting app correctness here).
export async function okBelow(base: string, pathname: string, ceiling = 500, init?: RequestInit): Promise<JourneyResult> {
  try {
    const r = await probe(base, pathname, init)
    return { ok: r.status < ceiling, status: r.status }
  } catch (e) {
    return { ok: false, detail: (e as Error).message }
  }
}
