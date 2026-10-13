#!/usr/bin/env bash
# Exit-path regressions use pipes so the full suite also runs them without PTY access.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=fixtures/watchdog.sh
source "$REPO/tests/fixtures/watchdog.sh"
WORK="$(mktemp -d "/tmp/loomy-watch-exit.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
trap 'exit 143' TERM HUP
trap 'exit 130' INT
mkdir -p "$WORK/home" "$WORK/config/loomy" "$WORK/project/.loomy/logs" "$WORK/tmp"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" TMPDIR="$WORK/tmp"
export CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export COLUMNS=170 LINES=65
export LOOMY_HOME="$REPO" LOOMY_LANG=en NO_COLOR=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1
unset LOOMY_DELEGATION LOOMY_PROJECT_ROOT LOOMY_UI_LANG AI_ROUTE_ENV LOOMY_WATCH_TOOL LOOMY_JOURNAL LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT
printf 'notify=no\n' >"$XDG_CONFIG_HOME/loomy/config"
perl "$REPO/tests/fixtures/watch-exit.pl" "$REPO" "$WORK/project"
perl "$REPO/tests/fixtures/watchdog-check.pl" "$REPO" "$WORK"
test -z "$(find "$WORK/tmp" -mindepth 1 -print)"
