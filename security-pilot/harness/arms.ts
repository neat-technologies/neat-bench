// The three bench arms. Model IDs pinned for reproducibility (claude-api ref, 2026-10-06).
// NEAT is the only variable between bare-opus and neat-opus; neat-sonnet tests whether
// NEAT lets a cheaper model match or beat bare Opus (the cost/wedge story).

export type ArmId = 'bare-opus' | 'neat-opus' | 'neat-sonnet'

export interface Arm {
  id: ArmId
  model: string // exact Anthropic model id, never date-suffixed
  neat: boolean // gets the NEAT MCP suite + Recon tools
  label: string
}

export const ARMS: Arm[] = [
  { id: 'bare-opus', model: 'claude-opus-5-5', neat: false, label: 'Opus (bare)' },
  { id: 'neat-opus', model: 'claude-opus-5-5', neat: true, label: 'NEAT + Opus' },
  { id: 'neat-sonnet', model: 'claude-sonnet-5-5', neat: true, label: 'NEAT + Sonnet' },
]

// Shared across every arm for fairness. The only differences allowed are (a) the model id
// and (b) whether the NEAT suite + Recon are present. Everything else is identical.
export const EFFORT = 'high' as const // output_config.effort, same for all arms
export const MAX_TURNS = 60 // agent-loop hard turn cap
export const TASK_BUDGET_TOKENS = 500_000 // advisory task budget per trial (beta task-budgets)
export const K = 1 // samples per (arm, scenario) for the pilot; 5 later for variance

// Secrets: ANTHROPIC_API_KEY sourced from ~/.neat-bench-secrets/anthropic.env on the box.
// Never inlined, never committed.
