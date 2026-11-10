#!/usr/bin/env node
// Build one arm's agent configuration as JSON. run.sh executes it; tests check it.
//
//   node arms/arm-config.mjs <task.json> <bare|full|oracle|jev> --skill-dir <dir> [--route <route.json>]
//
// The `full` arm reproduces harness/arms/run-arm.sh's WITH arm byte for byte:
// the same allowed tools, the same GRAPH_FIRST.md text as `$(cat ...)` yields
// (trailing newlines stripped), and the same search-nudge hook settings string.
// The other arms change only what the arms table in the README says they change.

import { readFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import { parseArgs } from 'node:util'
import { renderNote } from '../router/render.mjs'

export const ARMS = ['bare', 'full', 'oracle', 'jev']
// Copied from harness/arms/run-arm.sh (frozen); the order is part of the byte match.
export const BASE_TOOLS = 'Read,Grep,Glob,Edit,Bash'
export const NEAT_TOOLS_ALLOW =
  'get_graph,get_divergences,get_root_cause,get_blast_radius,get_observed_dependencies,get_dependencies,get_incident_history,get_graph_diff,get_recent_stale_edges,semantic_search,check_policies'

const bytes = (s) => (s ? Buffer.byteLength(s, 'utf8') : 0)

/** What `"$(cat file 2>/dev/null)"` produces: the file without trailing newlines. */
export function graphFirstText(skillDir) {
  return readFileSync(`${skillDir}/GRAPH_FIRST.md`, 'utf8').replace(/\n+$/, '')
}

/** The settings string run-arm.sh builds for its hook. */
export function hookSettings(skillDir) {
  return JSON.stringify({
    hooks: {
      PreToolUse: [
        { matcher: 'Grep|Glob|Bash', hooks: [{ type: 'command', command: `node ${skillDir}/hooks/neat-search-nudge.mjs` }] },
      ],
    },
  })
}

function fullArm(skillDir) {
  return {
    mcp: true,
    allowedTools: `${BASE_TOOLS},${NEAT_TOOLS_ALLOW}`,
    appendSystemPrompt: graphFirstText(skillDir),
    settings: hookSettings(skillDir),
  }
}

function notedArm(note) {
  return { mcp: true, allowedTools: `${BASE_TOOLS},${NEAT_TOOLS_ALLOW}`, appendSystemPrompt: note, settings: null }
}

export function armConfig({ task, arm, skillDir, route = null }) {
  if (!ARMS.includes(arm)) throw new Error(`arm must be one of ${ARMS.join(', ')}, got: ${arm}`)
  let cfg
  let routed = null
  if (arm === 'bare') {
    cfg = { mcp: false, allowedTools: BASE_TOOLS, appendSystemPrompt: null, settings: null }
  } else if (arm === 'full') {
    cfg = fullArm(skillDir)
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
    console.error('usage: node arms/arm-config.mjs <task.json> <bare|full|oracle|jev> --skill-dir <dir> [--route <route.json>]')
    process.exit(2)
  }
  const task = JSON.parse(readFileSync(taskPath, 'utf8'))
  const route = values.route ? JSON.parse(readFileSync(values.route, 'utf8')) : null
  process.stdout.write(JSON.stringify(armConfig({ task, arm, skillDir: values['skill-dir'], route }), null, 2) + '\n')
}
