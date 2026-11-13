// The three bench arms (Sinan's context-dose thesis). Model IDs pinned for reproducibility
// (claude-api ref). bare-opus is the no-NEAT control. neat-sonnet-full and neat-sonnet-lean are the
// SAME model + NEAT; they differ ONLY in context dose: full gets the whole graph tool surface and the
// base prompt; lean gets a card-first surface + the graph-first directive (go direct by default,
// escalate only when the fix is not obvious). That single difference IS the thesis.

export type ArmId = 'bare-opus' | 'neat-sonnet-full' | 'neat-sonnet-lean'

export interface Arm {
  id: ArmId
  model: string // exact Anthropic model id, never date-suffixed
  neat: boolean // gets the NEAT MCP suite + Recon tools
  lean?: boolean // lean dose: card-first NEAT surface + the graph-first directive in the system prompt
  label: string
}

export const ARMS: Arm[] = [
  { id: 'bare-opus', model: 'claude-opus-5-5', neat: false, label: 'Opus (bare)' },
  { id: 'neat-sonnet-full', model: 'claude-sonnet-5-5', neat: true, label: 'NEAT + Sonnet (full)' },
  { id: 'neat-sonnet-lean', model: 'claude-sonnet-5-5', neat: true, lean: true, label: 'NEAT + Sonnet (lean)' },
]

// Shared across every arm for fairness. The only differences allowed are (a) the model id,
// (b) whether the NEAT suite + Recon are present, and (c) the lean dose (card-first surface +
// directive) for neat-sonnet-lean. Everything else (effort, turn cap, task) is identical.
export const EFFORT = 'high' as const // output_config.effort, same for all arms
export const MAX_TURNS = 60 // agent-loop hard turn cap
export const TASK_BUDGET_TOKENS = 500_000 // advisory task budget per trial (beta task-budgets)
export const K = 1 // samples per (arm, scenario) for the pilot; 5 later for variance

// Secrets: ANTHROPIC_API_KEY sourced from ~/.neat-bench-secrets/anthropic.env on the box.
// Never inlined, never committed.
