#!/usr/bin/env python3
# Box-side watcher for the k=3 run: the running harness grades the bare arm's journeys but does
# not save them. During each bare trial's grading window (the patched app has been redeployed,
# redeploy.json is written, grade.json is not yet), drive the same journeys against the live app
# and save what each answered next to the trial's artifacts as journeys-postfix.manual.json.
# Separate sample from the grader's own journey run, same deployed app, same journey code.
import glob, json, os, re, subprocess, time

ROOT = os.path.expanduser('~/neat-bench/security-pilot')
RUN = sorted(glob.glob(ROOT + '/runs/k3-2026-11-15T00-43*'))[0]
TREES = ROOT + '/runs/_trees'
TSX = ROOT + '/node_modules/.bin/tsx'
ENV = dict(os.environ, PATH=os.path.expanduser('~/.nvm/versions/node/v20.20.2/bin') + ':' + os.environ['PATH'])
ARM = 'bare-opus'
OUT = 'journeys-postfix.manual.json'


def k3_running():
    return subprocess.run(['pgrep', '-f', 'harness/run-k3-suite.ts'], capture_output=True).returncode == 0


def live_tree(app):
    works = sorted(glob.glob(f'{TREES}/{app}-{ARM}-*__work'), key=os.path.getmtime, reverse=True)
    for w in works:
        try:
            m = re.search(r'on :(\d+)', open(w + '/logs/standup.out').read())
        except OSError:
            continue
        if m:
            return w[: -len('__work')], int(m.group(1))
    return None, None


def log(msg):
    print(time.strftime('%H:%M:%S'), msg, flush=True)


log(f'watching {RUN}/{ARM}')
while k3_running():
    for cell in sorted(glob.glob(f'{RUN}/{ARM}/*')):
        if not os.path.exists(cell + '/redeploy.json') or os.path.exists(cell + '/grade.json') or os.path.exists(cell + '/' + OUT):
            continue
        name = os.path.basename(cell)
        app = re.sub(r'-s\d+$', '', name)
        tree, port = live_tree(app)
        if not tree:
            log(f'{name}: no live tree found')
            continue
        t0 = time.time()
        p = subprocess.run([TSX, 'harness/journey-probe.ts', app, f'http://127.0.0.1:{port}', tree], cwd=ROOT, env=ENV, capture_output=True, text=True, timeout=300)
        try:
            probe = json.loads(p.stdout)
        except ValueError:
            probe = {'error': (p.stdout + p.stderr)[-1500:]}
        record = {
            'note': 'captured by an out-of-harness watcher during the grading window; a separate sample of the same journeys against the same redeployed app',
            'capturedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
            'appPort': port,
            'tree': os.path.basename(tree),
            'redeployWrittenAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(os.path.getmtime(cell + '/redeploy.json'))),
            'gradeExistedWhenProbeEnded': os.path.exists(cell + '/grade.json'),
            'probeSeconds': round(time.time() - t0, 1),
            **probe,
        }
        json.dump(record, open(cell + '/' + OUT, 'w'), indent=1)
        log(f'{name}: captured (port {port}, {record["probeSeconds"]}s, failures={len(probe.get("failures", [])) if "failures" in probe else "probe-error"})')
    time.sleep(2)
log('k3 suite no longer running; watcher exits')
