// Offline tests for unix/arrencada.sh: every external command is a stub on PATH.
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync, execFileSync } from 'node:child_process';
import {
  mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync,
  rmSync, symlinkSync, chmodSync, lstatSync, readlinkSync, readdirSync,
} from 'node:fs';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'unix', 'arrencada.sh');
const REPO = 'ACME-Org/web-prova';
const roots = [];
after(() => roots.forEach((r) => rmSync(r, { recursive: true, force: true })));

// Real tools the script legitimately needs; git/gh/node/curl are NOT here on purpose.
const TOOLS = ['sh', 'awk', 'grep', 'sed', 'tr', 'cat', 'ls', 'mkdir', 'mktemp', 'rm', 'cp', 'mv', 'ln',
  'chmod', 'dirname', 'basename', 'tail', 'head', 'tar', 'unzip', 'shasum', 'sha256sum', 'date', 'env', 'printf'];

function sh(path, body) {
  writeFileSync(path, `#!/bin/sh\n${body}\n`);
  chmodSync(path, 0o755);
}

const sha = (buf) => createHash('sha256').update(buf).digest('hex');

// Builds fixture archives served by the curl stub. `bad` corrupts the sums.
function makeFixtures(dir, { bad = false } = {}) {
  mkdirSync(dir, { recursive: true });
  const work = mkdtempSync(join(tmpdir(), 'arr-fx-'));
  roots.push(work);
  const nodeTop = 'node-v24.1.0-linux-x64';
  mkdirSync(join(work, nodeTop, 'bin'), { recursive: true });
  for (const b of ['node', 'npm', 'npx']) {
    sh(join(work, nodeTop, 'bin', b),
      b === 'node' ? 'echo v24.1.0' : `echo "${b} $*" >> "$LOG"`);
  }
  const ghTop = 'gh_9.9.9_linux_amd64';
  mkdirSync(join(work, ghTop, 'bin'), { recursive: true });
  sh(join(work, ghTop, 'bin', 'gh'),
    'echo "gh $*" >> "$LOG"\ncase "$1 $2" in "repo clone") mkdir -p "$4"; echo "{}" > "$4/package.json";; esac');
  const gsTop = 'gentle-shell-installer';
  mkdirSync(join(work, gsTop), { recursive: true });
  sh(join(work, gsTop, 'install-gentle-shell.sh'),
    'echo "installer ran" >> "$LOG"\nif [ "$INSTALL_GS" = 1 ]; then mkdir -p "$HOME/.local/bin"; printf \'#!/bin/sh\\necho "gentle-shell $*" >> "$LOG"\\n\' > "$HOME/.local/bin/gentle-shell"; chmod +x "$HOME/.local/bin/gentle-shell"; fi');
  execFileSync('tar', ['-czf', join(dir, 'gentle-shell-installer-linux.tar.gz'), '-C', work, gsTop]);
  execFileSync('tar', ['-czf', join(dir, `${nodeTop}.tar.gz`), '-C', work, nodeTop]);
  execFileSync('tar', ['-czf', join(dir, `${ghTop}.tar.gz`), '-C', work, ghTop]);
  const h = (f) => (bad ? '0'.repeat(64) : sha(readFileSync(join(dir, f))));
  writeFileSync(join(dir, 'SHASUMS256.txt'), `${h(`${nodeTop}.tar.gz`)}  ${nodeTop}.tar.gz\n`);
  writeFileSync(join(dir, 'gentle-shell-installers-SHA256SUMS.txt'),
    `${h('gentle-shell-installer-linux.tar.gz')}  gentle-shell-installer-linux.tar.gz\n`);
  writeFileSync(join(dir, 'gh_9.9.9_checksums.txt'), `${h(`${ghTop}.tar.gz`)}  ${ghTop}.tar.gz\n`);
}

