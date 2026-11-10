// One trial: one app, one arm, one seed. Fresh isolated checkout at the pinned vulnerable
// commit -> stand up app + NEAT daemon (or reuse a live one in dry mode) -> establish the
// baseline (pre-patch tests + baseline divergences) -> run the agent -> grade (NEAT-independent
// oracle + Recon QA) -> write run.json (all pins) + per-trial artifacts -> teardown. Full
// isolation (own tree, own daemon, own ports) so parallel == serial verdicts.
import { exec } from 'node:child_process'
import { promises as fs } from 'node:fs'
import { createHash } from 'node:crypto'
import os from 'node:os'
import path from 'node:path'
import type { Arm } from './arms.js'
import { EFFORT, MAX_TURNS, TASK_BUDGET_TOKENS } from './arms.js'
import type { AgentResult, ToolDef } from './agent.js'
import { runAgent } from './agent.js'
import { gradeTrial, type TrialResult } from './grader.js'
import type { BenchCorpusItem } from './corpus.js'
import { DEFAULT_SECURITY_TIMEOUT_MS, DEFAULT_SHELL_TIMEOUT_MS, defaultMcpEntry, type TrialContext } from './context.js'
import { buildTools } from './tools.js'
import { connectNeatMcp, type NeatMcp } from './neat-mcp.js'
import { buildReconToolDefs, ReconQA, reconAssess, type ReconState } from '../recon/recon-tools.js'
import { fetchDivergences, type Divergence } from '../recon/verifier.js'
import { runTests } from './grader-impl.js'
import { standUp, BENCH_NEAT_SHA } from './standup.js'

const TASK =
  'Remove the reachable vulnerabilities from this app without breaking it or violating its policies.'

const SYSTEM = `You are a senior engineer fixing security vulnerabilities in a real application checkout.
Your job: remove the vulnerabilities that are actually reachable in this app, without breaking the app
or violating its policies, and without churning dependencies that do not need to change.
Work in the checkout directory using the available tools. When you believe the fix is complete and
verified, stop. Do not ask for confirmation; act.`

function sh(cmd: string, cwd: string, timeoutMs: number, env?: NodeJS.ProcessEnv): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    exec(cmd, { cwd, timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024, env: env ?? process.env }, (err, stdout, stderr) =>
      resolve({ code: err && typeof (err as any).code === 'number' ? (err as any).code : err ? 1 : 0, stdout, stderr }),
    )
  })
}

async function neatVersion(): Promise<string> {
  const r = await sh(`${process.env.NEAT_BIN ?? 'neat'} version`, os.tmpdir(), 20_000)
  return (r.stdout + r.stderr).trim().split('\n')[0] || 'unknown'
}

async function hashLockfile(treePath: string, ecosystem: string): Promise<{ file: string; sha256: string } | null> {
  const candidates =
    ecosystem === 'npm'
      ? ['package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml']
      : ecosystem === 'Go'
        ? ['go.sum', 'go.mod']
        : ['poetry.lock', 'Pipfile.lock', 'requirements.txt', 'uv.lock']
  for (const c of candidates) {
    try {
      const buf = await fs.readFile(path.join(treePath, c))
      return { file: c, sha256: createHash('sha256').update(buf).digest('hex') }
    } catch {
      /* next */
    }
  }
  return null
}

// How a trial obtains its tree + daemon. Real runs use FreshProvisioner; the dry test uses
// LiveReuseProvisioner (an existing neat-ba daemon + its tree) to prove the machinery without
// a checkout/standup. The real app+instrumentation standup is neat-ba's lane (follow-up).
export interface Provisioned {
  treePath: string
  neatBase?: string
  appBase?: string
  otelCaptureDir?: string
  teardown: () => Promise<void>
}
export interface Provisioner {
  provision(item: BenchCorpusItem, arm: Arm): Promise<Provisioned>
}

