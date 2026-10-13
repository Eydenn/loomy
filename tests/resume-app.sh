#!/usr/bin/env bash
# Desktop resume and session-scoped routing, with no real launchers or user histories.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-resume-app.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/home/.codex"
export LOOMY_HOME="$REPO" NO_COLOR=1 LOOMY_UI_LANG=en LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0
export LOOMY_START_WATCH=0 AI_SESSION_REPROBED=1 LOOMY_NO_SWITCH=1
unset AI_ROUTE_ENV LOOMY_WATCH_TOOL CODEX_THREAD_ID LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$WORK/stubs"
cp "$LOOMY_TEST_STUBS/"* "$WORK/stubs/"
cp "$REPO/tests/fixtures/resume-app/"* "$WORK/stubs/"
chmod +x "$WORK/stubs/"*
export LOOMY_TEST_ORIGINAL_STUBS="$LOOMY_TEST_STUBS"
export LOOMY_TEST_STUBS="$WORK/stubs" PATH="$WORK/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export STUB_LOG="$WORK/calls" STUB_APPS='Codex Claude'
ROOT="$WORK/project"; OUT="$WORK/output"
perl "$REPO/tests/fixtures/resume-app.pl" "$ROOT" "$HOME"
printf '%s\n' '---' 'name: Resume fixture' 'ai_mode: HYBRID' 'ai_lead: codex' 'budget: equilibre' '---' >"$ROOT/.loomy/brief.md"
printf 'phase=done\n' >"$ROOT/.loomy/state"
cp "$ROOT/.loomy/brief.md" "$WORK/brief-original"
PASS=0; start_pid=""; cli_pid=""
check() { local title="$1"; shift; if "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else cat "$OUT" >&2; printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
start() { : >"$STUB_LOG"; bash "$REPO/scripts/loomy-start.sh" --root "$ROOT" --no-watch "$@" >"$OUT" 2>&1; }
failed() { local expected="$1" rc=0; shift; start "$@" || rc=$?; [[ "$rc" == "$expected" ]]; }
check 'Codex newest matching project/subfolder thread; bridge child and other project ignored' start --app
check 'Codex existing thread URL' grep -qx $'open\tcodex://threads/33333333-3333-3333-3333-333333333333' "$STUB_LOG"
# Reuse the same first-line discovery for standalone exec sessions too.
perl -pi -e 's/"vscode"/"exec"/' "$HOME/.codex/sessions/2026/01/02/rollout-2026-01-02T09-00-00-33333333-3333-3333-3333-333333333333.jsonl"
check 'standalone exec is resumable' start --app
check 'standalone exec opens existing thread' grep -q 'codex://threads/33333333' "$STUB_LOG"
mv "$HOME/.codex/sessions" "$HOME/.codex/saved"
check 'Codex without thread falls back' start --app
check 'Codex fallback has prefilled prompt' grep -q $'open\tcodex://threads/new?prompt=' "$STUB_LOG"
mv "$HOME/.codex/saved" "$HOME/.codex/sessions"
printf 'master=claude\nacting=codex\nmanual=1\n' >"$ROOT/.loomy/failover"
perl -pi -e 's/ai_lead: codex/ai_lead: claude/' "$ROOT/.loomy/brief.md"
export AI_ROUTE_ENV=claude
check 'active relay overrides stale environment in app opener' start --orchestrator
check 'relay reopens existing Codex thread' grep -q 'codex://threads/33333333' "$STUB_LOG"
# Target discovery may neither launch a provider nor write/clean state.
printf 'tool=codex\nowner_pid=2147483647\n' >"$ROOT/.loomy/session-only"
: >"$STUB_LOG"
check 'target is read-only and ignores inherited AI_ROUTE_ENV' bash -c 'source "$1/scripts/lib/models.sh"; SCRIPT_DIR="$1/scripts"; source "$SCRIPT_DIR/loomy-start.sh" --open-library; loomy_orchestrator_target "$2"; [[ "$LOOMY_OPEN_TOOL" == codex && -f "$2/.loomy/session-only" ]]' _ "$REPO" "$ROOT"
check 'target invokes no provider' bash -c '! grep -qE "^(claude|codex)" "$1"' _ "$STUB_LOG"
rm -f "$ROOT/.loomy/failover" "$ROOT/.loomy/session-only"
check 'Claude newest transcript is resumed' start --app
log="$(find "$ROOT/.loomy/logs" -name 'desktop-resume.*' | head -1)"
check 'Claude detached resume arguments' grep -qx $'claude\t--desktop\t--resume\t88888888-8888-8888-8888-888888888888\t--model\tclaude-opus-5-5' "$log"
check 'resume log is 0600' perl -e 'die unless ((stat($ARGV[0]))[2]&0777)==0600' "$log"
check 'Claude resume uses no new-session URL' bash -c '! grep -q "claude://" "$1"' _ "$STUB_LOG"
export STUB_APP_VERSION=2.1.284
check 'old Claude CLI fallback' start --app
check 'old Claude link is prefilled and never submitted' grep -q $'open\tclaude://code/new?folder=.*&q=' "$STUB_LOG"
export STUB_APP_VERSION=2.1.285
check 'Claude minimum supported CLI resumes' start --app
check 'minimum supported CLI uses no new-session URL' bash -c '! grep -q "claude://" "$1"' _ "$STUB_LOG"
unset STUB_APP_VERSION
export STUB_DESKTOP_FAIL=1
check 'desktop launch failure fallback' start --app
check 'desktop failure uses Claude new-session URL' grep -q $'open\tclaude://code/new?folder=' "$STUB_LOG"
unset STUB_DESKTOP_FAIL
slug="$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
touch "$HOME/.claude/projects/$slug/88888888-8888-8888-8888-888888888888.jsonl"
printf '{"type":"session","event":"start","tool":"claude","session":"88888888-8888-8888-8888-888888888888","pid":%s,"pid_role":"owner"}\n' "$$" >"$ROOT/.loomy/logs/events.jsonl"
check 'fresh transcript with live journal owner blocks app launch' failed 3 --app
check 'busy message is explicit' grep -q 'busy in a terminal: use /desktop' "$OUT"
check 'busy session launches nothing' test ! -s "$STUB_LOG"
check 'watch opener propagates busy status without terminal fallback' failed 3 --orchestrator
rm -f "$ROOT/.loomy/logs/events.jsonl"
export STUB_BUSY_PID=2147483646 STUB_BUSY_ROOT="$ROOT"
check 'running Claude process cwd blocks even without journal' failed 3 --app
check 'busy process launches nothing' test ! -s "$STUB_LOG"
unset STUB_BUSY_PID STUB_BUSY_ROOT AI_ROUTE_ENV
check '--only without explicit lead is usage error' failed 2 --only --new
check '--only with auto is usage error' failed 2 --lead auto --only --new
check '--only desktop combination fails explicitly without a durable owner' failed 2 --lead codex --only --app
check '--only print writes no marker' start --lead codex --only --print
check 'preview remains read-only' test ! -f "$ROOT/.loomy/session-only"
cp "$ROOT/.loomy/brief.md" "$WORK/brief-original"
test_guard_cleanup() {
  [[ -z "$cli_pid" ]] || kill -TERM "$cli_pid" 2>/dev/null || true
  [[ -z "$start_pid" ]] || { kill -TERM "$start_pid" 2>/dev/null || true; wait "$start_pid" 2>/dev/null || true; }
  cli_pid=""; start_pid=""
}
for tool in codex claude; do
  : >"$STUB_LOG"; rm -f "$WORK/cli-pid"
  STUB_SLEEP=30 STUB_PID_FILE="$WORK/cli-pid" bash "$REPO/scripts/loomy-start.sh" --root "$ROOT" --lead "$tool" --only --new --no-watch >"$OUT" 2>&1 &
  start_pid=$!
  for (( i=0; i<100; i++ )); do [[ ! -s "$WORK/cli-pid" ]] || break; sleep 0.1; done
  check "$tool only session writes marker" test -f "$ROOT/.loomy/session-only"
  cli_pid="$(cat "$WORK/cli-pid")"
  for role in lead architect debugger security reviewer developer executor explorer documenter; do
    actual="$(AI_ROUTE_ENV=hybrid-claude bash "$REPO/scripts/loomy-route.sh" --root "$ROOT" get "$role")"
    check "$tool only routes $role to validated tool chain" perl -e 'my ($s,$t)=@ARGV; die unless $s =~ /^\Q$t\E /; die if $t eq "codex" && $s !~ /gpt-6(?:\.1-sol|-luna) /; die if $t eq "claude" && $s !~ /claude-(?:opus|sonnet|haiku)-5-5 /' "$actual" "$tool"
  done
  check 'brief remains byte-for-byte unchanged' cmp "$WORK/brief-original" "$ROOT/.loomy/brief.md"
  bash "$REPO/scripts/loomy-route.sh" --root "$ROOT" >"$WORK/route-output" 2>&1
  check 'route header exposes only mode' grep -q "lead $tool · only" "$WORK/route-output"
  bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/phases.sh"; source "$1/scripts/lib/usage.sh"; source "$1/scripts/loomy-tree.sh" --library; ROOT="$2"; loomy_live_init; loomy_live_metadata; loomy_live_header; printf "%s\n" "$LV_HEADER"' _ "$REPO" "$ROOT" >"$WORK/header"
  check 'watch header exposes only mode' grep -q "lead $tool · only" "$WORK/header"
  LOOMY_UI_LANG=fr bash "$REPO/scripts/loomy-route.sh" --root "$ROOT" >"$WORK/route-fr" 2>&1
  check 'French route marker is translated' grep -q "lead $tool · uniquement" "$WORK/route-fr"
  kill -TERM "$cli_pid"; wait "$start_pid" || true
  cli_pid=""; start_pid=""
  check 'session end removes marker' test ! -f "$ROOT/.loomy/session-only"
done
printf 'tool=codex\nowner_pid=%s\n' "$$" >"$ROOT/.loomy/session-only"
check '--lead auto clears override' start --lead auto --new
check 'auto removes marker' test ! -f "$ROOT/.loomy/session-only"
printf 'tool=codex\nowner_pid=2147483647\n' >"$ROOT/.loomy/session-only"
actual="$(bash "$REPO/scripts/loomy-route.sh" --root "$ROOT" get lead)"
check 'dead owner cannot override lead' bash -c '[[ "$1" == claude\ * ]]' _ "$actual"
check 'dead marker cleaned' test ! -f "$ROOT/.loomy/session-only"
check 'all launches stayed hermetic' test ! -s "$LOOMY_TEST_GUARD_LOG"
printf 'PASS %s desktop resume/session-only checks\n' "$PASS"
