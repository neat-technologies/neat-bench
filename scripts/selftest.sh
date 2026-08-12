#!/usr/bin/env bash
# selftest — proves the scorers run and behave HONESTLY against the real Express
# fixture. No live target, no daemon, no agent — just the model-free bricks over a
# captured graph. The wall-certificate is EXPECTED to refuse the sample wall (the
# legible fixture has no real walls); that refusal is the pass condition.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0

echo "== claim-classifier (should quarantine the DB-identity twins, 0% true-blind) =="
node harness/claim-classifier.mjs fixtures/express-mongoose.graph.json | tail -5 || fail=1

echo ""
echo "== grounded-evidence (should score 40% grounded, sufficiency PASS) =="
node harness/grounded-evidence.mjs fixtures/express-mongoose.graph.json fixtures/sample-claims.json --require walls/sample-data-wall.json || fail=1

echo ""
echo "== wall-certificate (should REFUSE the sample wall — that is correct) =="
if node harness/wall-certificate.mjs walls/sample-data-wall.json fixtures/express-mongoose.graph.json; then
  echo "SELFTEST FAIL: certificate wrongly certified a non-wall"; fail=1
else
  echo "OK: certificate correctly refused (exit 1 is the pass here)"
fi

echo ""
echo "== aggregate (should roll up the synthetic trials into a delta) =="
node harness/aggregate.mjs fixtures/_sample-trials/*.json || fail=1

echo ""
if [ "$fail" -eq 0 ]; then echo "SELFTEST: all bricks behave."; else echo "SELFTEST: FAILURES above."; fi
exit "$fail"
