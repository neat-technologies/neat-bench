// Per-arm tool registry. The BASELINE tools are identical for every arm (fairness invariant):
// run_shell, read_file, write_file, run_tests. The bare arm additionally gets the ecosystem
// scanners (npm audit / pip-audit / osv-scanner) and read access to the raw OTel capture files.
// The NEAT arms additionally get the NEAT security tools (security-cli.ts), the NEAT graph MCP
// suite (neat-mcp.ts) and the Recon tools (recon/recon-tools.ts). NEAT is the ONLY variable.
import { exec } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'
import type { Arm } from './arms.js'
import type { ToolDef } from './agent.js'
import type { TrialContext } from './context.js'
import { buildSecurityToolDefs } from './security-cli.js'

function sh(cmd: string, cwd: string, timeoutMs: number): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    exec(cmd, { cwd, timeout: timeoutMs, maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ code: err && typeof (err as any).code === 'number' ? (err as any).code : err ? 1 : 0, stdout, stderr })
    })
  })
}

// Resolve a tool-supplied path inside an allowed root; reject escapes.
function resolveInRoots(p: string, roots: string[]): string | null {
  const abs = path.resolve(roots[0], p)
  for (const root of roots) {
    const r = path.resolve(root)
    if (abs === r || abs.startsWith(r + path.sep)) return abs
  }
  return null
}

function clip(s: string, n = 24000): string {
  return s.length > n ? s.slice(0, n) + `\n…[truncated ${s.length - n} chars]` : s
}

// --- baseline tools (identical for ALL arms) ---
export function baselineTools(ctx: TrialContext, testCmd: string): ToolDef[] {
  const readRoots = [ctx.treePath, ...(ctx.otelCaptureDir ? [ctx.otelCaptureDir] : [])]
  return [
    {
      name: 'run_shell',
      description: 'Run a shell command in the project checkout directory. Bounded timeout. Returns exit code, stdout, stderr.',
      input_schema: { type: 'object', properties: { command: { type: 'string' } }, required: ['command'], additionalProperties: false },
      run: async (input: any) => {
        const r = await sh(String(input?.command ?? ''), ctx.treePath, ctx.shellTimeoutMs)
        return { content: clip(`exit=${r.code}\n--- stdout ---\n${r.stdout}\n--- stderr ---\n${r.stderr}`), isError: r.code !== 0 }
      },
    },
    {
      name: 'read_file',
      description: 'Read a file in the project checkout (and, for the bare arm, the raw OTel capture directory). Path is relative to the checkout root.',
      input_schema: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'], additionalProperties: false },
      run: async (input: any) => {
        const abs = resolveInRoots(String(input?.path ?? ''), readRoots)
        if (!abs) return { content: `path outside the allowed roots: ${input?.path}`, isError: true }
        try {
          return { content: clip(await fs.readFile(abs, 'utf8')) }
        } catch (e) {
          return { content: `read failed: ${String(e)}`, isError: true }
        }
      },
    },
    {
      name: 'write_file',
      description: 'Write a file in the project checkout. Creates parent directories. Path is relative to the checkout root.',
      input_schema: { type: 'object', properties: { path: { type: 'string' }, content: { type: 'string' } }, required: ['path', 'content'], additionalProperties: false },
      run: async (input: any) => {
        const abs = resolveInRoots(String(input?.path ?? ''), [ctx.treePath])
        if (!abs) return { content: `path outside the checkout: ${input?.path}`, isError: true }
        try {
          await fs.mkdir(path.dirname(abs), { recursive: true })
          await fs.writeFile(abs, String(input?.content ?? ''), 'utf8')
          return { content: `wrote ${input?.path} (${String(input?.content ?? '').length} bytes)` }
        } catch (e) {
          return { content: `write failed: ${String(e)}`, isError: true }
        }
      },
    },
    {
      name: 'run_tests',
      description: "Run the app's own test suite (its native framework). Returns the raw test output.",
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const r = await sh(testCmd, ctx.treePath, ctx.shellTimeoutMs)
        return { content: clip(`$ ${testCmd}\nexit=${r.code}\n--- stdout ---\n${r.stdout}\n--- stderr ---\n${r.stderr}`), isError: r.code !== 0 }
      },
    },
  ]
}

// --- bare-arm scanners (ecosystem-native; the NEAT arms get NEAT's scanner instead) ---
export function bareScannerTools(ctx: TrialContext): ToolDef[] {
  return [
    {
      name: 'npm_audit',
      description: 'Run `npm audit --json` in the checkout (npm projects). Returns the raw audit JSON.',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const r = await sh('npm audit --json', ctx.treePath, ctx.securityTimeoutMs)
        return { content: clip(r.stdout || r.stderr) }
      },
    },
    {
      name: 'pip_audit',
      description: 'Run `pip-audit -f json` in the checkout (Python projects). Returns the raw audit JSON.',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const r = await sh('pip-audit -f json', ctx.treePath, ctx.securityTimeoutMs)
        return { content: clip(r.stdout || r.stderr), isError: r.code !== 0 && !r.stdout }
      },
    },
    {
      name: 'osv_scan',
      description: 'Run osv-scanner over the checkout (any ecosystem). Returns the OSV scan JSON.',
      input_schema: { type: 'object', properties: {}, additionalProperties: false },
      run: async () => {
        const r = await sh(`osv-scanner --format json ${ctx.treePath}`, ctx.treePath, ctx.securityTimeoutMs)
        return { content: clip(r.stdout || r.stderr), isError: r.code !== 0 && !r.stdout }
      },
    },
  ]
}

export interface BuildToolsOpts {
  testCmd: string
  neatToolDefs?: ToolDef[] // from connectNeatMcp(ctx)
  reconToolDefs?: ToolDef[] // from recon/recon-tools.ts
}

// Compose the full per-arm surface. Baseline first (identical), then the arm-specific additions.
export function buildTools(arm: Arm, ctx: TrialContext, opts: BuildToolsOpts): ToolDef[] {
  const tools = baselineTools(ctx, opts.testCmd)
  if (!arm.neat) {
    tools.push(...bareScannerTools(ctx))
  } else {
    tools.push(...buildSecurityToolDefs(ctx))
    if (opts.neatToolDefs) tools.push(...opts.neatToolDefs)
    if (opts.reconToolDefs) tools.push(...opts.reconToolDefs)
  }
  return tools
}
