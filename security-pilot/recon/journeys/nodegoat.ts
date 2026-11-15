// NodeGoat (OWASP) usage journeys. Express app; routes per server.js/app/routes.
// The vuln paths (marked, swig/marked/mongodb DAOs) ride the tutorial + profile + memos
// routes. Auth-gated routes return 302 to /login unauthenticated, which is still a real span.
import fs from 'node:fs'
import path from 'node:path'
import type { Journey } from './types.js'
import { okBelow, probe } from './types.js'

// The seeded user1 login, read from the seed file the app ships (artifacts/db-reset.js).
function seededLogin(treePath?: string): string | null {
  if (!treePath) return null
  try {
    const seed = fs.readFileSync(path.join(treePath, 'artifacts', 'db-reset.js'), 'utf8')
    return seed.match(/"userName":\s*"user1"[\s\S]*?"password":\s*"([^"]+)"/)?.[1] ?? null
  } catch {
    return null
  }
}

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
    // Signed-in walk: log in as the seeded user, read every gated page, write a contribution.
    // Unauthenticated journeys only ever see the 302 to /login, so this is the one that exercises
    // the session, body-parsing, templating and DAO paths the dependency fixes touch.
    name: 'authed-session',
    run: async (b, env) => {
      const pw = seededLogin(env?.treePath)
      if (!pw) return { ok: false, detail: 'seeded login not readable from artifacts/db-reset.js' }
      const form = { 'content-type': 'application/x-www-form-urlencoded' }
      const login = await probe(b, '/login', {
        method: 'POST',
        redirect: 'manual',
        headers: form,
        body: new URLSearchParams({ userName: 'user1', password: pw }).toString(),
      })
      const cookie = login.headers.getSetCookie().map((c) => c.split(';')[0]).join('; ')
      const steps = [`login:${login.status}`]
      let allOk = login.status === 302 && cookie.length > 0
      for (const p of ['/dashboard', '/profile', '/contributions', '/memos', '/allocations/2']) {
        const r = await probe(b, p, { headers: { cookie }, redirect: 'manual' })
        steps.push(`${p}:${r.status}`)
        allOk &&= r.status === 200
      }
      const write = await probe(b, '/contributions', {
        method: 'POST',
        redirect: 'manual',
        headers: { ...form, cookie },
        body: 'preTax=2&afterTax=2&roth=2',
      })
      steps.push(`post-contributions:${write.status}`)
      allOk &&= write.status === 200
      return { ok: allOk, status: login.status, shape: steps.join(','), detail: allOk ? undefined : steps.join(',') }
    },
  },
  {
    name: 'profile-get',
    run: async (b) => {
      const r = await probe(b, '/profile', { redirect: 'manual' }).catch(() => null)
      return r ? { ok: r.status < 500, status: r.status } : { ok: false, detail: 'unreachable' }
    },
  },
]
