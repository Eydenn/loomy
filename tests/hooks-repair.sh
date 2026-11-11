#!/usr/bin/env bash
# Standalone HOOK contract: synthetic settings and explicitly reaped children.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-hooks-repair.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
case "${1:-}" in
  ""|--flock-probe) ;;
  *) printf 'usage: %s [--flock-probe]\n' "$0" >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { printf 'usage: %s [--flock-probe]\n' "$0" >&2; exit 2; }
# Do not source tests/lib/guard.sh: its global process scan is outside this test.
unset BASH_ENV ENV PERL5OPT PERL5LIB TMUX TMUX_PANE
unset LOOMY_PROJECT_ROOT LOOMY_CONTENT_PROJECT LOOMY_DELEGATION LOOMY_PARENT_ID LOOMY_ATTEMPT
export HOME="$WORK/home" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache"
export TMPDIR="$WORK/tmp" TMUX_TMPDIR="$WORK/tmux"
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS="$REPO/tests/stubs" LOOMY_HOME="$REPO"
export LOOMY_LANG=en LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 NO_COLOR=1
export STUB_LOG="$WORK/provider-calls.log"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -p "$HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMPDIR" "$TMUX_TMPDIR"
chmod 700 "$WORK" "$HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMPDIR" "$TMUX_TMPDIR"
perl "$REPO/tests/fixtures/hooks-repair.pl" "$REPO" "$WORK" "${1:-}"
[[ ! -s "$STUB_LOG" ]] || { printf 'unexpected provider call in hooks-repair fixture\n' >&2; cat "$STUB_LOG" >&2; exit 1; }
