// Per-trial context shared by tools, recon, trial and runner. One value per running
// trial; carries every handle a tool or the oracle needs, so nothing is global and
// parallel trials never collide (each has its own tree, daemon, ports, artifacts).
import type { ArmId } from './arms.js'
import type { Ecosystem } from './grader.js'

export interface TrialContext {
  app: string
  arm: ArmId
  // NEAT service id slug for this app's graph (daemon serves the "default" project;
  // `service` is the ServiceNode name used by the recon verifier, e.g. 'gitea').
  service: string
  // The checkout the agent edits; run_shell runs here, read_file/write_file resolve here.
  treePath: string
  ecosystem: Ecosystem
  // NEAT daemon REST base (NEAT arms only), e.g. http://localhost:8204.
  neatBase?: string
  // Running app base URL for recon journeys, e.g. http://localhost:3001.
  appBase?: string
  // Raw OTel capture dir handed to the BARE arm (traces + logs as files) — the same
  // telemetry the NEAT arms get as a graph, per the fairness invariant.
  otelCaptureDir?: string
  // Absolute path to the NEAT MCP server entry (dist/index.cjs).
  mcpEntry: string
  // runs/<ts>/<arm>/<app>/ — all per-trial artifacts land here.
  artifactsDir: string
  // Bound for every run_shell / tool exec.
  shellTimeoutMs: number
  // Generous bound for the NEAT security CLI (dep resolve + OSV can exceed 2 min).
  securityTimeoutMs: number
}

export const DEFAULT_SHELL_TIMEOUT_MS = 120_000
export const DEFAULT_SECURITY_TIMEOUT_MS = Number(process.env.BENCH_SECURITY_TIMEOUT_MS ?? 600_000)

// Resolve the NEAT MCP server entry from the globally-installed package, overridable.
export function defaultMcpEntry(): string {
  return (
    process.env.NEAT_MCP_ENTRY ??
    '$HOME/.nvm/versions/node/v20.20.2/lib/node_modules/@neat.is/mcp/dist/index.cjs'
  )
}
