#!/usr/bin/env bash
# Deterministic guard grace checks; no system process scan or provider launch.
set -euo pipefail
REPO="$1"; WORK="$2"
export CODEX_HOME=foreign CLAUDE_CONFIG_DIR=foreign PATH="/foreign:$PATH"
# shellcheck source=../lib/guard.sh
source "$REPO/tests/lib/guard.sh"
trap - EXIT INT TERM HUP
[[ -z "${CODEX_HOME:-}" && -z "${CLAUDE_CONFIG_DIR:-}" ]]
[[ "$PATH" == "$LOOMY_TEST_STUBS:$LOOMY_TEST_TOOLS:/usr/bin:/bin:/usr/sbin:/sbin" ]]
# Counters persist through the guard's command substitutions.
test_guard_processes() {
  local n
  n="$(cat "$WORK/poll-count")"; n=$((n+1)); printf '%s\n' "$n" >"$WORK/poll-count"
  case "$poll_mode" in
    race) (( n > 3 )) || printf '123456\n' ;;
    leak) printf '123456\n' ;;
    unavailable) return 2 ;;
  esac
  return 0
}
test_guard_now_ms() { cat "$WORK/poll-clock"; }
sleep() { [[ "$1" == 0.200 ]]; printf '.\n' >>"$WORK/poll-sleeps"; printf '%s\n' "$(( $(cat "$WORK/poll-clock")+200 ))" >"$WORK/poll-clock"; }
for poll_mode in race leak unavailable; do
  printf '0\n' >"$WORK/poll-count"; printf '0\n' >"$WORK/poll-clock"; : >"$WORK/poll-sleeps"; rc=0
  got="$(test_guard_settled_processes)" || rc=$?
  case "$poll_mode" in
    race) [[ -z "$got" && "$rc" == 0 && "$(cat "$WORK/poll-count")" == 4 ]] ;;
    leak) [[ "$got" == 123456 && "$rc" == 0 && "$(cat "$WORK/poll-count")" == 15 && "$(wc -l <"$WORK/poll-sleeps" | tr -d ' ')" == 15 && "$(cat "$WORK/poll-clock")" == 3000 ]] ;;
    unavailable) [[ "$rc" == 2 && "$(cat "$WORK/poll-count")" == 1 && ! -s "$WORK/poll-sleeps" ]] ;;
  esac
done
