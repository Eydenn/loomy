#!/usr/bin/env bash
# Shared test boundary: private temp/socket roots and fail-closed CLI launches.
# Suite roots use /tmp to keep Unix socket paths within macOS limits.
# shellcheck disable=SC2034  # exported contract used by product scripts
[[ -n "${WORK:-}" && -d "$WORK" ]] || { printf 'ko test guard: missing work directory\n' >&2; exit 1; }
WORK="$(cd "$WORK" && pwd -P)"
export TMPDIR="$WORK/tmp" TMUX_TMPDIR="$WORK/tmux"
mkdir -p "$TMPDIR" "$TMUX_TMPDIR"
chmod 700 "$TMUX_TMPDIR"
unset TMUX TMUX_PANE CODEX_HOME CLAUDE_CONFIG_DIR
LOOMY_TEST_STUBS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../stubs" && pwd -P)"
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS LOOMY_TEST_GUARD_LOG="$WORK/guard-violations.log"
# tmux may live outside the restricted PATH (Homebrew on the Mac): expose only that binary through a private directory,
# so tmux/PTY tests run instead of skipping. Its sockets stay under TMUX_TMPDIR.
LOOMY_TEST_TOOLS="$WORK/tools"; mkdir -p "$LOOMY_TEST_TOOLS"
_guard_tmux="$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v tmux || true)"
[[ -z "$_guard_tmux" ]] || ln -sf "$_guard_tmux" "$LOOMY_TEST_TOOLS/tmux"
unset _guard_tmux
export LOOMY_TEST_TOOLS
export PATH="$LOOMY_TEST_STUBS:$LOOMY_TEST_TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"

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
  leaked="$(test_guard_settled_processes)" || return $?
  sessions="$(test_guard_tmux_sessions)"
  if [[ -n "$leaked" ]]; then printf 'ko leaked processes: %s\n' "$leaked" >&2; fi
  if [[ -n "$sessions" ]]; then printf 'ko leaked tmux sessions: %s\n' "$sessions" >&2; fi
  if [[ -s "$LOOMY_TEST_GUARD_LOG" ]]; then cat "$LOOMY_TEST_GUARD_LOG" >&2; fi
  [[ -z "$leaked$sessions" && ! -s "$LOOMY_TEST_GUARD_LOG" ]]
}

# PTY supervisors finish their process-group reaping after Expect receives EOF.
# Bound that teardown grace to three seconds; inspection failures remain fail-closed.
test_guard_now_ms() { command perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e 'printf "%.0f",1000*clock_gettime(CLOCK_MONOTONIC)'; }
test_guard_settled_processes() {
  local leaked="" tries=0 deadline now delay
  now="$(test_guard_now_ms)" || return $?
  deadline=$((now+3000))
  while :; do
    now="$(test_guard_now_ms)" || return $?
    (( tries == 0 || now < deadline )) || break
    leaked="$(test_guard_processes)" || return $?
    [[ -n "$leaked" && "$tries" -lt 15 ]] || break
    now="$(test_guard_now_ms)" || return $?
    delay=$((deadline-now)); (( delay > 0 )) || break
    (( delay <= 200 )) || delay=200
    sleep "$(printf '%d.%03d' $((delay/1000)) $((delay%1000)))"; tries=$((tries+1))
  done
  [[ -z "$leaked" ]] || printf '%s\n' "$leaked"
  return 0
}

test_guard_exit() {
  local status="$1" leaked socket
  (( BASH_SUBSHELL == 0 )) || return 0
  trap - EXIT
  # Fixtures with intentionally persistent owners stop them before checking for leaks.
  if declare -F test_guard_cleanup >/dev/null; then test_guard_cleanup || status=1; fi
  leaked="$(test_guard_settled_processes)" || status=1
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
