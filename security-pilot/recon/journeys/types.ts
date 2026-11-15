// Shared journey type for the Recon QA stack, generalized from e2e/brief/load.ts.
// A journey drives a real route/handler so the OBSERVED tier materializes and returns
// whether the app responded as expected (status/shape), not whether NEAT saw it.
export interface JourneyResult {
  ok: boolean
  status?: number
  detail?: string
  // What the app actually answered, in a form that is stable run to run (a status chain, a short
  // digest of a deterministic body). Compared against the same journey's baseline: a fix that
  // changes it changed the app's behavior.
  shape?: string
}
// What a journey may read besides the base URL. treePath is the app checkout (for seed data the
// app itself ships, such as a seeded test login).
export interface JourneyEnv {
  treePath?: string
}
export interface Journey {
  name: string
  run: (base: string, env?: JourneyEnv) => Promise<JourneyResult>
}

export function digest(text: string): string {
  let h = 0x811c9dc5
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i)
    h = Math.imul(h, 0x01000193) >>> 0
  }
  return h.toString(16).padStart(8, '0')
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
    // Redirects are not followed: the journey records what this route answered, not the page it
    // bounced to (an auth-gated route answers 302, and that is the fact worth comparing to baseline).
    const r = await probe(base, pathname, { redirect: 'manual', ...init })
    return { ok: r.status < ceiling, status: r.status }
  } catch (e) {
    return { ok: false, detail: (e as Error).message }
  }
}
