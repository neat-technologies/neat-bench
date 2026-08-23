#!/usr/bin/env bash
cd ~/praxis
echo "[$(date +%H:%M:%S)] downloading Zenodo artifact..."
curl -fsSL -o dsn26-praxis-ae.zip "https://zenodo.org/records/19247887/files/dsn26-praxis-ae.zip?download=1" 2>&1
echo "[$(date +%H:%M:%S)] download done ($(du -h dsn26-praxis-ae.zip 2>/dev/null | cut -f1)); extracting..."
unzip -q -o dsn26-praxis-ae.zip -d extracted 2>&1 | tail -2
echo "[$(date +%H:%M:%S)] extracted. layout:"
find extracted -maxdepth 3 -type d 2>/dev/null | grep -iE "itbench-lite-ae|praxis-ae|recommendation" | head -20
echo "[$(date +%H:%M:%S)] ground truth present?"; ls -la extracted/*/itbench-lite-ae/sre/ground_truths_all.json 2>/dev/null
echo "[$(date +%H:%M:%S)] DONE fetch"