// Sandbox: temp HOME, stub dir first in PATH, call log.
function sandbox(opts = {}) {
  const {
    os = 'Linux', arch = 'x86_64', git = true, gh = true, node = 'v24.1.0',
    xcode = 0, gentle = true, authOk = 0, loginOk = 0, viewOk = 0, lock = false,
    gitCfg = { 'user.name': 'Persona Prova', 'user.email': 'prova@fedefarma.com' },
    badSums = false, env = {},
  } = opts;
  const root = mkdtempSync(join(tmpdir(), 'arr-test-'));
  roots.push(root);
  const home = join(root, 'home');
  const stubs = join(root, 'stubs');
  const tools = join(root, 'tools');
  const fixtures = join(root, 'fixtures');
  const tmp = join(root, 'tmp');
  const log = join(root, 'calls.log');
  [home, stubs, tools, tmp].forEach((d) => mkdirSync(d, { recursive: true }));
  writeFileSync(log, '');
  makeFixtures(fixtures, { bad: badSums });
  for (const t of TOOLS) {
    const p = spawnSync('/bin/sh', ['-c', `command -v ${t}`], { encoding: 'utf8' }).stdout.trim();
    if (p.startsWith('/')) symlinkSync(p, join(tools, t));
  }
  const logLine = 'echo "$(basename "$0") $*" >> "$LOG"';
  sh(join(stubs, 'uname'), `case "$1" in -s) echo ${os};; -m) echo ${arch};; esac`);
  sh(join(stubs, 'curl'), `${logLine}
case "$*" in *" -I "*|*-fsSI*) echo "HTTP/2 302"; echo "location: https://github.com/cli/cli/releases/tag/v9.9.9"; exit 0;; esac
out=""; url=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; -*) shift;; *) url="$1"; shift;; esac; done
f="$FIXTURES/$(basename "$url")"
[ -f "$f" ] || exit 22
cp "$f" "$out"`);
  sh(join(stubs, 'xcode-select'), `${logLine}\n[ "$1" = "-p" ] && exit ${xcode}\nexit 0`);
  if (git) {
    sh(join(stubs, 'git'), `${logLine}
d="$HOME/.gitcfg"; mkdir -p "$d"
if [ "$1" = config ] && [ "$2" = --global ]; then
  if [ $# -eq 3 ]; then [ -f "$d/$3" ] && cat "$d/$3"; exit 0; fi
  printf '%s' "$4" > "$d/$3"; exit 0
fi
if [ "$1" = -C ] && [ "$3" = remote ]; then [ -f "$2/.git/origin-url" ] && cat "$2/.git/origin-url" || exit 128; exit 0; fi
exit 0`);
  }
  if (gh) {
    sh(join(stubs, 'gh'), `${logLine}
case "$1 $2" in
  "auth status") exit ${authOk};;
  "auth login") exit ${loginOk};;
  "auth setup-git") exit 0;;
  "repo view") exit ${viewOk};;
  "repo clone") mkdir -p "$4/.git"; echo "https://github.com/$3.git" > "$4/.git/origin-url"
     echo '{}' > "$4/package.json"; ${lock ? `echo '{}' > "$4/package-lock.json";` : ''} exit 0;;
  "api user") echo "Persona Prova"; exit 0;;
esac
exit 0`);
  }
  if (node) {
    sh(join(stubs, 'node'), `echo "${node}"`);
  }
  sh(join(stubs, 'npm'), logLine);
  if (gentle) sh(join(stubs, 'gentle-shell'), logLine);
  mkdirSync(join(home, '.gitcfg'));
  for (const [k, v] of Object.entries(gitCfg)) writeFileSync(join(home, '.gitcfg', k), v);

  const baseEnv = {
    HOME: home, PATH: `${stubs}:${tools}`, TMPDIR: tmp, LOG: log, FIXTURES: fixtures, ...env,
  };
  return {
    root, home, tmp, log,
    run(args) {
      const r = spawnSync('/bin/sh', [SCRIPT, ...args], { env: baseEnv, encoding: 'utf8', input: '' });
      return { code: r.status, out: r.stdout, err: r.stderr };
    },
    calls: () => readFileSync(log, 'utf8').split('\n').filter(Boolean),
    called(prefix) { return this.calls().some((l) => l.startsWith(prefix)); },
    dir: join(home, 'projectes', 'web-prova'),
  };
}

const ARGS = ['--repo', REPO, '--no-obrir', '--sense-gentle-shell'];

test('--help prints Catalan usage and exits 0', () => {
  const s = sandbox();
  const r = s.run(['--help']);
  assert.equal(r.code, 0);
  assert.match(r.out, /Ús: arrencada\.sh --repo ORG\/NOM/);
  assert.equal(s.calls().length, 0);
});

test('invalid repo name exits 64 and calls nothing', () => {
  for (const bad of ['sense-barra', 'acme/Web_Prova', 'acme/ab', '-acme/web-prova']) {
    const s = sandbox();
    const r = s.run(['--repo', bad]);
    assert.equal(r.code, 64, bad);
    assert.match(r.err, /Ús: arrencada\.sh/);
    assert.equal(s.calls().length, 0, bad);
  }
});

