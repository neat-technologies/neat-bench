// The advisory cache every NEAT security call in a trial reads, held identical across trials.
//
// `neat security scan` keeps its advisory cache (OSV records + fix-diffs) under NEAT_HOME. Left
// unset, every trial shared ~/.neat, so the cache a trial saw depended on which trials ran before
// it: a scan killed at the tool timeout still cached the packages it finished, and a later trial on
// the same app got a complete answer an earlier one never had. That made the NEAT arms' results
// order-dependent.
//
// Now each app has one seed cache, filled by a full scan of the pristine checkout before that
// app's first NEAT trial (outside the agent's clock and turns), and each NEAT trial gets its own
// copy of it as NEAT_HOME. Every NEAT trial on an app starts from the same cache, the way an
// installed NEAT does once its daemon has refreshed advisories, and nothing a trial writes reaches
// another. A seed is refilled when it's older than SEED_MAX_AGE_MS, inside NEAT's 24 h TTL, so no
// trial triggers a refresh of its own.
import { spawn } from 'node:child_process'
import { promises as fs } from 'node:fs'
import path from 'node:path'

const SEED_MAX_AGE_MS = 20 * 60 * 60 * 1000
const SEED_TIMEOUT_MS = Number(process.env.BENCH_ADVISORY_SEED_TIMEOUT_MS ?? 45 * 60 * 1000)
const NEAT_BIN = process.env.NEAT_BIN ?? 'neat'

export interface AdvisoryHome {
  // NEAT_HOME for this trial's security calls.
  home: string
  // When the seed was filled, and how long the fill took (0 when an existing seed was reused).
  seededAt: string
  seedMs: number
}

const seeding = new Map<string, Promise<{ seededAt: string; seedMs: number }>>()

function seedDir(runsRoot: string, app: string): string {
  return path.join(runsRoot, '_advisory-seed', app)
}

async function fill(dir: string, treePath: string): Promise<{ seededAt: string; seedMs: number }> {
  const stampFile = path.join(dir, 'seeded-at')
  try {
    const seededAt = (await fs.readFile(stampFile, 'utf8')).trim()
    if (Date.now() - Date.parse(seededAt) < SEED_MAX_AGE_MS) return { seededAt, seedMs: 0 }
  } catch {
    /* no seed yet */
  }
  await fs.rm(dir, { recursive: true, force: true })
  await fs.mkdir(dir, { recursive: true })
  const t0 = Date.now()
  const seededAt = new Date(t0).toISOString()
  const code = await new Promise<number>((resolve) => {
    const child = spawn('/bin/sh', ['-c', `${NEAT_BIN} security scan "${treePath}" --json > /dev/null 2> "${dir}/seed.err"`], {
      cwd: treePath,
      detached: true,
      env: { ...process.env, NEAT_HOME: path.join(dir, 'home') },
    })
    const timer = setTimeout(() => {
      try {
        if (child.pid) process.kill(-child.pid, 'SIGKILL')
      } catch {
        /* gone */
      }
    }, SEED_TIMEOUT_MS)
    child.on('close', (c) => {
      clearTimeout(timer)
      resolve(c ?? 1)
    })
  })
  if (code !== 0) throw new Error(`advisory seed scan failed (exit ${code}); see ${dir}/seed.err`)
  await fs.writeFile(stampFile, seededAt)
  return { seededAt, seedMs: Date.now() - t0 }
}

/** This trial's NEAT_HOME: a private copy of the app's seed cache, filling the seed first if needed. */
export async function advisoryHomeFor(runsRoot: string, app: string, treePath: string, trialDir: string): Promise<AdvisoryHome> {
  const dir = seedDir(runsRoot, app)
  let p = seeding.get(dir)
  if (!p) {
    p = fill(dir, treePath)
    seeding.set(dir, p)
    p.catch(() => seeding.delete(dir))
  }
  const { seededAt, seedMs } = await p
  // A later trial in the same process can find the seed stale after a long run; refill then.
  if (Date.now() - Date.parse(seededAt) >= SEED_MAX_AGE_MS) {
    seeding.delete(dir)
    return advisoryHomeFor(runsRoot, app, treePath, trialDir)
  }
  const home = path.join(trialDir, 'neat-advisory-home')
  await fs.rm(home, { recursive: true, force: true })
  await fs.cp(path.join(dir, 'home'), home, { recursive: true })
  return { home, seededAt, seedMs }
}
