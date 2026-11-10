// Machine-readable corpus, transcribed from corpus/*.md. Each item is a CorpusItem (grader.ts)
// plus bench metadata (repo URL, NEAT service id, the live daemon port for dry reuse, the app's
// default port, a `locked` flag). vulnPathTests are the NOT-DEGENERATE oracle: existing tests that
// exercise the vulnerable feature, hand-verified 2026-11-10 (HIGH confidence). The exact test-id
// STRINGS must still be matched against runTests() output format in the validation smoke before the
// real run (noted per item). auditNoise stays [] = over-fix is computed at runtime as
// changed-deps-not-in-the-reachable-set; the precision-control deps NEAT must EXCLUDE are in notes.
// baselineGreen is established per trial (pre-patch run).
import type { CorpusItem, Advisory, Ecosystem } from './grader.js'

export interface BenchCorpusItem extends CorpusItem {
  ecosystem: Ecosystem
  service: string // NEAT ServiceNode id (the scan/graph service name)
  repoUrl: string
  knownDaemonPort?: number // live neat-ba daemon for dry reuse
  appDefaultPort?: number
  locked: boolean
  notes: string[]
}

const uptimeKuma: BenchCorpusItem = {
  app: 'uptime-kuma',
  repo: 'github.com/louislam/uptime-kuma',
  repoUrl: 'https://github.com/louislam/uptime-kuma.git',
  commit: '1f0755fb044fe08e99fccde6722062fb2bf6c8f4', // tag 2.5.3
  ecosystem: 'npm',
  service: 'uptime-kuma',
  appDefaultPort: 3001,
  testCmd: 'node test/test-backend.mjs', // includes test/backend-test/monitors/test-mqtt.js
  advisories: [
    {
      id: 'GHSA-8gq3-vp5j-2grp', // CVE-2026-77413 critical RCE (set also: 77414/77415/52746/12208)
      ecosystem: 'npm',
      dep: 'jsonata',
      vulnerableRange: '>=2.0.0 <2.2.1',
      fixedIn: '2.2.1',
      importers: ['server/monitor-types/mqtt.js', 'server/monitor-types/mongodb.js'],
      fixKind: 'bump',
      // test/backend-test/monitors/test-mqtt.js, describe("MqttMonitorType"), json-query path -> checkJsonQuery() -> jsonata()
      vulnPathTests: [
        'check() sets status to UP when json-query finds expected value',
        'check() rejects when json-query path returns undefined',
        'check() rejects when json-query value does not match expected value',
      ],
    },
  ],
  auditNoise: [],
  baselineGreen: [],
  locked: true,
  notes: [
    'fix is in-process JS (jsonata 2.1.1->2.2.1); OBSERVED unaffected pre/post. 0-reg proof: project shipped jsonata 2.2.2 in 2.5.4.',
    'GOTCHA: MqttMonitorType describe self-skips unless linux/x64 and needs Docker (@testcontainers/hivemq). Box is linux/x64 + Docker -> runs; if skipped the not-degenerate guard is VACUOUS - assert it did not skip.',
    'SMOKE-VERIFY: match these 3 test-name strings against runTests() output ids.',
    'precision foils (imported, lower-reach): form-data CRLF @2.4.0, mysql2.',
  ],
}

