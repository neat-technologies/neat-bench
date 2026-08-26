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
| **traces** | `svc/jaeger-query` :16686, HTTP query API under **`/jaeger/ui/api`** | `kubectl port-forward` → local **16699** | **healthy, rich, fresh** |
| **logs** | pod stdout/stderr | `kubectl logs deploy/<svc>` (read-only) | **healthy** (app services; Envoy `frontend-proxy` is quiet by design — traces cover it) |
| **metrics** | `svc/prometheus` :9090 | `kubectl port-forward` → local **9099** | **healthy** — app RED (`traces_span_metrics_*`) + latency histograms + infra; one caveat (no alert *rules* loaded) in the note below |

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

## Status of the metrics leg (honest, current)

**History (why early smoke looked broken):** the otel-demo `prometheus` pod was
OOMKilling in a loop (300Mi limit, exit 137, 75 restarts). That cascaded — the collector
couldn't push to Prometheus, backpressured, and returned `UNAVAILABLE` to every exporter,
so **traces stopped landing in Jaeger too**. That is why some early `/traces` calls came
back empty. The operator **raised Prometheus to 1Gi**; it now runs `1/1` with 0 restarts
and the collector un-backpressured.

**Now (verified): all three legs are healthy and carrying live fault signal.**
- **Traces** flow fresh (new traces landing within the last minute).
- **Metrics** are reachable and rich — not just infra: the OpenTelemetry Demo's
  **application RED metrics are present** once the pipeline catches up after the restart
  (a few minutes): `traces_span_metrics_calls_total` (~90 series, filterable by
  `service_name` / `span_name` / `status_code`) and
  `traces_span_metrics_duration_milliseconds_bucket` (~1530 series → `histogram_quantile`
  p95/p99 per service), plus `up`/`target_info`/k8s infra (2400+ series total). Confirmed
  against the live fault (recommendation on the `neo4j-serving` variant, a 405–410-class
  external-dep fault): `frontend-proxy` error-rate ≈ 0.03/s and p95 ≈ 2.5s while healthy
  services sit at ~2ms.
- **Logs** are healthy for app services (Envoy `frontend-proxy` is quiet by design).

**One real caveat (honest):** **no alert *rules* are loaded** in this Prometheus (`/api/v1/rules`
→ 0 groups), so `obscode-metrics.sh --alerts` returns "no active alerts" regardless — the
PRAXIS `RequestErrorRate` named-alert oracle isn't wired here. That's a bench-setup /
grading concern for the operator (the fix oracle in INTEGRATION.md polls those alerts); it
does **not** affect the obscode agent's *diagnostic* surface, because the raw RED metrics
(error-rate + latency by service) and the error traces carry the same anomaly signal
directly — see the sample below. Also note app-RED series need a few minutes to repopulate
after any Prometheus restart; right after a restart, app-metric PromQL may transiently
return `empty result set` (reported honestly, never a silent empty).

**Not a strawman.** obscode gets the complete, unfused surface: full source + fresh
traces (error spans, exceptions, stack frames, latency) + raw logs + live RED/latency
metrics. It matches/exceeds PRAXIS's published runtime-only baseline and then some. The
only missing piece is *named alert rules*, which are an oracle-wiring detail, not a
diagnostic signal the agent needs.

### Sample (live neo4j-serving fault, 405–410 class)
```
$ obscode-metrics.sh 'sum by (service_name) (rate(traces_span_metrics_calls_total{status_code="STATUS_CODE_ERROR"}[5m]))'
service_name=frontend-proxy  ->  0.03
service_name=load-generator  ->  0.04
$ obscode-metrics.sh 'histogram_quantile(0.95, sum by (service_name,le) (rate(traces_span_metrics_duration_milliseconds_bucket[5m])))'
service_name=frontend-proxy  ->  2521.1      # the fault symptom; healthy peers ~1.9
$ obscode-traces.sh frontend-proxy --errors --lookback 10m
    ERROR  frontend-proxy :: ingress  dur=3031.6ms
    ERROR  frontend-proxy :: router frontend egress  dur=3031.5ms
```
Metrics say *which service is slow/erroring and how much*; traces say *where the 3s hang
is*; source says *why* — obscode hands the agent all three, **unfused**, and it stitches
them. `neat` fuses the same three into one graph; that difference is what the bench measures.
