# obscode arm — raw source + raw observability, UNFUSED

`obscode` is the load-bearing baseline of the ±NEAT PRAXIS bench. It hands a fresh
headless Claude Opus the **same two signals** the `neat` arm gets — the source tree
and the live runtime — but **does not fuse them**. The agent reads traces/logs/metrics
and stitches them to code by hand. If `neat` beats `obscode`, the win is **fusion
itself**, not extra data (CONTRACT rule 3, METHOD arms table).

For that to be honest, `obscode` must be genuinely strong: complete trace/metric
access over the same live app, full source, told to use both. This directory is that
surface.

## The obs surface (otel-demo namespace, verified 2026-08-27)

| signal | source | how reached | health |
|---|---|---|---|
| **traces** | `svc/jaeger-query` :16686, HTTP query API under **`/jaeger/ui/api`** | `kubectl port-forward` → local **16699** | **healthy, rich** |
| **logs** | pod stdout/stderr | `kubectl logs deploy/<svc>` (read-only) | **healthy** |
| **metrics / alerts** | `svc/prometheus` :9090 | `kubectl port-forward` → local **9099** | **DEGRADED — see gap below** |

`obscode-env.sh` is the one place that encodes those services + ports + API base
paths; every helper and the runner source it. Port-forwards are started detached
(`setsid … </dev/null`) and reused if already up. Local ports (16699/9099) are chosen
not to collide with the neat arm's forwards (8098 neat, 4319 otel, 8080 frontend).

## Helpers (a headless agent calls these with Bash)

```
obscode-traces.sh <service> --errors          # error spans + exception events + durations
obscode-traces.sh <service> --lookback 30m    # recent traces for a service
obscode-traces.sh --trace <traceID>           # one full request, end-to-end span tree
obscode-traces.sh --services | --operations <svc>
obscode-logs.sh   <service> --errors          # raw pod logs (error/exception filter)
obscode-logs.sh   <service> --since 10m --grep '5[0-9][0-9]'
obscode-metrics.sh '<promql>'                 # Prometheus instant query
obscode-metrics.sh '<promql>' --range 15m     # range query
obscode-metrics.sh --alerts                   # active Prometheus alerts (RED signal)
```

They return **real, compact, unfused** output — the trace digest lists each error
span with its service, operation, duration, status, and exception (`type: message`
+ the deepest stack frame), plus a per-subject summary (trace count, error-span
count, p50/p95 entry latency, top exception messages). Nothing joins a span to a
code line for the agent; that stitching is the agent's job. `--raw` on traces/metrics
returns the untouched Jaeger/Prometheus JSON.

### Sample (live, scenario-401 class fault present)
```
$ obscode-traces.sh recommendation --errors
trace 60dcdb812d148d6c  services=[recommendation]  spans=3  root_dur=29.4ms
    ERROR  recommendation :: get_product_list  dur=26.8ms
           exception: AttributeError: 'ListProductsResponse' object has no attribute 'products_list'
    ERROR  recommendation :: /oteldemo.RecommendationService/ListRecommendations  dur=29.4ms
           exception: AttributeError: 'ListProductsResponse' object has no attribute 'products_list'
[summary] subject=recommendation  traces=20  error_spans=…
[summary] top exceptions:
      …x  AttributeError: 'ListProductsResponse' object has no attribute 'products_list'
```
The runtime signal points straight at the failing operation and exception; the agent
still has to open `recommendation_server.py` and find the `products_list` line — the
unfused hand-stitch that `neat`'s symbol-grain join does for you.

## The arm-runner

```
run-obscode.sh <scenario> [trial] ["symptom text"]
```

Runs one fresh headless `claude -p` (stream-json), cwd = a fresh editable copy of the
recommendation service at `~/praxis/runs/<scenario>/obscode[/trial-N]/src`, with:
- **source**: read/grep over the whole app at `$OBSCODE_SRC_ROOT/src` (default
  `~/opentelemetry-demo/src`, pinned 2.0.1);
- **obs**: the three helpers on `PATH` (traces/logs/metrics);
- **NO MCP server** — `--strict-mcp-config` with no `--mcp-config` guarantees no
  `neat`, no ambient servers. The only difference vs the neat arm is fusion.

It writes the agent's fix to `…/src/recommendation_server.py`, so grading is identical
to the code/neat arms:
```
bash ~/praxis/grade-fix.sh    <run>/src/recommendation_server.py  <faultfree_ref.py>
bash ~/praxis/verify-generic.sh <run>/src  obscode<scen>  <fault_base_image>  ~/praxis/oracle-rec.sh
```
Model/budget are control variables: `NEAT_BENCH_MODEL` (default `opus`),
`NEAT_BENCH_MAX_TURNS` (default `40`) — set them identically for every arm.
Outputs per run: `prompt.txt`, `claude-stream.jsonl`/`transcript.jsonl`, `answer.txt`,
`tool-calls.log`, `patch.diff`, `arm.json`.

## Honest gap — Prometheus is OOMKilled (metrics/alerts unreliable)

The otel-demo `prometheus` pod is in a **CrashLoopBackOff / OOMKilled loop** (exit 137,
`memory: 300Mi` limit, 70+ restarts). It comes up for a ~40s window, replays its WAL,
then dies before/while scraping — so `obscode-metrics.sh` and `--alerts` are
**intermittent-to-down**. There is no substitute: the collector exposes only its own
self-telemetry on :8888 (no span→RED-metric exporter), and Grafana's datasource is that
same Prometheus.

This is a **cluster-config issue owned by the operator**, not a NEAT weakness and not a
harness bug — the fix is to **raise the Prometheus memory limit** (the bench box is
READ-ONLY to the obscode harness author, so we do not patch it here). It does **not**
strawman the baseline:

- Traces (Jaeger) + pod logs are **healthy and rich**, and for PRAXIS code-grain faults
  (401–416: AttributeError, timeouts, index errors) the **decisive** runtime signal is
  the exception/error span + log traceback — both fully present. This already matches
  or exceeds PRAXIS's published **runtime-only** baseline (which was trace-only).
- `obscode-metrics.sh` fails **loudly** (clear error + non-zero exit), never a silent
  empty, so the agent can never mistake "Prometheus down" for "no anomaly."
- The metrics helper is correct and ready; it lights up the instant the memory limit
  is raised, restoring the aggregate RED/alert leg.

**Recommendation before scored runs:** bump the Prometheus memory limit (e.g. 300Mi →
1Gi) so the metrics leg is live, then re-confirm `obscode-metrics.sh --alerts`. Until
then, obscode runs on traces + logs — a strong, honest surface, with the gap on record.
