// Journey registry, keyed by corpus app id. One suite per target (SPEC: journeys/ one module
// per target). Each suite drives real routes so OBSERVED materializes; the grader + recon_qa
// run the suite and read the graph back.
import type { Journey, JourneyEnv } from './types.js'
import * as nodegoat from './nodegoat.js'
import * as uptimeKuma from './uptime-kuma.js'
import * as paperless from './paperless-ngx.js'
import * as gitea from './gitea.js'

export interface JourneySuite {
  app: string
  serviceId: string
  journeys: Journey[]
}

const SUITES: Record<string, JourneySuite> = {
  nodegoat: { app: 'nodegoat', serviceId: nodegoat.serviceId, journeys: nodegoat.journeys },
  'uptime-kuma': { app: 'uptime-kuma', serviceId: uptimeKuma.serviceId, journeys: uptimeKuma.journeys },
  'paperless-ngx': { app: 'paperless-ngx', serviceId: paperless.serviceId, journeys: paperless.journeys },
  gitea: { app: 'gitea', serviceId: gitea.serviceId, journeys: gitea.journeys },
}

export function getSuite(app: string): JourneySuite {
  const s = SUITES[app]
  if (!s) throw new Error(`no journey suite for app '${app}' (have: ${Object.keys(SUITES).join(', ')})`)
  return s
}

// Drive the suite N times (default 1 pass of each journey here; the oracle sets repetition).
export async function driveJourneys(
  suite: JourneySuite,
  base: string,
  passes = 3,
  jitterMs = 40,
  env: JourneyEnv = {},
): Promise<{ failures: string[]; ran: number; signatures: Record<string, string[]> }> {
  const failures: string[] = []
  // Per journey, every distinct answer seen across the passes. One entry = the journey is stable.
  const seen: Record<string, Set<string>> = {}
  const note = (name: string, sig: string) => (seen[name] ??= new Set()).add(sig)
  let ran = 0
  for (let i = 0; i < passes; i++) {
    for (const j of suite.journeys) {
      ran++
      try {
        const r = await j.run(base, env)
        note(j.name, `${r.status ?? 'no-response'}${r.shape ? ` ${r.shape}` : ''}`)
        if (!r.ok) failures.push(`${j.name}${r.status ? ` (status ${r.status})` : ''}${r.detail ? ` ${r.detail}` : ''}`)
      } catch (e) {
        note(j.name, 'threw')
        failures.push(`${j.name} threw: ${(e as Error).message}`)
      }
      await new Promise((r) => setTimeout(r, jitterMs + Math.floor(Math.random() * jitterMs)))
    }
  }
  // Dedup failures across passes.
  const signatures: Record<string, string[]> = {}
  for (const [name, sigs] of Object.entries(seen)) signatures[name] = [...sigs].sort()
  return { failures: [...new Set(failures)], ran, signatures }
}