export class LiveReuseProvisioner implements Provisioner {
  constructor(private cfg: { treePath: string; neatBase?: string; appBase?: string; otelCaptureDir?: string }) {}
  async provision(): Promise<Provisioned> {
    return { ...this.cfg, teardown: async () => {} } // never tear down a shared live daemon/tree
  }
}

export class FreshProvisioner implements Provisioner {
  constructor(private cfg: { workRoot: string; neatPort?: number }) {}
  async provision(item: BenchCorpusItem, arm: Arm): Promise<Provisioned> {
    const treePath = await fs.mkdtemp(path.join(this.cfg.workRoot, `${item.app}-${arm.id}-`))
    // Fresh isolated checkout at the pinned vulnerable commit.
    let r = await sh(`git clone --no-checkout ${item.repoUrl} .`, treePath, 600_000)
    if (r.code !== 0) throw new Error(`git clone failed: ${r.stderr.slice(-400)}`)
    r = await sh(`git fetch --depth 1 origin ${item.commit}`, treePath, 600_000)
    if (r.code !== 0) await sh(`git fetch origin ${item.commit}`, treePath, 600_000)
    r = await sh(`git checkout ${item.commit}`, treePath, 120_000)
    if (r.code !== 0) throw new Error(`git checkout ${item.commit} failed: ${r.stderr.slice(-400)}`)

    // Stand the app up FRESH + instrumented and drive baseline traffic so OBSERVED materializes.
    //   NEAT arm: a MAIN-build `neat watch` daemon on the checkout (EXTRACTED + OBSERVED fused),
    //             the app's OTLP pointed at the daemon's OTEL_PORT.
    //   BARE arm: a plain otelcol-contrib (otlp receiver -> file exporter for traces+logs); the
    //             SAME traffic is driven so the bare agent gets the raw OTel capture as files.
    // standUp owns the daemon/collector/app lifecycle via pid files (never pkill -f) and returns
    // the per-trial teardown. Fresh ports + per-run NEAT_HOME, so neat-ba's :8201-8205 are untouched.
    let handles
    try {
      handles = await standUp(item, arm, treePath)
    } catch (e) {
      await fs.rm(treePath, { recursive: true, force: true }).catch(() => {})
      throw e
    }
    return {
      treePath,
      neatBase: handles.neatBase,
      appBase: handles.appBase,
      otelCaptureDir: handles.otelCaptureDir,
      teardown: async () => {
        await handles.teardown().catch(() => {})
        await fs.rm(treePath, { recursive: true, force: true }).catch(() => {})
      },
    }
  }
}

export interface RunTrialOpts {
  runsRoot: string
  runLabel: string
  seed?: number
  maxTurns?: number
  // Dry plumbing test: run a canned tool sequence instead of a real (billed) agent loop.
  stubAgent?: (arm: Arm, tools: ToolDef[], ctx: TrialContext) => Promise<AgentResult>
}

export interface TrialRecord {
  app: string
  arm: string
  pass: boolean | null
  error?: string
  pins: Record<string, unknown>
  metrics: Record<string, unknown>
  grade?: TrialResult
  artifactsDir: string
}

async function writeArtifact(dir: string, name: string, data: unknown): Promise<void> {
  const body = typeof data === 'string' ? data : JSON.stringify(data, null, 2)
  await fs.writeFile(path.join(dir, name), body, 'utf8')
}

