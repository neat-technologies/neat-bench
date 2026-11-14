import { resolveInstalledVersion, osvAffected_, runScanner, runTestsDetailed, type TestRun } from './grader-impl.js'
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
  // Set when the app's real suite cannot run in this environment and a placeholder command stands in
  // for it. The placeholder passing says nothing about the app, so no-regression reads UNVERIFIED.
  suiteUnavailable?: string
}

export interface ReconQA {
  qa(app: string, treePath: string): Promise<{ works: boolean; journeyFailures: string[]; newDivergences: string[] }>
}

export type Verdict = 'pass' | 'fail' | 'unverified'

export interface Criterion {
  name: 'vuln-gone' | 'no-regression' | 'not-degenerate' | 'actually-works'
  verdict: Verdict
  pass: boolean // convenience mirror of verdict === 'pass' (kept for back-compat printers/consumers)
  detail: string
}

export interface TrialResult {
  app: string
  pass: boolean // overall clean pass: every criterion verdict === 'pass'
  verdict: Verdict // 'fail' if any criterion failed, else 'unverified' if any unverified, else 'pass'
  unverified: string[] // names of criteria that could not be verified (counted out of the headline)
  criteria: Criterion[]
}

function crit(name: Criterion['name'], verdict: Verdict, detail: string): Criterion {
  return { name, verdict, pass: verdict === 'pass', detail }
}

// A set of verdicts collapses worst-first: any fail -> fail; else any unverified -> unverified.
function overallVerdict(criteria: Criterion[]): Verdict {
  if (criteria.some((c) => c.verdict === 'fail')) return 'fail'
  if (criteria.some((c) => c.verdict === 'unverified')) return 'unverified'
  return 'pass'
}

// --- independent authorities (NO NEAT in here) ---

// Resolve the dep's installed version from the post-patch lockfile, then ask OSV whether that
// version is still affected. Cross-checked by the ecosystem scanner (npm audit / pip-audit /
// govulncheck) in runScanner. Both must agree the advisory is cleared.
async function vulnGone(adv: Advisory, treePath: string, preFlagged: boolean | undefined): Promise<Criterion> {
  // Contamination guard: if we positively confirmed the advisory was NOT present on the pre-patch tree,
  // "vuln gone" has no signal (there was nothing to remove) -> UNVERIFIED, never a trivial pass.
  // preFlagged === undefined means the pre-check did not run / errored, so proceed normally.
  if (preFlagged === false) {
    return crit('vuln-gone', 'unverified', `${adv.id}: not flagged on the pre-patch tree (no signal); cannot credit removal`)
  }
  const resolved = await resolveInstalledVersion(adv.ecosystem, adv.dep, treePath) // read lockfile
  const scannerFlags = await runScanner(adv, treePath) // npm audit / pip-audit / govulncheck; throws if it can't run
  if (resolved === null) {
    // Resolver found no version. For a remove/replace fix that is the correct end state (confirm via the
    // scanner). For a bump the dep is expected present, so a null resolve means the resolver is blind,
    // NOT that the vuln is gone -> UNVERIFIED instead of the old fail-open pass.
    if (scannerFlags) return crit('vuln-gone', 'fail', `${adv.dep} still flagged by the scanner (${adv.id}); dep did not resolve`)
    if (adv.fixKind === 'remove' || adv.fixKind === 'replace') {
      return crit('vuln-gone', 'pass', `${adv.dep} removed from the resolved tree; scanner clear (${adv.id})`)
    }
    return crit('vuln-gone', 'unverified', `${adv.dep} did not resolve to a version (expected a ${adv.fixKind}); scanner clear but the fixed version cannot be confirmed`)
  }
  const osvAffected = await osvAffected_(adv, resolved) // POST api.osv.dev/v1/query, check ranges
  const cleared = !osvAffected && !scannerFlags
  return crit(
    'vuln-gone',
    cleared ? 'pass' : 'fail',
    cleared
      ? `${adv.dep}@${resolved} outside ${adv.id} affected range (OSV + scanner agree)`
      : `${adv.dep}@${resolved} still flagged (osvAffected=${osvAffected}, scanner=${scannerFlags})`,
  )
}

// Run the app's own suite; a regression is any baseline-green test now failing.
function noRegression(item: CorpusItem, run: TestRun): Criterion {
  if (item.suiteUnavailable) {
    return crit('no-regression', 'unverified', `the app's real suite cannot run in this env (${item.suiteUnavailable}); a placeholder ran instead, which certifies nothing`)
  }
  // A vacuous baseline (capture failed, or the suite ran nothing) cannot certify "no regression".
  if (item.baselineGreen.length === 0) {
    return crit('no-regression', 'unverified', 'no baseline-green tests captured (suite did not run at baseline); cannot certify no-regression')
  }
  const regressed = item.baselineGreen.filter((t) => run.ran.has(t) && !run.passed.has(t)) // ran and now failing
  const notRun = item.baselineGreen.filter((t) => !run.ran.has(t)) // did not execute post-patch (env/skip)
  if (regressed.length) return crit('no-regression', 'fail', `regressed: ${regressed.join(', ')}`)
  if (notRun.length) {
    const shown = notRun.slice(0, 8).join(', ')
    return crit('no-regression', 'unverified', `baseline-green tests did not run post-patch (env): ${shown}${notRun.length > 8 ? ` +${notRun.length - 8} more` : ''}`)
  }
  return crit('no-regression', 'pass', 'baseline-green tests still green')
}

