import assert from 'node:assert/strict'
import { test } from 'node:test'
import { extractFeatures, fetchFeatures, incidentSignal, parseNodeId } from '../router/features.mjs'
import { askResponse, fakeDaemon, fileId, searchResponse } from './helpers.mjs'

test('parseNodeId reads kind, service and path from NEAT ids', () => {
  assert.deepEqual(parseNodeId('file:svc:src/a/b.js'), { kind: 'file', service: 'svc', path: 'src/a/b.js' })
  assert.deepEqual(parseNodeId('symbol:svc:src/pay.js#charge'), { kind: 'symbol', service: 'svc', path: 'src/pay.js' })
  assert.deepEqual(parseNodeId('service:checkout'), { kind: 'service', service: 'checkout' })
  assert.deepEqual(parseNodeId('database:mongodb'), { kind: 'database' })
})

test('ask matches and search matches merge, dedupe by id and rank by score', () => {
  const a = fileId('src/services/user.service.js')
  const b = fileId('src/services/auth.service.js')
  const c = fileId('src/routes/v1/auth.route.js')
  const f = extractFeatures({
    prompt: 'login returns 401',
    ask: askResponse({ intent: 'overview', matched: [[a, 0.6], [b, 0.4]] }),
    search: searchResponse([b, c], [0.9, 0.3]),
  })
  assert.deepEqual(f.matches.map((m) => m.id), [b, a, c])
  assert.deepEqual(f.files, ['src/services/auth.service.js', 'src/services/user.service.js', 'src/routes/v1/auth.route.js'])
  assert.equal(f.distinctFiles, 3)
  assert.equal(f.distinctServices, 1)
  assert.equal(f.intent, 'overview')
})

test('matches with no file (a service, a database) count as services but add no files', () => {
  const f = extractFeatures({
    prompt: 'p',
    ask: askResponse({ matched: [['service:create-nodejs-express-app', 0.8, 'id']] }),
    search: searchResponse([]),
  })
  assert.deepEqual(f.files, [])
  assert.equal(f.distinctServices, 1)
})

test('incident signal comes from an incident or root-cause section with facts', () => {
  assert.equal(incidentSignal(askResponse({ sections: [{ heading: 'Recent incidents', facts: [{ text: 'x' }] }] })), true)
  assert.equal(incidentSignal(askResponse({ sections: [{ heading: 'Root cause', facts: [] }] })), false)
  assert.equal(incidentSignal(askResponse({ sections: [{ heading: 'Dependencies', facts: [{ text: 'x' }] }] })), false)
})

test('fetchFeatures hits the project mount with the bearer and asks for a bounded search', async () => {
  const d = fakeDaemon({ ask: askResponse(), search: searchResponse([]) })
  await fetchFeatures({ prompt: 'fix the login', daemonUrl: 'http://127.0.0.1:8090/', project: 'shop', token: 't0k', fetchImpl: d.fetchImpl })
  const urls = d.calls.map((c) => c.url).sort()
  assert.deepEqual(urls, [
    'http://127.0.0.1:8090/projects/shop/graph/ask?q=fix%20the%20login',
    'http://127.0.0.1:8090/projects/shop/search?q=fix%20the%20login&limit=8',
  ])
  for (const c of d.calls) assert.equal(c.headers.authorization, 'Bearer t0k')
})

test('fetchFeatures throws on a daemon error so the router can fall back', async () => {
  const d = fakeDaemon({ ask: {}, search: {}, status: 503 })
  await assert.rejects(fetchFeatures({ prompt: 'p', daemonUrl: 'http://x', fetchImpl: d.fetchImpl }), /daemon 503/)
})
