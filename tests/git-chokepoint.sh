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
ALLOW='scripts/lib/models.sh scripts/lib/runtime-paths.pl scripts/lib/watch-health.pl scripts/lib/tracked-fix.pl scripts/loomy-privacy.sh'
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
praw="$(grep -rnE "(exec|system|qx|open)[^#]*['\"]git['\"]|qx[{(/]git |\`git " scripts bin -I --include='*.pl' --include='*.sh' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
  | drop_allowed)"
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

printf '\nGit chokepoint: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
