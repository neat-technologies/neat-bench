// The size rubric. One source of truth: Jev's criteria are built from it, the
// task labels in tasks/ are judged against it, and the README quotes it. If you
// change a line here, relabel the tasks before the next scored run.
//
// Task labels say small / medium / big. The router's tiers say small / medium /
// full, because the router's answer is how much context to give, and the answer
// for a big task is everything NEAT has: the same as today.

export const RUBRIC = Object.freeze({
  small:
    'The fix touches one or two files and the request names or clearly points at the place: ' +
    'an endpoint, a field, an error message, a file. Reading those files is enough; no runtime ' +
    'or production information is needed.',
  medium:
    'The fix touches up to about five files, or the cause sits one step away from where the ' +
    'symptom shows: a shared helper, middleware, plugin, config or validation used by several ' +
    'routes. Reading the code is enough once you find it.',
  big:
    'The cause is not clear from the request: it spans many files or several services, or it ' +
    'depends on runtime behaviour such as incidents, production config or traffic, so it needs ' +
    'investigation.',
})

export const TIER_INSTRUCTIONS =
  'A developer sent this request to a coding agent. The graph summary lists the parts of the ' +
  'codebase the request matched, how many distinct files and services those span, and whether ' +
  'there is a live incident signal. How much of the codebase will the agent need to look at ' +
  'to make the fix?'

export const TIER_CRITERIA = Object.freeze({
  small: RUBRIC.small,
  medium: RUBRIC.medium,
  full: RUBRIC.big,
})

export const RUNTIME_INSTRUCTIONS =
  'Does fixing this request depend on how the system behaves at runtime (errors seen in ' +
  'production, traffic, deployed config, incidents) rather than on reading the code alone?'

/** Map a task's size label to the tier a perfect router would pick. */
export const TIER_FOR_SIZE = Object.freeze({ small: 'small', medium: 'medium', big: 'full' })
