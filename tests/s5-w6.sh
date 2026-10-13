#!/usr/bin/env bash
# Scoped quota/discovery/diagnostics checks; never starts a provider.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-s5-w6.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude" XDG_CONFIG_HOME="$WORK/config"
export LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_JOURNAL=1
unset LOOMY_NATIVE_NOW LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT
mkdir -p "$HOME" "$XDG_CONFIG_HOME/loomy" "$WORK/project/.loomy/logs" "$CODEX_HOME/sessions/2020/01/01"
PASS=0; FAIL=0
check() {
  if "$@"; then PASS=$((PASS+1)); printf 'PASS %s\n' "$1"
  else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$1" >&2; fi
}
check perl "$REPO/tests/fixtures/s5-performance.pl" "$REPO" "$WORK"
check bash "$REPO/tests/fixtures/s5-render.sh" "$REPO" "$WORK"
check perl "$REPO/tests/fixtures/s5-w6.pl" "$REPO" "$WORK"
check bash "$REPO/tests/fixtures/watch-error.sh" "$REPO" "$WORK"
# The lookup cache must survive command substitutions, used by every caller of ai_quota.
# shellcheck source=../scripts/lib/usage.sh
source "$REPO/scripts/lib/usage.sh"
now="$(date +%s)"
printf '{"rate_limits":{"primary":{"window_minutes":300,"used_percent":42,"resets_at":%s}}}\n' "$((now+300))" >"$CODEX_HOME/sessions/2020/01/01/rollout-quota.jsonl"
check test "$(ai_quota codex)" = "300 42 $((now+300))"
saved="$(cat "$XDG_CONFIG_HOME/loomy/codex-limits.source")"
printf '{"rate_limits":{"primary":{"window_minutes":300,"used_percent":43,"resets_at":%s}}}\n' "$((now+300))" >>"$CODEX_HOME/sessions/2020/01/01/rollout-quota.jsonl"
check test "$(ai_quota codex)" = "300 43 $((now+300))"
check test "$(cat "$XDG_CONFIG_HOME/loomy/codex-limits.source")" = "$saved"
# Repeated discovery reuses a negative cache as well as a positive one.
check perl "$REPO/tests/fixtures/s5-quota.pl" "$REPO" "$WORK" "$now"
if [[ "${LOOMY_TEST_NATIVE_PTY:-1}" == 0 ]]; then
  printf 'SKIP S5/W6 failing reducer and 60s idle CPU PTY (LOOMY_TEST_NATIVE_PTY=0)\n'
elif command -v expect >/dev/null 2>&1; then
  check expect "$REPO/tests/fixtures/watch-error.exp" "$REPO" "$WORK"
  check expect "$REPO/tests/fixtures/watch-idle.exp" "$REPO" "$WORK"
else
  printf 'SKIP S5/W6 failing reducer and 60s idle CPU PTY (expect missing)\n'
fi
printf '%s S5/W6 checks passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
