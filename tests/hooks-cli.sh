#!/usr/bin/env bash
# Standalone HOOK consumers: isolated configuration, local fixtures, no quota.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-hooks-cli.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
[[ $# == 0 ]] || { printf 'usage: %s\n' "$0" >&2; exit 2; }
# Do not source tests/lib/guard.sh: it scans unrelated processes and tmux.
python3 - "$REPO" "$WORK" <<'PY'
import atexit
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import time

repo, work = map(Path, sys.argv[1:])
universe = work / 'universe'
universe.mkdir(mode=0o700)
fixtures = work / 'fixtures'
fixtures.mkdir(mode=0o700)
children = {}
passed = 0


def stop_group(process):
    """Only signal groups created by this fixture, never inspect other jobs."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=2)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def cleanup():
    for process in list(children.values()):
        stop_group(process)
    children.clear()


atexit.register(cleanup)
for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(sig, lambda number, frame: sys.exit(128 + number))

env = dict(os.environ)
for key in list(env):
    if key.startswith(('LOOMY_', 'AI_', 'DELEGATE_', 'GIT_', 'STUB_')) or key in (
            'BASH_ENV', 'ENV', 'PERL5OPT', 'PERL5LIB', 'TMUX', 'TMUX_PANE',
            'CLAUDE_PROJECT_DIR', 'CLAUDE_CODE_ENTRYPOINT'):
        del env[key]
isolated = {
    'HOME': 'home', 'CODEX_HOME': 'codex-home', 'CLAUDE_CONFIG_DIR': 'claude-home',
    'XDG_CONFIG_HOME': 'config', 'XDG_STATE_HOME': 'state',
    'XDG_CACHE_HOME': 'cache', 'XDG_DATA_HOME': 'data',
    'XDG_RUNTIME_DIR': 'runtime', 'TMPDIR': 'tmp', 'TMUX_TMPDIR': 'tmux',
}
for key, name in isolated.items():
    directory = universe / name
    directory.mkdir(mode=0o700)
    env[key] = str(directory)
env.update(TMP=env['TMPDIR'], TEMP=env['TMPDIR'], LOOMY_HOME=str(repo),
           LOOMY_LANG='en', LOOMY_UI_LANG='en', LOOMY_NO_AUTOUPDATE='1',
           LOOMY_CATALOG_CHECK='0', NO_COLOR='1', TERM='dumb',
           LOOMY_RELAY_PATHS='', LOOMY_TEST_GUARD='1',
           LOOMY_TEST_STUBS=str(repo / 'tests/stubs'),
           STUB_LOG=str(work / 'provider-calls.log'),
           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(universe / 'gitconfig'),
           GIT_AUTHOR_NAME='fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
           GIT_COMMITTER_NAME='fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')
denied = fixtures / 'denied-tools'
denied.mkdir(mode=0o700)
for name in ('pgrep', 'tmux', 'curl', 'wget', 'ssh', 'npm', 'brew'):
    path = denied / name
    path.write_text('#!/bin/sh\nprintf "%s\\n" "$0" >> "$HOOKS_FORBIDDEN_LOG"\nexit 97\n')
    path.chmod(0o700)
env['HOOKS_FORBIDDEN_LOG'] = str(work / 'forbidden-tools.log')
env['PATH'] = f'{denied}:{repo}/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin'


def check(condition, description):
    global passed
    passed += 1
    print(f'{"ok" if condition else "not ok"} {passed} - {description}', flush=True)
    if not condition:
        raise AssertionError(description)


def put(path, body, mode=0o640):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.write_text(body if isinstance(body, str) else json.dumps(body, ensure_ascii=False))
    path.chmod(mode)


def read_json(path):
    return json.loads(path.read_text())


def manifest(root):
    """Fixture-only bytes plus identities/modes/times; do not follow links."""
    result = {}
    def visit(path):
        info = path.lstat()
        value = os.readlink(path) if stat.S_ISLNK(info.st_mode) else None
        if stat.S_ISREG(info.st_mode):
            value = hashlib.sha256(path.read_bytes()).hexdigest()
        result[str(path.relative_to(root))] = (info.st_dev, info.st_ino,
            info.st_mode, info.st_nlink, info.st_uid, info.st_gid, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns, value)
        if stat.S_ISDIR(info.st_mode):
            for child in sorted(path.iterdir()):
                visit(child)
    visit(root)
    return result


def run(*argv, cwd=None, overrides=None, input_data=None, success=True, timeout=20):
    command_env = dict(env)
    command_env.update({k: str(v) for k, v in (overrides or {}).items() if v is not None})
    for key, value in (overrides or {}).items():
        if value is None:
            command_env.pop(key, None)
    started = time.monotonic()
    process = subprocess.Popen([str(a) for a in argv], cwd=cwd or universe,
        env=command_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True, start_new_session=True)
    children[process.pid] = process
    try:
        out, err = process.communicate(input_data, timeout=timeout)
    finally:
        stop_group(process)
        children.pop(process.pid, None)
    result = subprocess.CompletedProcess(argv, process.returncode, out, err)
    result.elapsed = time.monotonic() - started
    if success and result.returncode:
        raise AssertionError(f'{argv!r}: exit {result.returncode}\n{out[-2000:]}\n{err[-2000:]}')
    return result


def cli(root, *args, **kwargs):
    return run(repo / 'bin/loomy', 'hooks', *args, '--root', root, **kwargs)


def settings(root, provider):
    return root / ('.claude/settings.json' if provider == 'claude' else '.codex/hooks.json')


specs = {
    'claude': [('SessionStart', 'start', 20), ('SessionEnd', 'end', 3),
        ('Stop', 'stop', 10), ('SubagentStop', 'subagent', 10),
        ('UserPromptSubmit', 'prompt', 5), ('PreToolUse', 'agent-start', 5),
        ('PostToolUse', 'agent-return', 5), ('PostToolUseFailure', 'agent-failure', 5)],
    'codex': [('SessionStart', 'start', 20), ('SessionEnd', 'end', 3)],
}
status_command = '''sh -c 'd=${CLAUDE_PROJECT_DIR:-$PWD}; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-statusline.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-statusline.sh" ] && exec bash "$d/.loomy/scripts/loomy-statusline.sh"' '''.rstrip()


def shell_command(provider, mode):
    if provider == 'claude':
        return 'bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/loomy-context.sh" --hook ' + mode
    return '''sh -c 'd=$PWD; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-context.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-context.sh" ] && exec bash "$d/.loomy/scripts/loomy-context.sh" --hook MODE --tool codex' '''.rstrip().replace('MODE', mode)


def shell_data(provider):
    data = {'hooks': {}}
    for event, mode, deadline in specs[provider]:
        group = {'hooks': [{'type': 'command', 'command': shell_command(provider, mode),
                            'timeout': deadline}]}
        if event in ('PreToolUse', 'PostToolUse', 'PostToolUseFailure'):
            group['matcher'] = 'Agent|Task'
        data['hooks'][event] = [group]
    if provider == 'claude':
        data['statusLine'] = {'type': 'command', 'padding': 0, 'command': status_command}
    return data


def project(name, managed=True, mode='HYBRID', lead='codex'):
    root = universe / name
    root.mkdir(mode=0o700)
    if managed:
        put(root / '.loomy/brief.md', '---\nname: HOOK fixture\ntype: web\nstage: mvp\n'
            f'ai_mode: {mode}\nai_lead: {lead}\nbudget: equilibre\nai_files: local\n---\n')
        put(root / '.loomy/VERSION', '0.0.0\n')
        put(root / '.loomy/state', 'phase=build\nupdated=2000-01-01 00:00\n')
    return root


def seed(root, provider, data):
    put(settings(root, provider), data)


def inspect(root, provider):
    result = run('perl', repo / 'scripts/lib/hooks.pl', 'inspect', root, provider)
    return json.loads(result.stdout)


def assert_catalog(root, description):
    for provider in specs:
        data = read_json(settings(root, provider))
        for event, mode, deadline in specs[provider]:
            groups = data['hooks'][event]
            owned = [(group, hook) for group in groups for hook in group['hooks']
                     if hook.get('type') == 'command' and hook.get('command') == shell_command(provider, mode)]
            check(len(owned) == 1, f'{description}: {provider}/{event} has one exact shell binding')
        check(inspect(root, provider)['facts']['ready'], f'{description}: {provider} is ready')


repair_script = '''set -euo pipefail
source "$1/scripts/lib/ui.sh"
source "$1/scripts/lib/models.sh"
source "$1/scripts/lib/project.sh"
loomy_project_repair "$2"
printf '%s\\n' "${LP_DONE[*]-}"
'''


def project_repair(root):
    return run('bash', '-c', repair_script, '_', repo, root)


def install(root, update=False, overrides=None):
    return run('bash', repo / 'scripts/loomy-install-project.sh', root,
               '--no-wizard', '--no-branch', *(['--update'] if update else []), overrides=overrides)


# Status/rollback use an outdated project with migration, memory and policy canaries.
scoped = project('scoped project 日本語')
(scoped / 'src/nested').mkdir(parents=True)
put(scoped / '.loomy/logs/events.jsonl', '{"type":"fixture","private":"PRIVATE_EVENT"}\n')
put(scoped / '.loomy/logs/checkpoint-v2', 'PRIVATE_CHECKPOINT')
put(scoped / '.loomy/logs/content-policy.conf', 'version=1\njournal=off\nlabels=off\nresults=off\n')
put(scoped / '.loomy/memory/STATE.md', 'PRIVATE_MEMORY\n')
put(scoped / 'AGENTS.md', '# Rules\nUse .loomy/scripts/ai-route.sh\n')
put(scoped / 'START.md', 'PRIVATE_PENDING_SETUP\n')
put(scoped / '.gitignore', 'node_modules/\n')
before = manifest(universe)
log_before = Path(env['STUB_LOG']).read_text() if Path(env['STUB_LOG']).exists() else ''
no_upkeep_bypass = {'LOOMY_NO_AUTOUPDATE': None, 'LOOMY_CATALOG_CHECK': None}
result = run(repo / 'bin/loomy', 'hooks', 'status', cwd=scoped / 'src/nested', overrides=no_upkeep_bypass)
check('Claude Code hooks' in result.stdout and 'Codex hooks' in result.stdout,
      'status discovers the spaced non-ASCII root from a nested cwd without project env')
for provider in specs:
    for event, mode, deadline in specs[provider]:
        check(re.search(r'\b' + event + r':\s*missing\b', result.stdout) is not None,
              f'status names missing {provider}/{event}')
claude_rows, codex_rows = result.stdout.split('Codex hooks', 1)
for provider, rows in (('claude', claude_rows), ('codex', codex_rows)):
    actual = re.findall(r'^\s+([A-Za-z]+):', rows, flags=re.MULTILINE)
    expected = [spec[0] for spec in specs[provider]] + (['statusLine'] if provider == 'claude' else [])
    check(actual == expected, f'status reports exactly the {provider} catalog, in order')
check('statusLine:' in result.stdout, 'status separately reports the Claude statusLine')
check(before == manifest(universe), 'status leaves the entire isolated universe manifest unchanged')
check(not Path(env['STUB_LOG']).exists() or Path(env['STUB_LOG']).read_text() == log_before,
      'status invokes no provider metadata or quota call')
before = manifest(universe)
for args in (('repair', '--native'), ('repair', '--shell', '--native')):
    refused = cli(scoped, *args, success=False)
    check(refused.returncode == 2 and re.search(r'not available|unavailable', refused.stdout + refused.stderr),
          'native activation is explicitly refused before repair')
check(before == manifest(universe), 'native refusal creates no settings or upkeep state')
before = manifest(universe)
result = cli(scoped, 'repair', '--shell', overrides=no_upkeep_bypass)
after = manifest(universe)
allowed = {'.', 'scoped project 日本語', 'scoped project 日本語/.claude',
           'scoped project 日本語/.claude/settings.json', 'scoped project 日本語/.codex',
           'scoped project 日本語/.codex/hooks.json'}
changed = {name for name in set(before) | set(after) if before.get(name) != after.get(name)}
check(changed <= allowed, 'repair --shell changes only registration files and their direct parents')
check('PRIVATE_' not in result.stdout + result.stderr and 'grant' not in (result.stdout + result.stderr).lower(),
      'scoped repair does not expose content or enter a grant questionnaire')
check(not Path(env['STUB_LOG']).exists(), 'scoped repair invokes no provider or upkeep probe')
assert_catalog(scoped, 'scoped repair')
before = manifest(universe)
cli(scoped, 'repair', '--shell')
check(before == manifest(universe), 'repeat shell repair preserves bytes, inode, mode and timestamps everywhere')

# Type/event/near-match commands stay custom; differing owned group semantics are ambiguous.
custom = project('custom-and-ambiguous')
data = shell_data('claude')
data['permissions'] = {'allow': ['Bash(ls:*)']}
data['statusLine'] = None
data['hooks']['SessionStart'][0]['hooks'][0]['type'] = 'prompt'
data['hooks']['SessionEnd'][0]['hooks'][0]['command'] += ' '
data['hooks']['Stop'][0]['hooks'][0]['command'] = shell_command('claude', 'end')
duplicate = copy.deepcopy(data['hooks']['PreToolUse'][0])
duplicate['matcher'] = 'Read'
data['hooks']['PreToolUse'].append(duplicate)
seed(custom, 'claude', data)
seed(custom, 'codex', shell_data('codex'))
before = manifest(universe)
result = cli(custom, 'status')
for event in ('SessionStart', 'SessionEnd', 'Stop'):
    check(re.search(event + r':\s*custom\b', result.stdout) is not None,
          f'status treats wrong type/event/near-match {event} as custom')
check(re.search(r'PreToolUse:\s*ambiguous\b', result.stdout) is not None,
      'status names ambiguous owned bindings with differing matchers')
check('Bash(ls:*)' not in result.stdout and '--hook' not in result.stdout,
      'status never echoes custom commands or permission data')
check(before == manifest(universe), 'custom/ambiguous status remains a zero-mutation read')
result = cli(custom, 'repair', success=False)
check(result.returncode == 1 and 'ambiguous' in result.stdout,
      'repair reports unresolved ambiguity as incomplete')
repaired = read_json(settings(custom, 'claude'))
check(repaired['statusLine'] is None and repaired['permissions'] == data['permissions'],
      'repair preserves explicit null statusLine and permissions')
check(repaired['hooks']['PreToolUse'] == data['hooks']['PreToolUse'],
      'repair preserves ambiguous matcher/deadline groups for manual review')

# Each provider commits independently, and a retry does not rewrite its successful sibling.
partial = project('partial-provider')
seed(partial, 'claude', '{invalid PRIVATE_INVALID_BYTES')
before_bad = manifest(partial / '.claude')
before = manifest(universe)
invalid_status = cli(partial, 'status', success=False)
check(invalid_status.returncode == 1 and before == manifest(universe),
      'status reports invalid JSON as failure without mutating any isolated directory')
result = cli(partial, 'repair', '--shell', success=False)
check(result.returncode == 1 and '.claude/settings.json' in result.stdout + result.stderr
      and 'loomy hooks' in result.stdout + result.stderr, 'partial repair names the failed provider and retry action')
check(before_bad == manifest(partial / '.claude'), 'invalid provider bytes and identity stay unchanged')
check(inspect(partial, 'codex')['facts']['ready'], 'failed Claude repair still completes Codex registration')
codex_before = manifest(partial / '.codex')
seed(partial, 'claude', {})
cli(partial, 'repair')
check(codex_before == manifest(partial / '.codex'), 'retry preserves the already successful provider identity')
assert_catalog(partial, 'partial retry')

# Consumer refusals must not escape into the former fallback generator or JSON rename.
for consumer in ('installer', 'project'):
    for problem in ('invalid', 'parent-link', 'file-link'):
        root = project(f'{consumer}-{problem}', managed=consumer == 'project')
        outside = universe / f'{consumer}-{problem}-outside'
        outside.mkdir(mode=0o700)
        put(outside / 'settings.json', '{"private":"PRIVATE_TARGET"}')
        if problem == 'invalid':
            seed(root, 'claude', '{bad PRIVATE_INVALID')
            seed(root, 'codex', '{bad PRIVATE_CODEX')
        elif problem == 'parent-link':
            (root / '.claude').symlink_to(outside, target_is_directory=True)
            (root / '.codex').symlink_to(outside, target_is_directory=True)
        else:
            (root / '.claude').mkdir(mode=0o700)
            (root / '.codex').mkdir(mode=0o700)
            settings(root, 'claude').symlink_to(outside / 'settings.json')
            settings(root, 'codex').symlink_to(outside / 'settings.json')
        outside_before = manifest(outside)
        registrations_before = {p: manifest(root / p) for p in ('.claude', '.codex')}
        output = install(root) if consumer == 'installer' else project_repair(root)
        check(outside_before == manifest(outside), f'{consumer}/{problem}: external target stays unchanged')
        check(registrations_before == {p: manifest(root / p) for p in ('.claude', '.codex')},
              f'{consumer}/{problem}: refused registrations stay unchanged without fallback writes')
        check(not (root / '.loomy/claude-hooks.json').exists(),
              f'{consumer}/{problem}: no degraded manual-merge generator file')
        check('loomy hooks' in output.stdout + output.stderr and 'PRIVATE_' not in output.stdout + output.stderr,
              f'{consumer}/{problem}: precise sanitized repair warning is visible')

for consumer in ('installer', 'project'):
    root = project(f'{consumer}-partial', managed=consumer == 'project')
    seed(root, 'claude', '{invalid PARTIAL_CLAUDE')
    bad_before = manifest(root / '.claude')
    install(root) if consumer == 'installer' else project_repair(root)
    check(bad_before == manifest(root / '.claude') and inspect(root, 'codex')['facts']['ready'],
          f'{consumer}: failure in Claude does not stop the independent Codex repair')
    codex_before = manifest(root / '.codex')
    seed(root, 'claude', {})
    install(root, update=True) if consumer == 'installer' else project_repair(root)
    check(codex_before == manifest(root / '.codex') and inspect(root, 'claude')['facts']['ready'],
          f'{consumer}: retry completes Claude without rewriting ready Codex settings')

fresh = project('fresh-installer', managed=False)
put(fresh / '.gitignore', 'node_modules/\n!.loomy/logs/\n')
install(fresh)
assert_catalog(fresh, 'fresh installer')
ignore = (fresh / '.gitignore').read_text()
check(ignore.count('# >>> Loomy: local history and work files, never versioned') == 1
      and '.loomy/project-id' in ignore and '.loomy/**/content-policy.conf' in ignore
      and ignore.startswith('node_modules/\n!.loomy/logs/\n'),
      'installer preserves the user gitignore and installs the complete managed R1 history block')
put(fresh / '.loomy/brief.md', (scoped / '.loomy/brief.md').read_text())
for provider in specs:
    data = read_json(settings(fresh, provider))
    data['hooks'].pop('SessionEnd')
    seed(fresh, provider, data)
project_repair(fresh)
assert_catalog(fresh, 'project repair fills each provider')

# Global custom statusLine capture must use exact ownership, not a filename substring.
global_settings = Path(env['CLAUDE_CONFIG_DIR']) / 'settings.json'
cache = Path(env['XDG_CONFIG_HOME']) / 'loomy/statusline-user'
custom_line = 'printf CUSTOM'
put(global_settings, {'statusLine': {'type': 'command', 'command': custom_line}})
install(fresh, update=True)
check(cache.read_text() == custom_line, 'installer captures an ordinary custom statusLine')
near_match = fixtures / 'near/scripts/loomy-statusline.sh'
near_match.parent.mkdir(parents=True, mode=0o700)
near_match.write_text((repo / 'scripts/loomy-statusline.sh').read_text())
for risky in (f'bash {near_match}', 'printf CUSTOM; # loomy-statusline.sh is user documentation',
              'bash /old/ai-statusline.sh'):
    put(global_settings, {'statusLine': {'type': 'command', 'command': risky}})
    install(fresh, update=True)
    check(cache.read_text() == custom_line, 'a global command naming a Loomy status line is never cached')
    cache.unlink()
    install(fresh, update=True)
    check(not cache.exists(), 'a Loomy-naming global command never populates an absent cache')
    put(cache, custom_line)
for owned_line in (status_command, status_command.replace('loomy-statusline.sh', 'ai-statusline.sh')):
    put(global_settings, {'statusLine': {'type': 'command', 'command': owned_line}})
    install(fresh, update=True)
    check(cache.read_text() == custom_line, 'exact owned global statusLine preserves an existing custom chain')
    put(cache, owned_line)
    install(fresh, update=True)
    check(not cache.exists(), 'cached exact owned current/historical statusLine is pruned to prevent recursion')
    install(fresh, update=True)
    check(not cache.exists(), 'owned global statusLine never populates an absent custom cache')
    put(cache, custom_line)
for source in ('{invalid PRIVATE_GLOBAL', {'statusLine': {'type': 'prompt', 'command': 'echo UNSUPPORTED'}}):
    put(global_settings, source)
    install(fresh, update=True)
    check(cache.read_text() == custom_line, 'invalid or unsupported global settings preserve the cached custom line')
put(global_settings, {'statusLine': None})
install(fresh, update=True)
check(not cache.exists(), 'explicit null global statusLine clears the cached selection')
capture_outside = universe / 'capture-outside'
put(capture_outside / 'statusline-user', 'PRIVATE_OUTSIDE_CACHE')
capture_link = universe / 'capture-link'
capture_link.mkdir(mode=0o700)
(capture_link / 'loomy').symlink_to(capture_outside, target_is_directory=True)
put(global_settings, {'statusLine': None})
before_capture = manifest(capture_outside)
install(fresh, update=True, overrides={'XDG_CONFIG_HOME': capture_link})
check(before_capture == manifest(capture_outside), 'global capture leaves a symlinked config target unchanged')

# The broad script rename must stay away from arbitrary settings JSON.
migration = project('historical-migration')
(migration / '.loomy/scripts').mkdir(mode=0o700)
put(migration / '.loomy/scripts/_loomy.sh', '# fixture relay marker\n')
put(migration / 'CLAUDE.md', '# Rules\nUse .loomy/scripts/ai-route.sh; keep vendor/ai-route.sh.\n')
for provider in specs:
    data = shell_data(provider)
    for groups in data['hooks'].values():
        for group in groups:
            for hook in group['hooks']:
                hook['command'] = hook['command'].replace('loomy-context.sh', 'ai-context.sh')
    if provider == 'claude':
        data['statusLine']['command'] = status_command.replace('loomy-statusline.sh', 'ai-statusline.sh')
        data['notes'] = {'script': '.loomy/scripts/ai-context.sh', 'private': 'PRIVATE_UNKNOWN'}
        data['hooks']['Stop'].append({'hooks': [{'type': 'command',
            'command': 'echo custom .loomy/scripts/ai-context.sh'}]})
    seed(migration, provider, data)
project_repair(migration)
migrated = read_json(settings(migration, 'claude'))
check(migrated['notes']['script'] == '.loomy/scripts/ai-context.sh'
      and migrated['hooks']['Stop'][-1]['hooks'][0]['command'] == 'echo custom .loomy/scripts/ai-context.sh',
      'project migration leaves custom JSON and near-match commands byte-valued unchanged')
check('Use .loomy/scripts/loomy-route.sh; keep vendor/ai-route.sh.' in (migration / 'CLAUDE.md').read_text()
      and (migration / '.loomy/scripts/loomy-context.sh').exists(),
      'project migration still updates managed document references and creates current relays')
assert_catalog(migration, 'exact historical registration migration')

# Doctor checks every typed event, rather than readiness from a command substring.
diagnostics = project('doctor-catalog')
for provider in specs:
    seed(diagnostics, provider, shell_data(provider))
for provider in specs:
    for event, mode, deadline in specs[provider]:
        data = shell_data(provider)
        data['hooks'].pop(event)
        seed(diagnostics, provider, data)
        before = manifest(diagnostics)
        result = run('bash', repo / 'scripts/loomy-doctor.sh', '--root', diagnostics, success=False)
        text = result.stdout + result.stderr
        check(f'{event} (missing)' in text and 'loomy hooks repair' in text,
              f'doctor names missing {provider}/{event} and its scoped repair')
        check(before == manifest(diagnostics), f'doctor/{provider}/{event} does not repair while inspecting')
        seed(diagnostics, provider, shell_data(provider))
data = shell_data('claude')
data['hooks']['SessionStart'][0]['hooks'][0]['type'] = 'prompt'
duplicate = copy.deepcopy(data['hooks']['PostToolUse'][0])
duplicate['hooks'][0]['timeout'] = 99
data['hooks']['PostToolUse'].append(duplicate)
seed(diagnostics, 'claude', data)
result = run('bash', repo / 'scripts/loomy-doctor.sh', '--root', diagnostics, success=False)
text = result.stdout + result.stderr
check('SessionStart (custom)' in text and 'PostToolUse (ambiguous)' in text,
      'doctor reports wrong-type custom and conflicting-deadline events exactly')
check('--hook' not in text and 'PRIVATE_' not in text,
      'doctor never prints arbitrary hook command text')
put(diagnostics / '.loomy/logs/content-policy.conf', 'PRIVATE_INVALID_POLICY\n', mode=0o600)
run('perl', repo / 'scripts/lib/policy-record.pl', 'record', diagnostics)   # a file Loomy wrote that went invalid: reported as invalid (an unrecorded one is ignored, ADR-0012)
put(diagnostics / '.loomy/logs/display-context-full', 'full\n', mode=0o600)
before = manifest(diagnostics)
result = run('bash', repo / 'scripts/loomy-doctor.sh', '--root', diagnostics, success=False)
text = result.stdout + result.stderr
check('Invalid content policy' in text and 'Label store full' in text
      and str(diagnostics / '.loomy/logs/content-policy.conf') in text,
      'typed hook diagnostics retain R1 policy, path and persistent label-store health')
check('PRIVATE_' not in result.stdout + result.stderr and before == manifest(diagnostics),
      'doctor R1 policy/label inspection stays sanitized and noncreating')
(diagnostics / '.loomy').chmod(0o777)
before = manifest(diagnostics)
result = run('bash', repo / 'scripts/loomy-doctor.sh', '--root', diagnostics, success=False)
text = result.stdout + result.stderr
check(str(diagnostics / '.loomy') in text and 'chmod g-w,o-w' in text
      and 'Invalid content policy' not in text,
      'doctor still names an unsafe R1 directory and its permission remedy')
check(before == manifest(diagnostics), 'doctor never normalizes unsafe directory modes')
(diagnostics / '.loomy').chmod(0o700)

# Provider scope: a Claude-only project never gets Codex files from any automatic or scoped repair.
solo = project('claude-only', mode='SOLO', lead='claude')
for action in (('repair',), ('repair', '--shell')):
    cli(solo, *action)
    check(settings(solo, 'claude').exists() and not (solo / '.codex').exists(),
          f'{" ".join(action)} creates Claude settings and never .codex in a Claude-only project')
project_repair(solo)
check(not (solo / '.codex').exists(), 'automatic project repair never creates .codex for a Claude-only project')
check(inspect(solo, 'claude')['facts']['ready'], 'Claude-only project is fully registered')
result = cli(solo, 'repair')
check('not used by this project' in result.stdout and 'Native hook registration' not in result.stdout,
      'repair names the skipped provider and omits the native footer')
result = run('bash', repo / 'scripts/loomy-doctor.sh', '--root', solo, success=False)
check('Codex hooks' not in result.stdout + result.stderr and not (solo / '.codex').exists(),
      'doctor inspects only providers in use')
codex_only = project('claude-only-existing-codex', mode='SOLO', lead='claude')
seed(codex_only, 'codex', shell_data('codex'))
before = manifest(codex_only / '.codex')
project_repair(codex_only)
check(settings(codex_only, 'claude').exists() and inspect(codex_only, 'codex')['facts']['ready']
      and before == manifest(codex_only / '.codex'), 'an existing registration file keeps its provider in scope')

# An ordinary custom statusLine is a supported case: init/update keep it without a warning-like line.
quiet = project('quiet-custom', managed=False)
put(settings(quiet, 'claude'), {'statusLine': {'type': 'command', 'command': 'echo mine'}})
output = install(quiet)
check('custom settings kept' not in output.stdout + output.stderr
      and read_json(settings(quiet, 'claude'))['statusLine']['command'] == 'echo mine',
      'init keeps an ordinary custom statusLine silently')

# Repair refuses outside a Loomy project; status still works there and changes nothing.
plain = project('plain-folder', managed=False)
(plain / '.git').mkdir()
before = manifest(universe)
for action in (('repair',), ('repair', '--shell')):
    result = cli(plain, *action, success=False)
    check(result.returncode == 1 and str(plain) in result.stderr and 'loomy init' in result.stderr
          and before == manifest(universe), f'{" ".join(action)} refuses a folder without .loomy and writes nothing')
result = cli(plain, 'status')
check(result.returncode == 0 and before == manifest(universe), 'status works in any folder with zero mutations')

# Wording: counts per state, footer only in --help, one error for a failed file.
mixed = project('mixed-wording')
data = shell_data('claude')
data['hooks'].pop('PostToolUse')
seed(mixed, 'claude', data)
seed(mixed, 'codex', shell_data('codex'))
result = cli(mixed, 'status')
check(re.search(r'Claude Code hooks \(\.claude/settings\.json\): 8 shell, 1 missing', result.stdout) is not None,
      'status counts each state instead of reporting the worst slot')
check('Native hook registration' not in result.stdout, 'status omits the native footer')
usage = run(repo / 'bin/loomy', 'hooks', 'bogus', success=False)
check(usage.returncode == 2 and 'Native hook registration' not in usage.stdout + usage.stderr,
      'usage errors omit the native footer')
check('Native hook registration' in run(repo / 'bin/loomy', 'hooks', '--help').stdout, '--help keeps the native footer')
broken = project('broken-once')
seed(broken, 'claude', '{invalid PRIVATE_BROKEN')
seed(broken, 'codex', shell_data('codex'))
result = cli(broken, 'status', success=False)
check(result.stdout.count('Invalid hook settings') == 1 and 'unavailable' not in result.stdout,
      'a failed file prints its error once, without per-event rows')

# Doctor: an ambiguous event gets a manual remedy rather than a repair that cannot resolve it.
amb = project('doctor-ambiguous')
data = shell_data('claude')
duplicate = copy.deepcopy(data['hooks']['PostToolUse'][0])
duplicate['hooks'][0]['timeout'] = 99
data['hooks']['PostToolUse'].append(duplicate)
seed(amb, 'claude', data)
seed(amb, 'codex', shell_data('codex'))
result = run('bash', repo / 'scripts/loomy-doctor.sh', '--root', amb, success=False)
text = result.stdout + result.stderr
check('PostToolUse (ambiguous)' in text and 'by hand' in text and 'fix: loomy hooks repair' not in text,
      'doctor tells the user to edit an ambiguous event rather than run repair')

# doctor --fix repairs hooks before reporting: one "project completed" line, no stale gap or fix line.
fixed = project('doctor-fix')
data = shell_data('claude')
data['hooks'].pop('UserPromptSubmit')
seed(fixed, 'claude', data)
seed(fixed, 'codex', shell_data('codex'))
result = run('bash', repo / 'scripts/loomy-doctor.sh', '--root', fixed, '--fix', success=False)
text = result.stdout + result.stderr
check('project completed' in text and 'hooks: .claude/settings.json' in text,
      'doctor --fix reports the hook repair in its project completed output')
check('need attention' not in text and 'fix: loomy hooks repair' not in text,
      'doctor --fix prints no stale hook gap or fix line after a successful repair')
check(inspect(fixed, 'claude')['facts']['ready'], 'doctor --fix leaves the Claude hooks ready')

# Pure descriptor fixtures only: production intentionally supplies no native descriptor.
descriptor = {'executable': '/opt/loomy/0.17.8/bin/loomy', 'version': '0.17.8', 'resource_version': '0.17.8'}
fixture_perl = r'''
use strict; use warnings; use JSON::PP;
my ($helper,$action,$provider)=@ARGV; require $helper;
local $/; my $input=decode_json(<STDIN>);
my ($data,$descriptor)=@{$input}{qw(data descriptor)};
my $r=$action eq 'native'
    ? Loomy::Hooks::fixture_native_transform($provider,$data,$descriptor,[$descriptor])
    : Loomy::Hooks::transform($provider,$data,'shell',[$descriptor]);
print JSON::PP->new->canonical->encode($r);
'''


def fixture_transform(action, provider, data):
    output = run('perl', '-e', fixture_perl, repo / 'scripts/lib/hooks.pl', action, provider,
        input_data=json.dumps({'data': data, 'descriptor': descriptor}))
    return json.loads(output.stdout)['data']


# Relevant automatic project/SessionStart path from 4d18f0c: the helper checks
# shell equality only. Kept literal so source archives need no historical git object.
old_helper = fixtures / 'pre-h-project-repair.pl'
put(old_helper, r'''use strict; use warnings; use JSON::PP;
my ($root)=@ARGV; exit 0 unless -f "$root/.loomy/brief.md";
my $path="$root/.claude/settings.json";
open my $in,'<',$path or die $!; local $/; my $d=decode_json(<$in>); close $in;
for my $spec (['SessionStart','start',20],['SessionEnd','end',3],['Stop','stop',10],
    ['SubagentStop','subagent',10],['UserPromptSubmit','prompt',5],
    ['PreToolUse','agent-start',5],['PostToolUse','agent-return',5],['PostToolUseFailure','agent-failure',5]) {
    my ($event,$mode,$timeout)=@$spec;
    my $cmd=q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/loomy-context.sh" --hook }.$mode;
    my $groups=$d->{hooks}{$event}//=[];
    next if grep {($event !~ /^(?:PreToolUse|PostToolUse|PostToolUseFailure)$/
        || ($_->{matcher}//'') eq 'Agent|Task')
        && grep {($_->{command}//'') eq $cmd} @{$_->{hooks}//[]}} @$groups;
    my $g={hooks=>[{type=>'command',command=>$cmd,timeout=>$timeout}]};
    $g->{matcher}='Agent|Task' if $event =~ /^(?:PreToolUse|PostToolUse|PostToolUseFailure)$/;
    push @$groups,$g;
}
open my $out,'>',$path or die $!; print {$out} encode_json($d); close $out or die $!;
''')
rollback = project('synthetic-pre-H')
data = shell_data('claude')
data['permissions'] = {'allow': ['Bash(ls:*)']}
data['statusLine']['padding'] = 7
native = fixture_transform('native', 'claude', data)
seed(rollback, 'claude', native)
run('perl', old_helper, rollback)
duplicated = read_json(settings(rollback, 'claude'))
check(len(duplicated['hooks']['SessionStart']) == 2,
      'synthetic pre-H automatic repair adds a duplicate shell binding beside fixture-native')
duplicated['user_edit_after_upgrade'] = {'keep': 'PRIVATE_INTERVENING_EDIT'}
duplicated['hooks']['Stop'].append({'hooks': [{'type': 'command', 'command': 'echo custom-after-upgrade'}]})
rolled = fixture_transform('shell', 'claude', duplicated)
check(len(rolled['hooks']['SessionStart']) == 1 and rolled['statusLine']['padding'] == 7
      and rolled['user_edit_after_upgrade'] == duplicated['user_edit_after_upgrade']
      and rolled['hooks']['Stop'][-1] == duplicated['hooks']['Stop'][-1],
      'fixture inverse coalesces only equivalent groups and preserves current user edits')
seed(rollback, 'claude', rolled)
run('perl', old_helper, rollback)
cli(rollback, 'repair', '--shell')
before = manifest(rollback)
cli(rollback, 'repair')
cli(rollback, 'repair', '--shell')
check(before == manifest(rollback), 'shell rollback followed by old repair and re-upgrade is idempotent')
for provider in specs:
    latest = read_json(settings(rollback, provider))
    upgraded = fixture_transform('native', provider, latest)
    downgraded = fixture_transform('shell', provider, upgraded)
    check(latest == downgraded, f'{provider}: fixture upgrade/downgrade uses current JSON without stale backup restore')

# Runtime handlers are unchanged; exercise actual generated commands through relays.
runtime = fresh
(runtime / 'src/深い folder').mkdir(parents=True)
codex_command = read_json(settings(runtime, 'codex'))['hooks']['SessionEnd'][0]['hooks'][0]['command']
result = run('sh', '-c', codex_command, cwd=runtime / 'src/深い folder',
    input_data='{"session_id":"fixture-runtime"}', overrides={'LOOMY_NO_REPAIR': '1'})
check(result.stdout == '' and result.stderr == '', 'nested Codex end hook keeps its silent stdout/stderr contract')
status_command_installed = read_json(settings(runtime, 'claude'))['statusLine']['command']
payload = '{"model":{"display_name":"Fixture Model"},"private":"PRIVATE_STDIN"}'
result = run('sh', '-c', status_command_installed, cwd=runtime / 'src/深い folder', input_data=payload)
check(result.stdout == 'Loomy · Fixture Model\n' and result.stderr == '',
      'nested statusLine without project env retains the existing stdout contract')
put(cache, 'cat')
result = run('sh', '-c', status_command_installed, cwd=runtime / 'src/深い folder', input_data=payload)
check(result.stdout == payload + '\n', 'custom statusLine receives unchanged stdin')
put(cache, 'exec /bin/sleep 5')
result = run('sh', '-c', status_command_installed, cwd=runtime / 'src/深い folder', input_data='{}', timeout=4)
check(result.elapsed < 3.2 and result.stdout == '\n',
      'custom statusLine keeps its two-second execution budget (with scheduler margin)')

def live(needle):
    out = subprocess.run(['/bin/ps', '-axo', 'command'], capture_output=True, text=True).stdout
    # Match by executable name so an unrelated parent command line that merely quotes the text is not counted.
    return [line for line in out.splitlines() if needle in line and line.split()[0].rsplit('/', 1)[-1] in ('sleep', 'bash')]


# A cached command that runs a Loomy status line again (a stale cache or hand edit) is bounded and leaves nothing.
put(cache, f'bash {near_match}')
result = run('sh', '-c', status_command_installed, cwd=runtime / 'src/深い folder', input_data=payload, timeout=8)
check(result.elapsed < 3.2 and result.stdout == 'Loomy · Fixture Model\n' and result.stderr == '',
      'self-referencing cached statusLine finishes in one bounded run')
time.sleep(0.5)
check(not live(str(near_match)), 'self-referencing cached statusLine leaves no process behind')
put(cache, "sh -c 'sleep 33 & sleep 34'")
result = run('sh', '-c', status_command_installed, cwd=runtime / 'src/深い folder', input_data='{}', timeout=6)
time.sleep(0.5)
check(result.elapsed < 3.2 and result.stderr == '' and not live('sleep 33') and not live('sleep 34'),
      'statusLine timeout stops the whole process group of the user command')
cache.unlink()

calls = Path(env['STUB_LOG']).read_text() if Path(env['STUB_LOG']).exists() else ''
check(all(re.fullmatch(r'(?:claude|codex)\t--version|gh\t(?:--version|auth\tstatus)', line)
          for line in calls.splitlines()),
      'no provider inference or quota request occurred anywhere in the suite')
check(not Path(env['HOOKS_FORBIDDEN_LOG']).exists(), 'no pgrep, tmux, network or package-manager command ran')
check(not children, 'every directly spawned child was explicitly reaped')
print(f'1..{passed}', flush=True)
PY
