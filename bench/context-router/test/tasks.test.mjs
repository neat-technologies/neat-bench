import assert from 'node:assert/strict'
import { existsSync, readFileSync } from 'node:fs'
import { basename, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { loadTasks } from '../eval-router.mjs'
import { RUBRIC } from '../router/rubric.mjs'

const DIR = fileURLToPath(new URL('../tasks/', import.meta.url))
const tasks = loadTasks(DIR)

test('the task set is non-empty and ids are unique', () => {
  assert.ok(tasks.length > 0)
  assert.equal(new Set(tasks.map((t) => t.id)).size, tasks.length)
})

test('every task is well formed against the rubric', () => {
  for (const t of tasks) {
    assert.ok(Object.keys(RUBRIC).includes(t.size), `${t.id}: size ${t.size}`)
    assert.match(t.base_commit, /^[0-9a-f]{40}$/, t.id)
    assert.ok(t.prompt?.trim(), `${t.id}: prompt`)
    assert.ok(Array.isArray(t.gold_files) && t.gold_files.length > 0, `${t.id}: gold_files`)
    assert.ok(existsSync(join(DIR, t.bug_patch)), `${t.id}: missing ${t.bug_patch}`)
    assert.ok(['tests', 'probe'].includes(t.oracle?.type), `${t.id}: oracle`)
  }
})

test('each patch touches exactly the gold files', () => {
  for (const t of tasks) {
    const diff = readFileSync(join(DIR, t.bug_patch), 'utf8')
    const touched = [...diff.matchAll(/^\+\+\+ b\/(.+)$/gm)].map((m) => m[1]).sort()
    assert.deepEqual(touched, [...t.gold_files].sort(), t.id)
  }
})

test('no prompt names the file its fix is in', () => {
  for (const t of tasks) {
    for (const g of t.gold_files) {
      const stem = basename(g).replace(/\.[^.]+$/, '')
      assert.ok(!t.prompt.toLowerCase().includes(stem.toLowerCase()), `${t.id} names ${stem}`)
    }
  }
})
