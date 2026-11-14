// Gitea usage journeys. Go app. The x/net/html vuln path is markup rendering of untrusted
// content (modules/markup/html*.go) — exercised by rendering a repo's markdown/issue. These
// journeys cover the public HTTP surface incl. a markup-render route; the deep authed
// render-untrusted-markdown journey is hand-mapped before the real run (corpus/gitea.md).
import type { Journey } from './types.js'
import fs from 'node:fs'
import { digest, okBelow, probe } from './types.js'

// The admin login the recipe generated for this trial instance (<checkout>__work/trial-creds).
// The markup API answers 401 without it, which would exercise nothing.
function trialAuth(treePath?: string): Record<string, string> {
  if (!treePath) return {}
  try {
    const pw = fs.readFileSync(`${treePath}__work/trial-creds`, 'utf8').match(/^TRIAL_PW=(.+)$/m)?.[1]
    return pw ? { authorization: `Basic ${Buffer.from(`neat:${pw}`).toString('base64')}` } : {}
  } catch {
    return {}
  }
}

export const serviceId = 'gitea'

export const journeys: Journey[] = [
  { name: 'home', run: (b) => okBelow(b, '/') },
  { name: 'api-version', run: (b) => okBelow(b, '/api/v1/version') },
  { name: 'explore-repos', run: (b) => okBelow(b, '/explore/repos') },
  { name: 'explore-users', run: (b) => okBelow(b, '/explore/users') },
  { name: 'login-page', run: (b) => okBelow(b, '/user/login') },
  {
    name: 'markdown-render',
    // modules/markup path -> x/net/html. The rendered HTML is deterministic, so its digest is
    // compared to baseline: a fix that alters how untrusted markup renders shows up here.
    run: async (b, env) => {
      const r = await probe(b, '/api/v1/markup', {
        method: 'POST',
        headers: { 'content-type': 'application/json', ...trialAuth(env?.treePath) },
        body: JSON.stringify({ Text: '# hi <b>x</b>\n\n<script>alert(1)</script> [a](http://example.invalid) <img src=x onerror=y>', Mode: 'markdown', Context: '' }),
      })
      return { ok: r.status < 500, status: r.status, shape: `html:${digest(await r.text())}` }
    },
  },
]
