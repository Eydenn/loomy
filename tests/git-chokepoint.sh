#!/usr/bin/env bash
# Git chokepoint: every git spawn of Loomy goes through loomy_git / loomy_git_user (scripts/lib/models.sh).
#   1. static guard: no raw git spawn in bin/ or scripts/ outside the helpers and the allow-listed Perl spawners;
#   2. hostile repository config (core.fsmonitor, hooks, a promisor remote) never runs a command from loomy status,
#      loomy tree --once or a delegation bridge (fake CLIs, no provider, no network).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "/tmp/loomy-gitw-tests.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
# shellcheck source=lib/content-grant.sh
source "$REPO/tests/lib/content-grant.sh"
for v in $(env | sed -nE 's/^((LOOMY|AI|DELEGATE|STUB)_[A-Z0-9_]*|CLAUDE_PROJECT_DIR|CODEX_HOME)=.*/\1/p'); do case "$v" in LOOMY_TEST_GUARD|LOOMY_TEST_STUBS|LOOMY_TEST_GUARD_LOG|LOOMY_TEST_TOOLS|LOOMY_TEST_CORE|LOOMY_TEST_NEXT_ROOT|LOOMY_TEST_ENTRY_LOG) continue ;; esac; unset "$v"; done
mkdir -p "$WORK/tmp" "$WORK/home" "$WORK/config/loomy" "$WORK/codex/sessions"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" TMPDIR="$WORK/tmp"
export LOOMY_CODEX_BIN="$HERE/stubs/codex" LOOMY_HOME="$REPO" LOOMY_LANG=en NO_COLOR=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1 LOOMY_START_WATCH=0
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
PASS=0; FAIL=0; OUT="$WORK/out"
ok() { PASS=$(( PASS + 1 )); printf '  ✓ %s\n' "$1"; }
ko() { FAIL=$(( FAIL + 1 )); printf '  ✗ %s\n' "$1"; tail -12 "$OUT" 2>/dev/null; }

# ── 1. static guard ──
# Allowed raw git: models.sh (the helpers' definition) and the Perl spawners that harden their own spawn.
ALLOW='scripts/lib/models.sh scripts/lib/runtime-paths.pl scripts/lib/watch-health.pl scripts/lib/tracked-fix.pl'
cd "$REPO" || exit 1
# Reads grep lines on stdin, drops those from allow-listed files.
drop_allowed() { local line f; while IFS= read -r line; do f="${line%%:*}"; if [[ " $ALLOW " != *" $f "* ]]; then printf '%s\n' "$line"; fi; done; }
# A raw spawn is `git` in command position (line start, after $( && || | ; ! then else do { or `command`/`exec`), outside
# comments and quoted user-facing messages (those never start a command word).
raw="$(grep -rnE '(^|\$\(|&&|\|\||[|;!]|\b(then|else|elif|do|if|command|exec|while|until)) *git +(-|[a-z])' bin scripts -I \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '/i18n/|fr\.tsv|/fr/' \
  | drop_allowed)"