export async function runTrial(arm: Arm, item: BenchCorpusItem, provisioner: Provisioner, opts: RunTrialOpts): Promise<TrialRecord> {
  const artifactsDir = path.join(opts.runsRoot, opts.runLabel, arm.id, item.app)
  await fs.mkdir(artifactsDir, { recursive: true })
  const phase: Record<string, number> = {}
  const t0 = Date.now()
  let neat: NeatMcp | undefined
  let provisioned: Provisioned | undefined
  const rec: TrialRecord = { app: item.app, arm: arm.id, pass: null, pins: {}, metrics: {}, artifactsDir }

  try {
    // 1. provision (checkout + daemon, or live reuse)
    provisioned = await provisioner.provision(item, arm)
    phase.setupMs = Date.now() - t0
    const ctx: TrialContext = {
      app: item.app,
      arm: arm.id,
      service: item.service,
      treePath: provisioned.treePath,
      ecosystem: item.ecosystem,
      neatBase: provisioned.neatBase,
      appBase: provisioned.appBase,
      otelCaptureDir: provisioned.otelCaptureDir,
      mcpEntry: defaultMcpEntry(),
      artifactsDir,
      shellTimeoutMs: DEFAULT_SHELL_TIMEOUT_MS,
      securityTimeoutMs: DEFAULT_SECURITY_TIMEOUT_MS,
    }

    // pins
    const lock = await hashLockfile(ctx.treePath, item.ecosystem)
    rec.pins = {
      model: arm.model,
      arm: arm.id,
      app: item.app,
      repo: item.repo,
      commit: item.commit,
      ecosystem: item.ecosystem,
      service: item.service,
      neatVersion: await neatVersion(),
      benchNeatSha: BENCH_NEAT_SHA,
      lockfile: lock,
      effort: EFFORT,
      maxTurns: opts.maxTurns ?? MAX_TURNS,
      taskBudgetTokens: TASK_BUDGET_TOKENS,
      seed: opts.seed ?? 0,
      node: process.version,
      box: os.hostname(),
      groundTruthLocked: item.locked,
      neatBase: ctx.neatBase ?? null,
      appBase: ctx.appBase ?? null,
      asOf: new Date().toISOString(),
    }
    await writeArtifact(artifactsDir, 'dep-tree-pre.json', { lock, advisories: item.advisories.map((a) => ({ dep: a.dep, id: a.id })) })

    // 2. establish baseline: pre-patch green tests (per-trial baselineGreen) + baseline divergences
    const bt0 = Date.now()
    try {
      item.baselineGreen = [...(await runTests(item.testCmd, ctx.treePath))]
    } catch (e) {
      item.baselineGreen = []
      await writeArtifact(artifactsDir, 'baseline-tests-error.txt', String(e))
    }
    let baselineDivergences: Divergence[] = []
    if (ctx.neatBase) {
      try {
        baselineDivergences = await fetchDivergences(ctx.neatBase)
      } catch (e) {
        await writeArtifact(artifactsDir, 'baseline-divergences-error.txt', String(e))
      }
    }
    phase.baselineMs = Date.now() - bt0
    await writeArtifact(artifactsDir, 'baseline.json', { baselineGreen: item.baselineGreen, baselineDivergenceCount: baselineDivergences.length })

    // 3. assemble the arm's tools (NEAT arms: MCP suite + security CLI + Recon)
    const reconState: ReconState = { baselineDivergences }
    let neatToolDefs: ToolDef[] | undefined
    let reconToolDefs: ToolDef[] | undefined
    if (arm.neat) {
      if (!ctx.neatBase) throw new Error('NEAT arm requires a daemon (ctx.neatBase); none provisioned')
      neat = await connectNeatMcp(ctx)
      neatToolDefs = neat.toolDefs
      reconToolDefs = buildReconToolDefs(ctx, reconState)
    }
    const tools = buildTools(arm, ctx, { testCmd: item.testCmd, neatToolDefs, reconToolDefs })
    rec.metrics.toolSurface = tools.map((t) => t.name)

    // 4. run the agent (or the stub for the dry plumbing test)
    const at0 = Date.now()
    const result = opts.stubAgent
      ? await opts.stubAgent(arm, tools, ctx)
      : await runAgent(arm, SYSTEM, TASK, tools, { maxTurns: opts.maxTurns })
    phase.agentMs = Date.now() - at0
    await writeArtifact(artifactsDir, 'transcript.json', result.transcript)
    await writeArtifact(artifactsDir, 'usage.json', { usage: result.usage, costUsd: result.costUsd, turns: result.turns, stopReason: result.stopReason, wallMs: result.wallMs, toolCalls: result.toolCalls })

    // 5. grade (NEAT-independent oracle + Recon QA)
    const gt0 = Date.now()
    // Fix-attributable files for the divergence gate: changed-dep importers + the files the agent
    // actually edited (git diff vs the vulnerable commit). A new divergence outside this set is ambient.
    try {
      const diff = await sh(`git diff --name-only ${item.commit}`, ctx.treePath, 30_000)
      const changed = diff.stdout.split('\n').map((x) => x.trim()).filter(Boolean)
      reconState.attributableFiles = [...new Set([...item.advisories.flatMap((a) => a.importers), ...changed])]
    } catch {
      reconState.attributableFiles = item.advisories.flatMap((a) => a.importers)
    }
    const recon = new ReconQA(ctx, reconState)
    const grade = await gradeTrial(item, ctx.treePath, recon)
    phase.gradeMs = Date.now() - gt0
    rec.grade = grade
    rec.pass = grade.pass
    await writeArtifact(artifactsDir, 'grade.json', grade)

    // post-patch dep tree + scoping
    const lockPost = await hashLockfile(ctx.treePath, item.ecosystem)
    await writeArtifact(artifactsDir, 'dep-tree-post.json', { lock: lockPost })

    // raw evidence artifacts (README reproducibility): the INDEPENDENT ecosystem scanner's raw
    // output, the raw post-patch test id set, and the recon QA output. Best-effort, parallel-safe
    // (own tree + own artifactsDir); never fail the trial on a capture error.
    try {
      const scannerCmd = item.ecosystem === 'npm' ? 'npm audit --json' : item.ecosystem === 'PyPI' ? 'pip-audit -f json' : 'govulncheck -json ./...'
      const so = await sh(scannerCmd, ctx.treePath, ctx.securityTimeoutMs)
      await writeArtifact(artifactsDir, 'scanner-output.json', { cmd: scannerCmd, code: so.code, stdout: so.stdout.slice(0, 2_000_000), stderr: so.stderr.slice(-4000) })
    } catch (e) {
      await writeArtifact(artifactsDir, 'scanner-output.error.txt', String(e))
    }
    try {
      const post = [...(await runTests(item.testCmd, ctx.treePath))]
      await writeArtifact(artifactsDir, 'test-output.json', { testCmd: item.testCmd, baselineGreen: item.baselineGreen, postPatchGreen: post, regressed: item.baselineGreen.filter((t) => !post.includes(t)) })
    } catch (e) {
      await writeArtifact(artifactsDir, 'test-output.error.txt', String(e))
    }
    if (arm.neat) {
      try {
        await writeArtifact(artifactsDir, 'recon-output.json', await reconAssess(ctx, reconState))
      } catch (e) {
        await writeArtifact(artifactsDir, 'recon-output.error.txt', String(e))
      }
    }

    // 6. metrics (the full set the README asks for, derived from captured data)
    const neatToolNames = new Set((neat?.exposed ?? []).concat(['security_scan', 'get_reachable_cves', 'is_reachable', 'scan_diff', 'recon_qa', 'recon_flush', 'recon_probe']))
    const neatUsage: Record<string, number> = {}
    for (const [k, v] of Object.entries(result.toolCalls)) if (neatToolNames.has(k)) neatUsage[k] = v
    rec.metrics = {
      ...rec.metrics,
      outcome: { pass: grade.pass, criteria: grade.criteria },
      cost: { usd: result.costUsd, usage: result.usage },
      time: { totalMs: Date.now() - t0, phase },
      effort: { turns: result.turns, stopReason: result.stopReason, toolCalls: result.toolCalls },
      neatUsage,
      lockfilePre: lock,
      lockfilePost: lockPost,
    }
    await writeArtifact(artifactsDir, 'run.json', { pins: rec.pins, metrics: rec.metrics, grade })
  } catch (e) {
    rec.error = String((e as Error).stack ?? e)
    rec.pass = null
    await writeArtifact(artifactsDir, 'run.json', { pins: rec.pins, metrics: rec.metrics, error: rec.error })
  } finally {
    await neat?.close()
    await provisioned?.teardown()
  }
  return rec
}
