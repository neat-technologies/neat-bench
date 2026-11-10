# Corpus item: Paperless-ngx (candidate, hand-verify before locking)

PICK: jinja2 CVE-2025-27516 (sandbox breakout) @ v2.15.3 — clean patch bump, STRONG reachability, 0-regression proof.

repo: github.com/paperless-ngx/paperless-ngx
TRIAL commit: v2.15.3 / e6253caa198cd6a91f3a4de1eb13799d17dd1c68 (instrumentation was validated at v3.4.2; the TRIAL re-checks out v2.15.3 where jinja2 is vulnerable. NOTE the large version gap: the Django/neat-otel instrumentation applies, but templating lives in src/documents/templating/filepath.py at v2.15.3, split into environment.py/workflows.py in v3.x. Per-trial stand-up at v2.15.3 is its own setup.)
ecosystem: PyPI (PEP 440). testCmd: pytest (needs postgres + redis); hand-map the templating test for the vuln-path guard.

## Primary reachable advisory
dep: jinja2 3.1.5, fixedIn 3.1.6, fixKind: BUMP (clean patch; constraint jinja2~=3.1.5 already allows 3.1.6 -> lockfile-only, zero code change).
advisory: CVE-2025-27516 / GHSA-cpwx-vrp4-4pq7 / PYSEC-2026-1471 — sandbox breakout via the attr filter selecting the format method.
importers: src/documents/templating/filepath.py (L17 from jinja2.sandbox import SandboxedEnvironment; L33 class FilePathEnvironment(SandboxedEnvironment); L321 renders a user-configured storage-path template). STRONG reach: the CVE escapes the exact sandbox Paperless relies on for user-supplied templates -> arbitrary Python.
0-regression proof: maintainers bumped to jinja2 3.1.6 in v2.16.0 (green release).

## audit-noise @ v2.15.3 (the scoping contrast)
heavy: pillow ~55 OSV, django ~18, djangorestframework 5, cryptography 5, lxml 1. jinja2 is 1 of ~85 flagged -> bare over-fixes pillow/django; NEAT scopes to the reachable sandbox-escape.

## precision controls (present-but-NOT-reachable — NEAT should EXCLUDE)
- cryptography CVEs: Paperless uses only Fernet/PBKDF2HMAC/hashes, not the vulnerable OpenSSL/X.509/TLS paths.
- lxml XXE (CVE-2026-41066): validators.py already sets resolve_entities=False + uses etree.parse, not the vulnerable iterparse/ETCompatXMLParser defaults. Also lxml is transitive (only lxml-stubs declared).
- scikit-learn TfidfVectorizer leak: classifier.py sets stop_words_=None (mitigated) + pins >=1.5.1.

## backups
Django @v2.20.15: CVE-2025-64459 SQLi (specific reach weak) OR CVE-2026-33033 MultiPartParser DoS (reachable via uploads); clean patch but VERY high django noise. DRF @v2.20.15: CVE-2026-73228/73229 (minor bump, declared+imported).

evidence (ephemeral): scratchpad/pngx.
