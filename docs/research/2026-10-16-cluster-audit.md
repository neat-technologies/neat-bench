# Cluster audit, 2026-10-16: why the injected faults survived every reset

Evidence behind the re-premised ADR-003. Captured on the bench box (kind `kind-dev`, namespace `otel-demo`) after the 16 October reboot, with the host-to-API-server path repaired first (the kind bridge had lost its IPv4 gateway; see the environment contract, rule 9).

## 1. The baseline file is clean

`~/benchops-baseline/deploys-clean.json` (mtime 2026-10-14 00:50 box time, 17 Deployments):

```
sleep-infinity=0 port40=0 invalid-node=0 items=17
email            init=[] live=- ready=- mem=100Mi
fraud-detection  init=["sh -c until nc -z -v -w30 kafka 9092; do echo waiting for kafka; sleep 2; done;"] live=- ready=- mem=300Mi
frontend         init=[] live=- ready=- mem=250Mi
```

`kubectl diff -n otel-demo -f deploys-clean.json` against the live cluster (client-side three-way merge):

```
--- LIVE  apps.v1.Deployment.otel-demo.fraud-detection
+++ MERGED
-            memory: 512Mi
+            memory: 300Mi
```

The only difference is the memory headroom set on purpose on 15 October. The file carries none of the faults.

## 2. The faults were live anyway

Live deployments diffed against the pinned chart rendering (`helm template otel-demo open-telemetry/opentelemetry-demo --version 0.36.4`, release values `null`), by `ops/audit-vs-chart.sh`:

```
chart deployments=23 live deployments=23
  checkout:        nenv live=16 chart=15
  currency:        nenv live=8 chart=7
  email:           init live=[('worker', '/bin/sh -c sleep infinity')] chart=[]
  fraud-detection: mem live=512Mi chart=300Mi
  frontend:        ready live=40 chart=-
  payment:         nenv live=9 chart=8
  shipping:        nenv live=8 chart=7
  valkey-cart:     nenv live=5 chart=4
```

The extra env vars are `IPV6_ENABLED` (currency, payment, shipping), `GOMEMLIMIT` (checkout) and `VALKEY_PASSWORD` (valkey-cart): the ITBench variant of the demo, not faults. The `email` init container and the `frontend` readiness probe on port 40 are the injected faults.

## 3. Who owns the injected fields

`kubectl get deploy -o json --show-managed-fields`, filtered to the managers whose `fieldsV1` carry the suspect paths:

```
email        mgr=OpenAPI-Generator        op=Update  t=2026-10-14T09:17:36  has=['initContainers']
email        mgr=helm                     op=Apply   t=2026-10-15T12:05:50  has=['f:limits']
email        mgr=kubectl                  op=Apply   t=2026-10-15T12:19:57  has=['f:limits']
email        mgr=kubectl-rollout          op=Update  t=2026-10-15T12:25:22  has=[]
frontend     mgr=OpenAPI-Generator        op=Update  t=2026-10-14T10:05:03  has=['readinessProbe']
frontend     mgr=helm                     op=Apply   t=2026-10-15T12:05:50  has=['f:limits']
frontend     mgr=kubectl                  op=Apply   t=2026-10-15T12:19:57  has=['f:limits']
fraud-detection mgr=kubectl-set           op=Update  t=2026-10-15T12:19:57  has=['initContainers', 'f:limits']
```

`OpenAPI-Generator` is the default user agent of the Python Kubernetes client the PRAXIS injector uses. The injections are stamped 2026-10-14T09:17Z and 10:05Z, during the `full81-clean` run. Every later writer (`helm` Apply, `kubectl` Apply, `kubectl-rollout`) owns other fields; server-side apply removes only fields the applying manager itself owns, so none of them removed the injected ones.

## 4. Why the baseline check did not see it

`~/praxis/harness/verify-baseline.sh` reports `CLEAN=YES|NO` from: storefront 2xx on three paths, count of `invalid-node` node selectors, image drift against the baseline images, and a neo4j check. It does not read init containers, probes or resource limits.

## 5. Consequences recorded

- The reset method must remove fields regardless of ownership: `kubectl replace` from the rendering, or `kubectl patch --type=json` deleting the path (ADR-003).
- The launch gate is the chart audit, not the storefront (run-validity contract, rule 1).
- The 15 October claim that the baseline file "carried injected faults" was wrong and is withdrawn; the surviving-fault mechanism above is what the 14 October clean re-run actually hit.

## 6. Other state found on the same audit

- A second full copy of the demo in namespace `default` (19 Deployments, chart 0.36.4 labels, no helm release secret, created 2026-10-11T00:50Z during the ITBench runs), crash-looping for five days: `kafka` 825 restarts, `ad` 780, `fraud-detection` OOMKilled 791. ITBench residue; purged by `ops/recover-20261016.sh`.
- Five `otel-demo` pods in `Unknown` after the reboot (accounting, cart, checkout, flagd, fraud-detection), recycled by the same script.
- `valkey-cart` OOMKilled at the chart's 20Mi limit and `prometheus` OOMKilled at 300Mi, both while the duplicate demo was running; re-checked after the purge.
