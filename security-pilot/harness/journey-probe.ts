// Drive one app's journeys against a running instance and print what each answered.
// Usage: tsx harness/journey-probe.ts <app> <baseUrl> [treePath]
import { driveJourneys, getSuite } from '../recon/journeys/index.js'

const [app, base, treePath] = process.argv.slice(2)
if (!app || !base) {
  console.error('usage: journey-probe.ts <app> <baseUrl> [treePath]')
  process.exit(2)
}
const r = await driveJourneys(getSuite(app), base, 2, 40, { treePath })
console.log(JSON.stringify({ failures: r.failures, signatures: r.signatures }, null, 1))
