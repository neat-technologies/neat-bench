// Uptime-Kuma usage journeys. Primarily a socket.io app with an Express shell; the HTTP
// surface here materializes OBSERVED for the express + socket.io handshake path. The jsonata
// RCE vuln path lives in a user-configured jsonPath monitor evaluated over socket.io; driving
// it end-to-end needs an authed setup + a created monitor (hand-map before the real run — see
// corpus/uptime-kuma.md). These journeys cover the reachable HTTP routes.
import type { Journey } from './types.js'
import { okBelow } from './types.js'

export const serviceId = 'uptime-kuma'

export const journeys: Journey[] = [
  { name: 'dashboard', run: (b) => okBelow(b, '/') },
  { name: 'entry-page', run: (b) => okBelow(b, '/api/entry-page') },
  { name: 'metrics', run: (b) => okBelow(b, '/metrics', 500) }, // 401 w/o token is still a span
  { name: 'badge-missing', run: (b) => okBelow(b, '/api/badge/1/status', 600) },
  { name: 'status-page-list', run: (b) => okBelow(b, '/api/status-page/list', 600) },
  // TODO(hand-map, corpus): authed socket.io journey that creates a jsonPath monitor and triggers
  // jsonata(monitor.jsonPath) — the actual vuln path. Required for not-degenerate/poke-holes.
]
