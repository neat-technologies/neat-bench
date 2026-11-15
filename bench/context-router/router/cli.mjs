#!/usr/bin/env node
// Route one request and print the decision as JSON.
//
//   node router/cli.mjs --prompt-file <file> --daemon <url> [--project <name>] [--out <file>]
//
// The daemon bearer, if the daemon has one, is read from NEAT_ROUTER_DAEMON_TOKEN.
// The TypeSafe key is read from TYPESAFE_API_KEY by the SDK. Neither is ever
// printed or written. Exit code is 0 whenever a decision was made, including a
// fall back to full; it is non-zero only for bad arguments.

import { readFileSync, writeFileSync } from 'node:fs'
import { parseArgs } from 'node:util'
import { fetchFeatures } from './features.mjs'
import { createJevClient } from './jev.mjs'
import { route } from './route.mjs'

const { values } = parseArgs({
  options: {
    'prompt-file': { type: 'string' },
    daemon: { type: 'string' },
    project: { type: 'string' },
    out: { type: 'string' },
  },
})
if (!values['prompt-file'] || !values.daemon) {
  console.error('usage: node router/cli.mjs --prompt-file <file> --daemon <url> [--project <name>] [--out <file>]')
  process.exit(2)
}

const prompt = readFileSync(values['prompt-file'], 'utf8').trim()
let jevClient = null
try {
  jevClient = await createJevClient()
} catch {
  // No key or no SDK: route() records jev_unavailable and falls back to full.
}

const decision = await route({
  prompt,
  getFeatures: (p) =>
    fetchFeatures({
      prompt: p,
      daemonUrl: values.daemon,
      project: values.project,
      token: process.env.NEAT_ROUTER_DAEMON_TOKEN || undefined,
    }),
  jevClient: jevClient ?? { systemOne: () => Promise.reject(Object.assign(new Error('no client'), { name: 'NoClient' })) },
})

const json = JSON.stringify(decision, null, 2) + '\n'
if (values.out) writeFileSync(values.out, json)
else process.stdout.write(json)
