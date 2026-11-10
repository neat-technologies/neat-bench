// Diagnostic: stand DRY_APP up (NEAT arm) and probe the daemon's /health and /graph via curl
// (status / size / reset), capture the daemon log + RSS before teardown. No grade, no API.
import { promises as fs } from 'node:fs'
import { exec } from 'node:child_process'
import path from 'node:path'
import { ARMS } from './arms.js'
import { getCorpusItem } from './corpus.js'
import { FreshProvisioner } from './trial.js'

function sh(cmd: string): Promise<{ code: number; stdout: string; stderr: string }> {
  return new Promise((r) => exec(cmd, { maxBuffer: 256 * 1024 * 1024 }, (e, so, se) => r({ code: e && typeof (e as any).code === 'number' ? (e as any).code : e ? 1 : 0, stdout: so, stderr: se })))
}

async function main() {
  const app = process.env.DRY_APP ?? 'gitea'
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const workRoot = path.join(runsRoot, 'diag', '_trees')
  await fs.mkdir(workRoot, { recursive: true })
  const item = getCorpusItem(app)
  console.error(`=== diag app=${app} ===`)
  const prov = new FreshProvisioner({ workRoot })
  const st = await prov.provision(item, ARMS.find((a) => a.id === 'neat-opus')!)
  const workDir = `${st.treePath}__work`
  try {
    console.error(`neatBase=${st.neatBase} treePath=${st.treePath}`)
    const port = (st.neatBase ?? '').split(':').pop()
    // daemon pid + RSS
    const pid = (await fs.readFile(path.join(workDir, 'neatd.pid'), 'utf8').catch(() => '')).trim()
    const rss = await sh(`ps -o rss= -p ${pid} 2>/dev/null | awk '{printf "%.0f MB", $1/1024}'`)
    console.error(`daemon pid=${pid} rss=${rss.stdout.trim()}`)
    // health
    const h = await sh(`curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:${port}/health`)
    console.error(`/health -> ${h.stdout.trim()} (code=${h.code})`)
    // graph: status, size, time; save body
    const bodyPath = path.join(runsRoot, 'diag', `graph-${app}.json`)
    const g = await sh(`curl -s -m 120 -o '${bodyPath}' -w 'http=%{http_code} size=%{size_download} time=%{time_total}' http://127.0.0.1:${port}/graph`)
    console.error(`/graph -> ${g.stdout.trim()} (curl exit=${g.code}) ${g.stderr.slice(-200)}`)
    const stat = await fs.stat(bodyPath).catch(() => null)
    console.error(`/graph body file: ${stat ? stat.size : 0} bytes`)
    if (stat && stat.size > 0) {
      try {
        const j = JSON.parse(await fs.readFile(bodyPath, 'utf8'))
        console.error(`/graph parsed: nodes=${j.nodes?.length} edges=${j.edges?.length}`)
      } catch (e) {
        console.error(`/graph parse failed: ${String(e).slice(0, 120)}`)
      }
    }
    // divergences
    const d = await sh(`curl -s -m 60 -o /dev/null -w 'http=%{http_code} size=%{size_download}' http://127.0.0.1:${port}/graph/divergences`)
    console.error(`/graph/divergences -> ${d.stdout.trim()} (curl exit=${d.code})`)

    // app log: did the OTel SDK/exporter init? any export errors? (the span-emission question)
    const appLog = await fs.readFile(path.join(workDir, 'logs', 'app.log'), 'utf8').catch(() => '(no app.log)')
    console.error(`--- app.log tail ---\n${appLog.split('\n').slice(-30).join('\n')}`)
    const otelLines = appLog.split('\n').filter((l) => /otel|otlp|trace|exporter|span|instrument/i.test(l))
    console.error(`--- app.log OTel-ish lines (${otelLines.length}) ---\n${otelLines.slice(0, 30).join('\n')}`)

    // re-drive a bit of traffic against the app, wait for flush, recheck OBSERVED.
    const appPort = (st.appBase ?? '').split(':').pop()
    for (let i = 0; i < 8; i++) {
      await sh(`curl -s -m 8 -o /dev/null http://127.0.0.1:${appPort}/api/v1/version`)
      await sh(`curl -s -m 8 -o /dev/null http://127.0.0.1:${appPort}/`)
    }
    await new Promise((r) => setTimeout(r, 6000))
    const g2 = await sh(`curl -s -m 120 -o '${bodyPath}.2' http://127.0.0.1:${port}/graph`)
    try {
      const j2 = JSON.parse(await fs.readFile(`${bodyPath}.2`, 'utf8'))
      const obs2 = (j2.edges ?? []).filter((e: any) => e.provenance === 'OBSERVED')
      console.error(`after extra traffic: OBSERVED edges total=${obs2.length} (curl exit=${g2.code})`)
    } catch (e) {
      console.error(`recheck parse failed: ${String(e).slice(0, 120)}`)
    }

    // daemon log tail
    const log = await fs.readFile(path.join(workDir, 'logs', 'neatd.log'), 'utf8').catch(() => '(no log)')
    console.error(`--- neatd.log tail ---\n${log.split('\n').slice(-25).join('\n')}`)
  } finally {
    await st.teardown()
    console.error('torn down')
  }
}
main().catch((e) => { console.error('[diag] fatal', e); process.exit(1) })
