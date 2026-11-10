import assert from 'node:assert/strict'
import { test } from 'node:test'
import { decide, route } from '../router/route.mjs'
import { renderNote } from '../router/render.mjs'

const features = {
  prompt: 'p',
  intent: 'overview',
  matches: [],
  files: ['src/a.js', 'src/b.js', 'src/c.js', 'src/d.js', 'src/e.js', 'src/f.js'],
  distinctFiles: 6,
  distinctServices: 1,
  incidentSignal: false,
  briefing: 'graph briefing',
}
const jev = (over = {}) => ({ tier: 'small', confidence: 0.9, needsRuntime: 0.1, ...over })

test('a confident small answer gives at most two files and no briefing', () => {
  const d = decide(features, jev())
  assert.equal(d.tier, 'small')
  assert.deepEqual(d.files, ['src/a.js', 'src/b.js'])
  assert.equal(d.briefing, null)
})

test('a confident medium answer gives at most five files and the briefing', () => {
  const d = decide(features, jev({ tier: 'medium' }))
  assert.equal(d.tier, 'medium')
  assert.equal(d.files.length, 5)
  assert.equal(d.briefing, 'graph briefing')
})

test('every uncertain path falls back to full', () => {
  const cases = [
    [null, features, 'jev_unavailable'],
    [jev({ confidence: 0.69 }), features, 'low_confidence'],
    [jev({ confidence: undefined }), features, 'low_confidence'],
    [jev({ needsRuntime: 0.5 }), features, 'needs_runtime'],
    [jev({ needsRuntime: Number.NaN }), features, 'needs_runtime'],
    [jev({ tier: 'full' }), features, 'jev_full'],
    [jev({ tier: 'something-else' }), features, 'jev_full'],
    [jev(), { ...features, files: [] }, 'no_files'],
    [jev(), null, 'features_unavailable'],
  ]
  for (const [answer, f, reason] of cases) {
    const d = decide(f, answer)
    assert.equal(d.tier, 'full', reason)
    assert.equal(d.reason, reason)
    assert.deepEqual(d.files, [])
  }
})

test('route falls back to full when Jev throws, and records why', async () => {
  const client = { systemOne: () => Promise.reject(Object.assign(new Error('x'), { name: 'APIConnectionError' })) }
  const r = await route({ prompt: 'p', getFeatures: async () => features, jevClient: client })
  assert.equal(r.tier, 'full')
  assert.equal(r.reason, 'jev_unavailable')
  assert.equal(r.jevError, 'APIConnectionError')
})

test('route falls back to full when Jev does not answer in time', async () => {
  const client = { systemOne: () => new Promise(() => {}) }
  const r = await route({ prompt: 'p', getFeatures: async () => features, jevClient: client, opts: { jevTimeoutMs: 50 } })
  assert.equal(r.tier, 'full')
  assert.equal(r.jevError, 'JevTimeout')
  assert.ok(r.jevLatencyMs < 1000)
})

test('route falls back to full when the daemon cannot be read', async () => {
  const client = { systemOne: () => assert.fail('Jev must not be called without features') }
  const r = await route({ prompt: 'p', getFeatures: async () => { throw new Error('daemon 503') }, jevClient: client })
  assert.equal(r.tier, 'full')
  assert.equal(r.reason, 'features_unavailable')
  assert.equal(r.featuresError, 'daemon 503')
})

test('route passes the per-call timeout to the SDK with retries off', async () => {
  let seen = null
  const client = {
    systemOne: (req, options) => {
      seen = options
      return Promise.resolve({ model: 'jev-1.13.0', answers: { tier: { choice: 'small', confidence: 0.95, probabilities: {} }, needs_runtime: { noul: 0.02 } } })
    },
  }
  const r = await route({ prompt: 'p', getFeatures: async () => features, jevClient: client })
  assert.equal(r.tier, 'small')
  assert.deepEqual(seen, { timeout: 2000, retry: { maxRetries: 0 } })
})

test('the note names the files and never says how they were chosen', () => {
  const note = renderNote({ files: ['src/a.js', 'src/b.js'] })
  assert.match(note, /^Start here/)
  assert.match(note, /- src\/a\.js\n- src\/b\.js/)
  assert.doesNotMatch(note, /oracle|jev|router|gold/i)
  assert.equal(renderNote({ files: [] }), '')
  assert.match(renderNote({ files: ['src/a.js'], briefing: 'b' }), /From NEAT's graph:\nb/)
})
