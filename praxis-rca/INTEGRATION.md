# PRAXIS Code-Cloud-RCA — concrete integration (verified against the artifact)

Artifact: `dsn26-praxis-ae.zip`, Zenodo record **19247887** (DOI 10.5281/zenodo.19163486, Apache-2.0). On the box at `~/praxis/extracted/dsn26-praxis-ae/`. The 30 scenarios are **Zenodo-only** (not in public itbench-hub). Everything below verified by unpacking, not from the paper.

## Version lock (MANDATORY — or fusion won't align)
- OTel Demo Helm chart **0.36.4** → app **v2.0.1** (`itbench-lite-ae/sre/group_vars/sample_applications.yaml`). Faulted images are `2.0.1-recommendation` variants; NEAT must extract the **2.0.1** recommendation source. Our box currently runs 2.2.0 → **re-pin to 2.0.1**.
- Helm 3.18.4 for the artifact's own Ansible (we can deploy the app via helm directly; we do NOT need PRAXIS's Neo4j dependency-monitor or CLDK PDG).

## The 30 scenarios (from `ground_truths_all.json`)
| set | ids | RCI ground truth | grain | our use |
|---|---|---|---|---|
| **CODE (recommendation, Python)** | **401–416 (16)** | `recommendation-service-1` (+`neo4j-productdb-service-1` on 405–410,416) | **code / RCR** | **THE HEADLINE RUNS** — fusion-decisive (runtime-only=0% RCR) |
| flagd feature-flag | 3,5,6,501–506 (9) | `flagd-config-1` | ConfigMap | draw-class (I already showed NEAT ties on adHighCpu/adFailure/adManualGc); run a few for the ladder |
| chaos + manifest | 17,25,29 / 20,32 | chaos CR / deployment | infra/k8s | draw-class; operational fix; optional |

The 16 code fixes (from `recommended_actions`): 401–404 data-schema (`products` not `products_list`); 405–410 external-dep handling (add timeout/retry/backoff around the neo4j product DB); 411 invert wrong product-format validation logic; 412 reimplement inefficient logic; 413–414 fix incorrect product-DB label env var; 415–416 fix list index-out-of-range.

## Injection
`INCIDENT_NUMBER=N make inject_incident_fault` (Ansible, tag `incident_N`). Mechanisms:
- **Code (401–416):** `kubectl set image` on `recommendation` Deployment → `quay.io/shengkunrz/it-bench-dev:<variant>-recommendation` (variants confirmed pullable: logicc, logics, monzo, neo4j*, nightly, …), replicas 0→1 to force a clean roll. Removal → stock `ghcr.io/open-telemetry/demo:2.0.1-recommendation` (= reference correct behaviour).
- **flagd (3,5,6,501–506):** flip `defaultVariant:"on"` in `flagd-config` ConfigMap + rollout restart.
- **chaos (17,25,29):** Chaos Mesh Network/Stress/JVM CRs.

## Symptom oracle (theirs, reused for our fix verification)
Each scenario declares Prometheus `alerts[]` (mostly `RequestErrorRate` on frontend-proxy/recommendation/frontend, + latency/Kafka). They go **Inactive→Firing ~3 min after injection**, **Firing→Inactive after removal**. Poll `http://localhost:8080/prometheus/api/v1/alerts`. This is the honest, machine-checkable "symptom cleared" signal — no LLM opinion.

## Find + fix loop (per code scenario)
1. **Seed once (offline, frozen):** build an *editable* faulted recommendation from the shipped reconstruction (`praxis-ae/examples/technology_codebase/opentelemetry-demo/src/recommendation/<variant>/` + `analysis_processed.json` code-snippets, diffed against `faultfree/`). Build image, `kind load`, deploy → confirm it fires the **same alert** as the quay image (validates the seed == authors' fault). Freeze.
2. **Inject** (image swap or the seeded image) → wait ~3 min → confirm alert Firing.
3. **Run the arm** (code / obs+graphify / opus+neat), fresh headless Claude Opus, diagnose **and** produce a source patch to `src/recommendation/`.
4. **Verify fix:** apply patch → `docker build` → `kind load` → `kubectl set image` + rollout → drive load (harness sets `BROWSE_PRODUCT_WEIGHT=1000`) → assert every scenario alert returns Firing→Inactive for a full window AND no new alert fires AND the deployment runs a *newly built* digest with replicas≥1 (anti-cheat: no scale-to-0, no revert-to-stock-image).
5. **Score** find (RCI entity exact-match + RCR our LLM-judge vs `propagations`/`recommended_actions`) + fix (symptom-cleared boolean), jointly. Per SCORING.md.

## Honest caveats (carry into any published number)
- Their exact RCI/RCR grader is **held out**; RCR is LLM-as-judge. We do RCI faithfully (entity match), RCR as our own LLM-judge approximation → cite PRAXIS's 73.9/61.5 & runtime-only-0% as reference points, not head-to-head parity.
- No fix oracle ships — we built apply→redeploy→symptom-clears (their alert signal, legitimate).
- Faulted images are third-party (quay.io/shengkunrz) — **archive them + the 2.0.1 baseline locally** (done/todo on box) against disappearance.
- The 3 chaos scenarios don't fit code find-AND-fix; exclude or grade as operational remediation.

## Setup state
- [x] Artifact downloaded + unpacked on box (`~/praxis/`).
- [x] Ground truth + injection + oracle mapped; images pull; reconstruction source present.
- [ ] Re-pin app to 2.0.1 (chart 0.36.4) + point NEAT at 2.0.1 recommendation source.  ← next
- [ ] Archive quay faulted images + 2.0.1 baseline to local tars.
- [ ] Wire 3 arms (code / obs+graphify=Safi graphify skill / opus+neat live daemon).
- [ ] Build fix-verify script (apply→build→load→rollout→alert-clears).
- [ ] Freeze editable faulted seeds for 401–416.