// The tests that exercised the vulnerable path must still exist and pass: can't "fix" by deleting
// the feature.
function notDegenerate(item: CorpusItem, run: TestRun): Criterion {
  const vulnPathTests = [...new Set(item.advisories.flatMap((a) => a.vulnPathTests))]
  if (vulnPathTests.length === 0) {
    return crit('not-degenerate', 'unverified', 'no vuln-path tests defined for this item; cannot guard against degenerate removal')
  }
  // Baseline-compared: a vuln-path test can only show the fix broke the feature if it was GREEN before
  // the fix. One that was not green at baseline (container-gated, flaky, absent in this env) carries no
  // signal either way, so its post-patch state is never attributed to the agent.
  const baseline = new Set(item.baselineGreen)
  const guardable = vulnPathTests.filter((t) => baseline.has(t))
  const noBaseline = vulnPathTests.filter((t) => !baseline.has(t))
  const failed = guardable.filter((t) => run.ran.has(t) && !run.passed.has(t)) // green before, failing now = feature broken/removed
  const notRun = guardable.filter((t) => !run.ran.has(t)) // green before, did not execute now -> cannot confirm it survived
  if (failed.length) return crit('not-degenerate', 'fail', `vuln-path tests green at baseline now failing (feature broken/removed): ${failed.join(', ')}`)
  if (guardable.length === 0) {
    return crit('not-degenerate', 'unverified', `no vuln-path test was green at baseline in this env, so the feature cannot be guarded: ${noBaseline.join(', ')}`)
  }
  if (notRun.length) return crit('not-degenerate', 'unverified', `vuln-path tests did not run post-patch (env/skip); cannot confirm the feature survived: ${notRun.join(', ')}`)
  if (noBaseline.length) {
    return crit('not-degenerate', 'unverified', `${guardable.length} vuln-path test(s) pass, but ${noBaseline.length} had no green baseline and cannot be guarded: ${noBaseline.join(', ')}`)
  }
  return crit('not-degenerate', 'pass', 'vuln-path tests persist and pass')
}

export async function gradeTrial(
  item: CorpusItem,
  treePath: string,
  recon: ReconQA,
  opts: { preFlagged?: Record<string, boolean>; baselineJourneyFailures?: string[]; deploy?: { ok: boolean; detail: string } } = {},
): Promise<TrialResult> {
  const pre = opts.preFlagged ?? {}
  const vuln = await Promise.all(item.advisories.map((a) => vulnGone(a, treePath, pre[a.id])))
  const vulnGoneAll = crit('vuln-gone', overallVerdict(vuln), vuln.map((c) => `${c.verdict}: ${c.detail}`).join(' | '))

  // Run the native suite ONCE (was twice) and feed both the regression + degenerate checks.
  const run = await runTestsDetailed(item.testCmd, treePath)
  const reg = noRegression(item, run)
  const deg = notDegenerate(item, run)

  const qa = await recon.qa(item.app, treePath)
  // Baseline-compared: journeys that already failed BEFORE the fix (the app never came up in this env)
  // say nothing about the fix. Only a journey that worked at baseline and fails now is the fix's doing.
  const baseFail = opts.baselineJourneyFailures
  const preExisting = baseFail ? qa.journeyFailures.filter((j) => baseFail.includes(j)) : []
  const introduced = baseFail ? qa.journeyFailures.filter((j) => !baseFail.includes(j)) : qa.journeyFailures
  // The verdict rests on the redeploy and the journeys alone. Both are the same for every arm and
  // neither reads NEAT. NEAT's own signals (new declared-vs-observed divergences, OBSERVED still
  // materializing) exist only for the NEAT arms, so counting them would hold those arms to a check
  // the bare arm never faces, and would put NEAT inside its own oracle. They are reported, not graded.
  const neatNote = qa.newDivergences.length ? ` (NEAT reports ${qa.newDivergences.length} new divergence(s), not graded: ${qa.newDivergences.slice(0, 4).join(', ')})` : ''
  let works: Criterion
  if (opts.deploy && !opts.deploy.ok) {
    // The patched checkout does not build or boot. Whatever is still answering is the old process.
    works = crit('actually-works', 'fail', `the patched checkout could not be rebuilt and restarted: ${opts.deploy.detail.slice(-300)}`)
  } else if (introduced.length > 0) {
    works = crit('actually-works', 'fail', `journeys that worked at baseline now fail or answer differently: ${introduced.join(', ')}${neatNote}`)
  } else if (preExisting.length > 0) {
    works = crit('actually-works', 'unverified', `app journeys already failed at baseline in this env (not attributable to the fix): ${preExisting.slice(0, 6).join(', ')}${neatNote}`)
  } else if (!opts.deploy) {
    // Journeys pass, but against a process that was never rebuilt from the patched checkout.
    works = crit('actually-works', 'unverified', `journeys pass, but the running app was not redeployed from the patched checkout, so they exercised pre-fix code${neatNote}`)
  } else {
    works = crit('actually-works', 'pass', `every journey answers as it did at baseline on the redeployed app${neatNote}`)
  }
  const criteria = [vulnGoneAll, reg, deg, works]
  const verdict = overallVerdict(criteria)
  return {
    app: item.app,
    pass: verdict === 'pass',
    verdict,
    unverified: criteria.filter((c) => c.verdict === 'unverified').map((c) => c.name),
    criteria,
  }
}

// --- ecosystem-specific helpers: implemented, NEAT-independent, in grader-impl.ts (imported at top) ---
