// NodeGoat (OWASP) usage journeys. Express app; routes per server.js/app/routes.
// The vuln paths (marked, swig/marked/mongodb DAOs) ride the tutorial + profile + memos
// routes. Auth-gated routes return 302 to /login unauthenticated, which is still a real span.
import type { Journey } from './types.js'
import { okBelow, probe } from './types.js'

// Graph ServiceNode id is `service:nodegoat` (OBSERVED edges attach here on the live daemon),
// distinct from the dep-manifest name `owasp-nodejs-goat` the security scan reports.
export const serviceId = 'nodegoat'

export const journeys: Journey[] = [
  { name: 'home', run: (b) => okBelow(b, '/') },
  { name: 'tutorial', run: (b) => okBelow(b, '/tutorial') }, // marked render path
  { name: 'login-get', run: (b) => okBelow(b, '/login') },
  {
    name: 'login-post-wrong',
    run: (b) =>
      okBelow(b, '/login', 500, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: 'userName=e2e&password=<redacted>',
      }),
  },
  { name: 'signup-get', run: (b) => okBelow(b, '/signup') },
  { name: 'contributions', run: (b) => okBelow(b, '/contributions') }, // auth-gated -> 302, still a span
  { name: 'memos', run: (b) => okBelow(b, '/memos') },
  {
    name: 'profile-get',
    run: async (b) => {
      const r = await probe(b, '/profile').catch(() => null)
      return r ? { ok: r.status < 500, status: r.status } : { ok: false, detail: 'unreachable' }
    },
  },
]
