# Corpus item: Gitea (candidate, hand-verify before locking)

PICK: Rank 1 — golang.org/x/net @ v28.2.0 (2 real CVEs, clean bump, project-proven fix, strong first-party reachability). PLUS chi as a reachability CONTROL (precision test).

repo: github.com/go-gitea/gitea
TRIAL commit: v28.2.0 / 829b49c1ae96015e345f9d2a0eb1ea7acd5f31e1 (instrumentation stood up at v28.3.0, where x/net is already fixed; the TRIAL re-checks out v28.2.0 where it's vulnerable).
ecosystem: Go. testCmd: Gitea CI go-test suite (heavy); hand-map the markup-rendering test for the vuln-path guard.

## Primary reachable advisory
dep: golang.org/x/net, installed 0.60.0, fixedIn 0.62.0, fixKind: BUMP (clean go.mod, same major; PROVEN — Gitea made this exact bump in v28.3.0).
advisories (both in x/net/html):
- CVE-2026-78661 / GO-2026-6860 — quadratic complexity coalescing html text nodes
- CVE-2026-97045 / GO-2026-6866 — ancestor namespace transitions rendering raw text
importers (first-party, 12): modules/markup/html.go + html_issue/html_email/html_link/html_codepreview/html_mention/html_node/html_emoji/html_commit.go, modules/markup/internal/renderinternal.go, services/mailer/mail.go. Core markdown/HTML rendering of untrusted content -> strong reachability.
0-regression proof: v28.3.0 ships 0.62.0 as a green release.

## Reachability CONTROL (precision test — key for VC-grade)
dep: github.com/go-chi/chi/v5 5.3.2, fixedIn 5.4.0, CVE-2026-114437 (X-Forwarded-For IP spoof in ClientIPFromXFF). chi is imported in 11 files (max use) BUT the vulnerable symbol is NOT reached: Gitea ships its own setRealIP (routers/private/internal.go:59) and never calls middleware.RealIP / ClientIPFromXFF. NEAT (reachable-static) should mark chi NOT reachable while a naive "imported = vulnerable" audit flags it. Use to prove the bench doesn't over-credit imported-module as reachable. imported != reachable.

## Second candidate (optional, on the instrumented tag v28.3.0)
klauspost/compress 1.20.0 -> 1.20.2 (CVE-2026-116591, panic on 2-block frames), clean patch bump; reachability transitive-within-module (zstd -> fse/huff0, via Arch .pkg.tar.zst parsing in modules/packages/arch) — govulncheck to settle.

## Non-clean Go example (if we want a remove/replace case)
blakesmith/ar (no fixedIn, unmaintained) — reachable (modules/packages/debian/metadata.go parses untrusted .deb ar archives); fixKind remove-or-replace.

## audit-noise at v28.2.0
~6 vulnerable modules / ~7 advisories: x/net (x2, reachable), x/crypto openpgp (NOT reachable — Gitea uses ProtonMail/go-crypto for PGP), chi (symbol NOT reachable, the control), klauspost/compress, blakesmith/ar, brotli (transitive). NEAT should scope to x/net and correctly EXCLUDE x/crypto + chi(symbol) + brotli.

evidence (ephemeral): scratchpad/gitea-research/ (go.mod snapshots + audit script).
