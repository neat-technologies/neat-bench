import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'
import { neatBytes } from '../arms/neat-bytes.mjs'
import { renderNote } from '../router/render.mjs'

const CR = fileURLToPath(new URL('../', import.meta.url))
const REPO = fileURLToPath(new URL('../../../', import.meta.url))
const RUN_ARM = join(REPO, 'harness/arms/run-arm.sh')
const TASK = join(CR, 'test/fixtures/task.json')

// A stand-in claude-skill dir. GRAPH_FIRST.md ends in newlines on purpose:
// `$(cat ...)` strips them and the full arm must match that exactly.
const SKILL = mkdtempSync(join(tmpdir(), 'skill-'))
mkdirSync(join(SKILL, 'hooks'))
writeFileSync(join(SKILL, 'GRAPH_FIRST.md'), '# Graph first\n\nAsk NEAT before you grep.\n\n\n')

function dryRun(arm, extra = []) {
  const out = mkdtempSync(join(tmpdir(), `arm-${arm}-`))
  const r = spawnSync('bash', [join(CR, 'arms/run.sh'), TASK, arm, '1', '--out', out, '--dry-run', ...extra], {
    env: { ...process.env, SKILL_DIR: SKILL, NEAT_MCP_BIN: '/opt/neat/mcp.cjs', REST: '8090' },
    encoding: 'utf8',
  })
  assert.equal(r.status, 0, r.stderr)
  const argv = JSON.parse(readFileSync(join(out, 'cmd.json'), 'utf8')).argv
  const flag = (name) => (argv.includes(name) ? argv[argv.indexOf(name) + 1] : undefined)
  return { out, argv, flag }
}

// What the frozen harness itself builds, evaluated from its own source lines.
function harness(snippet) {
  return execFileSync('bash', ['-c', snippet], { encoding: 'utf8', env: { ...process.env, RUN_ARM, skill: SKILL } })
}
const harnessHook = () =>
  harness(`eval "$(grep -E '^[[:space:]]*local hook_json=' "$RUN_ARM" | sed -E 's/^[[:space:]]*local //')"; printf %s "$hook_json"`)
const harnessAppend = () => harness(`printf %s "$(cat "$skill/GRAPH_FIRST.md" 2>/dev/null)"`)
const harnessAllow = () =>
  harness(
    `eval "$(grep -E '^NEAT_TOOLS_ALLOW=' "$RUN_ARM")"; eval "$(grep -E '^[[:space:]]*local allow="Read' "$RUN_ARM" | sed -E 's/^[[:space:]]*local //')"; printf %s "$allow,$NEAT_TOOLS_ALLOW"`,
  )

test('full reproduces run-arm.sh WITH arm injection byte for byte', () => {
  const { flag, argv } = dryRun('full')
  assert.equal(flag('--append-system-prompt'), harnessAppend())
  assert.equal(flag('--settings'), harnessHook())
  assert.equal(flag('--allowedTools'), harnessAllow())
  assert.ok(argv.includes('--mcp-config'))
  assert.ok(argv.includes('--strict-mcp-config'))
})

test('bare gets no NEAT at all', () => {
  const { flag, argv } = dryRun('bare')
  for (const f of ['--mcp-config', '--append-system-prompt', '--settings']) assert.ok(!argv.includes(f), f)
  assert.equal(flag('--allowedTools'), 'Read,Grep,Glob,Edit,Bash')
})

test('oracle keeps the tools, drops the directive and hook, and names the gold files', () => {
  const { flag, argv } = dryRun('oracle')
  assert.ok(argv.includes('--mcp-config'))
  assert.ok(!argv.includes('--settings'))
  assert.equal(flag('--append-system-prompt'), renderNote({ files: ['src/validations/custom.validation.js'] }))
  assert.equal(flag('--allowedTools'), harnessAllow())
})

test('jev routed small names the router files; routed full is the full arm', () => {
  const dir = mkdtempSync(join(tmpdir(), 'route-'))
  const small = join(dir, 'small.json')
  const fullRoute = join(dir, 'full.json')
  writeFileSync(small, JSON.stringify({ tier: 'small', reason: 'jev', confidence: 0.9, needsRuntime: 0.1, files: ['src/a.js', 'src/b.js'], briefing: null }))
  writeFileSync(fullRoute, JSON.stringify({ tier: 'full', reason: 'low_confidence', confidence: 0.4, needsRuntime: 0.1, files: [], briefing: null }))

  const s = dryRun('jev', ['--route-json', small])
  assert.equal(s.flag('--append-system-prompt'), renderNote({ files: ['src/a.js', 'src/b.js'] }))
  assert.ok(!s.argv.includes('--settings'))
  const cfg = JSON.parse(readFileSync(join(s.out, 'arm-config.json'), 'utf8'))
  assert.deepEqual(cfg.routed, { tier: 'small', reason: 'jev', confidence: 0.9, needsRuntime: 0.1 })

  const f = dryRun('jev', ['--route-json', fullRoute])
  const ref = dryRun('full')
  const normalize = (argv) => argv.map((a) => (a.endsWith('with-neat.mcp.json') ? '<mcp>' : a))
  assert.deepEqual(normalize(f.argv), normalize(ref.argv))
})

test('every arm sends the identical prompt', () => {
  const prompts = ['bare', 'full', 'oracle'].map((a) => dryRun(a).flag('-p'))
  assert.ok(prompts[0].startsWith("GET /v1/users/:id returns 400"))
  assert.equal(new Set(prompts).size, 1)
})

test('neat-bytes counts NEAT tool results and hook output, not other tools', () => {
  const lines = [
    { type: 'assistant', message: { content: [{ type: 'tool_use', id: 't1', name: 'mcp__neat__get_root_cause' }, { type: 'tool_use', id: 't2', name: 'Read' }] } },
    { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: 'abcd' }, { type: 'tool_result', tool_use_id: 't2', content: 'xxxxxxxx' }] } },
    { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't1', content: 'abcd' }] } },
    { type: 'stream_event', event: { content_block: { type: 'tool_use', id: 't3', name: 'mcp__neat__expand' } } },
    { type: 'user', message: { content: [{ type: 'tool_result', tool_use_id: 't3', content: [{ type: 'text', text: 'éé' }] }] } },
    { type: 'system', subtype: 'hook_response', output: 'nudge!' },
  ].map((e) => JSON.stringify(e))
  assert.deepEqual(neatBytes(lines), { neat_tool_results: 2, neat_tool_result_bytes: 8, hook_responses: 1, hook_output_bytes: 6 })
})