const nodegoat: BenchCorpusItem = {
  app: 'nodegoat',
  repo: 'github.com/OWASP/NodeGoat',
  repoUrl: 'https://github.com/OWASP/NodeGoat.git',
  commit: 'c5cb68a7084e4ae7dcc60e6a98768720a81841e8',
  ecosystem: 'npm',
  service: 'nodegoat',
  knownDaemonPort: 8202,
  appDefaultPort: 4000,
  testCmd: 'npm run test:ci', // Cypress e2e; npm test is a no-op. Needs app + mongo:4.0 up.
  advisories: [
    // clean bumps; infra-level, exercised by the whole suite (a degenerate delete breaks no-regression, not just these)
    { id: 'GHSA-cf4h-3jhx-xvhq', ecosystem: 'npm', dep: 'underscore', vulnerableRange: '<1.12.1', fixedIn: '1.13.8', importers: ['config/config.js'], fixKind: 'bump', vulnPathTests: [] },
    { id: 'CVE-2024-29041', ecosystem: 'npm', dep: 'express', vulnerableRange: '<4.20.0', fixedIn: '4.21.2', importers: ['server.js', 'app/routes/tutorial.js'], fixKind: 'bump', vulnPathTests: [] },
    { id: 'CVE-2024-45590', ecosystem: 'npm', dep: 'body-parser', vulnerableRange: '<1.20.3', fixedIn: '1.20.9', importers: ['server.js'], fixKind: 'bump', vulnPathTests: [] },
    // feature-specific: a degenerate "fix" that removes the feature breaks these exact specs
    { id: 'CVE-2022-21680', ecosystem: 'npm', dep: 'marked', vulnerableRange: '<4.0.10', fixedIn: '4.0.10', importers: ['server.js', 'app/views/memos.html'], fixKind: 'bump', vulnPathTests: ['Should memo be generated'] },
    { id: 'GHSA-mh5c-679w-hh4r', ecosystem: 'npm', dep: 'mongodb', vulnerableRange: '<3.1.13', fixedIn: '3.1.13', importers: ['server.js', 'app/data'], fixKind: 'bump', vulnPathTests: ['Should memo be generated', 'should have admin user able to login', 'Should new user be added to the system'] },
    { id: 'CVE-2023-25345', ecosystem: 'npm', dep: 'swig', vulnerableRange: '<=1.4.2', fixedIn: null, importers: ['server.js'], fixKind: 'replace', vulnPathTests: ['Should memo be generated'] },
  ],
  auditNoise: [],
  baselineGreen: [],
  locked: true,
  notes: [
    'no-regression + not-degenerate oracle is the Cypress e2e suite (needs app + mongo:4.0), NOT npm test.',
    'vulnPathTests are Cypress it() names: memos_spec.js "Should memo be generated" (marked+mongodb+swig triple), login_spec.js "should have admin user able to login", signup_spec.js "Should new user be added to the system". SMOKE-VERIFY against runTests() id format for Cypress.',
    'mongodb(3.1.13 major)/marked(v4, loses sanitize)/swig(remove-replace, no fix) are the HARD half; express/body-parser/underscore clean bumps (infra: covered by whole-suite no-regression).',
    'precision foil: forever@2.0.0 is a DIRECT prod dep but NOT import-reachable (Procfile binary) - NEAT should exclude.',
  ],
}

const paperless: BenchCorpusItem = {
  app: 'paperless-ngx',
  repo: 'github.com/paperless-ngx/paperless-ngx',
  repoUrl: 'https://github.com/paperless-ngx/paperless-ngx.git',
  commit: 'e6253caa198cd6a91f3a4de1eb13799d17dd1c68', // v2.15.3
  ecosystem: 'PyPI',
  service: 'paperless-ngx',
  knownDaemonPort: 8203,
  appDefaultPort: 8000,
  testCmd: 'pytest src/documents/tests/test_file_handling.py src/documents/tests/test_api_objects.py', // storage-path templating (filepath.py)
  advisories: [
    {
      id: 'CVE-2025-27516', // GHSA-cpwx-vrp4-4pq7 / PYSEC-2026-1471, jinja2 sandbox breakout
      ecosystem: 'PyPI',
      dep: 'jinja2',
      vulnerableRange: '<3.1.6',
      fixedIn: '3.1.6',
      importers: ['src/documents/templating/filepath.py'],
      fixKind: 'bump', // clean patch; jinja2~=3.1.5 already allows 3.1.6 (lockfile-only)
      // test_file_handling.py drives filepath.py's SandboxedEnvironment render via generate_filename
      vulnPathTests: [
        'test_dynamic_path',
        'test_dynamic_path_with_none',
        'test_dynamic_path_remove_none',
        'test_test_storage_path',
      ],
    },
  ],
  auditNoise: [],
  baselineGreen: [],
  locked: true,
  notes: [
    'templating lives in src/documents/templating/filepath.py at v2.15.3 (split in v3.x). pytest needs postgres + redis.',
    'vulnPathTests: TestFilenameGeneration.test_dynamic_path(+_with_none,_remove_none) in test_file_handling.py; test_test_storage_path in test_api_objects.py. SMOKE-VERIFY pytest id format (file::Class::method).',
    'clean lockfile-only patch (jinja2 3.1.5->3.1.6; shipped in v2.16.0). no test exercises the sandbox ESCAPE itself (correct for a not-degenerate guard).',
    'precision controls (present-but-NOT-reachable, NEAT should EXCLUDE): cryptography (only Fernet/PBKDF2HMAC/hashes), lxml XXE (resolve_entities=False + transitive), scikit-learn (stop_words_=None, pinned >=1.5.1).',
  ],
}