printf '%s' "$raw" >"$OUT"
if [[ -z "$raw" ]]; then ok 'no raw git spawn in bin/ and scripts/ outside the helpers and allow-listed spawners'; else ko 'raw git spawn found: use loomy_git / loomy_git_user'; fi
# Perl spawns: exec/system/qx/pipe-open of git outside the allow-list.
# loomy-privacy.sh is NOT allow-listed as a file: only its one hardened inventory exec (no-pager, fsmonitor off, hooks off) passes.
praw="$(grep -rnE "(exec|system|qx|open)[^#]*['\"]git['\"]|qx[{(/]git |\`git " scripts bin -I --include='*.pl' --include='*.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | drop_allowed | grep -vF "scripts/loomy-privacy.sh:" ; grep -nE "(exec|system|qx|open)[^#]*['\"]git['\"]|\`git " scripts/loomy-privacy.sh | grep -vE "^[0-9]+:[[:space:]]*#" | grep -vF "exec('git','--no-pager','-c','core.fsmonitor=false','-c','core.hooksPath=/dev/null','-c','log.showSignature=false'")"
printf '%s' "$praw" >"$OUT"
if [[ -z "$praw" ]]; then ok 'no raw git spawn from Perl or backticks outside the allow-list'; else ko 'raw Perl git spawn found'; fi
# The allow-listed spawners keep their hardening.
for f in scripts/lib/runtime-paths.pl scripts/lib/watch-health.pl scripts/lib/tracked-fix.pl scripts/loomy-privacy.sh; do
  if grep -q 'core.fsmonitor=false' "$f" && grep -q 'core.hooksPath=/dev/null' "$f" && grep -q 'NO_LAZY_FETCH' "$f"; then ok "allow-listed spawner stays hardened: $f"; else : >"$OUT"; ko "allow-listed spawner lost its hardening: $f"; fi
done
# Helper behaviour: arguments, status and exit code pass through unchanged.
cd "$WORK" || exit 1
git init -q -b main plain && printf x >plain/f
r="$(bash -c 'source "$1/scripts/lib/models.sh"; loomy_git -C "$2" status --porcelain; echo "rc=$?"; loomy_git -C "$2" rev-parse --is-inside-work-tree; loomy_git -C /nonexistent-dir status >/dev/null 2>&1; echo "rc=$?"; loomy_git_user -C "$2" rev-parse --show-toplevel' _ "$REPO" "$WORK/plain" 2>&1)"
printf '%s\n' "$r" >"$OUT"
if [[ "$r" == *'?? f'* && "$r" == *true* && "$r" == *'rc=0'* && "$r" == *'rc=128'* ]]; then ok 'helpers keep git stdout and exit codes'; else ko 'helpers changed git behaviour'; fi

# ── 2. hostile repository ──
P="$WORK/project"; MARK="$WORK/marker"; mkdir -p "$P/.loomy/logs"
echo 0.17.10 >"$P/.loomy/VERSION"
git init -q -b main "$P"
printf '#!/bin/sh\necho fsmonitor >>"%s"\nexit 0\n' "$MARK" >"$WORK/evil-fsmonitor"; chmod +x "$WORK/evil-fsmonitor"
printf '#!/bin/sh\necho hook >>"%s"\nexit 0\n' "$MARK" >"$WORK/evil-hook"; chmod +x "$WORK/evil-hook"
printf '#!/bin/sh\necho lazyfetch >>"%s"\nexit 1\n' "$MARK" >"$WORK/evil-upload"; chmod +x "$WORK/evil-upload"
( cd "$P" && printf 'a\n' >tracked.txt && git add tracked.txt && git -c core.hooksPath=/dev/null commit -qm init )
git -C "$P" config core.fsmonitor "$WORK/evil-fsmonitor"
git -C "$P" config core.hooksPath "$WORK/hooks"; mkdir -p "$WORK/hooks"
for h in post-checkout post-commit post-merge post-index-change reference-transaction pre-commit; do cp "$WORK/evil-hook" "$WORK/hooks/$h"; done
git -C "$P" config remote.origin.url "$WORK/nowhere.git"; git -C "$P" config remote.origin.promisor true
git -C "$P" config remote.origin.partialclonefilter blob:none
git -C "$P" config uploadpack.packObjectsHook "$WORK/evil-upload"
git -C "$P" config extensions.partialClone origin
printf 'b\n' >>"$P/tracked.txt"; printf 'new\n' >"$P/untracked.txt"
rm -f "$MARK"
cd "$P" || exit 1
no_marker() { if [[ ! -e "$MARK" ]]; then ok "$1"; else printf 'marker written:\n%s\n' "$(cat "$MARK")" >"$OUT"; ko "$1"; rm -f "$MARK"; fi; }
bash "$REPO/bin/loomy" status >"$OUT" 2>&1; no_marker 'hostile config: loomy status runs nothing'
bash "$REPO/bin/loomy" status --compact >"$OUT" 2>&1; no_marker 'hostile config: loomy status --compact runs nothing'
bash "$REPO/bin/loomy" tree --once >"$OUT" 2>&1; no_marker 'hostile config: loomy tree --once runs nothing'
bash "$REPO/scripts/loomy-context.sh" --root "$P" >"$OUT" 2>&1; no_marker 'hostile config: session context runs nothing'
bash "$REPO/scripts/loomy-review.sh" --working --print >"$OUT" 2>&1; no_marker 'hostile config: review --print runs nothing'
test_content_grant "$REPO" "$P" >/dev/null 2>&1 || true
export STUB_LOG="$WORK/calls"; : >"$STUB_LOG"
bash "$REPO/scripts/loomy-delegate-codex.sh" developer --write "bounded task" >"$OUT" 2>&1; no_marker 'hostile config: Codex write bridge runs nothing'
bash "$REPO/scripts/loomy-delegate-claude.sh" developer --write "bounded task" >"$OUT" 2>&1; no_marker 'hostile config: Claude write bridge runs nothing'
bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer "bounded review" >"$OUT" 2>&1; no_marker 'hostile config: Codex read bridge runs nothing'
if grep -q '^codex' "$STUB_LOG" 2>/dev/null; then ok 'the bridge reached the fake Codex CLI (the path was exercised)'; else printf 'no fake CLI call recorded\n' >"$OUT"; ko 'the bridge never reached the fake CLI'; fi
# Control: plain git on the same repository does trigger the marker, so the test can detect a leak.
git -C "$P" status >/dev/null 2>&1; git -C "$P" -c core.hooksPath="$WORK/hooks" checkout -q main >/dev/null 2>&1
if [[ -e "$MARK" ]]; then ok 'control: raw git on the hostile repository does run the marker'; else printf 'control did not fire\n' >"$OUT"; ko 'control: the hostile repository is not hostile'; fi

# ── 3. clone-shipped privacy companion (.loomy/ai.git carried by a plain clone) ──
cd "$WORK" || exit 1
SRC="$WORK/ship-src"; CL="$WORK/ship-clone"; EXFIL="$WORK/exfil.git"; MARK2="$WORK/marker2"; rm -f "$MARK2"
git init -q -b main "$SRC"; mkdir -p "$SRC/.loomy"
printf -- '---\nname: x\nai_files: private\n---\n' >"$SRC/.loomy/brief.md"; echo 0.17.10 >"$SRC/.loomy/VERSION"
git init -q --bare -b main "$EXFIL"
git init -q --bare -b main "$SRC/.loomy/ai.git"
for h in pre-commit post-index-change post-commit reference-transaction pre-push pre-rebase; do
  printf '#!/bin/sh\necho "hook %s" >>"%s"\nexit 0\n' "$h" "$MARK2" >"$SRC/.loomy/ai.git/hooks/$h"; chmod +x "$SRC/.loomy/ai.git/hooks/$h"
done
printf '#!/bin/sh\necho filter >>"%s"\ncat\n' "$MARK2" >"$WORK/evil-filter"; chmod +x "$WORK/evil-filter"
printf '#!/bin/sh\necho uploadpack >>"%s"\nexit 1\n' "$MARK2" >"$WORK/evil-uploadpack"; chmod +x "$WORK/evil-uploadpack"
printf '#!/bin/sh\necho fsmonitor >>"%s"\nexit 0\n' "$MARK2" >"$WORK/evil-fsm2"; chmod +x "$WORK/evil-fsm2"
C0="$SRC/.loomy/ai.git/config"
git config --file "$C0" core.fsmonitor "$WORK/evil-fsm2"; git config --file "$C0" core.hooksPath "$SRC/.loomy/ai.git/hooks"
git config --file "$C0" filter.evil.clean "$WORK/evil-filter"; git config --file "$C0" filter.evil.process "$WORK/evil-filter"
git config --file "$C0" remote.origin.url "$EXFIL"; git config --file "$C0" remote.origin.uploadpack "$WORK/evil-uploadpack"
git config --file "$C0" uploadpack.packObjectsHook "$WORK/evil-uploadpack"; git config --file "$C0" core.pager "$WORK/evil-fsm2"
git config --file "$C0" alias.status "!$WORK/evil-fsm2"
printf '* filter=evil\n' >"$SRC/.loomy/.gitattributes"; printf 'secret\n' >"$SRC/.loomy/AGENTS-secret.md"
( cd "$SRC" && git add -f .loomy >/dev/null 2>&1 && git -c core.hooksPath=/dev/null commit -qm ship )
git clone -q "$SRC" "$CL" >/dev/null 2>&1
if [[ -x "$CL/.loomy/ai.git/hooks/pre-commit" && -f "$CL/.loomy/ai.git/config" ]]; then ok 'the plain clone ships .loomy/ai.git with executable hooks (the attack surface exists)'; else : >"$OUT"; ko 'the clone did not ship the companion'; fi
no_marker2() { if [[ ! -e "$MARK2" ]]; then ok "$1"; else printf 'marker:\n%s\n' "$(cat "$MARK2")" >"$OUT"; ko "$1"; rm -f "$MARK2"; fi; }
no_push() { if [[ -z "$(git -C "$EXFIL" for-each-ref 2>/dev/null)" ]]; then ok "$1"; else : >"$OUT"; ko "$1"; fi; }
printf 'edit\n' >>"$CL/.loomy/AGENTS-secret.md"
cd "$CL" || exit 1
bash "$REPO/scripts/loomy-context.sh" --root "$CL" --hook end </dev/null >"$OUT" 2>&1; sleep 1.5
no_marker2 'foreign companion: the SessionEnd hook path runs nothing'; no_push 'foreign companion: the SessionEnd hook path pushes nothing'
bash "$REPO/bin/loomy" status >"$OUT" 2>&1; no_marker2 'foreign companion: loomy status runs nothing'
if grep -q 'Private history not verified' "$OUT"; then ok 'foreign companion: loomy status shows the adopt note'; else ko 'foreign companion: no adopt note in status'; fi
bash "$REPO/scripts/loomy-doctor.sh" --root "$CL" >"$OUT" 2>&1; no_marker2 'foreign companion: doctor runs nothing'
if grep -q 'Private history not verified' "$OUT"; then ok 'foreign companion: doctor shows the adopt line'; else ko 'foreign companion: no adopt line in doctor'; fi
printf '{}' | bash "$REPO/scripts/loomy-statusline.sh" >"$OUT" 2>&1; no_marker2 'foreign companion: statusline runs nothing'
bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1; rc=$?; no_marker2 'foreign companion: loomy privacy sync runs nothing'; no_push 'foreign companion: loomy privacy sync pushes nothing'
if (( rc != 0 )) && grep -q 'not verified' "$OUT"; then ok 'foreign companion: loomy privacy sync refuses with the note'; else ko 'foreign companion: sync did not refuse'; fi
bash "$REPO/bin/loomy" privacy adopt >"$OUT" 2>&1; rc=$?; no_marker2 'foreign companion: adopt runs nothing'
if (( rc != 0 )) && grep -q 'tracked by the project repository\|not allowed' "$OUT" && ! grep -q "$CL" "$WORK/config/loomy/companions" 2>/dev/null; then ok 'foreign companion: adopt refuses it and records nothing'; else ko 'foreign companion: adopt did not refuse'; fi
# Untracked but unrecorded copy (older Loomy, copied folder): adopt reports every dangerous key and the hooks, refuses.
git -C "$CL" rm -rq --cached .loomy/ai.git >/dev/null 2>&1
bash "$REPO/bin/loomy" privacy adopt >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'core.hookspath' "$OUT" && grep -q 'filter.evil.clean' "$OUT" && grep -q 'hook present' "$OUT" && grep -q 'alias.status' "$OUT"; then ok 'adopt lists hooksPath, filter, alias and shipped hooks, and refuses'; else ko 'adopt did not report the hostile config'; fi
no_marker2 'adopt of an unrecorded hostile copy runs nothing'
bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1; no_marker2 'still foreign after a refused adopt: sync runs nothing'; no_push 'still foreign: nothing pushed'

# A Loomy-created companion keeps working: sync commits, the local file remote receives the push, hooks stay off.
G="$WORK/good"; BARE="$WORK/good-remote.git"; mkdir -p "$G/.loomy"; git init -q -b main "$G"; git init -q --bare -b main "$BARE"
printf -- '---\nname: good\nai_files: local\n---\n' >"$G/.loomy/brief.md"; echo 0.17.10 >"$G/.loomy/VERSION"; printf 'a\n' >"$G/AGENTS.md"
( cd "$G" && git add .gitignore >/dev/null 2>&1; true )
cd "$G" || exit 1
bash "$REPO/bin/loomy" privacy private --remote "$BARE" >"$OUT" 2>&1; rc=$?
if (( rc == 0 )) && [[ -n "$(git -C "$BARE" for-each-ref refs/heads/main)" ]]; then ok 'created companion: private init commits and pushes to a local file remote'; else ko 'created companion: init failed'; fi
if grep -q "$G" "$WORK/config/loomy/companions" 2>/dev/null; then ok 'created companion: provenance recorded in the per-user config'; else : >"$OUT"; ko 'created companion: nothing recorded'; fi
printf 'b\n' >>"$G/AGENTS.md"; bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1; rc=$?
if (( rc == 0 )) && [[ "$(git --git-dir="$BARE" show main:AGENTS.md 2>/dev/null | wc -l | tr -d ' ')" == 2 ]]; then ok 'created companion: sync keeps working after the hardening'; else ko 'created companion: sync broken'; fi
# Adopting a clean companion created by an older Loomy (no record) works, and hooks put there afterwards never run.
rm -f "$WORK/config/loomy/companions"
bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'not verified' "$OUT"; then ok 'older companion without a record: refused with the adopt note'; else ko 'older companion not refused'; fi
bash "$REPO/bin/loomy" privacy adopt >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'local remote refused' "$OUT"; then ok 'adopt refuses a local remote'; else ko 'adopt accepted a local remote'; fi
git --git-dir="$G/.loomy/ai.git" config remote.origin.url https://example.invalid/good-ai.git
bash "$REPO/bin/loomy" privacy adopt >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'terminal' "$OUT"; then ok 'adopt without a terminal refuses (no silent trust)'; else ko 'adopt trusted without a terminal'; fi
pty_adopt() { python3 - "$REPO" "$1" "$2" <<'PYEOF'
import os, pty, sys, select
repo, ans, root = sys.argv[1:4]
pid, fd = pty.fork()
if pid == 0:
    os.chdir(root); os.execvp('bash', ['bash', repo + '/bin/loomy', 'privacy', 'adopt'])
out = b''; sent = False
while True:
    r, _, _ = select.select([fd], [], [], 20)
    if not r: break
    try: d = os.read(fd, 4096)
    except OSError: break
    if not d: break
    out += d
    if not sent and b'[y/N]' in out: os.write(fd, (ans + '\n').encode()); sent = True
_, st = os.waitpid(pid, 0)
sys.stdout.write(out.decode(errors='replace')); sys.exit(os.WEXITSTATUS(st))
PYEOF
}
pty_adopt n "$G" >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'example.invalid/good-ai.git' "$OUT"; then ok 'adopt shows every URL and refuses when not confirmed'; else ko 'adopt did not show the URL / accepted n'; fi
pty_adopt y "$G" >"$OUT" 2>&1; rc=$?
if (( rc == 0 )); then ok 'older clean companion: adopt shows the URLs, asks, validates and records it'; else ko 'older clean companion: adopt refused'; fi
printf '#!/bin/sh\necho late >>"%s"\n' "$MARK2" >"$G/.loomy/ai.git/hooks/pre-commit"; chmod +x "$G/.loomy/ai.git/hooks/pre-commit"
printf 'c\n' >>"$G/AGENTS.md"; bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1
no_marker2 'adopted companion: a hook added later is refused and never runs'
rm -f "$G/.loomy/ai.git/hooks/pre-commit"; pty_adopt y "$G" >/dev/null 2>&1

# ── 3b. re-audit on every call, revocation, URLs, op-state, nonce, protocols, filters ──
cd "$G" || exit 1
ready_rc() { bash -c 'source "$1/scripts/lib/privacy.sh"; privacy_companion_ready "$2"' _ "$REPO" "$G" >/dev/null 2>&1; }
if ready_rc; then ok 'adopted companion is ready'; else : >"$OUT"; ko 'adopted companion is not ready'; fi
# a later change of the config (hooksPath) is caught by the next call and revokes the record
git --git-dir="$G/.loomy/ai.git" config core.hooksPath "$WORK/hooks"
if ! ready_rc; then ok 'config changed after adoption: refused on the next call'; else : >"$OUT"; ko 'config change not caught'; fi
git --git-dir="$G/.loomy/ai.git" config --unset core.hooksPath
if ! ready_rc; then ok 'record revoked: the clean config is not trusted again without adopt'; else : >"$OUT"; ko 'revoked record came back'; fi
pty_adopt y "$G" >"$OUT" 2>&1; if ready_rc; then ok 're-adopt restores trust'; else ko 're-adopt failed'; fi
# a pushurl different from the url is refused (exfiltration by push)
git --git-dir="$G/.loomy/ai.git" config remote.origin.pushurl https://example.invalid/evil.git
pty_adopt y "$G" >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'pushurl differs' "$OUT"; then ok 'pushurl different from url: adopt refuses'; else ko 'pushurl exfil not refused'; fi
git --git-dir="$G/.loomy/ai.git" config --unset remote.origin.pushurl
pty_adopt y "$G" >/dev/null 2>&1
# tracked config pulled into an adopted companion, then untracked: still refused until adopt, which refuses the hostile config
cp "$G/.loomy/ai.git/config" "$WORK/good-config"
git --git-dir="$G/.loomy/ai.git" config credential.helper "!sh -c 'echo cred >>$MARK2'"
git --git-dir="$G/.loomy/ai.git" config core.sshCommand "$WORK/evil-fsm2"
( cd "$G" && git add -f .loomy/ai.git/config >/dev/null 2>&1; true )
if ! ready_rc; then ok 'tracked companion config: refused (record revoked)'; else : >"$OUT"; ko 'tracked companion trusted'; fi
git -C "$G" rm -q --cached -r .loomy/ai.git >/dev/null 2>&1
if ! ready_rc; then ok 'untracked afterwards: still refused until adopt'; else : >"$OUT"; ko 'untracking restored trust'; fi
bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1; no_marker2 'untracked hostile config: sync runs nothing'
pty_adopt y "$G" >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && grep -q 'credential.helper' "$OUT"; then ok 'adopt refuses the hostile config left behind'; else ko 'adopt accepted credential.helper'; fi
cp "$WORK/good-config" "$G/.loomy/ai.git/config"; pty_adopt y "$G" >/dev/null 2>&1
if ready_rc; then ok 'clean config + adopt: trusted again'; else ko 'could not re-adopt'; fi
# operation in progress shipped in the companion: refused, project files untouched
mkdir -p "$G/.loomy/ai.git/rebase-merge"; echo deadbeef >"$G/.loomy/ai.git/rebase-merge/orig-head"
sum_before="$(cksum "$G/AGENTS.md")"
bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1; rc=$?
if (( rc != 0 )) && [[ "$(cksum "$G/AGENTS.md")" == "$sum_before" ]] && grep -q 'not verified' "$OUT"; then ok 'shipped rebase-merge: sync refused, project files untouched'; else ko 'rebase-merge not refused'; fi
rm -rf "$G/.loomy/ai.git/rebase-merge"; pty_adopt y "$G" >/dev/null 2>&1
# nonce mismatch (simulated inode reuse) and missing nonce
cp "$G/.loomy/ai.git/loomy-provenance" "$WORK/nonce.bak"; printf '%032d\n' 0 >"$G/.loomy/ai.git/loomy-provenance"; chmod 600 "$G/.loomy/ai.git/loomy-provenance"
if ! ready_rc; then ok 'nonce mismatch (inode reuse): refused'; else ko 'nonce mismatch trusted'; fi
rm -f "$G/.loomy/ai.git/loomy-provenance"; pty_adopt y "$G" >/dev/null 2>&1
rm -f "$G/.loomy/ai.git/loomy-provenance"
if ! ready_rc; then ok 'missing nonce file: refused'; else ko 'missing nonce trusted'; fi
pty_adopt y "$G" >/dev/null 2>&1
# record file: tricky paths, permissions, exact compare
CPL="$REPO/scripts/lib/companion.pl"; RF="$WORK/recs/config/companions"
mkdir -p "$WORK/recs/a" "$WORK/recs/a2" "$WORK/recs/tab"$'\t'"x" "$WORK/recs/nl"$'\n'"x"
perl "$CPL" write "$RF" "$WORK/recs/a" abc >/dev/null 2>&1; r1=$?
perl "$CPL" write "$RF" "$WORK/recs/tab"$'\t'"x" abc >/dev/null 2>&1; r2=$?
perl "$CPL" write "$RF" "$WORK/recs/nl"$'\n'"x" abc >/dev/null 2>&1; r3=$?
perl "$CPL" match "$RF" "$WORK/recs/a2" >/dev/null 2>&1; r4=$?
perl "$CPL" match "$RF" "$WORK/recs/a" >/dev/null 2>&1; r5=$?
mode="$(perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$RF")"; dmode="$(perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$(dirname "$RF")")"
if (( r1 == 0 && r2 != 0 && r3 != 0 && r4 != 0 && r5 == 0 )) && [[ "$mode" == 600 && "$dmode" == 700 ]] && [[ "$(wc -l <"$RF" | tr -d ' ')" == 1 ]]; then ok 'record file: exact match, refuses tab/newline paths, 0600 file in a 0700 folder'; else printf 'r=%s %s %s %s %s mode=%s dmode=%s\n' "$r1" "$r2" "$r3" "$r4" "$r5" "$mode" "$dmode" >"$OUT"; ko 'record file robustness'; fi
# repository protocol.ext.allow cannot re-enable ext:: (GIT_ALLOW_PROTOCOL)
X="$WORK/extproj"; mkdir -p "$X/.loomy"; git init -q -b main "$X"; git init -q --bare -b main "$X/.loomy/ai.git"
git --git-dir="$X/.loomy/ai.git" config protocol.ext.allow always
git --git-dir="$X/.loomy/ai.git" remote add origin "ext::sh -c 'echo ext >>$MARK2' %S"
bash -c 'source "$1/scripts/lib/privacy.sh"; ai_git "$2" ls-remote origin' _ "$REPO" "$X" >"$OUT" 2>&1
no_marker2 'protocol.ext.allow in the repository config does not run ext::'
# a user-level filter driver (git-lfs style) selected by the project .gitattributes does not run on companion add
git config --global filter.evil.clean "$WORK/evil-filter"; git config --global filter.evil.smudge cat; git config --global filter.evil.required true
printf 'AGENTS.md filter=evil\n' >"$G/.gitattributes"; printf 'filtered\n' >>"$G/AGENTS.md"
bash -c 'source "$1/scripts/lib/privacy.sh"; ai_git "$2" add -A -- AGENTS.md; ai_git "$2" status --porcelain' _ "$REPO" "$G" >"$OUT" 2>&1
no_marker2 'global filter driver neutralised for the companion'
git config --global --unset filter.evil.clean; git config --global --unset filter.evil.smudge; git config --global --unset filter.evil.required
# a local remote with a post-receive hook on an unverified companion: nothing runs
H="$WORK/hookproj"; HB="$WORK/hookbare.git"; mkdir -p "$H/.loomy"; git init -q -b main "$H"; git init -q --bare -b main "$HB"
printf '#!/bin/sh\necho post-receive >>"%s"\n' "$MARK2" >"$HB/hooks/post-receive"; chmod +x "$HB/hooks/post-receive"
printf -- '---\nname: h\nai_files: private\n---\n' >"$H/.loomy/brief.md"; echo 0.17.10 >"$H/.loomy/VERSION"
git init -q --bare -b main "$H/.loomy/ai.git"; git --git-dir="$H/.loomy/ai.git" remote add origin "$HB"
( cd "$H" && bash "$REPO/bin/loomy" privacy sync >"$OUT" 2>&1 ); no_marker2 'unverified companion with a local hook remote: sync pushes nothing'
( cd "$H" && pty_adopt y "$H" >"$OUT" 2>&1 ); no_marker2 'unverified companion with a local hook remote: adopt runs nothing'

# ── 4. blobless partial clone: user-variant helpers keep lazy fetch (worktree add, checkout) ──
cd "$WORK" || exit 1
git init -q -b main plsrc && printf 'one\n' >plsrc/f && git -C plsrc add f && git -C plsrc commit -qm one && git -C plsrc config uploadpack.allowFilter true && git -C plsrc config uploadpack.allowAnySHA1InWant true
git clone -q --filter=blob:none --no-checkout "file://$WORK/plsrc" plclone >/dev/null 2>&1
r="$(bash -c 'source "$1/scripts/lib/models.sh"; loomy_git_user -C "$2" checkout -q main && cat "$2/f"; loomy_git_user -C "$2" worktree add -q "$3" -b wt >/dev/null && cat "$3/f"' _ "$REPO" "$WORK/plclone" "$WORK/plwt" 2>&1)"
printf '%s\n' "$r" >"$OUT"
if [[ "$r" == "one"$'\n'"one" ]]; then ok 'blobless clone: loomy_git_user checkout and worktree add fetch the missing blob'; else ko 'blobless clone: checkout/worktree add broke'; fi
# Probes never fetch (loomy_git keeps GIT_NO_LAZY_FETCH=1): no marker, no failure on a missing blob.
# ── 5. loomy_git drops inherited repository-location variables ──
r="$(GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0="$WORK/evil-fsm2" bash -c 'source "$1/scripts/lib/models.sh"; loomy_git -C "$2" rev-parse --show-toplevel' _ "$REPO" "$WORK/plain" 2>&1)"
printf '%s\n' "$r" >"$OUT"
if [[ "$r" == "$WORK/plain" ]] || [[ "$r" == *"/plain" ]]; then ok 'loomy_git ignores an inherited GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE / GIT_CONFIG_COUNT'; else ko 'loomy_git followed inherited GIT variables'; fi
no_marker2 'inherited GIT_CONFIG_COUNT fsmonitor did not run'

printf '\nGit chokepoint: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
