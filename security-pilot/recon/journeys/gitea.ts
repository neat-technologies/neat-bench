// Gitea usage journeys. Go app. The x/net/html vuln path is markup rendering of untrusted
// content (modules/markup/html*.go) — exercised by rendering a repo's markdown/issue. These
// journeys cover the public HTTP surface incl. a markup-render route; the deep authed
// render-untrusted-markdown journey is hand-mapped before the real run (corpus/gitea.md).
import type { Journey } from './types.js'
import { okBelow } from './types.js'

export const serviceId = 'gitea'

export const journeys: Journey[] = [
  { name: 'home', run: (b) => okBelow(b, '/') },
  { name: 'api-version', run: (b) => okBelow(b, '/api/v1/version') },
  { name: 'explore-repos', run: (b) => okBelow(b, '/explore/repos') },
  { name: 'explore-users', run: (b) => okBelow(b, '/explore/users') },
  { name: 'login-page', run: (b) => okBelow(b, '/user/login') },
  {
    name: 'markdown-render',
    run: (b) =>
      okBelow(b, '/api/v1/markup', 600, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ Text: '# hi <b>x</b>', Mode: 'markdown', Context: '' }),
      }), // modules/markup path -> x/net/html
  },
]
