// Paperless-ngx usage journeys. Django + DRF. The jinja2 sandbox-escape vuln path is the
// storage-path template render in src/documents/templating/filepath.py, exercised when a
// document is consumed against a storage-path template (needs postgres+redis+auth; hand-map
// the authed document-consume journey before the real run — see corpus/paperless-ngx.md).
import type { Journey } from './types.js'
import { okBelow } from './types.js'

export const serviceId = 'paperless-ngx'

export const journeys: Journey[] = [
  { name: 'root', run: (b) => okBelow(b, '/', 600) }, // 302 -> /accounts/login/ unauthenticated
  { name: 'login-page', run: (b) => okBelow(b, '/accounts/login/') },
  { name: 'api-root', run: (b) => okBelow(b, '/api/', 600) }, // 403/401 still a span
  { name: 'api-documents', run: (b) => okBelow(b, '/api/documents/', 600) },
  { name: 'api-storage-paths', run: (b) => okBelow(b, '/api/storage_paths/', 600) }, // the templating config surface
  { name: 'health', run: (b) => okBelow(b, '/api/status/', 600) },
]
