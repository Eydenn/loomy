#!/usr/bin/env bash
# Bound external fixture/watch commands; shell assertions still run in their caller.
TEST_WATCHDOG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/watchdog.pl"
test_bounded() {
  local deadline="${LOOMY_TEST_STEP_TIMEOUT:-300}"
  case "${2:-}" in */tests/*.sh) deadline="${LOOMY_TEST_SUITE_TIMEOUT:-900}" ;; esac
  command perl "$TEST_WATCHDOG" "$deadline" "$@"
}
test_step() {
  if declare -F "$1" >/dev/null; then "$@"; else test_bounded "$@"; fi
}
perl() { test_bounded perl "$@"; }
bash() { test_bounded bash "$@"; }
expect() { test_bounded expect "$@"; }
