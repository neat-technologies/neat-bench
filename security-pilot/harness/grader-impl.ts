// The grader's ecosystem-specific oracle helpers. These were the `declare function` stubs at
// the bottom of grader.ts ("to implement per target; all NEAT-independent"). They are
// implemented here and imported by grader.ts. HARD RULE: nothing in this file touches NEAT —
// "vuln gone" is decided by OSV + the ecosystem's own scanner (npm audit / pip-audit /
// govulncheck), never NEAT's scanner, so the bench can never grade itself. A scanner that
// cannot run THROWS (the trial errors loudly) rather than silently reporting "not flagged".
import { exec } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import type { Advisory, Ecosystem } from './grader.js'

function sh(cmd: string, cwd: string, timeoutMs = 600_000): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    exec(cmd, { cwd, timeout: timeoutMs, maxBuffer: 128 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ code: err && typeof (err as any).code === 'number' ? (err as any).code : err ? 1 : 0, stdout, stderr })
    })
  })
}

function osvEcosystem(eco: Ecosystem): string {
  return eco // grader's Ecosystem already uses OSV names: 'npm' | 'PyPI' | 'Go'
}

async function fileExists(p: string): Promise<boolean> {
  try {
    await fs.access(p)
    return true
  } catch {
    return false
  }
}

// --- resolveInstalledVersion: read the resolved version from the installed/locked tree ---
export async function resolveInstalledVersion(eco: Ecosystem, dep: string, treePath: string): Promise<string | null> {
  if (eco === 'npm') return resolveNpm(dep, treePath)
  if (eco === 'PyPI') return resolvePyPI(dep, treePath)
  if (eco === 'Go') return resolveGo(dep, treePath)
  return null
}

async function resolveNpm(dep: string, treePath: string): Promise<string | null> {
  const lockPath = path.join(treePath, 'package-lock.json')
  if (await fileExists(lockPath)) {
    try {
      const lock = JSON.parse(await fs.readFile(lockPath, 'utf8'))
      if (lock.packages) {
        const key = `node_modules/${dep}`
        if (lock.packages[key]?.version) return lock.packages[key].version
        // nested: take the first resolved occurrence
        for (const [k, v] of Object.entries<any>(lock.packages)) {
          if (k.endsWith(`node_modules/${dep}`) && v?.version) return v.version
        }
      }
      if (lock.dependencies?.[dep]?.version) return lock.dependencies[dep].version // v1 lockfiles
    } catch {
      /* fall through */
    }
  }
  const pkgPath = path.join(treePath, 'node_modules', dep, 'package.json')
  if (await fileExists(pkgPath)) {
    try {
      return JSON.parse(await fs.readFile(pkgPath, 'utf8')).version ?? null
    } catch {
      /* ignore */
    }
  }
  return null
}

// PEP 503 normalization of a project name.
const normPy = (s: string) => s.toLowerCase().replace(/[-_.]+/g, '-')

