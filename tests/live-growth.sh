#!/usr/bin/env bash
# S4 checkpoint/recovery, bounded journal and Round 4 Claude regressions.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-live-growth.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export LOOMY_NATIVE_NOW=1791853207 LOOMY_FIXTURE_NOW=1791853200
export LOOMY_JOURNAL=1 LOOMY_JOURNAL_TASKS=1
mkdir -p "$HOME"
PASS=0
for finding in G2 G3 G4 G6 arrival-race growth prune migration crash-codex crash-claude reconstruct-codex reconstruct-claude crash-batch reconstruct-batch rotation corruption backup quarantine shards repair privacy; do
  perl "$REPO/tests/fixtures/growth-live.pl" "$REPO" "$WORK" "$finding"
  PASS=$((PASS+1)); printf 'PASS S4 %s\n' "$finding"
done
printf '%s S4 growth checks passed\n' "$PASS"