test('missing --repo exits 64', () => {
  const s = sandbox();
  const r = s.run([]);
  assert.equal(r.code, 64);
  assert.match(r.err, /Falta --repo/);
});

test('unknown option exits 64 with usage on stderr', () => {
  const s = sandbox();
  const r = s.run(['--repo', REPO, '--foo']);
  assert.equal(r.code, 64);
  assert.match(r.err, /Opció desconeguda: --foo/);
  assert.match(r.err, /Ús: arrencada\.sh/);
  assert.equal(s.calls().length, 0);
});

test('Linux without git exits 10 with hint and no downloads', () => {
  const s = sandbox({ git: false });
  const r = s.run(ARGS);
  assert.equal(r.code, 10);
  assert.match(r.err, /sudo apt-get install -y git/);
  assert.match(r.err, /sudo dnf install -y git/);
  assert.equal(s.called('curl'), false);
});

test('macOS without Command Line Tools runs xcode-select --install and exits 10', () => {
  const s = sandbox({ os: 'Darwin', arch: 'arm64', xcode: 1, git: false });
  const r = s.run(ARGS);
  assert.equal(r.code, 10);
  assert.match(r.err, /torna a executar/);
  assert.ok(s.called('xcode-select --install'));
  assert.equal(s.called('curl'), false);
});

