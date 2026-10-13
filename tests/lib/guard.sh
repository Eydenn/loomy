#!/usr/bin/env bash
# Shared test boundary: private temp/socket roots and fail-closed CLI launches.
# Suite roots use /tmp to keep Unix socket paths within macOS limits.
# shellcheck disable=SC2034  # exported contract used by product scripts
[[ -n "${WORK:-}" && -d "$WORK" ]] || { printf 'ko test guard: missing work directory\n' >&2; exit 1; }
WORK="$(cd "$WORK" && pwd -P)"
export TMPDIR="$WORK/tmp" TMUX_TMPDIR="$WORK/tmux"
mkdir -p "$TMPDIR" "$TMUX_TMPDIR"
chmod 700 "$TMUX_TMPDIR"
unset TMUX TMUX_PANE
LOOMY_TEST_STUBS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stubs" && pwd -P)"
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS LOOMY_TEST_GUARD_LOG="$WORK/guard-violations.log"
export PATH="$LOOMY_TEST_STUBS:$PATH"

# pgrep treats its argument as a regexp; escape paths before matching, exclude this shell.
test_guard_processes() {
  local pattern pid pids rc=0
  pattern="$(printf '%s' "$WORK" | sed 's/[][\\.^$*+?(){}|]/\\&/g')"
  pids="$(pgrep -f "$pattern" 2>"$WORK/process-scan-error.log")" || rc=$?
  if (( rc > 1 )); then
    printf 'ko process inspection unavailable: ' >&2
    cat "$WORK/process-scan-error.log" >&2
    return "$rc"
  fi
  for pid in $pids; do
    [[ "$pid" == "$$" || "$pid" == "${BASHPID:-$$}" ]] || printf '%s\n' "$pid"
  done
  return 0
}

test_guard_tmux_sessions() {
  local socket
  for socket in "$TMUX_TMPDIR"/tmux-*/*; do
    [[ -S "$socket" ]] || continue
    command tmux -S "$socket" list-sessions 2>/dev/null || true
  done
}

test_guard_gate() {
  local leaked sessions
  leaked="$(test_guard_processes)" || return $?
  sessions="$(test_guard_tmux_sessions)"
  if [[ -n "$leaked" ]]; then printf 'ko leaked processes: %s\n' "$leaked" >&2; fi
  if [[ -n "$sessions" ]]; then printf 'ko leaked tmux sessions: %s\n' "$sessions" >&2; fi
  if [[ -s "$LOOMY_TEST_GUARD_LOG" ]]; then cat "$LOOMY_TEST_GUARD_LOG" >&2; fi
  [[ -z "$leaked$sessions" && ! -s "$LOOMY_TEST_GUARD_LOG" ]]
}

test_guard_exit() {
  local status="$1" leaked socket
  (( BASH_SUBSHELL == 0 )) || return 0
  trap - EXIT
  # Fixtures with intentionally persistent owners stop them before checking for leaks.
  if declare -F test_guard_cleanup >/dev/null; then test_guard_cleanup || status=1; fi
  leaked="$(test_guard_processes)" || status=1
  if [[ -n "$leaked" ]]; then
    printf 'ko leaked processes: %s\n' "$leaked" >&2
    status=1
    # shellcheck disable=SC2086  # pgrep output is a list of numeric PIDs
    kill -TERM $leaked 2>/dev/null || true
    sleep 2
    # shellcheck disable=SC2086
    kill -KILL $leaked 2>/dev/null || true
  fi
  for socket in "$TMUX_TMPDIR"/tmux-*/*; do
    [[ -S "$socket" ]] || continue
    command tmux -S "$socket" kill-server 2>/dev/null || true
  done
  [[ ! -s "$LOOMY_TEST_GUARD_LOG" ]] || status=1
  cd / || true
  rm -rf "$WORK"
  exit "$status"
}
trap 'test_guard_exit "$?"' EXIT
trap 'exit 143' TERM HUP
trap 'exit 130' INT
