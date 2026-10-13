#!/usr/bin/env bash
# Two-minute accelerated structural replay, using only private PTY/tmux and CLI stubs.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-replay-soak.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
if [[ "${LOOMY_TEST_NATIVE_PTY:-1}" == 0 ]]; then
  printf 'SKIP replay soak PTY (LOOMY_TEST_NATIVE_PTY=0)\n'
  exit 0
fi
for dependency in expect tmux; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'SKIP replay soak PTY (%s missing)\n' "$dependency"
    exit 0
  fi
done
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_JOURNAL=1 LOOMY_JOURNAL_TASKS=1
unset LOOMY_NATIVE_NOW LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT LOOMY_WATCH_TOOL
mkdir -p "$HOME" "$XDG_CONFIG_HOME/loomy"
printf 'notify=no\nwatch_view=tree\nplan_claude=api\nplan_codex=api\n' >"$XDG_CONFIG_HOME/loomy/config"
expect "$REPO/tests/fixtures/replay-watch.exp" "$REPO" "$WORK"
# The guard also checks every private socket and leftover process on EXIT.
test_guard_gate
