#!/usr/bin/env bash
# Content privacy boundary: synthetic projects, local Git only, no providers.
# No process/session inspection is needed; every child has a bounded lifetime.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-content-privacy.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$REPO" "$WORK" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time

repo, work = map(Path, sys.argv[1:])
passed = 0
env = dict(os.environ)
for key in list(env):
    if key.startswith(('LOOMY_', 'AI_', 'DELEGATE_', 'GIT_')) or key in ('BASH_ENV', 'PERL5OPT', 'PERL5LIB'):
        del env[key]
env.update(HOME=str(work / 'home'), XDG_CONFIG_HOME=str(work / 'config'),
           CODEX_HOME=str(work / 'codex'), CLAUDE_CONFIG_DIR=str(work / 'claude'),
           TMPDIR=str(work / 'tmp'), LOOMY_LANG='en', LOOMY_UI_LANG='en', NO_COLOR='1',
           LOOMY_HOME=str(repo), LOOMY_NO_AUTOUPDATE='1', LOOMY_CATALOG_CHECK='0',
           LOOMY_TEST_GUARD='1', LOOMY_TEST_STUBS=str(repo / 'tests/stubs'),
           PATH=f'{repo}/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin',
           GIT_AUTHOR_NAME='test', GIT_AUTHOR_EMAIL='test@example.com',
           GIT_COMMITTER_NAME='test', GIT_COMMITTER_EMAIL='test@example.com')
for key in ('HOME', 'XDG_CONFIG_HOME', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'TMPDIR'):
    Path(env[key]).mkdir()

def check(ok, description):
    global passed
    if not ok:
        print(f'not ok {passed + 1} - {description}', flush=True)
        raise AssertionError(description)
    passed += 1
    print(f'ok {passed} - {description}', flush=True)

def run(*argv, overrides=None, success=True, timeout=20, cwd=None, input_data=None):
    result = subprocess.run([str(a) for a in argv], env=dict(env, **(overrides or {})),
                            capture_output=True, text=True, timeout=timeout, cwd=cwd, input=input_data)
    if success and result.returncode:
        raise AssertionError(f'{argv[0]} exited {result.returncode}: {result.stderr[-2000:]}')
    return result

