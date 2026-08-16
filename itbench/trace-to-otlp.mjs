#!/usr/bin/env node
// itbench/trace-to-otlp.mjs — stream an ITBench `otel_traces_raw.tsv` snapshot into
// a running NEAT daemon as OTLP/HTTP JSON, so NEAT builds the OBSERVED service graph
// (PRAXIS's SDG) + incidents from real captured traces — no live cluster needed.
//
//   node itbench/trace-to-otlp.mjs <otel_traces_raw.tsv> <otlp-endpoint> [--max N]
//   e.g. ... /projects/otel-demo/v1/traces on the scoped daemon's OTLP port.
//
// NEAT reads traceId/spanId/parentSpanId as opaque strings (otel.ts) so ITBench's
// hex ids feed straight through; the resource only needs service.name.

import { createReadStream } from 'node:fs'
import readline from 'node:readline'

const [tsvPath, endpoint, ...rest] = process.argv.slice(2)
if (!tsvPath || !endpoint) { console.error('usage: trace-to-otlp.mjs <traces.tsv> <otlp-endpoint> [--max N]'); process.exit(1) }
const maxIdx = rest.indexOf('--max')
const MAX = maxIdx !== -1 ? parseInt(rest[maxIdx + 1], 10) : Infinity
const BATCH = 2000

const KIND = { Internal: 1, Server: 2, Client: 3, Producer: 4, Consumer: 5 }
const STATUS = { Unset: 0, Ok: 1, Error: 2 }

const tsToNanos = (ts) => {
  // "2025-12-15 17:17:04.499417946" -> base-10 nanoseconds string
  const [d, t] = ts.split(' ')
  if (!t) return '0'
  const [hms, frac = '0'] = t.split('.')
  const secs = Math.floor(Date.parse(`${d}T${hms}Z`) / 1000)
  if (Number.isNaN(secs)) return '0'
  const fracNs = (frac + '000000000').slice(0, 9)
  return (BigInt(secs) * 1000000000n + BigInt(fracNs)).toString()
}
const parseAttrs = (s) => {
  const out = []
  if (!s || s === '[]') return out
  const re = /'([^']*)':\s*'([^']*)'/g
  let m
  while ((m = re.exec(s))) out.push({ key: m[1], value: { stringValue: m[2] } })
  return out
}

let posted = 0, seen = 0, errors = 0
// group spans by service within a batch -> OTLP resourceSpans
async function flush(spansByService) {
  const resourceSpans = [...spansByService.entries()].map(([svc, spans]) => ({
    resource: { attributes: [{ key: 'service.name', value: { stringValue: svc } }] },
    scopeSpans: [{ scope: { name: 'itbench-replay' }, spans }],
  }))
  if (resourceSpans.length === 0) return
  try {
    const res = await fetch(endpoint, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ resourceSpans }),
    })
    if (!res.ok) { errors++; if (errors <= 3) console.error(`  POST ${res.status}: ${(await res.text()).slice(0, 200)}`) }
    else posted += resourceSpans.reduce((n, rs) => n + rs.scopeSpans[0].spans.length, 0)
  } catch (e) { errors++; if (errors <= 3) console.error('  POST failed:', e.message) }
}

const rl = readline.createInterface({ input: createReadStream(tsvPath), crlfDelay: Infinity })
let header = null
let batch = new Map()
let batchCount = 0
for await (const line of rl) {
  if (!header) { header = line.split('\t'); continue }
  if (seen >= MAX) break
  const f = line.split('\t')
  const svc = f[7]
  if (!svc || svc === '[]') continue
  const start = tsToNanos(f[0])
  const dur = BigInt(/^\d+$/.test(f[12]) ? f[12] : '0')
  const span = {
    traceId: f[1], spanId: f[2],
    ...(f[3] ? { parentSpanId: f[3] } : {}),
    name: f[5],
    kind: KIND[f[6]] ?? 1,
    startTimeUnixNano: start,
    endTimeUnixNano: (BigInt(start) + dur).toString(),
    attributes: parseAttrs(f[11]),
    status: { code: STATUS[f[13]] ?? 0 },
  }
  if (!batch.has(svc)) batch.set(svc, [])
  batch.get(svc).push(span)
  seen++; batchCount++
  if (batchCount >= BATCH) { await flush(batch); batch = new Map(); batchCount = 0; if (posted % 20000 < BATCH) process.stderr.write(`  ingested ~${posted}\n`) }
}
await flush(batch)
console.log(`done: read ${seen} spans, ingested ${posted}, post-errors ${errors}`)
