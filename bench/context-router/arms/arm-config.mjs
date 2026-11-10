#!/usr/bin/env node
// Build one arm's agent configuration as JSON. run.sh executes it; tests check it.
//
//   node arms/arm-config.mjs <task.json> <bare|full|lean-full|oracle|jev> --skill-dir <dir> [--route <route.json>]
//
// The `full` arm reproduces harness/arms/run-arm.sh's WITH arm byte for byte:
// the same allowed tools, the same GRAPH_FIRST.md text as `$(cat ...)` yields
// (trailing newlines stripped), and the same search-nudge hook settings string.
// The other arms change only what the arms table in the README says they change.


import { readFileSync } from 'node:fs'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { renderNote } from '../router/render.mjs'

export const ARMS = ['bare', 'full', 'lean-full', 'oracle', 'jev']
// Copied from harness/arms/run-arm.sh (frozen); the order is part of the byte match.
export const BASE_TOOLS = 'Read,Grep,Glob,Edit,Bash'
export const NEAT_TOOLS_ALLOW =
  'get_graph,get_divergences,get_root_cause,get_blast_radius,get_observed_dependencies,get_dependencies,get_incident_history,get_graph_diff,get_recent_stale_edges,semantic_search,check_policies'

const bytes = (s) => (s ? Buffer.byteLength(s, 'utf8') : 0)

/** What `"$(cat file 2>/dev/null)"` produces: the file without trailing newlines. */
export function graphFirstText(skillDir) {
  return readFileSync(`${skillDir}/GRAPH_FIRST.md`, 'utf8').replace(/\n+$/, '')
}

/** The settings string run-arm.sh builds for its hook; `envPrefix` is for lean-full only. */
export function hookSettings(skillDir, envPrefix = '') {
  return JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: 'Grep|Glob|Bash', hooks: [{ type: 'command', command: `${envPrefix}node ${skillDir}/hooks/neat-search-nudge.mjs` }] },
      ],
    },
  })
}

// The lean-full arm: today's NEAT with the opt-in lean-session switches from
// neat-technologies/neat#1611 and a short directive. A NEAT build without those
// switches ignores them, so run.sh records the NEAT commit under test.
export const LEAN_MCP_ENV = Object.freeze({ NEAT_SESSION_LEAD: '0', NEAT_MCP_TOOLS: 'core' })
export const LEAN_HOOK_ENV = 'NEAT_SEARCH_NUDGE_ONCE=1 '
export const LEAN_DIRECTIVE = fileURLToPath(new URL('./GRAPH_FIRST.lean.md', import.meta.url))

function fullArm(skillDir) {
  return {
    mcp: true,
    mcpEnv: null,
    allowedTools: `${BASE_TOOLS},${NEAT_TOOLS_ALLOW}`,
    appendSystemPrompt: graphFirstText(skillDir),
    settings: hookSettings(skillDir),
  }
}

function leanFullArm(skillDir) {
  return {
    mcp: true,
    mcpEnv: { ...LEAN_MCP_ENV },
    allowedTools: `${BASE_TOOLS},${NEAT_TOOLS_ALLOW}`,
    appendSystemPrompt: readFileSync(LEAN_DIRECTIVE, 'utf8').replace(/\n+$/, ''),
    settings: hookSettings(skillDir, LEAN_HOOK_ENV),
  }
}

function notedArm(note) {
  return { mcp: true, mcpEnv: null, allowedTools: `${BASE_TOOLS},${NEAT_TOOLS_ALLOW}`, appendSystemPrompt: note, settings: null }
}

export function armConfig({ task, arm, skillDir, route = null }) {
  if (!ARMS.includes(arm)) throw new Error(`arm must be one of ${ARMS.join(', ')}, got: ${arm}`)
  let cfg
  let routed = null
  if (arm === 'bare') {
    cfg = { mcp: false, mcpEnv: null, allowedTools: BASE_TOOLS, appendSystemPrompt: null, settings: null }
  } else if (arm === 'full') {
    cfg = fullArm(skillDir)
  } else if (arm === 'lean-full') {
    cfg = leanFullArm(skillDir)
  } else if (arm === 'oracle') {
    if (!task.gold_files?.length) throw new Error(`task ${task.id} has no gold_files`)
    cfg = notedArm(renderNote({ files: task.gold_files }))
  } else {
    if (!route) throw new Error('the jev arm needs --route <route.json>')
    routed = { tier: route.tier, reason: route.reason, confidence: route.confidence ?? null, needsRuntime: route.needsRuntime ?? null }
    cfg = route.tier === 'full' ? fullArm(skillDir) : notedArm(renderNote({ files: route.files, briefing: route.briefing }))
  }
  return {
    task: task.id,
    size: task.size,
    arm,
    routed,
    ...cfg,
    injectedBytes: { appendSystemPrompt: bytes(cfg.appendSystemPrompt), settings: bytes(cfg.settings) },
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: { 'skill-dir': { type: 'string' }, route: { type: 'string' } },
  })
  const [taskPath, arm] = positionals
  if (!taskPath || !arm || !values['skill-dir']) {
    console.error('usage: node arms/arm-config.mjs <task.json> <bare|full|lean-full|oracle|jev> --skill-dir <dir> [--route <route.json>]')
    process.exit(2)
  }
  const task = JSON.parse(readFileSync(taskPath, 'utf8'))
  const route = values.route ? JSON.parse(readFileSync(values.route, 'utf8')) : null
  process.stdout.write(JSON.stringify(armConfig({ task, arm, skillDir: values['skill-dir'], route }), null, 2) + '\n')
}
