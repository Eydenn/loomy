#!/usr/bin/env bash
# Standalone LOCK primitives: synthetic roots and known children only.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ "${1:-}" != --isolated ]]; then
  [[ "$#" == 0 ]] || { printf 'usage: %s\n' "$0" >&2; exit 2; }
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /bin/bash "$REPO/tests/collector-owner.sh" --isolated
fi
[[ "$#" == 1 ]] || exit 2
WORK="$(mktemp -d /tmp/loomy-owner.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state"
export XDG_CACHE_HOME="$WORK/cache" XDG_RUNTIME_DIR="$WORK/runtime" TMPDIR="$WORK/tmp"
export CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude" TMUX_TMPDIR="$WORK/tmux"
export LOOMY_HOME="$REPO" LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1
export LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_REPAIR=1
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS="$REPO/tests/stubs"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -m 700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" \
  "$XDG_RUNTIME_DIR" "$TMPDIR" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR" "$TMUX_TMPDIR"
printf '# Collector ownership primitives\n'
perl "$REPO/tests/fixtures/collector-owner.pl" "$REPO" "$WORK/owner"
printf '# Runtime paths and public CONTENT readers\n'
perl "$REPO/tests/fixtures/runtime-readers.pl" "$REPO" "$WORK/readers"
