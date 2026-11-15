// Paperless-ngx usage journeys. Django + DRF. The jinja2 sandbox-escape vuln path is the
// storage-path template render in src/documents/templating/filepath.py, exercised when a
// document is consumed against a storage-path template (needs postgres+redis+auth; hand-map
// the authed document-consume journey before the real run — see corpus/paperless-ngx.md).
import type { Journey } from './types.js'
import { digest, okBelow, probe } from './types.js'

// The admin account the bench recipe creates for the trial instance.
const AUTH = { authorization: `Basic ${Buffer.from('admin:changeme').toString('base64')}` }

export const serviceId = 'paperless-ngx'

export const journeys: Journey[] = [
  { name: 'root', run: (b) => okBelow(b, '/', 600) }, // 302 -> /accounts/login/ unauthenticated
  { name: 'login-page', run: (b) => okBelow(b, '/accounts/login/') },
  { name: 'api-root', run: (b) => okBelow(b, '/api/', 600) }, // 403/401 still a span
  { name: 'api-documents', run: (b) => okBelow(b, '/api/documents/', 600) },
  { name: 'api-storage-paths', run: (b) => okBelow(b, '/api/storage_paths/', 600) }, // the templating config surface
  { name: 'health', run: (b) => okBelow(b, '/api/status/', 600) },
  {
    // Signed-in API read: the document list must answer 200 with a count.
    name: 'documents-authed',
    run: async (b) => {
      const r = await probe(b, '/api/documents/', { headers: AUTH })
      const body = (await r.json().catch(() => null)) as { count?: number } | null
      const ok = r.status === 200 && typeof body?.count === 'number'
      return { ok, status: r.status, shape: ok ? 'count' : 'no-count' }
    },
  },
  {
    // The jinja2 path itself: render a storage-path template against a consumed document. The
    // rendered result is deterministic for a given document, so its digest is compared to baseline.
    name: 'storage-path-render',
    run: async (b) => {
      const list = await probe(b, '/api/documents/?page_size=1&ordering=id', { headers: AUTH })
      const docs = (await list.json().catch(() => null)) as { results?: { id: number }[] } | null
      const id = docs?.results?.[0]?.id
      if (id === undefined) return { ok: list.status < 500, status: list.status, shape: 'no-document' }
      const r = await probe(b, '/api/storage_paths/test/', {
        method: 'POST',
        headers: { ...AUTH, 'content-type': 'application/json' },
        body: JSON.stringify({ document: id, path: '{{ title }}/{{ created_year }}' }),
      })
      return { ok: r.status < 500, status: r.status, shape: `render:${digest(await r.text())}` }
    },
  },
]