// Resolve a PyPI dep's pinned version from the checkout's LOCK/manifest (uv.lock, requirements.txt,
// Pipfile.lock). A fresh checkout is not pip-installed, so there are no site-packages to read; the
// pinned version lives in the lock. NEAT-independent (plain file parse). The lock is also what the
// agent edits to fix, so this reflects the post-patch state.
async function resolvePyPIFromManifests(want: string, treePath: string): Promise<string | null> {
  // uv.lock (TOML): repeated [[package]] blocks with name/version.
  const uvLock = path.join(treePath, 'uv.lock')
  if (await fileExists(uvLock)) {
    try {
      const txt = await fs.readFile(uvLock, 'utf8')
      for (const block of txt.split(/\[\[package\]\]/)) {
        const nm = block.match(/\bname\s*=\s*"([^"]+)"/)
        const ver = block.match(/\bversion\s*=\s*"([^"]+)"/)
        if (nm && ver && normPy(nm[1]) === want) return ver[1]
      }
    } catch {
      /* fall through */
    }
  }
  // Pipfile.lock (JSON): default/develop -> { name: { version: "==x" } }.
  const pipLock = path.join(treePath, 'Pipfile.lock')
  if (await fileExists(pipLock)) {
    try {
      const j = JSON.parse(await fs.readFile(pipLock, 'utf8'))
      for (const section of ['default', 'develop']) {
        const deps = j[section] ?? {}
        for (const [name, spec] of Object.entries<any>(deps)) {
          if (normPy(name) === want && typeof spec?.version === 'string') return spec.version.replace(/^==/, '')
        }
      }
    } catch {
      /* fall through */
    }
  }
  // requirements*.txt: lines like `name==version`.
  for (const req of ['requirements.txt', 'requirements/base.txt', 'requirements/production.txt']) {
    const rp = path.join(treePath, req)
    if (!(await fileExists(rp))) continue
    try {
      const txt = await fs.readFile(rp, 'utf8')
      for (const line of txt.split('\n')) {
        const m = line.match(/^\s*([A-Za-z0-9._-]+)\s*==\s*([^\s;#]+)/)
        if (m && normPy(m[1]) === want) return m[2]
      }
    } catch {
      /* next */
    }
  }
  return null
}

async function resolvePyPI(dep: string, treePath: string): Promise<string | null> {
  const want = normPy(dep)
  // Prefer the checkout lock (fresh checkouts have no site-packages); fall back to an installed tree.
  const fromLock = await resolvePyPIFromManifests(want, treePath)
  if (fromLock) return fromLock
  const roots = [treePath, path.join(treePath, '.venv'), path.join(treePath, 'venv'), path.join(treePath, 'src')]
  // Find site-packages dirs under candidate roots (shallow walk).
  const sitePkgs: string[] = []
  for (const root of roots) {
    for (const guess of [
      path.join(root, 'lib'),
      path.join(root, 'Lib'),
      path.join(root, '.venv', 'lib'),
    ]) {
      if (!(await fileExists(guess))) continue
      try {
        const entries = await fs.readdir(guess, { withFileTypes: true })
        for (const e of entries) {
          const sp = path.join(guess, e.name, 'site-packages')
          if (await fileExists(sp)) sitePkgs.push(sp)
          if (e.name === 'site-packages') sitePkgs.push(path.join(guess, e.name))
        }
      } catch {
        /* ignore */
      }
    }
  }
  for (const sp of sitePkgs) {
    try {
      const entries = await fs.readdir(sp)
      for (const name of entries) {
        const m = name.match(/^(.+?)-(\d[^-]*)\.dist-info$/)
        if (m && normPy(m[1]) === want) return m[2]
      }
    } catch {
      /* ignore */
    }
  }
  return null
}

async function resolveGo(dep: string, treePath: string): Promise<string | null> {
  const out = await sh(`go list -m -f '{{.Version}}' ${dep}`, treePath, 120_000)
  const v = out.stdout.trim()
  if (v && !/no required module|error|not a known/i.test(v)) return v
  // Fallback: parse go.mod require + replace, then go.sum.
  const goMod = path.join(treePath, 'go.mod')
  if (await fileExists(goMod)) {
    const txt = await fs.readFile(goMod, 'utf8')
    const re = new RegExp(`^\\s*${dep.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\s+(v\\S+)`, 'm')
    const m = txt.match(re)
    if (m) return m[1]
  }
  return null
}

// --- osvAffected_: is `resolvedVersion` still inside the advisory's affected set, per OSV? ---
export async function osvAffected_(adv: Advisory, resolvedVersion: string): Promise<boolean> {
  const body = { version: resolvedVersion, package: { name: adv.dep, ecosystem: osvEcosystem(adv.ecosystem) } }
  const res = await fetch('https://api.osv.dev/v1/query', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!res.ok) throw new Error(`OSV query failed (${res.status}) for ${adv.dep}@${resolvedVersion}`)
  const j = (await res.json()) as { vulns?: { id: string; aliases?: string[] }[] }
  const want = adv.id.toLowerCase()
  return (j.vulns ?? []).some((v) => v.id.toLowerCase() === want || (v.aliases ?? []).some((a) => a.toLowerCase() === want))
}

// --- runScanner: does the ecosystem's own scanner still flag this advisory on this tree? ---
export async function runScanner(adv: Advisory, treePath: string): Promise<boolean> {
  if (adv.ecosystem === 'npm') return scanNpm(adv, treePath)
  if (adv.ecosystem === 'PyPI') return scanPyPI(adv, treePath)
  if (adv.ecosystem === 'Go') return scanGo(adv, treePath)
  throw new Error(`no scanner for ecosystem ${adv.ecosystem}`)
}

const idMatches = (hay: string, id: string) => hay.toLowerCase().includes(id.toLowerCase())

async function scanNpm(adv: Advisory, treePath: string): Promise<boolean> {
  const out = await sh('npm audit --json', treePath)
  if (!out.stdout.trim()) throw new Error(`npm audit produced no JSON: ${out.stderr.slice(-300)}`)
  let j: any
  try {
    j = JSON.parse(out.stdout)
  } catch {
    throw new Error('npm audit JSON parse failed')
  }
  const vulns = j.vulnerabilities ?? {}
  const node = vulns[adv.dep]
  if (!node) {
    // v1 schema fallback
    const adv1 = j.advisories ?? {}
    return Object.values<any>(adv1).some((a) => a.module_name === adv.dep && (idMatches(JSON.stringify(a), adv.id)))
  }
  return idMatches(JSON.stringify(node), adv.id) || (Array.isArray(node.via) && node.via.length > 0 && node.via.some((v: any) => typeof v === 'object' && idMatches(JSON.stringify(v), adv.id)))
}

// pip-audit is NOT on the box (no pip + PEP 668). For the PyPI corpus (paperless), it is baked into
// the app image and run via `docker exec` at grade time, auditing the LIVE checkout lock: the checkout
// root is bind-mounted at /checkout, we export its frozen uv lock to a requirements file in the
// container, then `pip-audit -r` it. The container name is recorded by paperless-fresh.sh at
// <tree>__work/paperless-container. OSV host-query stays the PRIMARY authority; this is the
// independent cross-check. Scoped to PyPI only (npm/Go paths unchanged).
async function scanPyPI(adv: Advisory, treePath: string): Promise<boolean> {
  const container = (await fs.readFile(path.join(`${treePath}__work`, 'paperless-container'), 'utf8').catch(() => '')).trim()
  if (!container) {
    throw new Error('scanPyPI: no app container recorded (expected <tree>__work/paperless-container); the PyPI cross-check runs pip-audit inside the container')
  }
  // Export the live checkout lock -> requirements, then audit it (all inside the container).
  // `timeout` bounds the IN-CONTAINER work so a slow uv/pip-audit self-terminates (the host-side
  // exec timeout can't reach a process inside the container).
  const exec = `docker exec ${container} sh -lc "cd /checkout && (timeout 120 uv export --frozen --no-hashes --no-emit-project --format requirements-txt -o /tmp/neat-req.txt 2>/tmp/neat-uv.err || timeout 120 uv export --frozen --no-hashes -o /tmp/neat-req.txt 2>>/tmp/neat-uv.err) && timeout 300 pip-audit -r /tmp/neat-req.txt -f json"`
  const out = await sh(exec, treePath)
  if (!out.stdout.trim()) throw new Error(`pip-audit (in container ${container}) produced no JSON (code=${out.code}): ${out.stderr.slice(-300)}`)
  let j: any
  try {
    j = JSON.parse(out.stdout)
  } catch {
    // pip-audit can emit a non-JSON prefix/suffix (progress/warnings) on stdout; extract the JSON span.
    const raw = out.stdout
    const sArr = raw.indexOf('[')
    const sObj = raw.indexOf('{')
    const start = sArr >= 0 && (sObj < 0 || sArr < sObj) ? sArr : sObj
    const end = Math.max(raw.lastIndexOf(']'), raw.lastIndexOf('}'))
    if (start >= 0 && end > start) {
      try { j = JSON.parse(raw.slice(start, end + 1)) } catch { /* fall through */ }
    }
    if (!j) throw new Error(`pip-audit JSON parse failed (code=${out.code}): ${out.stdout.slice(0, 200)} | err: ${out.stderr.slice(-200)}`)
  }
  const deps: any[] = Array.isArray(j) ? j : (j.dependencies ?? [])
  const node = deps.find((d) => normPy(d.name ?? '') === normPy(adv.dep))
  if (!node) return false
  return (node.vulns ?? []).some((v: any) => idMatches(v.id ?? '', adv.id) || (v.aliases ?? []).some((a: string) => idMatches(a, adv.id)))
}

async function scanGo(adv: Advisory, treePath: string): Promise<boolean> {
  const out = await sh('govulncheck -json ./...', treePath)
  if (!out.stdout.trim()) throw new Error(`govulncheck unavailable/failed: ${out.stderr.slice(-300)}`)
  return govulncheckFlags(out.stdout, adv.id)
}

// Split a concatenated/pretty-printed JSON-object stream (govulncheck -json) into objects.
function parseJsonStream(s: string): any[] {
  const out: any[] = []
  let depth = 0
  let start = -1
  let inStr = false
  let esc = false
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (inStr) {
      if (esc) esc = false
      else if (c === '\\') esc = true
      else if (c === '"') inStr = false
      continue
    }
    if (c === '"') inStr = true
    else if (c === '{') {
      if (depth === 0) start = i
      depth++
    } else if (c === '}') {
      depth--
      if (depth === 0 && start >= 0) {
        try {
          out.push(JSON.parse(s.slice(start, i + 1)))
        } catch {
          /* skip malformed */
        }
        start = -1
      }
    }
  }
  return out
}

// `govulncheck -json` streams the ENTIRE OSV database (as "osv" messages) PLUS the actual detections
// (as "finding" messages). The old idMatches(stdout, id) matched the corpus id in the DB dump, so it
// always flagged. Scope to FINDINGS only, expanding each finding's osv id through its aliases (findings
// carry GO-ids; the corpus may name the CVE alias). Exported so an offline re-grader reuses it verbatim.
export function govulncheckFlags(stdout: string, advId: string): boolean {
  const msgs = parseJsonStream(stdout)
  const aliasOf: Record<string, Set<string>> = {}
  for (const m of msgs) {
    const o = m?.osv
    if (o?.id) aliasOf[o.id] = new Set([String(o.id).toLowerCase(), ...((o.aliases ?? []) as string[]).map((a) => String(a).toLowerCase())])
  }
  const want = advId.toLowerCase()
  for (const m of msgs) {
    const oid = m?.finding?.osv
    if (!oid) continue
    const ids = aliasOf[oid] ?? new Set([String(oid).toLowerCase()])
    if (ids.has(want)) return true
  }
  return false
}

// --- runTests: run the suite, return the set of PASSING test ids (framework-aware) ---
export async function runTests(testCmd: string, treePath: string): Promise<Set<string>> {
  const ids = new Set<string>()
  const lower = testCmd.toLowerCase()

  if (lower.includes('node --test') || lower.includes('test-backend') || /\.mjs\b/.test(lower)) {
    const out = await sh(testCmd, treePath)
    // node:test emits TAP ("ok N - name") OR the spec reporter ("✔ name (1.2ms)" pass / "✖ name" fail).
    // uptime-kuma runs --test-reporter=spec, so both are handled; only PASSING names are recorded.
    for (const line of (out.stdout + '\n' + out.stderr).split('\n')) {
      const tap = line.match(/^\s*ok\s+\d+\s*-\s*(.+?)\s*$/)
      if (tap && !/# (skip|todo)/i.test(line)) {
        ids.add(tap[1].trim())
        continue
      }
      const spec = line.match(/^\s*[✔✓]\s+(.+?)(?:\s+\([\d.]+\s*m?s\))?\s*$/)
      if (spec) ids.add(spec[1].trim())
    }
    return ids
  }

  if (lower.includes('pytest')) {
    const cmd = /\s-v\b/.test(testCmd) ? testCmd : `${testCmd} -v`
    const out = await sh(cmd, treePath)
    for (const line of (out.stdout + '\n' + out.stderr).split('\n')) {
      const m = line.match(/^(\S+::\S+)\s+PASSED/)
      if (!m) continue
      // Add the full nodeid AND the bare method + Class::method, so corpus vulnPathTests written
      // as bare method names (e.g. test_dynamic_path) match the same way full ids do.
      const full = m[1]
      ids.add(full)
      const parts = full.split('::')
      ids.add(parts[parts.length - 1])
      if (parts.length >= 2) ids.add(parts.slice(-2).join('::'))
    }
    return ids
  }

  if (lower.includes('go test')) {
    const cmd = lower.includes('-json') ? testCmd : `${testCmd} -json`
    const out = await sh(cmd, treePath)
    for (const line of out.stdout.split('\n')) {
      if (!line.trim()) continue
      try {
        const ev = JSON.parse(line)
        // Full "Package Test" AND bare Test (corpus vulnPathTests use the bare name, e.g. TestPostProcess).
        if (ev.Action === 'pass' && ev.Test) {
          ids.add(`${ev.Package} ${ev.Test}`)
          ids.add(ev.Test)
        }
      } catch {
        /* non-JSON line */
      }
    }
    return ids
  }

  // Fallback (e.g. cypress `npm run test:ci`): coarse, but pre/post use the SAME runTests so
  // baselineGreen (established per trial) and this call agree on the id scheme.
  const out = await sh(testCmd, treePath)
  if (out.code === 0) ids.add('suite:pass')
  return ids
}
