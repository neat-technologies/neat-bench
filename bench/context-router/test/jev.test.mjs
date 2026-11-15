import assert from 'node:assert/strict'
import { test } from 'node:test'
import { TypeSafeClient } from '@typesafe-ai/sdk'
import { extractFeatures } from '../router/features.mjs'
import { askJev, buildJevRequest, JEV_MODEL } from '../router/jev.mjs'
import { askResponse, fileId, nodeById, searchResponse } from './helpers.mjs'

const SERVICE = 'service:create-nodejs-express-app'

// Features built from real node attributes, including a service node that
// carries package dependencies, an owner and a connection target, and an ask
// briefing. None of that may reach TypeSafe.
function realFeatures() {
  return extractFeatures({
    prompt: 'GET /v1/users/:id returns 400 for valid ids',
    ask: askResponse({
      intent: 'overview',
      matched: [[fileId('src/validations/custom.validation.js'), 0.7]],
      sections: [{ heading: 'Local context', facts: [{ text: 'BRIEFING-ONLY-FACT' }] }],
      answer: 'BRIEFING-ONLY-ANSWER',
    }),
    search: searchResponse([SERVICE, fileId('src/validations/custom.validation.js')], [0.6, 0.9]),
  })
}

test('the Jev request carries the prompt and an allowlisted graph summary only', () => {
  const req = buildJevRequest(realFeatures())
  assert.equal(req.model, JEV_MODEL)
  assert.deepEqual(Object.keys(req.state), ['request', 'graph'])
  assert.deepEqual(Object.keys(req.state.graph).sort(), ['distinctFiles', 'distinctServices', 'incidentSignal', 'intent', 'matchedNodes'])
  for (const n of req.state.graph.matchedNodes) {
    for (const k of Object.keys(n)) assert.ok(['id', 'type', 'service', 'path', 'score'].includes(k), `unexpected key ${k}`)
  }

  const sent = JSON.stringify(req)
  const svc = nodeById(SERVICE)
  for (const leaked of [svc.owner, svc.dbConnectionTarget, 'bcryptjs', 'BRIEFING-ONLY-FACT', 'BRIEFING-ONLY-ANSWER']) {
    assert.ok(!sent.includes(leaked), 'a non-allowlisted value reached the Jev request')
  }
})

test('questions are the shapes the SDK helpers build: a tier choice and a runtime yes/no', () => {
  const { questions } = buildJevRequest(realFeatures())
  assert.equal(questions.tier.type, 'choice')
  assert.deepEqual(Object.keys(questions.tier.criteria), ['small', 'medium', 'full'])
  assert.equal(questions.needs_runtime.type, 'noul')
})

test('the real SDK accepts the request and askJev reads its answer (no network)', async () => {
  let posted = null
  const fetch = async (url, init) => {
    posted = { url, body: JSON.parse(init.body), auth: new Headers(init.headers).get('authorization') }
    const body = {
      model: 'jev-1.13.0',
      answers: {
        tier: { type: 'choice', choice: 'small', confidence: 0.83, probabilities: { small: 0.83, medium: 0.12, full: 0.05 } },
        needs_runtime: { type: 'noul', noul: 0.07 },
      },
      usage: { input_tokens: 210, output_tokens: 0 },
    }
    return new Response(JSON.stringify(body), { status: 200, headers: { 'content-type': 'application/json' } })
  }
  const client = new TypeSafeClient({ apiKey: 'test-key', fetch, compression: false, baseURL: 'https://typesafe.invalid' })
  const req = buildJevRequest(realFeatures())
  const out = await askJev(client, req, { timeoutMs: 1500 })

  assert.equal(posted.url, 'https://typesafe.invalid/v1/systemone')
  assert.equal(posted.auth, 'Bearer test-key')
  assert.equal(posted.body.model, 'jev-1.13.0')
  assert.deepEqual(posted.body.state, JSON.parse(JSON.stringify(req.state)))
  assert.deepEqual(out, {
    tier: 'small',
    confidence: 0.83,
    probabilities: { small: 0.83, medium: 0.12, full: 0.05 },
    needsRuntime: 0.07,
    model: 'jev-1.13.0',
    usage: { input_tokens: 210, output_tokens: 0 },
  })
})
