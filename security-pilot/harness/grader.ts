import { resolveInstalledVersion, osvAffected_, runScanner, runTests } from './grader-impl.js'
// The bench grader. The pass oracle is deterministic and, for the vuln check, INDEPENDENT of
// NEAT (OSV + the ecosystem's own scanner decide "vuln gone", never NEAT's scanner) so the bench
// can never grade itself. recon.qa supplies the "actually works" signal (its own spec); the
// vuln/regression/degenerate checks here do not call NEAT at all.

export type Ecosystem = 'npm' | 'PyPI' | 'Go'
export type FixKind = 'bump' | 'remove' | 'replace' | 'mitigate'

export interface Advisory {
  id: string // GHSA/CVE
  ecosystem: Ecosystem
  dep: string
  vulnerableRange: string // OSV affected range, for the independent check
  fixedIn: string | null
  importers: string[] // first-party files that import the dep (reachability ground truth)
  fixKind: FixKind
  vulnPathTests: string[] // tests that exercise the vulnerable path (degenerate guard)
}

export interface CorpusItem {
  app: string
  repo: string
  commit: string
  testCmd: string // native framework per app (node --test / pytest / go test / npm test)
  advisories: Advisory[] // the reachable CVEs to remediate
  auditNoise: string[] // transitive/unused advisory ids present, to measure bare over-fixing
  baselineGreen: string[] // test ids green at `commit` before any patch (established per trial)
}

export interface ReconQA {
  qa(app: string, treePath: string): Promise<{ works: boolean; journeyFailures: string[]; newDivergences: string[] }>
}

export interface Criterion {
  name: 'vuln-gone' | 'no-regression' | 'not-degenerate' | 'actually-works'
  pass: boolean
  detail: string
}

export interface TrialResult {
  app: string
  pass: boolean
  criteria: Criterion[]
}

// --- independent authorities (NO NEAT in here) ---

// Resolve the dep's installed version from the post-patch lockfile, then ask OSV whether that
// version is still affected. Cross-checked by the ecosystem scanner (npm audit / pip-audit /
// govulncheck) in runScanner. Both must agree the advisory is cleared.
async function vulnGone(adv: Advisory, treePath: string): Promise<Criterion> {
  const resolved = await resolveInstalledVersion(adv.ecosystem, adv.dep, treePath) // read lockfile
  if (resolved === null) {
    return { name: 'vuln-gone', pass: true, detail: `${adv.dep} removed from the resolved tree` }
  }
  const osvAffected = await osvAffected_(adv, resolved) // POST api.osv.dev/v1/query, check ranges
  const scannerFlags = await runScanner(adv, treePath) // npm audit / pip-audit / govulncheck
  const cleared = !osvAffected && !scannerFlags
  return {
    name: 'vuln-gone',
    pass: cleared,
    detail: cleared
      ? `${adv.dep}@${resolved} outside ${adv.id} affected range (OSV + scanner agree)`
      : `${adv.dep}@${resolved} still flagged (osvAffected=${osvAffected}, scanner=${scannerFlags})`,
  }
}

// Run the app's own suite; a regression is any baseline-green test now failing.
async function noRegression(item: CorpusItem, treePath: string): Promise<Criterion> {
  const now = await runTests(item.testCmd, treePath) // -> set of passing test ids
  const regressed = item.baselineGreen.filter((t) => !now.has(t))
  return {
    name: 'no-regression',
    pass: regressed.length === 0,
    detail: regressed.length === 0 ? 'baseline-green tests still green' : `regressed: ${regressed.join(', ')}`,
  }
}

// The tests that exercised the vulnerable path must still exist and pass: can't "fix" by deleting
// the feature.
async function notDegenerate(item: CorpusItem, treePath: string): Promise<Criterion> {
  const now = await runTests(item.testCmd, treePath)
  const vulnPathTests = item.advisories.flatMap((a) => a.vulnPathTests)
  const missing = vulnPathTests.filter((t) => !now.has(t))
  return {
    name: 'not-degenerate',
    pass: missing.length === 0,
    detail: missing.length === 0 ? 'vuln-path tests persist and pass' : `missing/failing path tests: ${missing.join(', ')}`,
  }
}

export async function gradeTrial(item: CorpusItem, treePath: string, recon: ReconQA): Promise<TrialResult> {
  const vuln = await Promise.all(item.advisories.map((a) => vulnGone(a, treePath)))
  const vulnGoneAll: Criterion = {
    name: 'vuln-gone',
    pass: vuln.every((c) => c.pass),
    detail: vuln.map((c) => c.detail).join(' | '),
  }
  const reg = await noRegression(item, treePath)
  const deg = await notDegenerate(item, treePath)
  const qa = await recon.qa(item.app, treePath)
  const works: Criterion = {
    name: 'actually-works',
    pass: qa.works && qa.newDivergences.length === 0,
    detail: qa.works
      ? qa.newDivergences.length === 0
        ? 'journeys correct, no new divergence'
        : `new divergence introduced: ${qa.newDivergences.join(', ')}`
      : `journeys failed: ${qa.journeyFailures.join(', ')}`,
  }
  const criteria = [vulnGoneAll, reg, deg, works]
  return { app: item.app, pass: criteria.every((c) => c.pass), criteria }
}

// --- ecosystem-specific helpers: implemented, NEAT-independent, in grader-impl.ts (imported at top) ---
