# Reproducing the security bench

Everything needed to stand the bench up on a new machine and re-run it is in this directory.
Nothing lives only on the original box except the API key and the raw (pre-redaction) transcripts.

## What you need

- **A Linux box.** The runs were made on Ubuntu 26.04, x86_64, 16 cores, 29 GB RAM. Leave plenty of
  disk: gitea's shared Go caches and build trees grew to 97 GB on the original box. The bench is driven on the box itself; a
  laptop only needs `ssh` and `git`.
- **Docker**, usable by your user without sudo.
- **An Anthropic API key** with access to `claude-opus-5-5` and `claude-sonnet-5-5`.
- **The checkout at `$HOME/neat-bench`.** The launch scripts and some standup scripts assume it.

## 1. Set the box up

```bash
git clone https://github.com/neat-technologies/neat-bench "$HOME/neat-bench"
cd "$HOME/neat-bench/security-pilot"
./bootstrap-box.sh          # run it again after the re-login it asks for
```

`bootstrap-box.sh` installs the pinned toolchains and builds what the trials share. The pins:

| Piece | Version | Where |
|---|---|---|
| Node | 20.20.2 | nvm |
| Go (system) | 1.27.0 | `/usr/local/go` |
| Go (gitea builds) | 1.27.3 | `gitea/toolchain/go` |
| osv-scanner | 1.9.2 | `~/go/bin` |
| govulncheck | 1.9.0 | `~/go/bin` |
| uv | 0.13.8 | `~/.local/bin` |
| otelcol-contrib | 0.111.0 | `bin/` |
| otelc (OpenTelemetry Go compile-time instrumentation) | commit 70b4fe8 (v1.2.0) | `gitea/otelc` |
| `@neat.is/otel-node` | the tarball at `nodegoat/otel-node-main-c2aaa93.tgz` | `nodegoat/attach`, `uptime-kuma/attach` |
| paperless-ngx base image | `ghcr.io/paperless-ngx/paperless-ngx:2.15.3` | Docker |
| pip-audit | runs inside the paperless container | none on the host |
| NEAT | one build per commit under `~/neat-builds/<commit>` | built from source |

The app checkouts themselves are not installed by the bootstrap. Each trial clones its app at the
commit pinned in `corpus/<app>.md` and stands it up with `<app>/<app>-fresh.sh`.

Then put the key in `~/.neat-bench-secrets/anthropic.env`:

```bash
export ANTHROPIC_API_KEY=...
```

The file is sourced by the launch scripts. Nothing prints or logs the key.

The bootstrap script was written from the state of the box that made these runs. It has not been
run end to end on a fresh machine. The next section is how to find out whether it worked before
spending API money.

## 2. Check the box

These cost nothing (no model calls).

```bash
cd "$HOME/neat-bench/security-pilot"
export PATH="$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"

# The harness type-checks.
npx tsc --noEmit

# The NEAT build is the one the k=3 run used.
sha256sum ~/neat-builds/b1e6654/packages/core/dist/cli.cjs    # bb183208a968a0d5...
sha256sum ~/neat-builds/b1e6654/packages/mcp/dist/index.cjs   # 7334969f2ab4ef68...

# The grader grades known fixes the known way: a correct fix passes, no fix fails, a fix that
# guts the feature fails. It stands the app up for real, so it is slow.
./controls-launch.sh uptime-kuma
```

If the controls disagree with their expected verdicts, stop: the box is not grading the way the
published runs were graded.

## 3. Run

`run-suite.sh` is the general launcher. Runs are serial and long, so start them detached.

```bash
cd "$HOME/neat-bench/security-pilot"

# The whole matrix: 4 apps x every arm in harness/arms.ts x k trials.
NEAT_COMMIT=b1e6654 BENCH_LABEL=k3 BENCH_K=3 \
  nohup ./run-suite.sh > runs/k3.out 2>&1 < /dev/null &

# One app, or some arms.
NEAT_COMMIT=b1e6654 BENCH_LABEL=gitea BENCH_K=3 BENCH_APPS=gitea \
  nohup ./run-suite.sh > runs/gitea.out 2>&1 < /dev/null &

tail -f runs/k3.out        # one line per trial start and finish, then a summary
```

