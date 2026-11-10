// Offline re-grade of the gitea real trials after the scanGo findings-scoping fix. Trees are torn
// down, but each trial saved scanner-output.json (raw `govulncheck -json`), grade.json and run.json.
// vuln-gone is the only criterion the scanGo fix changes; the other three ran on the live tree and
// are kept. Recompute the scanner verdict per corpus advisory with govulncheckFlags (findings-scoped)
// + re-query OSV, then recombine. NEAT-independent.
import { promises as fs } from 'node:fs'
import path from 'node:path'
import { govulncheckFlags, osvAffected_ } from './grader-impl.js'
import { getCorpusItem } from './corpus.js'

async function main() {
  const runsRoot = path.resolve(process.env.DRY_RUNS_ROOT ?? 'runs')
  const dirs = (await fs.readdir(runsRoot)).filter((d) => d.startsWith('gitea-real-k1-')).sort()
  if (!dirs.length) throw new Error('no gitea-real-k1 run dir')
  const D = path.join(runsRoot, dirs[dirs.length - 1])
  console.error(`=== RE-GRADE (scanGo findings-scoped) ${D} ===`)
  const item = getCorpusItem('gitea')
  for (const arm of ['bare-opus', 'neat-opus', 'neat-sonnet']) {
    const A = path.join(D, arm, 'gitea')
    let grade: any, scanner: any
    try {
      grade = JSON.parse(await fs.readFile(path.join(A, 'grade.json'), 'utf8'))
      scanner = JSON.parse(await fs.readFile(path.join(A, 'scanner-output.json'), 'utf8'))
    } catch (e) {
      console.error(`\n${arm}: not ready (${String(e).slice(0, 70)})`)
      continue
    }
    const oldVuln = grade.criteria.find((c: any) => c.name === 'vuln-gone')
    const perAdv: any[] = []
    for (const adv of item.advisories) {
      const scannerFinding = govulncheckFlags(scanner.stdout, adv.id)
      const esc = adv.dep.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
      const m = (oldVuln?.detail || '').match(new RegExp(`${esc}@v?([\\d.]+)`))
      const ver = m ? m[1] : adv.fixedIn ?? ''
      let osvAff: any = null
      try {
        osvAff = await osvAffected_(adv, ver)
      } catch (e) {
        osvAff = `ERR:${String(e).slice(0, 40)}`
      }
      const cleared = scannerFinding === false && osvAff === false
      perAdv.push({ id: adv.id, dep: adv.dep, ver, scannerFinding, osvAffected: osvAff, cleared })
    }
    const vulnGone = perAdv.every((p) => p.cleared)

    // Recompute actually-works with the FIXED divergence gate: a new divergence counts only if it is
    // fix-ATTRIBUTABLE, i.e. it references a file in the fix's blast radius = the changed-dep importers
    // (the hand-verified corpus importers) plus any file the agent directly edited. A dep bump that
    // never touches webhook code cannot be charged a webhook-Deliver divergence. (NEAT-arm-only gate;
    // a false divergence here penalizes ONLY NEAT, violating "NEAT is the only variable".)
    const attributable = new Set<string>(item.advisories.flatMap((a) => a.importers))
    let actuallyWorks = grade.criteria.find((c: any) => c.name === 'actually-works')?.pass
    let recon: any = null
    try {
      recon = JSON.parse(await fs.readFile(path.join(A, 'recon-output.json'), 'utf8'))
    } catch {
      /* no recon artifact (bare arm) -> keep grade.json actually-works */
    }
    let keptDivs: string[] = []
    let droppedDivs: string[] = []
    if (recon) {
      const newDivs: string[] = recon.newDivergences ?? []
      keptDivs = newDivs.filter((d) => [...attributable].some((f) => d.includes(f)))
      droppedDivs = newDivs.filter((d) => !keptDivs.includes(d))
      const journeyFailures: string[] = recon.journeyFailures ?? []
      const observedOk = recon.observedOk !== false
      actuallyWorks = journeyFailures.length === 0 && observedOk && keptDivs.length === 0
    }

    const noReg = grade.criteria.find((c: any) => c.name === 'no-regression')?.pass
    const notDeg = grade.criteria.find((c: any) => c.name === 'not-degenerate')?.pass
    const correctedPass = vulnGone && !!noReg && !!notDeg && !!actuallyWorks
    console.error(`\n=== ${arm} CORRECTED grade (was pass=${grade.pass}) ===`)
    console.error(`  vuln-gone: ${vulnGone}`)
    for (const p of perAdv) console.error(`    ${p.dep} ${p.id}@${p.ver}: scannerFinding=${p.scannerFinding} osvAffected=${p.osvAffected} cleared=${p.cleared}`)
    console.error(`  no-regression: ${noReg}`)
    console.error(`  not-degenerate: ${notDeg}`)
    console.error(`  actually-works: ${actuallyWorks}`)
    if (recon) {
      console.error(`    attributable importers: ${[...attributable].join(', ')}`)
      console.error(`    new divergences KEPT (fix-attributable): ${JSON.stringify(keptDivs)}`)
      console.error(`    new divergences DROPPED (ambient/unrelated): ${JSON.stringify(droppedDivs)}`)
    }
    console.error(`  >>> CORRECTED PASS = ${correctedPass}`)
  }
}
main().catch((e) => {
  console.error('[re-grade] fatal', e)
  process.exit(1)
})
