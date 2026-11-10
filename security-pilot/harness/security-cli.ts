// NEAT security tools for the NEAT arms, backed by the `neat security` CLI (the in-process
// engine, no daemon). The current daemon/MCP build (0.10.9 MCP, 0.11.0 core) does not expose
// get_reachable_cves / is_reachable / scan_diff over MCP or daemon REST, so they are hand-wired
// here onto `neat security scan` / `neat security diff`. scan surfaces per-finding reachability
// (level + grain + fix-diff) which is the backing for reachable-CVE and is-reachable.
import { spawn } from 'node:child_process'
import { statSync } from 'node:fs'
import path from 'node:path'
import type { ToolDef } from './agent.js'
import type { TrialContext } from './context.js'

const NEAT_BIN = process.env.NEAT_BIN ?? 'neat'

// Per-tree scan memo. The scan output is a function of the dependency manifest + lockfile, so we
// key the cache on their mtimes: if the agent hasn't touched the deps, repeated scan-backed tool
// calls (security_scan, get_reachable_cves, is_reachable) return the same findings and we avoid
// re-running the (slow) OSV resolve. Any edit to a manifest/lockfile bumps the mtime and busts it.
const scanCache = new Map<string, Promise<SecurityScan>>()
const MANIFESTS = ['package.json', 'package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml', 'go.mod', 'go.sum', 'requirements.txt', 'poetry.lock', 'Pipfile.lock', 'uv.lock', 'pyproject.toml']
function manifestSignature(treePath: string): string {
  const parts: string[] = []
  for (const f of MANIFESTS) {
    try {
      parts.push(`${f}:${statSync(path.join(treePath, f)).mtimeMs}`)
    } catch {
      /* absent */
    }
  }
  return parts.join('|')
}

interface ExecOut {
  code: number
  stdout: string
  stderr: string
}

// Run in its OWN process group (detached) so a timeout kills the WHOLE tree, not just the shell.
// `neat security scan` spawns OSV-query children that survive exec()'s SIGTERM; on a slow scan the
// tool timed out but the scan kept running, and the next (cache-miss) tool launched another -> a
// pileup that ate RAM. SIGKILL to -pid (the group) stops the scan and all its children.
function run(cmd: string, cwd: string, timeoutMs: number): Promise<ExecOut> {
  return new Promise((resolve) => {
    const child = spawn('/bin/sh', ['-c', cmd], { cwd, detached: true })
    let stdout = ''
    let stderr = ''
    let timedOut = false
    const cap = 64 * 1024 * 1024
    child.stdout.on('data', (d) => { if (stdout.length < cap) stdout += d.toString() })
    child.stderr.on('data', (d) => { if (stderr.length < 8 * 1024 * 1024) stderr += d.toString() })
    const timer = setTimeout(() => {
      timedOut = true
      try {
        if (child.pid) process.kill(-child.pid, 'SIGKILL')
      } catch {
        try { child.kill('SIGKILL') } catch { /* gone */ }
      }
    }, timeoutMs)
    child.on('close', (code) => {
      clearTimeout(timer)
      resolve({ code: timedOut ? 124 : code ?? 1, stdout, stderr: stderr + (timedOut ? `\n[bench] killed scan after ${timeoutMs}ms (process group)` : '') })
    })
    child.on('error', (e) => {
      clearTimeout(timer)
      resolve({ code: 1, stdout, stderr: `${stderr}\n${String(e)}` })
    })
  })
}

export interface SecurityScan {
  advisories: string
  inventory: number
  findings: any[]
  context: any[]
  errors: any[]
  asOf: string
}

export async function runNeatSecurityScan(ctx: TrialContext): Promise<SecurityScan> {
  const key = `${ctx.treePath}@${manifestSignature(ctx.treePath)}`
  const cached = scanCache.get(key)
  if (cached) return cached
  const p = (async () => {
    // No --service: the scan auto-detects the dep-manifest service name; passing the graph service
    // id would mis-scope (the two names differ, e.g. nodegoat vs owasp-nodejs-goat).
    const out = await run(`${NEAT_BIN} security scan ${ctx.treePath} --json`, ctx.treePath, ctx.securityTimeoutMs)
    if (!out.stdout.trim()) {
      throw new Error(`neat security scan produced no JSON (code=${out.code}): ${out.stderr.slice(-400)}`)
    }
    return JSON.parse(out.stdout) as SecurityScan
  })()
  scanCache.set(key, p)
  // Keep a failed/timed-out scan CACHED for the trial: the tree is fixed within a trial, so a slow
  // scan (e.g. a timeout-kill) must not be relaunched by every scan-backed tool (that caused a
  // pileup). One scan attempt per (tree, manifest) per trial; an edit to the manifest busts the key.
  p.catch(() => {})
  return p
}

