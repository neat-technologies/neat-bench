// The run matrix: 3 arms x 4 targets x k=1 = 12 trials (pilot). Trials run concurrently, bounded
// by a semaphore AND a RAM floor: the box is a shared gaming rig, so before launching each trial
// the runner checks real MemAvailable and holds if under the floor (keep the game breathing).
// Concurrency must not change results: each trial is fully isolated (own tree, own daemon, own
// ports), so parallel == serial verdicts.
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { ARMS, type Arm } from './arms.js'
import { CORPUS, type BenchCorpusItem } from './corpus.js'
import { runTrial, FreshProvisioner, type Provisioner, type RunTrialOpts, type TrialRecord } from './trial.js'

const GiB = 1024 * 1024 * 1024
export const MAX_CONCURRENCY = Number(process.env.CONCURRENCY ?? '2')

// Real available memory (MemAvailable), not os.freemem() (which excludes reclaimable cache).
export async function availableGi(): Promise<number> {
  try {
    const meminfo = await fs.readFile('/proc/meminfo', 'utf8')
    const m = meminfo.match(/^MemAvailable:\s+(\d+)\s+kB/m)
    if (m) return Number(m[1]) * 1024 / GiB
  } catch {
    /* fall through */
  }
  const os = await import('node:os')
  return os.freemem() / GiB
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms))

// Hold until there is headroom above the RAM floor, then proceed (polls every few seconds).
export async function waitForRam(floorGi: number, label: string): Promise<void> {
  for (;;) {
    const avail = await availableGi()
    if (avail >= floorGi) return
    console.error(`[runner] RAM ${avail.toFixed(1)}Gi < floor ${floorGi}Gi — holding ${label}`)
    await sleep(5000)
  }
}

export interface MatrixOpts {
  runsRoot: string
  runLabel: string
  apps?: string[] // default: all four
  arms?: Arm[] // default: all three
  k?: number
  concurrency?: number
  ramFloorGi?: number
  provisionerFor?: (item: BenchCorpusItem, arm: Arm) => Provisioner
  trialOpts?: Partial<RunTrialOpts>
}

export async function runMatrix(opts: MatrixOpts): Promise<TrialRecord[]> {
  const apps = opts.apps ?? Object.keys(CORPUS)
  const arms = opts.arms ?? ARMS
  const k = opts.k ?? 1
  const concurrency = opts.concurrency ?? MAX_CONCURRENCY
  const ramFloor = opts.ramFloorGi ?? RAM_FLOOR_GI
  const provFor = opts.provisionerFor ?? (() => new FreshProvisioner({ workRoot: path.join(opts.runsRoot, '_trees') }))

  await fs.mkdir(path.join(opts.runsRoot, '_trees'), { recursive: true })

  // Build the full job list (arm x app x seed).
  const jobs: { arm: Arm; item: BenchCorpusItem; seed: number }[] = []
  for (const arm of arms) for (const app of apps) for (let s = 0; s < k; s++) jobs.push({ arm, item: CORPUS[app], seed: s })

  const results: TrialRecord[] = []
  let next = 0
  async function worker(id: number): Promise<void> {
    for (;;) {
      const idx = next++
      if (idx >= jobs.length) return
      const { arm, item, seed } = jobs[idx]
      const label = `${arm.id}/${item.app}#${seed}`
      await waitForRam(ramFloor, label)
      console.error(`[runner] worker ${id} starting ${label} (avail ${(await availableGi()).toFixed(1)}Gi)`)
      const rec = await runTrial(arm, item, provFor(item, arm), {
        runsRoot: opts.runsRoot,
        runLabel: opts.runLabel,
        seed,
        ...opts.trialOpts,
      })
      results.push(rec)
      console.error(`[runner] done ${label}: pass=${rec.pass}${rec.error ? ' ERROR' : ''}`)
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, concurrency) }, (_, i) => worker(i)))

  const summary = {
    runLabel: opts.runLabel,
    asOf: new Date().toISOString(),
    ramFloorGi: ramFloor,
    concurrency,
    trials: results.map((r) => ({ arm: r.arm, app: r.app, pass: r.pass, error: r.error ? r.error.split('\n')[0] : undefined })),
  }
  await fs.writeFile(path.join(opts.runsRoot, opts.runLabel, 'matrix-summary.json'), JSON.stringify(summary, null, 2), 'utf8')
  return results
}

// CLI entry: `tsx harness/runner.ts` runs the full pilot matrix (needs provisioned daemons).
if (import.meta.url === `file://${process.argv[1]}`) {
  const runLabel = new Date().toISOString().replace(/[:.]/g, '-')
  runMatrix({ runsRoot: path.resolve('runs'), runLabel })
    .then((rs) => {
      const pass = rs.filter((r) => r.pass === true).length
      console.error(`[runner] matrix complete: ${pass}/${rs.length} pass`)
    })
    .catch((e) => {
      console.error('[runner] fatal', e)
      process.exit(1)
    })
}
