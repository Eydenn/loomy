#!/usr/bin/env bash
# LOCK L1 storage boundary: synthetic roots only, once per umask.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ "${1:-}" != --isolated ]]; then
  [[ "$#" == 0 ]] || { printf 'usage: %s\n' "$0" >&2; exit 2; }
  exec env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C \
    /bin/bash "$REPO/tests/collector-storage.sh" --isolated
fi
[[ "$#" == 1 ]] || exit 2
WORK="$(mktemp -d /tmp/loomy-storage.XXXXXX)"
WORK="$(cd "$WORK" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state"
export XDG_CACHE_HOME="$WORK/cache" TMPDIR="$WORK/tmp" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export LOOMY_HOME="$REPO" LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1
export LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_REPAIR=1
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS="$REPO/tests/stubs"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
mkdir -m 700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMPDIR" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
for mask in 022 002; do
  printf '# Collector storage boundary (umask %s)\n' "$mask"
  ( umask "$mask"; exec perl "$REPO/tests/fixtures/collector-storage.pl" "$REPO" "$WORK/storage-$mask" )
done