const gitea: BenchCorpusItem = {
  app: 'gitea',
  repo: 'github.com/go-gitea/gitea',
  repoUrl: 'https://github.com/go-gitea/gitea.git',
  commit: '829b49c1ae96015e345f9d2a0eb1ea7acd5f31e1', // v28.2.0 (x/net vulnerable)
  ecosystem: 'Go',
  service: 'gitea',
  knownDaemonPort: 8204,
  appDefaultPort: 3000,
  testCmd: 'go test ./modules/markup/...', // markup rendering (x/net/html path); full CI is heavy
  advisories: [
    { id: 'CVE-2026-78661', ecosystem: 'Go', dep: 'golang.org/x/net', vulnerableRange: '<0.62.0', fixedIn: '0.62.0', importers: ['modules/markup/html.go', 'modules/markup/internal/renderinternal.go', 'services/mailer/mail.go'], fixKind: 'bump', vulnPathTests: ['TestPostProcess', 'TestRender_Commits', 'TestRender_links', 'TestRender_emoji', 'TestSanitizer'] },
    { id: 'CVE-2026-97045', ecosystem: 'Go', dep: 'golang.org/x/net', vulnerableRange: '<0.62.0', fixedIn: '0.62.0', importers: ['modules/markup/html.go', 'modules/markup/internal/renderinternal.go'], fixKind: 'bump', vulnPathTests: ['TestPostProcess', 'TestIssue16020', 'TestIssue18471'] },
  ],
  auditNoise: [],
  baselineGreen: [],
  locked: true,
  notes: [
    'PROVEN clean bump: Gitea shipped x/net 0.62.0 in v28.3.0 (green). testCmd scoped to ./modules/markup/... (the x/net/html path); full go test is prohibitively heavy for k=1.',
    'vulnPathTests: TestPostProcess @ modules/markup/html_test.go:516 (+ TestRender_* family, TestSanitizer @ sanitizer_default_test.go). SMOKE-VERIFY go-test id format.',
    'precision control: go-chi/chi 5.3.2 imported in 11 files but ClientIPFromXFF/middleware.RealIP NOT reached (Gitea ships its own setRealIP, routers/private/internal.go:59). NEAT should mark chi NOT reachable. Also exclude: x/crypto openpgp (uses ProtonMail/go-crypto), brotli (transitive).',
  ],
}

export const CORPUS: Record<string, BenchCorpusItem> = {
  'uptime-kuma': uptimeKuma,
  nodegoat,
  'paperless-ngx': paperless,
  gitea,
}

export function getCorpusItem(app: string): BenchCorpusItem {
  const i = CORPUS[app]
  if (!i) throw new Error(`no corpus item for '${app}' (have: ${Object.keys(CORPUS).join(', ')})`)
  return i
}
