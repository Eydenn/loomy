#!/usr/bin/env bash
# Isolated ANSI geometry regressions; optional output directory for parent visual review.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "/tmp/loomy-tree-layout.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export NO_COLOR=1 LOOMY_LANG=en LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_HOME="$REPO"
unset CODEX_THREAD_ID LOOMY_JOURNAL LOOMY_JOURNAL_TASKS LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT AI_ROUTE_ENV LOOMY_WATCH_TOOL
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
printf 'advisor=opus\n' >"$XDG_CONFIG_HOME/loomy-config-tmp"
mkdir -p "$XDG_CONFIG_HOME/loomy"
mv "$XDG_CONFIG_HOME/loomy-config-tmp" "$XDG_CONFIG_HOME/loomy/config"
PASS=0
check() { local title="$1"; shift; if "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
for mode in codex advisor unknown catchup; do
  ROOT="$WORK/$mode"
  perl "$REPO/tests/fixtures/tree-layout.pl" "$ROOT" "$$" "$mode"
  for width in 124 140 170 200; do
    for lang in en fr; do
      output="$WORK/$mode-$width-$lang.ansi"
      LOOMY_LANG="$lang" LOOMY_TREE=diagram COLUMNS="$width" LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$output" 2>&1
      check "$mode $width $lang borders, padding, wrapped labels and no false DONE" perl "$REPO/tests/fixtures/tree-layout-check.pl" "$output" "$width" "$([[ "$mode" == advisor ]] && echo 1 || echo 0)"
      if [[ -n "${LOOMY_TREE_LAYOUT_OUT:-}" ]]; then mkdir -p "$LOOMY_TREE_LAYOUT_OUT"; cp "$output" "$LOOMY_TREE_LAYOUT_OUT/"; fi
      if [[ "$mode" == unknown ]]; then
        if [[ "$lang" == en ]]; then check 'unknown model is named' grep -q 'MODEL UNKNOWN' "$output"
        else check 'unknown model is translated' grep -q 'MODÈLE INCONNU\|MODèLE INCONNU' "$output"; fi
      fi
      if [[ "$mode" == catchup ]]; then
        check 'model identity row stays separate from freshness' perl -ne 'if (/GPT-6\.1-SOL.*(main session|session principale)/) { $found=1 } END { die unless $found }' "$output"
      fi
    done
  done
done
for width in 80 123; do
  LOOMY_TREE=diagram COLUMNS="$width" LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$WORK/narrow" 2>&1
  check "$width keeps list fallback" grep -q 'diagram view: enlarge' "$WORK/narrow"
done
LOOMY_TREE=auto COLUMNS=170 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$WORK/short" 2>&1
check 'short terminal keeps list fallback' grep -q 'diagram view: enlarge' "$WORK/short"
check 'canvas centering cannot clobber outside reserved cells' bash -c 'source "$1"; cv_init 30 3; cv_put 0 1 "" "LEFT"; cv_put 20 1 "" "RIGHT"; cv_center 6 1 10 "" "a_label_far_too_long_for_the_slot"; [[ ${CV_ROW[1]:0:4} == LEFT && ${CV_ROW[1]:20:5} == RIGHT && ${#CV_ROW[1]} == 30 && ${#CV_COL[1]} == 30 ]]' _ "$REPO/scripts/lib/canvas.sh"
ROOT="$WORK/no-session"
perl "$REPO/tests/fixtures/tree-layout.pl" "$ROOT" "$$" codex
rm "$ROOT/.loomy/logs/events.jsonl"
LOOMY_TREE=diagram COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$WORK/no-session.ansi" 2>&1
check 'standalone diagram renders without a session context' grep -q 'no session' "$WORK/no-session.ansi"
printf '%s tree layout checks passed\n' "$PASS"
