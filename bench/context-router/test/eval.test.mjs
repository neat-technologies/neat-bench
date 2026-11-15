import assert from 'node:assert/strict'
import { test } from 'node:test'
import { scoreRow, summarize } from '../eval-router.mjs'

const task = (id, size, gold) => ({ id, size, gold_files: gold })
const decision = (tier, files, candidateFiles, reason = 'jev') => ({
  tier,
  reason,
  files,
  candidateFiles,
  jev: { confidence: 0.9, needsRuntime: 0.1 },
  jevLatencyMs: 100,
})

test('a big task sent to small is counted as the costly mistake', () => {
  const r = scoreRow(task('b1', 'big', ['src/x.js']), decision('small', ['src/x.js'], ['src/x.js']))
  assert.equal(r.expected, 'full')
  assert.equal(r.correct, false)
  assert.equal(r.demoted, true)
})

test('the file half is scored from the graph ranking even when the tier is full', () => {
  const r = scoreRow(task('s1', 'small', ['src/b.js']), decision('full', [], ['src/a.js', 'src/b.js', 'src/c.js'], 'low_confidence'))
  assert.equal(r.routedFilesCoverGold, null)
  assert.equal(r.graphTop2CoversGold, true)
  assert.equal(r.graphTop5CoversGold, true)
})

test('a two-file fix is covered only when both files are named', () => {
  const r = scoreRow(task('m1', 'medium', ['src/a.js', 'src/z.js']), decision('medium', ['src/a.js', 'src/b.js'], ['src/a.js', 'src/b.js']))
  assert.equal(r.routedFilesCoverGold, false)
})

test('summary: accuracy, confusion, demotions, coverage, reasons', () => {
  const rows = [
    scoreRow(task('s1', 'small', ['a']), decision('small', ['a', 'b'], ['a', 'b'])),
    scoreRow(task('s2', 'small', ['c']), decision('full', [], ['a', 'b', 'c'], 'low_confidence')),
    scoreRow(task('m1', 'medium', ['d']), decision('medium', ['d'], ['d'])),
    scoreRow(task('b1', 'big', ['e']), decision('small', ['x'], ['x'])),
  ]
  const s = summarize(rows)
  assert.equal(s.tasks, 4)
  assert.deepEqual(s.bySize, { small: 2, medium: 1, big: 1 })
  assert.equal(s.tierAccuracyPct, 50)
  assert.equal(s.confusion.small.small, 1)
  assert.equal(s.confusion.small.full, 1)
  assert.equal(s.confusion.full.small, 1)
  assert.equal(s.bigSentSmall, 1)
  assert.equal(s.smallRoutedSmallPct, 50)
  assert.equal(s.routedFilesCoverGoldPct, 66.7)
  assert.equal(s.graphTop2CoversGoldPct, 50)
  assert.equal(s.graphTop5CoversGoldPct, 75)
  assert.deepEqual(s.fallbackReasons, { jev: 3, low_confidence: 1 })
})