def put(path, body, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(body)
    path.chmod(mode)

def manifest(root):
    """Hashes are test-fixture evidence only, never an inventory operation."""
    result = {}
    def visit(path):
        s = path.lstat()
        digest = None
        if stat.S_ISREG(s.st_mode):
            # Fixture denied files are temporarily readable only by this test
            # runner; don't chmod them when constructing the manifest.
            try:
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
            except PermissionError:
                digest = 'permission-denied'
        result[str(path.relative_to(root))] = (s.st_mode, s.st_uid, s.st_nlink,
            s.st_size, s.st_mtime_ns, s.st_ino, os.readlink(path) if path.is_symlink() else digest)
        if stat.S_ISDIR(s.st_mode):
            for child in path.iterdir():
                visit(child)
    visit(root)
    return result

def inventory(root, *options, overrides=None):
    output = run(repo / 'bin/loomy', 'privacy', 'inventory', '--root', root,
                 '--json', *options, overrides=overrides)
    if output.stderr:
        raise AssertionError(f'inventory diagnostics: {output.stderr[:1500]}')
    check(True, 'inventory has no raw diagnostics')
    return json.loads(output.stdout), output.stdout

def category(report, name):
    return next(r for r in report['categories'] if r['category'] == name)

project = work / 'project'
logs = project / '.loomy/logs'
logs.mkdir(parents=True)
put(project / '.loomy/brief.md', '---\nname: PRIVATE_BRIEF\ntype: web\nstage: mvp\nai_mode: SOLO\nai_lead: codex\nbudget: equilibre\nai_files: local\n---\nPRIVATE_BODY\n')
put(project / '.loomy/VERSION', '0.17.6\n')
put(project / '.loomy/state', 'phase=build\nPRIVATE_STATE\n')
events = [dict(type='delegation', ts='2026-10-27T12:00:00Z', id=f'event-{n:02}',
               role='developer', tool='codex', model='gpt-6.1-sol', outcome='ok',
               task='PRIVATE_TASK', excerpt='PRIVATE_EXCERPT', why='PRIVATE_WHY',
               checkpoint_value={'task': 'PRIVATE_NESTED'}, unknown='PRIVATE_UNKNOWN')
          for n in range(1, 21)]
put(logs / 'events.jsonl', ''.join(json.dumps(e) + '\n' for e in events))
put(logs / 'codex-native.idx', 'PRIVATE_CHECKPOINT')
put(logs / 'archive/old.jsonl', 'PRIVATE_ARCHIVE')
put(project / '.loomy/memory/private-results-v1/result.json', 'PRIVATE_RESULT')
put(project / '.loomy/memory/receipts-v1/receipt.json', 'PRIVATE_RECEIPT')
put(project / '.loomy/memory/delegations/legacy.md', 'PRIVATE_LEGACY')
put(project / '.loomy/restore-backup-old/runtime.txt', 'PRIVATE_BACKUP')
put(project / 'docs/reports/private-name.md', 'PRIVATE_REPORT')
before = manifest(project)
for options in ((), ('--paths',), ('--git-history',), ('--host',), ('--paths', '--git-history', '--host')):
    report, raw = inventory(project, *options)
    check(report['inventory_version'] == 1 and report['project_id'] is None,
          'inventory has a version and does not read or initialise project identity')
    check(category(report, 'journal-active')['file_count'] == 1 and
          category(report, 'journal-active')['bytes'] == (logs / 'events.jsonl').stat().st_size,
          'inventory counts regular-file metadata')
    check(all(r['content_status'] in ('legacy-possible', 'structural-marked-unverified', 'unknown')
              for r in report['categories']), 'inventory never claims absence of secrets')
    check('PRIVATE_' not in raw and ('--paths' in options or 'private-name' not in raw),
          'inventory exports neither bodies nor default identifying paths')
    check(before == manifest(project), 'P17 names, modes, timestamps and fixture hashes are unchanged')
    if '--git-history' in options:
        check(not report['scan_complete'] and all(not g['index']['scan_complete'] for g in report['git']),
              'missing Git and companion are explicitly partial')

plain = run(repo / 'scripts/loomy-privacy.sh', 'inventory', '--root', project)
french = run(repo / 'scripts/loomy-privacy.sh', 'inventory', '--root', project,
             overrides={'LOOMY_LANG': 'fr', 'LOOMY_UI_LANG': 'fr'})
check('metadata only' in plain.stdout and 'métadonnées' in french.stdout, 'inventory text is EN/FR')
check('private-name' not in plain.stdout and 'PRIVATE_' not in french.stdout, 'text inventory has no private context')
check(before == manifest(project), 'text inventory does not mutate historical files')

for name in ('missing', 'denied', 'symlink'):
    target = work / name
    if name == 'denied':
        target.mkdir()
        target.chmod(0)
    elif name == 'symlink':
        target.symlink_to(project, target_is_directory=True)
    report, raw = inventory(target, '--paths')
    check(not report['scan_complete'] and 'PRIVATE_' not in raw, f'P16 {name} root is bounded and partial')
    if name == 'denied':
        check(stat.S_IMODE(target.stat().st_mode) == 0, 'denied root mode is preserved')
        target.chmod(0o700)

unsafe = work / 'unsafe'
(unsafe / '.loomy/logs').mkdir(parents=True)
(unsafe / '.loomy/logs/events.jsonl').symlink_to(logs / 'events.jsonl')
os.mkfifo(unsafe / '.loomy/logs/codex-native.idx')
put(unsafe / '.loomy/logs/archive/hardlink.jsonl', 'PRIVATE_HARDLINK')
os.link(unsafe / '.loomy/logs/archive/hardlink.jsonl', unsafe / '.loomy/logs/archive/other.jsonl')
put(unsafe / '.loomy/logs/archive/denied.jsonl', 'PRIVATE_DENIED', 0)
put(unsafe / '.loomy/logs/archive/escape\n\x1b[31m.jsonl', 'PRIVATE_ESCAPED')
unsafe_before = manifest(unsafe)
report, raw = inventory(unsafe, '--paths')
check(not report['scan_complete'] and category(report, 'journal-active')['symlink_count'] == 1,
      'P16 symlink is counted without following its target')
check(category(report, 'checkpoints-and-scratch')['unreadable_count'] > 0,
      'P16 FIFO is reported without an open or blocking read')
check(category(report, 'journal-archives')['unreadable_count'] >= 3,
      'P16 hardlinks and unreadable entries make coverage partial')
check('escape\\n\\u001b' in raw and '\x1b' not in raw, '--paths escapes hostile filenames')
check(unsafe_before == manifest(unsafe), 'P17 unsafe paths stay byte-for-byte and metadata identical')

# Deterministically inject metadata returned by the OS; creating devices or
# changing ownership would require privileged fixture setup on macOS.
probe = work / 'probes/T5Metadata.pm'
put(probe, '''package T5Metadata;
use strict; use warnings; use Time::HiRes (); use Fcntl qw(:mode);
my $original=\\&Time::HiRes::lstat; my $calls=0;
no warnings 'redefine';
*Time::HiRes::lstat=sub (;$) {
  my @s=$original->(@_);
  if (@s && $_[0] eq 'events.jsonl') {
    if ($ENV{T5_METADATA_FAULT} eq 'owner') {$s[4]=$<+1}
    elsif ($ENV{T5_METADATA_FAULT} eq 'device') {$s[2]=S_IFCHR|0600}
    elsif ($ENV{T5_METADATA_FAULT} eq 'growth') {$s[7]+=++$calls}
  } elsif ($ENV{T5_METADATA_FAULT} eq 'host-growth' && @s && $_[0] eq 'repair-test.log' && !$calls++) {
    open my $f,'>>','repair-test.log' or die; print $f 'x'; close $f;
  } elsif ($ENV{T5_METADATA_FAULT} eq 'appears' && !@s && $_[0] eq 'events.jsonl' && !$calls++) {
    open my $f,'>','events.jsonl' or die; print $f 'x'; close $f;
  }
  return wantarray?@s:scalar @s;
};
1;
''')
for fault in ('owner', 'device', 'growth'):
    report, raw = inventory(project, overrides={'PERL5OPT': f'-I{probe.parent} -MT5Metadata',
                                               'T5_METADATA_FAULT': fault})
    check(not category(report, 'journal-active')['scan_complete'] and 'PRIVATE_' not in raw,
          f'P16 {fault} metadata produces a content-free partial result')
check(before == manifest(project), 'injected metadata failures never change fixture files')

appears = work / 'appears'
(appears / '.loomy/logs').mkdir(parents=True)
report, _ = inventory(appears, overrides={'PERL5OPT': f'-I{probe.parent} -MT5Metadata', 'T5_METADATA_FAULT': 'appears'})
check(not category(report, 'journal-active')['scan_complete'], 'an initially absent file created during lstat makes coverage partial')
host_config = work / 'host-config'
put(host_config / 'loomy/logs/repair-test.log', 'x')
report, _ = inventory(project, '--host', overrides={'XDG_CONFIG_HOME': str(host_config),
    'PERL5OPT': f'-I{probe.parent} -MT5Metadata', 'T5_METADATA_FAULT': 'host-growth'})
check(not category(report, 'host-repair-reports-cache')['scan_complete'], 'host growth receives the same final metadata recheck as project files')
host_link = work / 'host-link'
host_link.mkdir()
(host_link / 'loomy').symlink_to(host_config / 'loomy', target_is_directory=True)
report, _ = inventory(project, '--host', overrides={'XDG_CONFIG_HOME': str(host_link)})
check(not category(report, 'host-repair-reports-cache')['scan_complete'], 'a linked host ancestor never becomes complete empty coverage')
census = work / 'census'
for name in ('events.next', 'usage.idx', 'desktop-resume.stdout', 'skill-install.log'):
    put(census / '.loomy/logs' / name, 'PRIVATE_CENSUS')
report, _ = inventory(census)
check(category(report, 'checkpoints-and-scratch')['file_count'] == 4, 'rotation, usage and desktop scratch sinks are inventoried')

no_bodies = work / 'probes/T5NoBodies.pm'
put(no_bodies, '''package T5NoBodies;
use strict; use warnings; use Fcntl qw(O_DIRECTORY);
BEGIN {
 *CORE::GLOBAL::sysopen=sub (*$$;$) {
   die "body open forbidden\\n" unless $_[2]&O_DIRECTORY;
   return CORE::sysopen($_[0],$_[1],$_[2],$_[3]//0666);
 };
 *CORE::GLOBAL::open=sub (*;$@) {
   die "body open forbidden\\n" unless defined($_[2]) && ($_[1] eq '>&' || $_[2] eq '/dev/null');
   return CORE::open($_[0],$_[1],$_[2]);
 };
}
1;
''')
report, _ = inventory(project, '--paths', '--host', overrides={'PERL5OPT': f'-I{probe.parent} -MT5NoBodies'})
check(category(report, 'journal-active')['file_count'] == 1, 'inventory succeeds with all non-directory file opens forbidden')

large = work / 'large'
(large / '.loomy/logs/archive').mkdir(parents=True)
for n in range(10100):
    (large / f'.loomy/logs/archive/{n}.jsonl').touch()
started = time.monotonic()
report, _ = inventory(large)
check(time.monotonic() - started < 8 and not report['scan_complete'], 'large/growing candidate set has an explicit operation budget')

# Inventory must not start provider CLIs, repair, host process probes or network
# clients. Git is permitted only for the explicit local-history option.
blocked = work / 'blocked'
blocked.mkdir()
spawn_log = work / 'forbidden.log'
for name in ('gh', 'claude', 'codex', 'curl', 'wget', 'tmux', 'ps', 'pgrep', 'git', 'open', 'xdg-open'):
    put(blocked / name, '#!/bin/sh\nprintf "%s\\n" "$0 $*" >>"$T5_SPAWN_LOG"\nexit 96\n', 0o700)
report, raw = inventory(project, '--host', overrides={'PATH': f'{blocked}:{env["PATH"]}', 'T5_SPAWN_LOG': str(spawn_log)})
check(not spawn_log.exists(), 'inventory default/host starts no Git, provider, network or process collector')

git = Path('/usr/bin/git')
run(git, '-C', project, 'init', '-q')
run(git, '-C', project, 'add', '-f', '.loomy/logs/events.jsonl')
run(git, '-C', project, 'commit', '-qm', 'synthetic historical runtime')
git_before = manifest(project)
report, raw = inventory(project, '--git-history')
g = next(g for g in report['git'] if g['repository'] == 'project')
check(g['index']['file_count'] == 1 and g['history']['commit_count'] == 1,
      'local index and historical runtime counts are distinct')
check(git_before == manifest(project), '--git-history changes no working file, index, ref or object')

git_meta = work / 'git-metadata'
put(git_meta / '.loomy/task.state', 'PRIVATE_STATE_RUNTIME')
put(git_meta / '.loomy/memory/STATE.md', 'PRIVATE_AUTHORED')
run(git, '-C', git_meta, 'init', '-q')
run(git, '-C', git_meta, 'add', '-f', '.')
run(git, '-C', git_meta, 'commit', '-qm', 'runtime and authored fixture')
report, _ = inventory(git_meta, '--git-history')
g = next(g for g in report['git'] if g['repository'] == 'project')
check(g['index']['file_count'] == 1 and g['history']['commit_count'] == 1,
      'Git runtime selectors include task state and exclude authored continuity')
for name in ('index', 'config', 'objects'):
    original = git_meta / '.git' / name
    outside = work / f'git-outside-{name}'
    original.rename(outside)
    original.symlink_to(outside, target_is_directory=outside.is_dir())
    report, _ = inventory(git_meta, '--git-history')
    g = next(g for g in report['git'] if g['repository'] == 'project')
    check(not g['index']['scan_complete'] and not g['history']['scan_complete'], f'Git refuses linked {name} metadata')
    original.unlink()
    outside.rename(original)

signature_marker = work / 'signature-spawned'
verifier = work / 'verifier'
put(verifier, f'#!/bin/sh\nprintf spawned > "{signature_marker}"\nexit 1\n', 0o700)
tree = run(git, '-C', git_meta, 'write-tree').stdout.strip()
commit = f'tree {tree}\nauthor test <test@example.com> 1700000000 +0000\ncommitter test <test@example.com> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n ZmFrZQ==\n -----END PGP SIGNATURE-----\n\nsigned fixture\n'
oid = run(git, '-C', git_meta, 'hash-object', '-t', 'commit', '-w', '--stdin', input_data=commit).stdout.strip()
run(git, '-C', git_meta, 'update-ref', 'refs/heads/main', oid)
run(git, '-C', git_meta, 'config', 'log.showSignature', 'true')
run(git, '-C', git_meta, 'config', 'gpg.program', verifier)
signature_before = manifest(git_meta)
report, _ = inventory(git_meta, '--git-history')
check(not signature_marker.exists(), 'Git metadata queries never invoke a configured signature verifier')
check(signature_before == manifest(git_meta), 'Git diagnostics leave signed history and configuration unchanged')
include_target = work / 'external-config'
put(include_target, 'PRIVATE_INVALID_GIT_CONFIG')
include_link = work / 'included-config'
include_link.symlink_to(include_target)
for target in (include_link, work / 'included-fifo'):
    if target.name == 'included-fifo':
        os.mkfifo(target)
    run(git, 'config', '--no-includes', '--file', git_meta / '.git/config', '--add', 'include.path', target)
    report, raw = inventory(git_meta, '--git-history')
    g = next(g for g in report['git'] if g['repository'] == 'project')
    check(not g['index']['scan_complete'] and not g['history']['scan_complete'] and 'PRIVATE_' not in raw,
          f'Git refuses external includes without following {target.name}')
    run(git, 'config', '--no-includes', '--file', git_meta / '.git/config', '--unset', 'include.path')
for key in ('extensions.worktreeConfig', 'extensions.partialClone', 'remote.fixture.promisor'):
    run(git, 'config', '--no-includes', '--file', git_meta / '.git/config', key, 'true')
    report, _ = inventory(git_meta, '--git-history')
    g = next(g for g in report['git'] if g['repository'] == 'project')
    check(not g['index']['scan_complete'] and not g['history']['scan_complete'], f'Git reports unknown for unsupported {key} metadata')
    run(git, 'config', '--no-includes', '--file', git_meta / '.git/config', '--unset', key)
for name in ('commondir', 'objects/info/alternates', 'objects/pack/fixture.promisor'):
    put(git_meta / '.git' / name, 'PRIVATE_EXTERNAL_POINTER')
    report, _ = inventory(git_meta, '--git-history')
    g = next(g for g in report['git'] if g['repository'] == 'project')
    check(not g['index']['scan_complete'] and not g['history']['scan_complete'], f'Git pointer {name} remains explicitly unknown')
    (git_meta / '.git' / name).unlink()

tmp_before = manifest(Path(env['TMPDIR']))
feedback = run(repo / 'scripts/loomy-feedback.sh', '--root', project, '--print', 'Explicit user message',
               overrides={'TERM_PROGRAM': 'PRIVATE_TERM\n| injected |', 'TERM': 'PRIVATE_TERM\x1b[31m'})
check('Explicit user message' in feedback.stdout and '| Loomy |' in feedback.stdout and 'phase build' in feedback.stdout,
      'P13 feedback retains explicit message and useful bounded context')
check('PRIVATE_' not in feedback.stdout and str(project) not in feedback.stdout,
      'P13 feedback drops all brief, journal, label/result and environment canaries')
exported = [json.loads(line) for line in feedback.stdout.splitlines() if line.startswith('{')]
check([e['id'] for e in exported] == [f'event-{n:02}' for n in range(6, 21)], 'P13 feedback attaches exactly the last 15 projected events')
check(all(e.get('content_policy') == 'structural-v1' and not set(e).intersection(('task', 'excerpt', 'why', 'unknown'))
          for e in exported), 'P13 historical events pass the structural projector')
check(git_before == manifest(project), 'feedback never creates identity, copies or mutates project state')
check(tmp_before == manifest(Path(env['TMPDIR'])), 'feedback --print leaves temporary metadata unchanged')

# The only permitted gh query is its local --version metadata.
offline = run(repo / 'scripts/loomy-feedback.sh', '--root', project, '--print', 'offline',
              overrides={'PATH': f'{blocked}:{env["PATH"]}', 'T5_SPAWN_LOG': str(spawn_log)})
calls = spawn_log.read_text() if spawn_log.exists() else ''
check(not any(word in calls for word in ('/gh auth', '/gh api', '/gh issue', '/curl ', '/wget ', '/open ', '/xdg-open ')),
      'feedback --print invokes no GitHub API, browser or network operation')
for sub in ('list', 'triage', 'mark', 'close', '--check-fixed'):
    if spawn_log.exists():
        spawn_log.unlink()
    result = run(repo / 'scripts/loomy-feedback.sh', sub, '--print', success=False,
                 overrides={'PATH': f'{blocked}:{env["PATH"]}', 'T5_SPAWN_LOG': str(spawn_log)})
    check(result.returncode == 2 and not spawn_log.exists(), f'--print rejects {sub} before network work')

defaults = run('perl', '-MJSON::PP', '-e',
               'require $ARGV[0]; print encode_json(Loomy::ContentPolicy::defaults())',
               repo / 'scripts/lib/content-policy.pl')
policy = json.loads(defaults.stdout)
for state in ('missing', 'valid', 'invalid', 'fifo', 'symlink', 'hardlink', 'oversized'):
    doctor_root = work / f'doctor-{state}'
    doctor_logs = doctor_root / '.loomy/logs'
    doctor_logs.mkdir(parents=True)
    conf = doctor_logs / 'content-policy.conf'
    marker = doctor_logs / 'display-context-full'
    if state == 'valid':
        p = dict(policy, label_sources='explicit-user,explicit-lead', private_results='on')
        put(conf, ''.join(f'{k}={v}\n' for k, v in p.items()))
        put(marker, 'full\n')
    elif state == 'invalid':
        put(conf, 'PRIVATE_POLICY_EXCEPTION\n')
        put(marker, 'full\n')
    elif state == 'fifo':
        os.mkfifo(conf)
    elif state == 'symlink':
        conf.symlink_to(project / '.loomy/brief.md')
    elif state == 'hardlink':
        put(conf, 'PRIVATE_POLICY_HARDLINK')
        os.link(conf, doctor_logs / 'other')
    elif state == 'oversized':
        put(conf, 'PRIVATE_OVERSIZED' * 2000)
    before_doctor = manifest(doctor_root)
    for lang in ('en', 'fr'):
        result = run(repo / 'scripts/loomy-doctor.sh', '--compact', '--root', doctor_root,
                     overrides={'LOOMY_LANG': lang, 'LOOMY_UI_LANG': lang}, success=False)
        combined = result.stdout + result.stderr
        expected = {'en': ('Content policy valid', 'Invalid content policy', 'No content policy file', 'Label store full'),
                    'fr': ('Politique de contenu valide', 'Politique de contenu invalide', 'Aucun fichier de politique', 'Stockage des libellés plein')}[lang]
        check(expected[2 if state == 'missing' else 0 if state == 'valid' else 1] in combined,
              f'doctor {lang}: {state} policy health is explicit')
        check('PRIVATE_' not in combined and str(conf) in combined,
              f'doctor {lang}: policy path is shown without raw errors or content')
        if state in ('valid', 'invalid'):
            check(expected[3] in combined, f'doctor {lang}: persistent label-full fact survives policy state')
        if state == 'valid':
            check('explicit-user,explicit-lead' in combined and ('private results: on' in combined if lang == 'en' else 'résultats privés : activés' in combined),
                  f'doctor {lang}: stored label and results grants are visible')
        check(before_doctor == manifest(doctor_root), f'doctor {lang}: no identity, mode, content or marker mutation')

print(f'1..{passed}')
PY

# P15: both indexes, historical companions, and registered worktrees.
python3 - "$REPO" "$WORK/p15" <<'PY'
from pathlib import Path
import hashlib, io, json, os, stat, subprocess, sys, tarfile
REPO=Path(sys.argv[1])
W=Path(sys.argv[2]); W.mkdir()
APP=REPO
STUBS=W/'stubs'; STUBS.mkdir()
for name in ('claude','codex','gh','curl','wget','ssh'):
    p=STUBS/name
    p.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >>"$T5_CALL_LOG"\nexit 99\n')
    p.chmod(0o755)
ENV={**{k:v for k,v in os.environ.items() if not k.startswith(('LOOMY_', 'AI_', 'DELEGATE_', 'GIT_')) and k not in ('BASH_ENV','PERL5OPT','PERL5LIB')},'PATH':str(STUBS)+':/usr/bin:/bin:/usr/sbin:/sbin',
 'T5_CALL_LOG':str(W/'forbidden-calls.log'),'GIT_CONFIG_GLOBAL':'/dev/null',
 'GIT_CONFIG_NOSYSTEM':'1','GIT_ALLOW_PROTOCOL':'file','GIT_TERMINAL_PROMPT':'0',
 'GIT_AUTHOR_NAME':'T5 Fixture','GIT_AUTHOR_EMAIL':'fixture@example.invalid',
 'GIT_COMMITTER_NAME':'T5 Fixture','GIT_COMMITTER_EMAIL':'fixture@example.invalid',
 'HOME':str(W/'home'),'TMPDIR':str(W),'XDG_CONFIG_HOME':str(W/'config'),'XDG_CACHE_HOME':str(W/'cache'),
 'LOOMY_LANG':'en','LOOMY_UI_LANG':'en','NO_COLOR':'1','LOOMY_NO_REPAIR':'1'}
TRACE=W/'commands.jsonl'; CHECKS=[]

def command(args,cwd=None,allow_failure=False,env=None,input_data=None):
    args=[str(x) for x in args]
    r=subprocess.run(args,cwd=cwd,env=env or ENV,capture_output=True,timeout=25,input=input_data)
    with TRACE.open('a') as out:
        out.write(json.dumps({'argv':args,'cwd':str(cwd or Path.cwd()),'exit':r.returncode,
          'stdout':r.stdout.decode(errors='backslashreplace'),'stderr':r.stderr.decode(errors='backslashreplace')})+'\n')
    if r.returncode and not allow_failure:
        raise RuntimeError(f'{args!r} => {r.returncode}\n{r.stdout!r}\n{r.stderr!r}')
    return r

def check(title,test):
    if not test: raise AssertionError(title)
    CHECKS.append(title); print('PASS '+title,flush=True)

def git(root,*args,**kw): return command(['git','-C',root,*args],**kw)
def companion(root,*args,**kw):
    return command(['git',f'--git-dir={root}/.loomy/ai.git',f'--work-tree={root}',*args],**kw)
def lib(root,script,allow_failure=False,env=None):
    return command(['bash','-c','set -euo pipefail; source "$1/scripts/lib/privacy.sh"; '+script,'_',APP,root],allow_failure=allow_failure,env=env)
def write(root,path,data):
    p=root/path; p.parent.mkdir(parents=True,exist_ok=True); p.write_text(data)
def init(root):
    root.mkdir(); git(root,'init','-q','-b','main')
def names(result): return {p.decode() for p in result.stdout.split(b'\0') if p}
def snapshot(root,paths):
    out={}
    for name in paths:
        p=root/name; s=p.lstat()
        value=os.readlink(p).encode() if stat.S_ISLNK(s.st_mode) else p.read_bytes()
        out[name]=(s.st_mode,s.st_mtime_ns,s.st_size,hashlib.sha256(value).hexdigest())
    return out

RUNTIME=[
 '.loomy/logs/events.jsonl','.loomy/logs/archive/old.jsonl',
 '.loomy/logs/display-context-v1.jsonl','.loomy/logs/display-context-full',
 '.loomy/logs/content-policy.conf','.loomy/logs/display-context.lock/owner',
 '.loomy/logs/content-policy.lock/owner','.loomy/project-id',
 '.loomy/memory/delegations/legacy.md','.loomy/memory/private-results-v1/result.json',
 '.loomy/memory/receipts-v1/result.json','.loomy/tasks/deep/task.md',
 '.loomy/reviews/deep/result.md','.loomy/audits/deep/result.md',
 '.loomy/scratch/logs/deep/raw.jsonl','.loomy/scratch/memory/deep/raw.json',
 '.loomy/scratch/tasks/deep/task.md','.loomy/scratch/reviews/deep/result.md',
 '.loomy/scratch/audits/deep/result.md','.loomy/scratch/task-prompt.txt',
 '.loomy/scratch/prompts/deep/prompt.txt','.loomy/scratch/TASKS.md',
 '.loomy/scratch/audit.md','.loomy/scratch/assessment.md',
 '.loomy/restore-backup-old/logs/raw','.loomy/scratch/restore-backup-old/raw',
 '.loomy/scratch/private-results-v1/result.json','.loomy/scratch/receipts-v1/result.json',
 '.loomy/scratch/display-context-v1.jsonl','.loomy/scratch/display-context-full',
 '.loomy/scratch/content-policy.conf','.loomy/scratch/project-id',
 '.loomy/scratch/inventory.json','.loomy/scratch/inventory-export/deep/raw',
 '.loomy/scratch/tmp/deep/raw','.loomy/scratch/temp/deep/raw',
 '.loomy/scratch/value.tmp','.loomy/scratch/value.tmp.123',
 '.loomy/scratch/tree.tmp/deep/raw','.loomy/scratch/tree.tmp.123/deep/raw',
 '.loomy/scratch/ai.git/objects/raw']
CONTINUITY=['.loomy/memory/STATE.md','.loomy/memory/DEAD-ENDS.md','.loomy/docs/HANDOFF.md']
AUTHORED=['AGENTS.md','.loomy/brief.md','.loomy/docs/AI_WORKFLOW.md',
 '.loomy/docs/tutorial.state','.loomy/docs/notes\nwith tab\t.md',
 '.loomy/custom/allowed.txt','.ai/notes.md','.claude/agents/executor.md','.codex/config.toml',*CONTINUITY]
CANARY='T5_RAW_RUNTIME_CANARY_9f4a01'
def populate(root,mode):
    for name in RUNTIME: write(root,name,CANARY+' '+name+'\n')
    for name in AUTHORED: write(root,name,'authored '+name+'\n')
    write(root,'.loomy/brief.md',f'---\nname: Fixture\nslug: fixture\nai_files: {mode}\n---\n')
    git(root,'add','-f','--',*RUNTIME,*AUTHORED); git(root,'commit','-q','-m','legacy fixture')

def archive_clean(root,companion_repo=False):
    data=(companion(root,'archive','HEAD') if companion_repo else git(root,'archive','HEAD')).stdout
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        return not any(CANARY.encode() in archive.extractfile(m).read() for m in archive if m.isfile())

for mode in ('versioned','local','private'):
    p=W/f'project-{mode}'; init(p); populate(p,mode)
    before=snapshot(p,RUNTIME+CONTINUITY)
    lib(p,'loomy_gitignore_sync "$2"; '+('privacy_add_exclude "$2"; ' if mode!='versioned' else '')+
        'while IFS= read -r p; do git -C "$2" check-ignore --no-index -q -- "$p"; done < <(printf "%s\\n" '+
        ' '.join("'"+v+"'" for v in RUNTIME)+')')
    check(f'{mode}: project ignores all 41 recursive runtime fixtures',True)
    tracked=lib(p,'loomy_history_tracked "$2"').stdout.decode().splitlines()
    # Test fixture runtime paths have no newlines; authored odd path must remain outside this set.
    check(f'{mode}: pretracked runtime detected without matching authored tutorial.state',
          set(RUNTIME)<=set(tracked) and '.loomy/docs/tutorial.state' not in tracked)
    lib(p,'while IFS= read -r spec; do git -C "$2" rm -r --cached --quiet --ignore-unmatch -- "$spec"; done < <(loomy_history_pathspecs)')
    indexed=names(git(p,'ls-files','-z'))
    check(f'{mode}: existing project untrack semantics remove runtime index entries',not set(RUNTIME)&indexed)
    check(f'{mode}: all runtime originals and continuity bytes/modes/mtimes preserved',snapshot(p,RUNTIME+CONTINUITY)==before)
    check(f'{mode}: authored docs remain indexed',set(AUTHORED)-set(CONTINUITY)<=indexed)
    git(p,'add','.gitignore'); git(p,'commit','-q','-m','filter fixture runtime index')
    check(f'{mode}: current project archive contains no raw runtime canary',archive_clean(p))

p=W/'private-sync'; init(p); populate(p,'private'); before=snapshot(p,RUNTIME+CONTINUITY)
origin=W/'origin.git'; git(W,'init','--bare','-q','-b','main',origin)
git(W,'init','--bare','-q','-b','main',p/'.loomy/ai.git')
companion(p,'remote','add','origin',origin)
companion(p,'add','-f','--',*RUNTIME,*AUTHORED)
companion(p,'commit','-q','-m','legacy runtime in companion')
legacy=companion(p,'rev-parse','HEAD').stdout.strip().decode()
historical=W/'historical.git'; command(['git','clone','--bare','-q',p/'.loomy/ai.git',historical])
# Companion exclusions must work without the project's managed ignore block.
command(['bash',APP/'scripts/loomy-privacy.sh','--root',p,'--quiet','sync'])
indexed=names(companion(p,'ls-files','-z'))
check('private sync: pretracked runtime removed without a project gitignore',not set(RUNTIME)&indexed)
check('private sync: all authored documents and three continuity exceptions retained',set(AUTHORED)<=indexed)
check('private sync: runtime and authored continuity originals unchanged',snapshot(p,RUNTIME+CONTINUITY)==before)
check('private sync: historical raw objects retained',CANARY.encode() in companion(p,'show',legacy+':'+RUNTIME[0]).stdout)
check('private sync: current companion archive contains no raw runtime canary',archive_clean(p,True))
first_exclude=(p/'.loomy/ai.git/info/exclude').read_bytes()
lib(p,'privacy_companion_config "$2"; privacy_companion_config "$2"')
check('companion mandatory exclusions idempotent',first_exclude==(p/'.loomy/ai.git/info/exclude').read_bytes())
lib(p,'for p in .loomy/scratch/project-id .loomy/scratch/inventory.json .loomy/memory/receipts-v1/result.json; do ai_git "$2" check-ignore --no-index -q -- "$p"; done')
check('companion independently ignores policy identity, receipt and inventory runtime',True)

restored=W/'restored'; init(restored)
local_runtime=[RUNTIME[0],'.loomy/project-id']
for name in local_runtime: write(restored,name,'LOCAL RUNTIME PRESERVE '+name+'\n')
write(restored,'AGENTS.md','local authored AGENTS\n')
odd='.loomy/docs/notes\nwith tab\t.md'; write(restored,odd,'local authored odd name\n')
local_before=snapshot(restored,local_runtime)
command(['bash',APP/'scripts/loomy-privacy.sh','--root',restored,'restore',historical])
check('restore: preexisting runtime never moved or changed',snapshot(restored,local_runtime)==local_before)
check('restore: no missing historical runtime materialized',all(not (restored/n).exists() for n in set(RUNTIME)-set(local_runtime)))
check('restore: authored continuity restored from historical commit',all((restored/n).read_bytes()==(p/n).read_bytes() for n in CONTINUITY))
backups=list((restored/'.loomy').glob('restore-backup-*'))
check('restore: exactly one authored backup directory created',len(backups)==1)
backup=backups[0]
check('restore: no runtime copied into backup',not any((backup/n).exists() for n in RUNTIME))
check('restore: NUL path handling preserves newline/tab authored filenames',(backup/odd).read_text()=='local authored odd name\n' and (backup/'AGENTS.md').read_text()=='local authored AGENTS\n')
check('restore: runtime filtered out of companion index before checkout',not set(RUNTIME)&names(companion(restored,'ls-files','-z')))
check('restore: legacy raw objects still available in history',CANARY.encode() in companion(restored,'show','HEAD:'+RUNTIME[0]).stdout)
command(['bash',APP/'scripts/loomy-privacy.sh','--root',restored,'--quiet','sync'])
check('restore then sync: filtered deletions committed and runtime remains excluded',not set(RUNTIME)&names(companion(restored,'ls-files','-z')) and archive_clean(restored,True))
check('restore then sync: existing local runtime untouched',snapshot(restored,local_runtime)==local_before)

# Fully shared .loomy: only registered same-project sibling roots can use the owner's index.
owner=W/'owner'; init(owner); write(owner,'app.txt','fixture app\n'); git(owner,'add','app.txt'); git(owner,'commit','-q','-m','owner fixture')
populate(owner,'private')
# Return tracked .loomy to local files so the worktree carries only the app.
git(owner,'rm','-r','--cached','-q','--','.loomy','.ai','.claude','.codex','AGENTS.md'); git(owner,'commit','-q','-m','keep AI files local')
owner_origin=W/'owner-origin.git'; command(['git','init','--bare','-q','-b','main',owner_origin])
command(['git','init','--bare','-q','-b','main',owner/'.loomy/ai.git'])
companion(owner,'remote','add','origin',owner_origin); companion(owner,'add','-f','--',*RUNTIME,*AUTHORED); companion(owner,'commit','-q','-m','owner legacy fixture')
worker=W/'worker'; git(owner,'worktree','add','-q','-b','fixture-worker',worker,'HEAD'); (worker/'.loomy').symlink_to(owner/'.loomy',target_is_directory=True)
owner_before=snapshot(owner,RUNTIME+CONTINUITY)
resolved=lib(worker,'privacy_companion_worktree "$2"').stdout.decode().strip()
check('full shared worktree: resolves registered owner',resolved==str(owner))
command(['bash',APP/'scripts/loomy-privacy.sh','--root',worker,'--quiet','sync'])
indexed=names(companion(owner,'ls-files','-z'))
check('full shared worktree: companion retains authored owner docs and no root symlink',set(AUTHORED)<=indexed and '.loomy' not in indexed)
check('full shared worktree: runtime not staged; target bytes/modes/mtimes and worktree link preserved',not set(RUNTIME)&indexed and snapshot(owner,RUNTIME+CONTINUITY)==owner_before and (worker/'.loomy').is_symlink())

# A copied .git pointer shares metadata but is not a registered worktree.
fake=W/'fake'; fake.mkdir(); (fake/'.git').write_bytes((worker/'.git').read_bytes()); (fake/'.loomy').symlink_to(owner/'.loomy',target_is_directory=True)
config_before=snapshot(owner,['.loomy/ai.git/config','.loomy/ai.git/info/exclude'])
r=lib(fake,'privacy_companion_config "$2"',allow_failure=True)
check('unregistered copied worktree pointer rejected before companion writes',r.returncode!=0 and snapshot(owner,['.loomy/ai.git/config','.loomy/ai.git/info/exclude'])==config_before)
unrelated=W/'unrelated'; init(unrelated); (unrelated/'.loomy').symlink_to(owner/'.loomy',target_is_directory=True)
r=lib(unrelated,'privacy_companion_worktree "$2"',allow_failure=True)
check('unrelated Git repository cannot claim shared owner',r.returncode!=0)

# Versioned .loomy: only logs is linked; runtime symlink itself must also be excluded/untracked.
logs_owner=W/'logs-owner'; init(logs_owner); write(logs_owner,'app.txt','app\n'); write(logs_owner,'.loomy/brief.md','---\nname: Logs\nai_files: private\n---\n'); write(logs_owner,'.loomy/docs/AI_WORKFLOW.md','authored docs\n')
git(logs_owner,'add','.'); git(logs_owner,'commit','-q','-m','versioned AI fixture')
write(logs_owner,'.loomy/logs/events.jsonl',CANARY+' shared logs target\n')
logs_worker=W/'logs-worker'; git(logs_owner,'worktree','add','-q','-b','fixture-logs',logs_worker,'HEAD'); (logs_worker/'.loomy/logs').symlink_to(logs_owner/'.loomy/logs',target_is_directory=True)
write(logs_worker,'.loomy/project-id',CANARY+' worker identity\n')
logs_origin=W/'logs-origin.git'; command(['git','init','--bare','-q','-b','main',logs_origin]); command(['git','init','--bare','-q','-b','main',logs_worker/'.loomy/ai.git'])
companion(logs_worker,'remote','add','origin',logs_origin); companion(logs_worker,'add','-f','--','.loomy/brief.md','.loomy/docs/AI_WORKFLOW.md','.loomy/logs','.loomy/project-id'); companion(logs_worker,'commit','-q','-m','legacy shared logs link')
logs_before=snapshot(logs_owner,['.loomy/logs/events.jsonl']); link_before=snapshot(logs_worker,['.loomy/logs'])
command(['bash',APP/'scripts/loomy-privacy.sh','--root',logs_worker,'--quiet','sync'])
indexed=names(companion(logs_worker,'ls-files','-z'))
check('logs-only worktree: runtime symlink and local identity removed from index','.loomy/logs' not in indexed and '.loomy/project-id' not in indexed)
check('logs-only worktree: target and link unchanged; authored docs retained',snapshot(logs_owner,['.loomy/logs/events.jsonl'])==logs_before and snapshot(logs_worker,['.loomy/logs'])==link_before and '.loomy/docs/AI_WORKFLOW.md' in indexed)

# A concurrently advanced remote must be inspected before rebase materializes any runtime.
incoming=W/'incoming'; command(['git','clone','-q',origin,incoming])
remote_runtime='.loomy/logs/remote-new.jsonl'; write(incoming,remote_runtime,CANARY+' remote-only fixture\n')
git(incoming,'add','-f','--',remote_runtime); git(incoming,'commit','-q','-m','remote runtime advance'); git(incoming,'push','-q','origin','main')
local_head=companion(p,'rev-parse','HEAD').stdout
remote_head=command(['git',f'--git-dir={origin}','rev-parse','HEAD']).stdout
before_race=snapshot(p,RUNTIME+CONTINUITY)
refused=command(['bash',APP/'scripts/loomy-privacy.sh','--root',p,'--quiet','sync'],allow_failure=True)
check('advanced raw remote: sync refuses before rebase with clear explanation',refused.returncode!=0 and b'cannot be rebased safely' in refused.stdout+refused.stderr)
check('advanced raw remote: no runtime materialized or indexed',not (p/remote_runtime).exists() and remote_runtime not in names(companion(p,'ls-files','-z')))
check('advanced raw remote: local originals and HEAD unchanged',snapshot(p,RUNTIME+CONTINUITY)==before_race and companion(p,'rev-parse','HEAD').stdout==local_head)
check('advanced raw remote: remote commit untouched and warning omits raw paths',command(['git',f'--git-dir={origin}','rev-parse','HEAD']).stdout==remote_head and remote_runtime.encode() not in refused.stdout+refused.stderr)
lib(p,'privacy_companion_ref_safe "$2" HEAD')
unknown=lib(p,'privacy_companion_ref_safe "$2" missing-reference',allow_failure=True)
check('ref guard: clean continuity accepted; unreadable tree fails closed without filenames',unknown.returncode!=0 and not unknown.stdout and not unknown.stderr)

# Concurrent authored-only edits must still rebase and preserve both sides.
safe=W/'safe-sync'; init(safe)
for name in ['.loomy/brief.md',*CONTINUITY]: write(safe,name,'authored clean '+name+'\n')
write(safe,'.loomy/brief.md','---\nname: Safe\nai_files: private\n---\n')
safe_origin=W/'safe-origin.git'; command(['git','init','--bare','-q','-b','main',safe_origin]); command(['git','init','--bare','-q','-b','main',safe/'.loomy/ai.git'])
companion(safe,'remote','add','origin',safe_origin); companion(safe,'add','-f','--','.loomy/brief.md',*CONTINUITY); companion(safe,'commit','-q','-m','clean authored baseline'); companion(safe,'push','-q','-u','origin','main')
safe_incoming=W/'safe-incoming'; command(['git','clone','-q',safe_origin,safe_incoming]); write(safe_incoming,'.loomy/docs/remote.md','remote authored\n'); git(safe_incoming,'add','-f','--','.loomy/docs/remote.md'); git(safe_incoming,'commit','-q','-m','remote authored advance'); git(safe_incoming,'push','-q','origin','main')
write(safe,'.loomy/docs/local.md','local authored\n'); command(['bash',APP/'scripts/loomy-privacy.sh','--root',safe,'--quiet','sync'])
check('authored-only divergent remote: rebase succeeds and retains both sides',(safe/'.loomy/docs/remote.md').read_text()=='remote authored\n' and (safe/'.loomy/docs/local.md').read_text()=='local authored\n')
check('authored-only divergent remote: three continuity exceptions retained',set(CONTINUITY)<=names(companion(safe,'ls-files','-z')))

# Historical runtime directory symlinks must not be restored, nor may a historical .loomy link replace the live root.
links_legacy=W/'links-legacy.git'; command(['git','clone','--bare','-q',logs_worker/'.loomy/ai.git',links_legacy])
# The logs companion's previous generation contains its formerly tracked logs symlink.
legacy_ref=companion(logs_worker,'rev-parse','HEAD^').stdout.decode().strip(); command(['git',f'--git-dir={links_legacy}','update-ref','refs/heads/main',legacy_ref])
links_restore=W/'links-restored'; init(links_restore); command(['bash',APP/'scripts/loomy-privacy.sh','--root',links_restore,'restore',links_legacy])
check('restore historical logs symlink: excluded before materialization',not (links_restore/'.loomy/logs').is_symlink() and not (links_restore/'.loomy/logs').exists())
root_link=W/'root-link.git'; command(['git','init','--bare','-q','-b','main',root_link])
root_link_index=W/'root-link-index'; root_env={**ENV,'GIT_INDEX_FILE':str(root_link_index)}
# Use an input file with synthetic bytes; no live or provider data is inspected.
root_target=W/'root-link-target.txt'; root_target.write_text(str(owner/'.loomy'))
blob=command(['git',f'--git-dir={root_link}','hash-object','-w',root_target],env=root_env).stdout.decode().strip()
command(['git',f'--git-dir={root_link}','update-index','--add','--cacheinfo','120000',blob,'.loomy'],env=root_env)
tree=command(['git',f'--git-dir={root_link}','write-tree'],env=root_env).stdout.decode().strip()
commit=command(['git',f'--git-dir={root_link}','commit-tree',tree,'-m','historical worktree link'],env=root_env).stdout.decode().strip(); command(['git',f'--git-dir={root_link}','update-ref','refs/heads/main',commit])
root_restore=W/'root-link-restored'; init(root_restore); command(['bash',APP/'scripts/loomy-privacy.sh','--root',root_restore,'restore',root_link])
check('restore historical .loomy symlink: live root remains directory and companion is usable',not (root_restore/'.loomy').is_symlink() and (root_restore/'.loomy/ai.git').is_dir() and '.loomy' not in names(companion(root_restore,'ls-files','-z')))

companion(safe,'fetch','-q',root_link,'main:refs/remotes/fixture/root-link')
bad=lib(safe,'privacy_companion_ref_safe "$2" refs/remotes/fixture/root-link',allow_failure=True)
check('ref guard: whole .loomy symlink refused without paths',bad.returncode!=0 and not bad.stdout and not bad.stderr)
lib(safe,'privacy_companion_ref_safe "$2" HEAD')
check('ref guard: ordinary authored .loomy descendants accepted',True)
base=companion(safe,'rev-parse','HEAD').stdout.decode().strip()
regular=companion(safe,'rev-parse',base+':'+CONTINUITY[0]).stdout.decode().strip()
target_blob=companion(safe,'hash-object','-w',root_target).stdout.decode().strip()
def guard_ref(label,mode,oid):
    alternate={**ENV,'GIT_INDEX_FILE':str(W/(label+'-index'))}
    companion(safe,'read-tree',base,env=alternate)
    companion(safe,'update-index','--add','--cacheinfo',mode,oid,CONTINUITY[0],env=alternate)
    tree=companion(safe,'write-tree',env=alternate).stdout.decode().strip()
    oid=companion(safe,'commit-tree',tree,'-p',base,'-m',label,env=alternate).stdout.decode().strip()
    ref='refs/remotes/fixture/'+label; companion(safe,'update-ref',ref,oid)
    return lib(safe,'privacy_companion_ref_safe "$2" '+ref,allow_failure=True)
for label,mode,oid in (('continuity-link','120000',target_blob),('continuity-gitlink','160000',base)):
    bad=guard_ref(label,mode,oid)
    check(f'ref guard: {label} refused without paths',bad.returncode!=0 and not bad.stdout and not bad.stderr)
check('ref guard: regular executable continuity accepted',guard_ref('continuity-executable','100755',regular).returncode==0)
companion(safe,'update-index','--add','--cacheinfo','120000',target_blob,CONTINUITY[0])
bad=lib(safe,'privacy_companion_ref_safe "$2" HEAD',allow_failure=True)
check('ref guard: index continuity symlink refused',bad.returncode!=0 and not bad.stdout and not bad.stderr)
companion(safe,'read-tree',base)
conflict=f'0 {"0"*40}\t{CONTINUITY[0]}\n'+''.join(f'100644 {regular} {stage}\t{CONTINUITY[0]}\n' for stage in (1,2,3))
companion(safe,'update-index','--index-info',input_data=conflict.encode())
bad=lib(safe,'privacy_companion_ref_safe "$2" HEAD',allow_failure=True)
check('ref guard: unresolved continuity index stages refused',bad.returncode!=0 and not bad.stdout and not bad.stderr)
companion(safe,'read-tree',base)
companion(safe,'push','-q','origin','refs/remotes/fixture/root-link:refs/heads/main','--force')
authors_before=snapshot(safe,['.loomy/brief.md',*CONTINUITY]); head_before=companion(safe,'rev-parse','HEAD').stdout
remote_before=command(['git',f'--git-dir={safe_origin}','rev-parse','HEAD']).stdout
bad=command(['bash',APP/'scripts/loomy-privacy.sh','--root',safe,'--quiet','sync'],allow_failure=True)
check('sync: remote root link rejected before rebase',bad.returncode!=0 and b'cannot be rebased safely' in bad.stdout+bad.stderr)
check('sync: root-link refusal keeps authors, local HEAD, remote and live root',snapshot(safe,['.loomy/brief.md',*CONTINUITY])==authors_before and companion(safe,'rev-parse','HEAD').stdout==head_before and command(['git',f'--git-dir={safe_origin}','rev-parse','HEAD']).stdout==remote_before and not (safe/'.loomy').is_symlink())

check('no provider CLI, gh, HTTP client or SSH executed',not (W/'forbidden-calls.log').exists())
(W/'results.json').write_text(json.dumps({'checks':CHECKS,'count':len(CHECKS),'fixture_root':str(W)},indent=2)+'\n')
print(f'RESULT {len(CHECKS)} passed; fixture {W}',flush=True)

PY

# P13: real PTY cancellation and interruption, with owned-process cleanup.
python3 - "$REPO" "$WORK" <<'PY'
#!/usr/bin/env python3
"""Hermetic P13 PTY checks. Usage: python3 feedback-pty-test.py REPO WORK.

All generated files live in a unique directory under the existing WORK directory.
Only Python stdlib is needed; the tested shell script uses the system Bash/Perl.
"""

import errno
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import stat
import sys
import tempfile
import time


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: feedback-pty-test.py REPO WORK")
    repo, work = (Path(arg).resolve(strict=True) for arg in sys.argv[1:])
    script = repo / "scripts/loomy-feedback.sh"
    assert script.is_file() and work.is_dir(), "REPO/WORK must already exist"
    fixture = Path(tempfile.mkdtemp(prefix="feedback-pty-", dir=work)).resolve()
    directories = ("bin", "home", "config", "cache", "data", "state", "tmp",
                   "codex", "claude", "no-app", "project/.loomy/logs")
    for name in directories:
        (fixture / name).mkdir(parents=True, exist_ok=True, mode=0o700)
    project = fixture / "project"
    logs = project / ".loomy/logs"
    scratch = fixture / "tmp"
    calls = fixture / "calls.tsv"
    violations = fixture / "forbidden-calls.tsv"
    guard_log = fixture / "guard.log"
    paused = fixture / "meta-paused"

    def put(path, text, mode=0o600):
        path.write_text(text, encoding="utf-8")
        path.chmod(mode)

    meta = r'''#!/bin/bash
name=${0##*/}
printf '%s\t%s\n' "$name" "$*" >>"$CALL_LOG"
if [[ $# == 1 && $1 == --version ]]; then
  if [[ $name == git && ${META_PAUSE:-0} == 1 ]]; then
    printf 'paused\n' >"$META_PAUSED_FILE"
    sleep 2
  fi
  case $name in
    git) echo 'git version 2.50.1' ;;
    claude) echo '2.1.300 (Claude Code)' ;;
    codex) echo 'codex-cli 0.162.0' ;;
    gh) echo 'gh version 2.80.0 (2026-01-01)' ;;
  esac
  exit 0
fi
# This is a local stub, never the real GitHub authentication command.
if [[ $name == gh && $# == 2 && $1 == auth && $2 == status ]]; then exit 0; fi
printf '%s\t%s\n' "$name" "$*" >>"$FORBIDDEN_LOG"
exit 97
'''
    for name in ("git", "claude", "codex", "gh"):
        put(fixture / "bin" / name, meta, 0o700)
    blocked = r'''#!/bin/bash
printf '%s\t%s\n' "${0##*/}" "$*" >>"$FORBIDDEN_LOG"
exit 97
'''
    # These binaries must never be invoked, even for process/session inspection.
    for name in ("curl", "wget", "ssh", "open", "osascript", "pbcopy", "pbpaste",
                 "pgrep", "tmux"):
        put(fixture / "bin" / name, blocked, 0o700)

    excluded = ("LOOMY_", "AI_", "DELEGATE_", "CLAUDE_", "CODEX_", "XDG_", "GIT_", "TMUX")
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(excluded)
           and key not in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "PERL5OPT", "PERL5LIB")}
    env.update(
        PATH=f"{fixture}/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        HOME=str(fixture / "home"), XDG_CONFIG_HOME=str(fixture / "config"),
        XDG_CACHE_HOME=str(fixture / "cache"), XDG_DATA_HOME=str(fixture / "data"),
        XDG_STATE_HOME=str(fixture / "state"), TMPDIR=str(scratch),
        CODEX_HOME=str(fixture / "codex"), CLAUDE_CONFIG_DIR=str(fixture / "claude"),
        LOOMY_CODEX_BIN=str(fixture / "bin/codex"), LOOMY_CODEX_APPS=str(fixture / "no-app"),
        LOOMY_TEST_GUARD="1", LOOMY_TEST_STUBS=str(fixture / "bin"),
        LOOMY_TEST_GUARD_LOG=str(guard_log), LOOMY_UI_LANG="en", LOOMY_LANG="en",
        LOOMY_NO_AUTOUPDATE="1", LOOMY_CATALOG_CHECK="0", LOOMY_NO_CLEAR="1",
        NO_COLOR="1", TERM="xterm-256color", TERM_PROGRAM="iTerm.app",
        CALL_LOG=str(calls), FORBIDDEN_LOG=str(violations), META_PAUSED_FILE=str(paused),
    )
    put(project / ".loomy/brief.md", "---\nname: PRIVATE_BRIEF_CANARY\ntype: web\n"
        "stage: mvp\nai_mode: SOLO\nai_lead: codex\nbudget: equilibre\n"
        "ai_files: local\n---\nPRIVATE_BRIEF_CANARY\n")
    put(project / ".loomy/state", "phase=build\nPRIVATE_STATE_CANARY\n")
    put(project / ".loomy/VERSION", "0.17.6\n")
    events = [dict(type="delegation", ts="2026-10-27T12:00:00Z", id=f"pty-{n:02}",
                   role="developer", family="codex", model="gpt-6-luna", status="ok",
                   task="PRIVATE_LOG_CANARY", unknown={"text": "PRIVATE_LOG_CANARY"})
              for n in range(20)]
    put(logs / "events.jsonl", "".join(json.dumps(event) + "\n" for event in events))

    def manifest():
        return {str(path.relative_to(project)): (
            path.stat().st_mode, path.stat().st_ino, path.stat().st_mtime_ns,
            hashlib.sha256(path.read_bytes()).hexdigest())
            for path in project.rglob("*") if path.is_file()}

    initial = manifest()
    allowed_calls = {"git\t--version", "claude\t--version", "codex\t--version",
                     "gh\t--version", "gh\tauth status"}

    def assert_boundary():
        assert not violations.exists() or not violations.stat().st_size, "forbidden CLI invocation"
        assert not guard_log.exists() or not guard_log.stat().st_size, "provider guard violation"
        assert not calls.exists() or set(calls.read_text().splitlines()) <= allowed_calls
        assert manifest() == initial, "feedback mutated the project fixture"

    def sample_staging():
        observed_dir = observed_body = False
        entries = list(scratch.iterdir())
        assert len(entries) <= 1, "feedback created more than one staging directory"
        for directory in entries:
            try:
                info = directory.lstat()
                assert stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
                observed_dir = True
                children = list(directory.iterdir())
                assert len(children) <= 1 and all(path.name == "issue.md" for path in children)
                for body in children:
                    mode = body.lstat().st_mode
                    assert stat.S_ISREG(mode) and stat.S_IMODE(mode) == 0o600
                    text = body.read_text()
                    assert "PRIVATE_" not in text and str(project) not in text
                    observed_body = True
            except FileNotFoundError:
                # Normal cleanup may race this read-only sampler.
                continue
        return observed_dir, observed_body

    def reap_until(pid, deadline):
        while time.monotonic() < deadline:
            found, status = os.waitpid(pid, os.WNOHANG)
            if found:
                return status
            time.sleep(0.02)
        raise AssertionError("PTY child did not reap within its cleanup timeout")

    def scenario(label, message=True, interrupt=None, alt=False, staging=False):
        assert not list(scratch.iterdir()), "previous scenario left temporary files"
        child_env = dict(env)
        if alt:
            child_env.pop("LOOMY_NO_CLEAR", None)
        if staging:
            child_env["META_PAUSE"] = "1"
        pid, fd = pty.fork()
        if pid == 0:
            try:
                os.chdir(fixture)
                args = ["/bin/bash", str(script), "--root", str(project)]
                if message:
                    args.append("explicit PTY feedback message")
                os.execve("/bin/bash", args, child_env)
            except BaseException:
                os._exit(127)
        captured = bytearray()
        observed_dir = observed_body = acted = reaped = False
        prompt_at = None
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                ready, _, _ = select.select([fd], [], [], 0.05)
                if ready:
                    try:
                        captured.extend(os.read(fd, 65536))
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                    # Diagnostic capture is bounded; no raw terminal spool file.
                    del captured[:-262144]
                saw_dir, saw_body = sample_staging()
                observed_dir |= saw_dir
                observed_body |= saw_body
                needle = (b"What to do with this feedback?" if message
                          else b"Your feedback, in one or two sentences")
                ready_to_act = (staging and paused.exists() and saw_body) or (
                    not staging and needle in captured)
                if prompt_at is None and ready_to_act:
                    prompt_at = time.monotonic()
                if not acted and prompt_at is not None and time.monotonic() - prompt_at > 0.2:
                    acted = True
                    if interrupt is None:
                        # The managed sandbox can deny stty TIOCGETD. A newline
                        # delivers q even while the PTY stays in canonical mode.
                        os.write(fd, b"q\n")
                    elif interrupt == "parent":
                        os.kill(pid, signal.SIGTERM)
                    else:
                        os.killpg(pid, interrupt)
                found, status = os.waitpid(pid, os.WNOHANG)
                if found:
                    reaped = True
                    break
            else:
                raise AssertionError(f"{label}: 15s timeout; terminal tail={bytes(captured[-2000:])!r}")
            assert acted and observed_dir, f"{label}: expected prompt/staging was not observed"
            assert not message or observed_body, f"{label}: no issue body was observed"
            assert not list(scratch.iterdir()), f"{label}: temporary files survived exit"
            code = os.waitstatus_to_exitcode(status)
            assert code == 0 if interrupt is None else code != 0, (label, code)
            assert_boundary()
            print(f"PASS P13 PTY {label}: 0700/0600 staging, no copied context, cleanup complete", flush=True)
        finally:
            # The PTY child owns its session/process group. Never inspect or
            # signal unrelated processes; terminate any remaining owned children.
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                if not reaped:
                    reap_until(pid, time.monotonic() + 3)
            finally:
                os.close(fd)

    scenario("cancel")
    scenario("SIGTERM during input", message=False, interrupt=signal.SIGTERM)
    scenario("SIGINT during input", message=False, interrupt=signal.SIGINT)
    scenario("parent-only SIGTERM after preview", interrupt="parent")
    scenario("alternate screen cancel", alt=True)
    scenario("alternate screen parent-only SIGTERM", interrupt="parent", alt=True)
    scenario("SIGTERM during body staging", interrupt=signal.SIGTERM, staging=True)
    print("PASS all 7 feedback PTY scenarios", flush=True)


if __name__ == "__main__":
    main()

PY
