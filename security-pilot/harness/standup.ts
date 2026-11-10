// Per-trial app standup for the FreshProvisioner. Given a fresh checkout, this stands the app up
// instrumented and drives baseline traffic so the OBSERVED layer materializes:
//   NEAT arm  -> start a MAIN-build `neat watch` daemon on the checkout (EXTRACTED + OBSERVED
//                fused), point the app's OTLP at the daemon's OTEL_PORT, drive the recipe traffic.
//   BARE arm  -> start a plain otelcol-contrib (otlp receiver + file exporter for traces+logs),
//                point the app's OTLP at it, drive the SAME traffic, so the bare agent gets the raw
//                OTel capture as files (fairness: same telemetry, as a graph vs as files).
// App-specific work (deps/seed/app-start/traffic) lives in the per-app <app>-fresh.sh recipes
// (adapted from the validated run.sh scripts). The daemon + collector lifecycle is owned here so
// teardown is clean via pid files (never pkill -f). Fresh ports + per-run NEAT_HOME per trial, so
// it never touches neat-ba's live daemons on :8201-8205.
import { exec } from 'node:child_process'
import { promises as fs } from 'node:fs'
import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomBytes } from 'node:crypto'
import type { Arm } from './arms.js'
import type { BenchCorpusItem } from './corpus.js'

// The box's main-build NEAT CLI (packages/core/dist/cli.cjs). Built from BENCH_NEAT_SHA; the daemon
// started for NEAT arms uses THIS, not the globally-installed `neat`. Bump BENCH_NEAT_SHA to the
// final pinned SHA and rebuild; the harness records it in run.json via neatVersion()/pins.
export const BENCH_NEAT_SHA = process.env.BENCH_NEAT_SHA ?? 'eb330c2f382f'
export function neatCliPath(): string {
  return process.env.BENCH_NEAT_CLI ?? '$HOME/neat-src/packages/core/dist/cli.cjs'
}
const SECURITY_PILOT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
export function otelcolBin(): string {
  return process.env.BENCH_OTELCOL ?? path.join(SECURITY_PILOT_ROOT, 'bin', 'otelcol-contrib')
}

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms))

function sh(cmd: string, cwd: string, timeoutMs: number, env?: NodeJS.ProcessEnv): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((resolve) => {
    exec(cmd, { cwd, timeout: timeoutMs, maxBuffer: 64 * 1024 * 1024, env: env ?? process.env }, (err, stdout, stderr) =>
      resolve({ code: err && typeof (err as any).code === 'number' ? (err as any).code : err ? 1 : 0, stdout, stderr }),
    )
  })
}

// An OS-assigned free loopback port. Small TOCTOU window between close and reuse; acceptable for
// the bench (sequential dry test; parallel trials each grab their own and a collision just fails
// the standup loudly rather than silently sharing).
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer()
    srv.on('error', reject)
    srv.listen(0, '127.0.0.1', () => {
      const addr = srv.address() as net.AddressInfo
      const p = addr.port
      srv.close(() => resolve(p))
    })
  })
}

async function waitHttpOk(url: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  let last = ''
  while (Date.now() < deadline) {
    try {
      const r = await fetch(url, { signal: AbortSignal.timeout(4000) })
      if (r.ok) return
      last = `HTTP ${r.status}`
    } catch (e) {
      last = (e as Error).message
    }
    await sleep(1500)
  }
  throw new Error(`timed out waiting for ${url} (${timeoutMs}ms; last=${last})`)
}

function tcpUp(host: string, port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const s = net.connect({ host, port })
    const done = (ok: boolean) => {
      s.destroy()
      resolve(ok)
    }
    s.once('connect', () => done(true))
    s.once('error', () => done(false))
    s.setTimeout(2000, () => done(false))
  })
}

async function waitTcp(host: string, port: number, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    if (await tcpUp(host, port)) return
    await sleep(800)
  }
  throw new Error(`timed out waiting for tcp ${host}:${port} (${timeoutMs}ms)`)
}

// Per-app recipe wiring. The corpus app id equals the app's directory name under security-pilot.
interface Recipe {
  dir: string
  script: string // relative to SECURITY_PILOT_ROOT
  driver?: string // relative driver (kuma socket.io)
}
const RECIPES: Record<string, Recipe> = {
  nodegoat: { dir: 'nodegoat', script: 'nodegoat/nodegoat-fresh.sh' },
  'uptime-kuma': { dir: 'uptime-kuma', script: 'uptime-kuma/kuma-fresh.sh', driver: 'uptime-kuma/kuma-drive.cjs' },
  'paperless-ngx': { dir: 'paperless-ngx', script: 'paperless-ngx/paperless-fresh.sh' },
  gitea: { dir: 'gitea', script: 'gitea/gitea-fresh.sh' },
}