What the 2026-11-15 runs cost and took, for planning:

| Run | Trials | Wall time | Spend |
|---|---|---|---|
| k=3, three arms, four apps | 36 | 8 h 44 min | $259.31 |
| paperless supplement, two NEAT arms | 6 | 2 h 20 min | $93.87 |
| bare-sonnet, four apps | 12 | 2 h 2 min | $37.27 |

A trial that reaches `BENCH_TRIAL_COST_CAP` (default $25) is stopped and graded as it stands.

## 4. Read the results

Each trial writes a directory `runs/<label>-<timestamp>/<arm>/<app>[-s<n>]/`:

| File | What it is |
|---|---|
| `run.json` | Pins (model, app commit, lockfile hash, NEAT paths), cost, token usage, timings, and the grade |
| `grade.json` | The four criteria with the evidence for each |
| `transcript.json` | The full agent conversation, every tool call and result |
| `baseline.json` | The app's tests and journeys before the agent touched it |
| `scanner-output.json`, `test-output.json`, `redeploy.json` | What the grader saw after the fix |
| `usage.json` | Tokens, turns, stop reason, tool-call counts |

Rebuild the tables:

```bash
node scripts/summarize-runs.mjs runs/<run-dir> [runs/<run-dir> ...]
```

## 5. Re-grade a saved fix without calling a model

A trial's fix can be re-applied and re-graded on a fresh checkout. This is how the bare-opus
paperless trial was re-graded after the redeploy fix:

```bash
REPLAY_APP=paperless-ngx REPLAY_ARM=bare-opus REPLAY_PATCH=/path/to/fix.patch ./controls-launch.sh
```

`REPLAY_PATCH` is a `git diff --binary` of the fixed tree against the pinned commit.

## Which code made which run

| Run | Launch script (as run) | Harness commit | NEAT build |
|---|---|---|---|
| `k3-2026-11-15T00-43-40-620Z` | `k3-launch.sh` | 156fd5a | b1e6654 |
| `supp-paperless-1622-2026-11-15T09-32-16-120Z` | `supp-launch.sh` | 8e06b8d | bf8c29a |
| `k3-bare-sonnet-2026-11-15T13-08-53-914Z` | `bare-sonnet-launch.sh` | 683b226 | none used |
| `controls-2026-11-15T09-27-38-850Z-replay-...` | `controls-launch.sh` with the `REPLAY_*` variables | ed18724 | none used |

The harness commits are on this repository's history; `git checkout <commit> -- security-pilot/harness`
gives the harness exactly as a run used it. The as-run launch scripts point at paths on the original
box (`~/neat-src/.../dist-fixed`, `~/neat-main-1622`); `run-suite.sh` is their portable form.

To reproduce the k=3 run as it was, including its known faults, check out harness commit 156fd5a
and launch with `NEAT_COMMIT=b1e6654`. To run the bench as it should be run now, use the current
harness.

## What is not in the repository

- **The API key.**
- **Raw transcripts.** The committed ones went through `scripts/redact-runs.py`, which replaces the
  box's private network address (12 occurrences) and the names of two unrelated tools that appeared
  in directory listings (26 occurrences). Nothing else is changed. The originals are on the box
  under `~/neat-bench/security-pilot/runs/`.
- **App checkouts, build trees, Docker images and the advisory cache.** All rebuilt by the
  bootstrap or by the trials.
- **Earlier exploratory runs** (smoke runs, single-app checks from 2026-11-10 to 2026-11-14) beyond
  those already committed. They stay on the box.

## Credentials in the standup scripts

The `*-fresh.sh` scripts the trials use generate a random secret and admin password per trial. The
older `*-run.sh` reference scripts contain fixed passwords (`Pilot-pass-1` and similar). These are
for throwaway app instances bound to loopback on the bench box and protect nothing.