test('node major 22 triggers node download, symlinks and PATH marker', () => {
  const s = sandbox({ node: 'v22.3.0' });
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.ok(s.calls().some((l) => l.includes('https://nodejs.org/dist/latest-v24.x/node-v24.1.0-linux-x64.tar.gz')));
  for (const b of ['node', 'npm', 'npx']) {
    const p = join(s.home, '.local', 'bin', b);
    assert.ok(lstatSync(p).isSymbolicLink(), b);
    assert.equal(readlinkSync(p), join(s.home, '.local', 'node', 'bin', b));
  }
  assert.match(readFileSync(join(s.home, '.profile'), 'utf8'), /# kit-arrencada/);
  assert.deepEqual(readdirSync(s.tmp), [], 'scratch dir removed');
});

test('missing gh is downloaded, verified and installed into ~/.local/bin', () => {
  const s = sandbox({ gh: false });
  // gh stub is gone, but the installed one must be used for the next steps
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.ok(s.calls().some((l) => l.includes('https://github.com/cli/cli/releases/download/v9.9.9/gh_9.9.9_linux_amd64.tar.gz')));
  assert.ok(existsSync(join(s.home, '.local', 'bin', 'gh')));
  assert.ok(s.called(`gh repo clone ${REPO}`), 'installed gh used afterwards');
});

test('checksum mismatch exits 11, removes download and installs nothing', () => {
  const s = sandbox({ node: 'v22.0.0', badSums: true });
  const r = s.run(ARGS);
  assert.equal(r.code, 11);
  assert.match(r.err, /no coincideix/);
  assert.equal(existsSync(join(s.home, '.local', 'node')), false);
  assert.equal(existsSync(join(s.home, '.local', 'bin', 'node')), false);
  assert.equal(existsSync(join(s.home, '.profile')), false);
  assert.deepEqual(readdirSync(s.tmp), [], 'download removed');
});

// Spec S7: base URL overrides are refused (64) outside ARRENCADA_TEST=1, before any download.
test('base URL overrides are refused without ARRENCADA_TEST', () => {
  const s = sandbox({ node: 'v22.0.0', env: { ARRENCADA_NODE_DIST: 'https://evil.example.com/dist' } });
  const r = s.run(ARGS);
  assert.equal(r.code, 64);
  assert.equal(s.called('curl'), false);
});

test('non-https base URL override is rejected without ARRENCADA_TEST', () => {
  const s = sandbox({ env: { ARRENCADA_GH_RELEASES: 'http://github.com/x' } });
  const r = s.run(ARGS);
  assert.equal(r.code, 64);
  assert.equal(s.calls().length, 0);
});

test('gh already authenticated: login NOT called, setup-git is', () => {
  const s = sandbox();
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.equal(s.called('gh auth login'), false);
  assert.ok(s.called('gh auth setup-git'));
});

test('gh not authenticated: login called with web flow', () => {
  const s = sandbox({ authOk: 1 });
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.ok(s.called('gh auth login --hostname github.com --web --git-protocol https'));
});

test('gh login failure exits 13', () => {
  const s = sandbox({ authOk: 1, loginOk: 1 });
  const r = s.run(ARGS);
  assert.equal(r.code, 13);
  assert.equal(s.called('gh auth setup-git'), false);
  assert.equal(s.called('gh repo clone'), false);
});

test('repo without access exits 13 asking Plataforma and does not clone', () => {
  const s = sandbox({ viewOk: 1 });
  const r = s.run(ARGS);
  assert.equal(r.code, 13);
  assert.match(r.err, /Plataforma/);
  assert.equal(s.called('gh repo clone'), false);
});

test('existing git user.name/user.email are not overwritten', () => {
  const s = sandbox();
  const r = s.run([...ARGS, '--correu', 'altre@fedefarma.com']);
  assert.equal(r.code, 0, r.err);
  assert.equal(readFileSync(join(s.home, '.gitcfg', 'user.email'), 'utf8'), 'prova@fedefarma.com');
  assert.equal(readFileSync(join(s.home, '.gitcfg', 'user.name'), 'utf8'), 'Persona Prova');
  assert.equal(s.called('git config --global user.email '), false);
});

test('unset git identity is filled from gh and --correu', () => {
  const s = sandbox({ gitCfg: {} });
  const r = s.run([...ARGS, '--correu', 'Nova@FedeFarma.com']);
  assert.equal(r.code, 0, r.err);
  assert.equal(readFileSync(join(s.home, '.gitcfg', 'user.name'), 'utf8'), 'Persona Prova');
  assert.equal(readFileSync(join(s.home, '.gitcfg', 'user.email'), 'utf8'), 'Nova@FedeFarma.com');
});

test('email with disallowed domain exits 64 and leaves git config untouched', () => {
  const s = sandbox({ gitCfg: {} });
  const r = s.run([...ARGS, '--correu', 'persona@gmail.com']);
  assert.equal(r.code, 64);
  assert.match(r.err, /domini/);
  assert.equal(existsSync(join(s.home, '.gitcfg', 'user.email')), false);
  assert.equal(existsSync(join(s.home, '.gitcfg', 'user.name')), false);
  assert.equal(s.called('gh repo clone'), false);
});

test('ARRENCADA_DOMINIS overrides the allowed domains', () => {
  const s = sandbox({ gitCfg: {}, env: { ARRENCADA_DOMINIS: 'exemple.cat fedefarma.com' } });
  const r = s.run([...ARGS, '--correu', 'persona@exemple.cat']);
  assert.equal(r.code, 0, r.err);
  assert.equal(readFileSync(join(s.home, '.gitcfg', 'user.email'), 'utf8'), 'persona@exemple.cat');
});

test('fresh target is cloned into the default directory', () => {
  const s = sandbox();
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.ok(s.called(`gh repo clone ${REPO} ${s.dir}`));
  assert.ok(existsSync(join(s.dir, 'package.json')));
});

test('existing clone of the same repo skips the clone (case-insensitive)', () => {
  const s = sandbox();
  mkdirSync(join(s.dir, '.git'), { recursive: true });
  writeFileSync(join(s.dir, '.git', 'origin-url'), 'https://github.com/acme-org/WEB-PROVA.git\n');
  writeFileSync(join(s.dir, 'package.json'), '{}');
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.equal(s.called('gh repo clone'), false);
  assert.match(r.out, /no es torna a clonar/);
});

test('other non-empty directory exits 64 and is not touched', () => {
  const s = sandbox();
  mkdirSync(s.dir, { recursive: true });
  writeFileSync(join(s.dir, 'fitxer.txt'), 'hola');
  const r = s.run(ARGS);
  assert.equal(r.code, 64);
  assert.equal(s.called('gh repo clone'), false);
  assert.equal(readFileSync(join(s.dir, 'fitxer.txt'), 'utf8'), 'hola');
});

test('package-lock.json runs npm ci', () => {
  const s = sandbox({ lock: true });
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.ok(s.called('npm ci'));
  assert.equal(s.called('npm install'), false);
});

test('no lockfile runs npm install', () => {
  const s = sandbox({ lock: false });
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.ok(s.called('npm install'));
  assert.equal(s.called('npm ci'), false);
});

test('--no-obrir does not exec gentle-shell; without it gentle-shell is exec\'d', () => {
  const a = sandbox();
  const ra = a.run(['--repo', REPO, '--no-obrir']);
  assert.equal(ra.code, 0, ra.err);
  assert.equal(a.called('gentle-shell'), false);
  assert.match(ra.out, /\/gentle:guide/);
  const b = sandbox();
  const rb = b.run(['--repo', REPO]);
  assert.equal(rb.code, 0, rb.err);
  assert.ok(b.called('gentle-shell'));
});

test('missing Gentle Shell downloads the installer, verifies it and exits 12 if still missing', () => {
  const s = sandbox({ gentle: false });
  const r = s.run(['--repo', REPO, '--no-obrir']);
  assert.equal(r.code, 12);
  assert.ok(s.calls().some((l) => l.includes('Gentleman-Programming/gentle-shell/releases/latest/download/gentle-shell-installers-SHA256SUMS.txt')));
  assert.ok(s.called('installer ran'));
  assert.equal(s.called('gh auth'), false);
});

test('Gentle Shell installer that completes lets the run continue and opens it', () => {
  const s = sandbox({ gentle: false, env: { INSTALL_GS: '1' } });
  const r = s.run(['--repo', REPO]);
  assert.equal(r.code, 0, r.err);
  assert.ok(s.called('installer ran'));
  assert.ok(s.called('gentle-shell'));
  assert.match(readFileSync(join(s.home, '.profile'), 'utf8'), /# kit-arrencada/);
});

test('Gentle Shell checksum mismatch exits 11 and does not run the installer', () => {
  const s = sandbox({ gentle: false, badSums: true });
  const r = s.run(['--repo', REPO, '--no-obrir']);
  assert.equal(r.code, 11);
  assert.equal(s.called('installer ran'), false);
});

test('--sense-gentle-shell skips the Gentle Shell step', () => {
  const s = sandbox({ gentle: false });
  const r = s.run(ARGS);
  assert.equal(r.code, 0, r.err);
  assert.equal(s.called('curl'), false);
});

test('PATH marker is appended only once across two runs', () => {
  const s = sandbox({ node: 'v22.0.0' });
  assert.equal(s.run(ARGS).code, 0);
  rmSync(s.dir, { recursive: true, force: true });
  assert.equal(s.run(ARGS).code, 0);
  const profile = readFileSync(join(s.home, '.profile'), 'utf8');
  assert.equal(profile.split('# kit-arrencada').length - 1, 1);
});

test('macOS persists PATH in ~/.zprofile', () => {
  const s = sandbox({ os: 'Darwin', arch: 'arm64', node: 'v22.0.0', env: {} });
  // macOS node asset is darwin-arm64: no fixture, so the download must fail cleanly with 11
  const r = s.run(ARGS);
  assert.equal(r.code, 11);
  assert.equal(existsSync(join(s.home, '.zprofile')), false);
});

test('ARRENCADA_INSTALAR_PREREQUISITS=0 never installs: old node exits 10 without downloads', () => {
  const s = sandbox({ node: 'v22.0.0', env: { ARRENCADA_INSTALAR_PREREQUISITS: '0' } });
  const r = s.run(ARGS);
  assert.equal(r.code, 10);
  assert.match(r.err, /ARRENCADA_INSTALAR_PREREQUISITS=0/);
  assert.equal(s.called('curl'), false);
  assert.equal(existsSync(join(s.home, '.local')), false);
});

test('ARRENCADA_INSTALAR_PREREQUISITS=0 with missing gh exits 10; invalid value exits 64', () => {
  const s = sandbox({ gh: false, env: { ARRENCADA_INSTALAR_PREREQUISITS: '0' } });
  assert.equal(s.run(ARGS).code, 10);
  assert.equal(s.called('curl'), false);
  const t = sandbox({ env: { ARRENCADA_INSTALAR_PREREQUISITS: 'x' } });
  assert.equal(t.run(ARGS).code, 64);
});

test('existing clone: ssh and scp-style origins match, lookalike repo is refused', () => {
  for (const [url, code] of [['git@github.com:ACME-org/WEB-prova.git', 0], ['ssh://git@github.com/acme-org/web-prova', 0],
    ['https://github.com/ACME-Org/web-prova-evil.git', 64], ['git@gitlab.com:ACME-Org/web-prova.git', 64]]) {
    const s = sandbox();
    mkdirSync(join(s.dir, '.git'), { recursive: true });
    writeFileSync(join(s.dir, '.git', 'origin-url'), url + '\n');
    writeFileSync(join(s.dir, 'package.json'), '{}');
    assert.equal(s.run(ARGS).code, code, url);
  }
});
