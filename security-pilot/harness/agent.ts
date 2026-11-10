import Anthropic from '@anthropic-ai/sdk'
import type { Arm } from './arms.js'
import { EFFORT, MAX_TURNS } from './arms.js'

// A tool the agent can call. Handlers are injected per arm (tools.ts) so the exact
// surface differs by arm (bare vs NEAT) while the loop + capture stay identical = fairness.
export interface ToolDef {
  name: string
  description: string
  input_schema: Anthropic.Tool.InputSchema
  run: (input: any) => Promise<{ content: string; isError?: boolean }>
}

export interface AgentResult {
  stopReason: string
  turns: number
  usage: { input: number; output: number; cacheRead: number; cacheCreation: number }
  costUsd: number
  toolCalls: Record<string, number> // calls per tool name (the "which NEAT tools did it use" signal)
  wallMs: number
  transcript: Anthropic.MessageParam[]
}

// Pinned prices ($/token), claude-api ref. Cost is API-side so it is load-independent.
const PRICE: Record<string, { in: number; out: number }> = {
  'claude-opus-5-5': { in: 4 / 1e6, out: 20 / 1e6 },
  'claude-sonnet-5-5': { in: 2 / 1e6, out: 10 / 1e6 },
}

// The agentic loop. Manual (not the tool-runner) so every token, turn, and tool call is captured
// for the bench. Same model params for every arm; only `tools` and `arm.model` differ.
export async function runAgent(
  arm: Arm,
  systemPrompt: string,
  userTask: string,
  tools: ToolDef[],
  opts: { maxTurns?: number } = {},
): Promise<AgentResult> {
  const client = new Anthropic() // ANTHROPIC_API_KEY from env (~/.neat-bench-secrets/anthropic.env)
  const maxTurns = opts.maxTurns ?? MAX_TURNS
  const toolDefs = tools.map((t) => ({ name: t.name, description: t.description, input_schema: t.input_schema }))
  const byName = new Map(tools.map((t) => [t.name, t]))
  const messages: Anthropic.MessageParam[] = [{ role: 'user', content: userTask }]
  const usage = { input: 0, output: 0, cacheRead: 0, cacheCreation: 0 }
  const toolCalls: Record<string, number> = {}
  const start = Date.now()
  let turns = 0
  let stopReason = 'end_turn'

  while (turns < maxTurns) {
    turns++
    const res = await client.messages.create({
      model: arm.model,
      max_tokens: 16000,
      system: systemPrompt,
      thinking: { type: 'adaptive' },
      output_config: { effort: EFFORT },
      tools: toolDefs,
      messages,
    })
    usage.input += res.usage.input_tokens
    usage.output += res.usage.output_tokens
    usage.cacheRead += res.usage.cache_read_input_tokens ?? 0
    usage.cacheCreation += res.usage.cache_creation_input_tokens ?? 0
    messages.push({ role: 'assistant', content: res.content })
    stopReason = res.stop_reason ?? 'end_turn'
    if (res.stop_reason !== 'tool_use') break

    // Opt-in per-trial cost cap (BENCH_TRIAL_COST_CAP, USD). Honors the bench $25 guardrail: stop a
    // runaway trial BEFORE it blows past, rather than only noticing at the end. 0/unset = no cap.
    const _cap = Number(process.env.BENCH_TRIAL_COST_CAP ?? '0')
    if (_cap > 0) {
      const _pr = PRICE[arm.model] ?? { in: 0, out: 0 }
      const _run = usage.input * _pr.in + usage.output * _pr.out + usage.cacheRead * _pr.in * 0.1
      if (_run > _cap) { stopReason = 'cost-cap'; break }
    }

    // Execute every tool_use block; return ALL tool_results in a single user message (parallel-safe).
    const results: Anthropic.ToolResultBlockParam[] = []
    for (const block of res.content) {
      if (block.type !== 'tool_use') continue
      toolCalls[block.name] = (toolCalls[block.name] ?? 0) + 1
      const tool = byName.get(block.name)
      if (!tool) {
        results.push({ type: 'tool_result', tool_use_id: block.id, content: `unknown tool: ${block.name}`, is_error: true })
        continue
      }
      try {
        const r = await tool.run(block.input)
        results.push({ type: 'tool_result', tool_use_id: block.id, content: r.content, is_error: r.isError })
      } catch (e) {
        results.push({ type: 'tool_result', tool_use_id: block.id, content: String(e), is_error: true })
      }
    }
    messages.push({ role: 'user', content: results })
  }

  const price = PRICE[arm.model] ?? { in: 0, out: 0 }
  // cache reads ~0.1x input price; creation ~1.25x (small, folded into input approx)
  const costUsd = usage.input * price.in + usage.output * price.out + usage.cacheRead * price.in * 0.1
  return { stopReason, turns, usage, costUsd, toolCalls, wallMs: Date.now() - start, transcript: messages }
}
