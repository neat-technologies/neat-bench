// Journey registry, keyed by corpus app id. One suite per target (SPEC: journeys/ one module
// per target). Each suite drives real routes so OBSERVED materializes; the grader + recon_qa
// run the suite and read the graph back.
import type { Journey } from './types.js'
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
): Promise<{ failures: string[]; ran: number }> {
  const failures: string[] = []
  let ran = 0
  for (let i = 0; i < passes; i++) {
    for (const j of suite.journeys) {
      ran++
      try {
        const r = await j.run(base)
        if (!r.ok) failures.push(`${j.name}${r.status ? ` (status ${r.status})` : ''}${r.detail ? ` ${r.detail}` : ''}`)
      } catch (e) {
        failures.push(`${j.name} threw: ${(e as Error).message}`)
      }
      await new Promise((r) => setTimeout(r, jitterMs + Math.floor(Math.random() * jitterMs)))
    }
  }
  // Dedup failures across passes.
  return { failures: [...new Set(failures)], ran }
}
