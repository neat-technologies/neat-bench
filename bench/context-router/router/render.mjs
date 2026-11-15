// The "start here" note an arm appends to the agent's system prompt. The oracle
// arm and the router's small/medium tiers use the same renderer, so the only
// difference between those arms is which files are named (and, for medium,
// the briefing). The wording never says how the files were chosen.

export function renderNote({ files, briefing = null }) {
  if (!files || files.length === 0) return ''
  const lines = [
    'Start here: the code for this request is most likely in these files.',
    ...files.map((f) => `- ${f}`),
  ]
  if (briefing) lines.push('', "From NEAT's graph:", briefing)
  lines.push('', "NEAT's graph tools are available if you need more than this.")
  return lines.join('\n')
}
