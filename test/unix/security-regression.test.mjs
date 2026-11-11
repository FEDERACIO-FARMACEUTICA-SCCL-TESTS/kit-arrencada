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
    NO_UPDATE_NOTIFIER: "1", NODE_COMPILE_CACHE: process.env.NODE_COMPILE_CACHE, HOME: home, PATH: `${stubs}:${tools}`, TMPDIR: tmp, LOG: log, FIXTURES: fixtures, ...env,
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


const {relative}=await import('node:path');
const ARGS=['--repo',REPO,'--no-obrir','--sense-gentle-shell'];
function source(s,code,env={}) {
 return spawnSync('/bin/sh',['-c','. "$SCRIPT"; '+code],{encoding:'utf8',env:{...process.env,HOME:s.home,TMPDIR:s.tmp,ARRENCADA_TEST:'',ARRENCADA_NOMES_FUNCIONS:'1',SCRIPT,...env}});
}
// S7: must reject authority prefix/userinfo lookalikes.
test('S7 refuses lookalike download authorities',()=>{
 for(const u of ['https://objects.githubusercontent.com.attacker.example/a','https://objects.githubusercontent.com@attacker.example/a']){
 const s=sandbox();const r=source(s,'check_url "$U"',{U:u});assert.equal(r.status,11,u);assert.equal(r.stderr,'[arrencada] ERROR: URL no permesa: '+u+'\n');
 }
});
// S6/S7: only the official publisher may supply both installer and checksum.
test('S6 S7 refuses nonofficial installer override outside test mode',()=>{
 const s=sandbox({gentle:false,env:{INSTALL_GS:'1',ARRENCADA_GS_RELEASES:'https://github.com/attacker/project/releases/latest/download'}});
 const r=s.run(['--repo',REPO,'--no-obrir']);assert.equal(r.code,64);assert.equal(s.called('installer ran'),false);assert.equal(s.called('curl'),false);
});
// S5: reject whole invalid values before touching identity.
test('S5 rejects multiline repo',()=>{
 const s=sandbox();const p=join(s.home,'.gitcfg','user.email');const before=sha(readFileSync(p));const r=s.run(['--repo','A/web-prova\nBAD','--no-obrir','--sense-gentle-shell']);assert.equal(r.code,64);assert.equal(sha(readFileSync(p)),before);assert.equal(s.calls().length,0);
});
test('S5 rejects multiline email without writing git config',()=>{
 const s=sandbox({gitCfg:{}});const r=s.run([...ARGS,'--correu','bad\nvalid@fedefarma.com']);assert.equal(r.code,64);assert.deepEqual(readdirSync(join(s.home,'.gitcfg')),[]);assert.equal(s.calls().length,0);
});
// S5/S6: relative CLI directories must work through step 7.
test('S5 S6 opens relative destination',()=>{
 const s=sandbox();const r=s.run(['--repo',REPO,'--directori',relative(process.cwd(),s.dir),'--sense-gentle-shell']);assert.equal(r.code,0,r.err);assert.ok(s.called('gentle-shell'));
});
// S6: same path at another hosting provider is not the requested GitHub repo.
test('S6 refuses different origin host before npm',()=>{
 const s=sandbox();mkdirSync(join(s.dir,'.git'),{recursive:true});writeFileSync(join(s.dir,'.git','origin-url'),'https://gitlab.com/'+REPO+'.git\n');writeFileSync(join(s.dir,'package.json'),'{}');const r=s.run(ARGS);assert.equal(r.code,64);assert.equal(s.called('npm install'),false);
});
// S7: exact names, removal, exact errors and unchanged identity on rejection.
test('S7 checksum positive, missing exact name and mismatch',()=>{
 for(const mode of ['ok','missing','mismatch']){
  const s=sandbox();const file=join(s.root,'asset'),sums=join(s.root,'sums');writeFileSync(file,'payload');writeFileSync(sums,(mode==='mismatch'?'0'.repeat(64):sha('payload'))+'  '+(mode==='missing'?'asset.evil':'asset')+'\n');
  const p=join(s.home,'.gitcfg','user.email'),before=sha(readFileSync(p));const r=source(s,'verify_sha "$FILE" "$SUMS" asset',{FILE:file,SUMS:sums});assert.equal(r.status,mode==='ok'?0:11);assert.equal(existsSync(file),mode==='ok');assert.equal(sha(readFileSync(p)),before);
  const message=mode==='missing'?'No hi ha suma de verificació per a asset. Descàrrega eliminada.':'La suma SHA-256 de asset no coincideix. Descàrrega eliminada.';
  assert.equal(r.stderr,mode==='ok'?'':'[arrencada] ERROR: '+message+'\n');
 }
});
// S6: modern active account and legacy CLI fallback both avoid needless login.
test('S6 stale second account and older-gh fallback',()=>{
 for(const old of [false,true]){
  const s=sandbox();sh(join(s.root,'stubs','gh'),'echo "gh $*" >> "$LOG"\ncase "$1 $2" in\n"auth status") case "$*" in *--active*) exit '+(old?1:0)+';; *) exit '+(old?0:1)+';; esac;;\n"repo clone") mkdir -p "$4";;\nesac\nexit 0');const r=s.run(ARGS);assert.equal(r.code,0,r.err);assert.equal(s.called('gh auth login'),false);assert.equal(s.calls().filter(x=>x.startsWith('gh auth status')).length,old?2:1);
 }
});
// S3/S7: don't edit profiles when no install occurs; clean temp before exec.
test('S3 S7 profile invariant and pre-exec cleanup',()=>{
 const s=sandbox(),p=join(s.home,'.profile');writeFileSync(p,'# existing\n');const before=sha(readFileSync(p));assert.equal(s.run(ARGS).code,0);assert.equal(sha(readFileSync(p)),before);
 const t=sandbox({node:'v22.0.0'}),r=t.run(['--repo',REPO]);assert.equal(r.code,0,r.err);assert.deepEqual(readdirSync(t.tmp),[]);assert.ok(t.called('gentle-shell'));
});