async function resolveOtelNodeTgz(): Promise<string> {
  const dir = path.join(SECURITY_PILOT_ROOT, 'nodegoat')
  const entries = await fs.readdir(dir).catch(() => [] as string[])
  const tgz = entries.find((e) => /^otel-node-main-.*\.tgz$/.test(e))
  if (!tgz) throw new Error(`no @neat.is/otel-node tarball under ${dir}`)
  return path.join(dir, tgz)
}

export interface StandupHandles {
  neatBase?: string
  appBase: string
  otelCaptureDir?: string
  teardown: () => Promise<void>
}

export async function standUp(item: BenchCorpusItem, arm: Arm, treePath: string): Promise<StandupHandles> {
  const recipe = RECIPES[item.app]
  if (!recipe) throw new Error(`no standup recipe for app '${item.app}'`)
  const appDir = path.join(SECURITY_PILOT_ROOT, recipe.dir)
  const scriptPath = path.join(SECURITY_PILOT_ROOT, recipe.script)
  const workDir = `${treePath}__work`
  const logsDir = path.join(workDir, 'logs')
  await fs.mkdir(logsDir, { recursive: true })
  const nodeBin = path.dirname(process.execPath)
  const sidecar = path.join(appDir, 'attach', 'node_modules', '@neat.is', 'otel-node', 'register.cjs')
  const tgz = await resolveOtelNodeTgz()

  // teardown is assembled up front so a failed standup still cleans the processes it started.
  const teardownScript = path.join(workDir, '_teardown.sh')
  await fs.writeFile(
    teardownScript,
    [
      '#!/usr/bin/env bash',
      '# Clean per-trial teardown via pid files + recorded containers. NO pkill -f.',
      `W="${workDir}"`,
      'for f in app.pid neatd.pid otelcol.pid sink.pid; do [ -f "$W/$f" ] && kill "$(cat "$W/$f")" 2>/dev/null; done',
      'if [ -f "$W/extra-pids" ]; then while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < "$W/extra-pids"; fi',
      'sleep 1',
      'for f in app.pid neatd.pid otelcol.pid sink.pid; do [ -f "$W/$f" ] && kill -9 "$(cat "$W/$f")" 2>/dev/null; done',
      'if [ -f "$W/extra-pids" ]; then while read -r p; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done < "$W/extra-pids"; fi',
      'if [ -f "$W/docker-containers" ]; then while read -r c; do [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1; done < "$W/docker-containers"; fi',
      'exit 0',
      '',
    ].join('\n'),
    'utf8',
  )
  const teardown = async () => {
    await sh(`bash "${teardownScript}"`, SECURITY_PILOT_ROOT, 60_000).catch(() => {})
    await fs.rm(workDir, { recursive: true, force: true }).catch(() => {})
  }

  try {
    const appPort = await freePort()
    let neatBase: string | undefined
    let otelCaptureDir: string | undefined
    let otlpTracesEndpoint: string
    let otlpBaseEndpoint: string

    if (arm.neat) {
      // MAIN-build NEAT daemon on the checkout. Own NEAT_HOME + fresh ports.
      const restPort = await freePort()
      const otelPort = await freePort()
      const neatHome = path.join(workDir, 'neat-home')
      await fs.mkdir(neatHome, { recursive: true })
      const cli = neatCliPath()
      const daemonLog = path.join(logsDir, 'neatd.log')
      const daemonPid = path.join(workDir, 'neatd.pid')
      const cmd = `nohup "${process.execPath}" "${cli}" watch "${treePath}" > "${daemonLog}" 2>&1 < /dev/null & echo $! > "${daemonPid}"`
      await sh(cmd, workDir, 30_000, {
        ...process.env,
        PATH: `${nodeBin}:${process.env.PATH ?? ''}`,
        NEAT_HOME: neatHome,
        NEAT_WEB_DISABLED: '1',
        PORT: String(restPort),
        OTEL_PORT: String(otelPort),
        HOST: '127.0.0.1',
      })
      // Large repos (e.g. gitea) take longer to extract before the daemon serves /health.
      await waitHttpOk(`http://127.0.0.1:${restPort}/health`, Number(process.env.BENCH_DAEMON_HEALTH_MS ?? 300_000))
      neatBase = `http://127.0.0.1:${restPort}`
      otlpTracesEndpoint = `http://127.0.0.1:${otelPort}/v1/traces`
      otlpBaseEndpoint = `http://127.0.0.1:${otelPort}`
    } else {
      // BARE arm: plain otelcol-contrib, otlp receiver -> file exporter (traces + logs).
      const grpcPort = await freePort()
      const httpPort = await freePort()
      otelCaptureDir = path.join(workDir, 'otel-capture')
      await fs.mkdir(otelCaptureDir, { recursive: true })
      const cfgPath = path.join(workDir, 'otelcol.yaml')
      await fs.writeFile(cfgPath, otelcolConfig(grpcPort, httpPort, otelCaptureDir), 'utf8')
      const colLog = path.join(logsDir, 'otelcol.log')
      const colPid = path.join(workDir, 'otelcol.pid')
      const cmd = `nohup "${otelcolBin()}" --config "${cfgPath}" > "${colLog}" 2>&1 < /dev/null & echo $! > "${colPid}"`
      await sh(cmd, workDir, 30_000)
      await waitTcp('127.0.0.1', httpPort, 30_000)
      otlpTracesEndpoint = `http://127.0.0.1:${httpPort}/v1/traces`
      otlpBaseEndpoint = `http://127.0.0.1:${httpPort}`
    }

    const mongoPort = await freePort()
    const tag = randomBytes(3).toString('hex')
    const mongoName = `sec-pilot-fresh-${item.app}-${arm.id}-${tag}`
    // paperless needs TWO datastores on fresh host ports (postgres + redis), each its own container.
    const pgPort = await freePort()
    const redisPort = await freePort()
    // OTLP wire protocol is ecosystem-specific: @neat.is/otel-node (npm) exports http/json, but the
    // Go (otelc) and Python OTLP exporters only speak http/protobuf. The daemon's OTLP receiver and
    // otelcol-contrib both accept either; the APP is what's picky. Matches the validated recipes
    // (nodegoat/kuma http/json; gitea/paperless http/protobuf).
    const otlpProtocol = item.ecosystem === 'npm' ? 'http/json' : 'http/protobuf'
    const env: NodeJS.ProcessEnv = {
      ...process.env,
      PATH: `${nodeBin}:${process.env.PATH ?? ''}`,
      ARM: arm.neat ? 'neat' : 'bare',
      SRC: treePath,
      WORK: workDir,
      APP_PORT: String(appPort),
      OTLP_TRACES_ENDPOINT: otlpTracesEndpoint,
      OTLP_ENDPOINT: otlpBaseEndpoint,
      OTLP_PROTOCOL: otlpProtocol,
      SIDECAR: sidecar,
      APP_DIR: appDir,
      NODE_BIN: nodeBin,
      OTEL_NODE_TGZ: tgz,
      MONGO_PORT: String(mongoPort),
      MONGO_NAME: mongoName,
      PG_PORT: String(pgPort),
      REDIS_PORT: String(redisPort),
      PG_NAME: `sec-pilot-fresh-${item.app}-${arm.id}-${tag}-pg`,
      REDIS_NAME: `sec-pilot-fresh-${item.app}-${arm.id}-${tag}-redis`,
      DRIVER: recipe.driver ? path.join(SECURITY_PILOT_ROOT, recipe.driver) : '',
      DRIVE_SECS: process.env.DRIVE_SECS ?? '10',
    }
    // Generous timeout: a fresh npm ci / go build / docker build dominates setup.
    const r = await sh(`bash "${scriptPath}"`, workDir, 1_800_000, env)
    await fs.writeFile(path.join(logsDir, 'standup.out'), `${r.stdout}\n--- stderr ---\n${r.stderr}`, 'utf8').catch(() => {})
    if (r.code !== 0) {
      throw new Error(`standup script failed (code ${r.code}): ${(r.stdout + r.stderr).slice(-700)}`)
    }

    return { neatBase, appBase: `http://127.0.0.1:${appPort}`, otelCaptureDir, teardown }
  } catch (e) {
    // Preserve logs (daemon/app/build) before teardown rm's the work dir, so failures are diagnosable.
    try {
      const dest = path.join(SECURITY_PILOT_ROOT, 'runs', '_faillogs', `${item.app}-${arm.id}-${randomBytes(3).toString('hex')}`)
      await fs.mkdir(path.dirname(dest), { recursive: true })
      await fs.cp(logsDir, dest, { recursive: true }).catch(() => {})
    } catch {
      /* best effort */
    }
    await teardown()
    throw e
  }
}

function otelcolConfig(grpcPort: number, httpPort: number, captureDir: string): string {
  return `receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:${grpcPort}
      http:
        endpoint: 127.0.0.1:${httpPort}
exporters:
  file/traces:
    path: ${path.join(captureDir, 'traces.jsonl')}
  file/logs:
    path: ${path.join(captureDir, 'logs.jsonl')}
service:
  telemetry:
    logs:
      level: warn
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [file/traces]
    logs:
      receivers: [otlp]
      exporters: [file/logs]
`
}

// Exposed for the hostname pin / diagnostics.
export function box(): string {
  return os.hostname()
}
