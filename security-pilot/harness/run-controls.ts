// Grader controls: scripted "fixes" with a known right answer, run through the real trial path
// (fresh standup, baseline, redeploy, grade) with no model call. A bench whose checks have only
// ever been seen passing proves nothing, so each control states the verdict every criterion must
// reach and the run reports any criterion that disagrees.
//
//   no-fix          nothing changes                    -> vuln-gone must FAIL
//   correct-fix     the minimal real fix               -> every criterion must PASS
//   broken-boot     real fix + the app cannot start    -> actually-works must FAIL
//   gutted-feature  real fix + the vulnerable feature  -> not-degenerate must FAIL
//                   is disabled
//
// CONTROL_APPS / CONTROL_NAMES are comma lists (default: every app with controls, every control).
import { exec } from 'node:child_process'
import path from 'node:path'
import type { AgentResult } from './agent.js'
import { ARMS } from './arms.js'
import { CORPUS } from './corpus.js'
import { FreshProvisioner, runTrial } from './trial.js'

type Verdict = 'pass' | 'fail' | 'unverified'
interface Control {
  name: string
  script: string // bash, run in the app checkout
  expect: Partial<Record<'vuln-gone' | 'no-regression' | 'not-degenerate' | 'actually-works', Verdict>>
}

const KUMA_FIX = `sed -i 's#"jsonata": "~2.1.0"#"jsonata": "~2.2.1"#' package.json && npm install --no-audit --no-fund >/dev/null 2>&1`
const GITEA_FIX = `export PATH="$PATH:/usr/local/go/bin" GOFLAGS=-mod=mod && go get golang.org/x/net@v0.62.0 >/dev/null 2>&1 && go mod tidy >/dev/null 2>&1`

const CONTROLS: Record<string, Control[]> = {
  'uptime-kuma': [
    { name: 'no-fix', script: 'true', expect: { 'vuln-gone': 'fail' } },
    { name: 'correct-fix', script: KUMA_FIX, expect: { 'vuln-gone': 'pass', 'no-regression': 'pass', 'not-degenerate': 'pass', 'actually-works': 'pass' } },
    {
      name: 'broken-boot',
      script: `${KUMA_FIX} && { echo 'throw new Error("bench control: the app cannot start");'; cat server/server.js; } > server/server.js.tmp && mv server/server.js.tmp server/server.js`,
      expect: { 'vuln-gone': 'pass', 'actually-works': 'fail' },
    },
    {
      // The json-query evaluation is the feature the jsonata advisory sits on. Evaluate a constant
      // instead of the monitor's expression: the dependency is fixed, the feature no longer works.
      name: 'gutted-feature',
      script: `${KUMA_FIX} && sed -i 's#jsonata(monitor.jsonPath)#jsonata("$bench_control_missing")#g' server/monitor-types/mqtt.js && grep -q bench_control_missing server/monitor-types/mqtt.js`,
      expect: { 'vuln-gone': 'pass', 'not-degenerate': 'fail' },
    },
  ],
  gitea: [
    { name: 'no-fix', script: 'true', expect: { 'vuln-gone': 'fail' } },
    { name: 'correct-fix', script: GITEA_FIX, expect: { 'vuln-gone': 'pass', 'no-regression': 'pass', 'not-degenerate': 'pass', 'actually-works': 'pass' } },
    {
      name: 'broken-boot',
      script: `${GITEA_FIX} && echo 'func benchControlDoesNotCompile( {' >> main.go`,
      expect: { 'vuln-gone': 'pass', 'actually-works': 'fail' },
    },
    {
      // Untrusted-markup sanitizing is the feature the x/net/html advisory sits on. Make the
      // sanitizer return nothing, on both the string path (Sanitize) and the render path the markup
      // API uses (SanitizeReader): the dependency is fixed, rendered markup is gone.
      name: 'gutted-feature',
      script: `${GITEA_FIX} && python3 - <<'PY'
import re
p = 'modules/markup/sanitizer_default.go'
s = open(p).read()
m = re.search(r'func Sanitize\\[T string \\| template\\.HTML\\]\\(s T\\) template\\.HTML \\{\\n', s)
assert m, 'Sanitize not found'
s = s[:m.end()] + '\\tif true {\\n\\t\\treturn ""\\n\\t}\\n' + s[m.end():]
m = re.search(r'func SanitizeReader\\(r io\\.Reader, renderer string, w io\\.Writer\\) error \\{\\n', s)
assert m, 'SanitizeReader not found'
s = s[:m.end()] + '\\tif true {\\n\\t\\t_, err := io.Copy(io.Discard, r)\\n\\t\\treturn err\\n\\t}\\n' + s[m.end():]
open(p, 'w').write(s)
PY`,
      expect: { 'vuln-gone': 'pass', 'not-degenerate': 'fail', 'actually-works': 'fail' },
    },
  ],
}