// Compact a finding for the agent: keep what drives a fix decision, drop the fix-diff bulk.
function trimFinding(f: any) {
  const r = f.reachability ?? {}
  return {
    id: f.id,
    dependency: f.dependency
      ? { name: f.dependency.name, version: f.dependency.version, ecosystem: f.dependency.ecosystem, scope: f.dependency.scope, dev: f.dependency.dev }
      : undefined,
    advisory: f.advisory ? { id: f.advisory.id, aliases: f.advisory.aliases, severity: f.advisory.severity?.label, summary: f.advisory.summary } : undefined,
    fix: f.fix,
    reachability: { level: r.level, grain: r.grain, grainSource: r.grainSource, changedInFixCount: Array.isArray(r.changedInFix) ? r.changedInFix.length : undefined },
    coverage: f.coverage,
    headline: f.headline,
  }
}

// NEAT's own reachability verdict. The engine marks a level + grain per finding; we treat a
// present level that is not an explicit negative as "NEAT surfaced this as reachable". This is
// the agent-facing reachable set; the grader's precision metric checks it against ground truth.
const NOT_REACHABLE = new Set(['unreachable', 'not-reached', 'not-imported', 'absent', 'transitive-unreached'])
function neatReachable(f: any): boolean {
  const lvl = f?.reachability?.level
  return typeof lvl === 'string' && !NOT_REACHABLE.has(lvl)
}

export function buildSecurityToolDefs(ctx: TrialContext): ToolDef[] {
  return [
    {
      name: 'security_scan',
      description:
        'NEAT security scan of the checkout: known-vulnerability findings with per-dependency reachability (level + grain) and the recommended fix action. Use to see every advisory NEAT found and which are reachable.',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const scan = await runNeatSecurityScan(ctx)
        return {
          content: JSON.stringify(
            { asOf: scan.asOf, inventory: scan.inventory, findingCount: scan.findings.length, findings: scan.findings.map(trimFinding) },
            null,
            1,
          ),
        }
      },
    },
    {
      name: 'get_reachable_cves',
      description:
        'The CVEs/advisories NEAT considers reachable in this app (the vulnerable symbol is imported/reached per the graph), as opposed to merely present in the dependency tree. Each carries its reachability level + grain and recommended fix.',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const scan = await runNeatSecurityScan(ctx)
        const reachable = scan.findings.filter(neatReachable).map(trimFinding)
        const notReachable = scan.findings.filter((f) => !neatReachable(f)).map((f) => ({ dep: f.dependency?.name, advisory: f.advisory?.id, level: f.reachability?.level }))
        return { content: JSON.stringify({ reachableCount: reachable.length, reachable, excluded: notReachable }, null, 1) }
      },
    },
    {
      name: 'is_reachable',
      description:
        'Ask NEAT whether a specific dependency or CVE is reachable (its vulnerable symbol is imported/reached). Provide dep (package name) and/or cve (CVE or GHSA id).',
      input_schema: {
        type: 'object',
        properties: { dep: { type: 'string', description: 'package name, e.g. underscore' }, cve: { type: 'string', description: 'CVE or GHSA id' } },
        additionalProperties: false,
      },
      run: async (input: any) => {
        const scan = await runNeatSecurityScan(ctx)
        const dep = (input?.dep ?? '').toLowerCase()
        const cve = (input?.cve ?? '').toLowerCase()
        const matches = scan.findings.filter((f) => {
          const byDep = dep && String(f.dependency?.name ?? '').toLowerCase() === dep
          const ids = [f.advisory?.id, ...(f.advisory?.aliases ?? [])].map((s) => String(s).toLowerCase())
          const byCve = cve && ids.includes(cve)
          return byDep || byCve
        })
        if (matches.length === 0) return { content: JSON.stringify({ found: false, note: 'no finding for that dep/cve in the scan (not flagged, or not in the tree)' }) }
        return {
          content: JSON.stringify(
            { found: true, verdicts: matches.map((f) => ({ dep: f.dependency?.name, advisory: f.advisory?.id, reachable: neatReachable(f), reachability: trimFinding(f).reachability, fix: f.fix })) },
            null,
            1,
          ),
        }
      },
    },
    {
      name: 'scan_diff',
      description:
        'What a change introduced or cleared, security-wise: diff the scan between two git refs. Provide base and head git refs. Requires the checkout to be a git repo.',
      input_schema: {
        type: 'object',
        properties: { base: { type: 'string', description: 'base git ref' }, head: { type: 'string', description: 'head git ref (default: working tree)' } },
        required: ['base'],
        additionalProperties: false,
      },
      run: async (input: any) => {
        const base = input?.base
        const head = input?.head ? ` --head ${input.head}` : ''
        const out = await run(`${NEAT_BIN} security diff ${ctx.treePath} --base ${base}${head} --json`, ctx.treePath, ctx.securityTimeoutMs)
        if (!out.stdout.trim()) {
          return { content: `scan_diff unavailable: ${out.stderr.slice(-500) || 'no output'} (needs a git checkout with the given refs)`, isError: true }
        }
        return { content: out.stdout.slice(0, 20000) }
      },
    },
  ]
}