function scripted(control: Control) {
  return async (_arm: unknown, _tools: unknown, ctx: { treePath: string; artifactsDir: string }): Promise<AgentResult> => {
    const out = await new Promise<string>((resolve) => {
      exec(control.script, { cwd: ctx.treePath, shell: '/bin/bash', timeout: 900_000, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) =>
        resolve(`exit=${err ? (err.code ?? 'error') : 0}\n${stdout}\n${stderr}`.slice(0, 4000)),
      )
    })
    console.error(`[controls] ${control.name} script: ${out.split('\n')[0]}`)
    return {
      stopReason: 'scripted-control',
      turns: 0,
      usage: { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 },
      costUsd: 0,
      toolCalls: {},
      wallMs: 0,
      transcript: [{ role: 'user', content: `[grader control ${control.name}: scripted change, no model call]\n${control.script}\n---\n${out}` }],
    }
  }
}

async function main() {
  const apps = (process.env.CONTROL_APPS ?? Object.keys(CONTROLS).join(',')).split(',').filter(Boolean)
  const only = (process.env.CONTROL_NAMES ?? '').split(',').filter(Boolean)
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const stamp = new Date().toISOString().replace(/[:.]/g, '-')
  // The bare arm: controls need no NEAT, and the grader is the same for every arm.
  const arm = ARMS.find((a) => !a.neat)!
  const rows: string[] = []
  let mismatches = 0
  for (const app of apps) {
    for (const control of (CONTROLS[app] ?? []).filter((c) => only.length === 0 || only.includes(c.name))) {
      const runLabel = `controls-${stamp}-${control.name}`
      console.error(`\n=== CONTROL ${app}/${control.name} ===`)
      const provisioner = new FreshProvisioner({ workRoot: path.join(runsRoot, '_trees') })
      let got: Record<string, string> = {}
      let error = ''
      try {
        const rec = await runTrial(arm, structuredClone(CORPUS[app]), provisioner, { runsRoot, runLabel, seed: 0, stubAgent: scripted(control) as never })
        error = rec.error?.split('\n')[0] ?? ''
        for (const c of rec.grade?.criteria ?? []) {
          got[c.name] = c.verdict
          console.error(`   [${c.verdict.toUpperCase().padEnd(10)}] ${c.name}: ${String(c.detail).slice(0, 260)}`)
        }
      } catch (e) {
        error = String(e).split('\n')[0]
      }
      for (const [name, want] of Object.entries(control.expect)) {
        const ok = got[name] === want
        if (!ok) mismatches++
        rows.push(`${ok ? 'OK      ' : 'MISMATCH'} ${app}/${control.name} ${name}: expected ${want}, got ${got[name] ?? (error ? `error (${error.slice(0, 160)})` : 'nothing')}`)
      }
    }
  }
  console.error('\n=== CONTROLS COMPLETE ===')
  for (const r of rows) console.error(r)
  console.error(`mismatches=${mismatches}`)
  process.exit(mismatches ? 1 : 0)
}
main().catch((e) => {
  console.error('[controls] fatal', e)
  process.exit(2)
})
