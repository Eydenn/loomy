#!/usr/bin/env bash
# Structural check of the live block's fit: when the frame is taller than the viewport, recently ended rows fold first
# (oldest ended first, across every live group) so running rows never leave the screen, and no row is listed twice.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "/tmp/loomy-fold-fit.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export PATH="$REPO/tests/stubs:$LOOMY_TEST_TOOLS:/usr/bin:/bin:/usr/sbin:/sbin"
export LOOMY_HOME="$REPO" NO_COLOR=1 LOOMY_LANG=en LOOMY_UI_LANG=en LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_JOURNAL=1
unset LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT LOOMY_WATCH_TOOL LOOMY_WATCH_ID
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
ROOT="$WORK/project"
PASS=0
check() { local title="$1"; shift; if "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }

# Four live groups (Claude and Codex, CLI and app) plus the bridge rows of the Codex CLI group: five trials have ended
# (oldest first), the sixth is running everywhere.
EV="$REPO/tests/fixtures/replay-events.pl"
perl "$EV" "$WORK" seed
for trial in 1 2 3 4 5; do perl "$EV" "$WORK" start "$trial"; perl "$EV" "$WORK" end "$trial"; sleep 1.1; done  # end stamps have a one-second resolution
perl "$EV" "$WORK" start 6
frame() { COLUMNS=120 LINES="$1" LOOMY_NO_HEADER=1 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once; }
count() { grep -c -- "$2" "$1" || true; }
frame 200 >"$WORK/roomy"; frame 30 >"$WORK/tight"; frame 40 >"$WORK/medium"; frame 22 >"$WORK/tiny"
RUN='cxcli6 cxapp6 clcli6 clapp6 bridge1-6 bridge2-6'
check 'roomy viewport keeps the 30-minute rule: nothing folded, oldest ended row still listed' bash -c '! grep -q "earlier" "$1" && grep -q cxcli1 "$1" && grep -q clapp1 "$1"' _ "$WORK/roomy"
check 'tight viewport: every running row stays visible' bash -c 'for l in '"$RUN"'; do grep -q "$l" "$1" || exit 1; done' _ "$WORK/tight"
check 'tight viewport: the live block fits the viewport (the recap scrolls below it)' bash -c '[ "$(sed "/recap/,\$d" "$1" | grep -c .)" -le 30 ]' _ "$WORK/tight"
check 'tight viewport: older rows fold into +N earlier lines of several groups' bash -c '[ "$(grep -c "+[0-9]* earlier" "$1")" -ge 2 ]' _ "$WORK/tight"
check 'medium viewport: ended rows fold oldest first, the newest stay in the live block' bash -c 'live="$(sed "/recap/,\$d" "$1")"; grep -q "earlier" "$1" && ! printf "%s\n" "$live" | grep -q "cxapp1 " && printf "%s\n" "$live" | grep -q "cxapp5 " && [ "$(grep -c "cxapp5 " "$1")" -eq 1 ]' _ "$WORK/medium"
check 'tight viewport: a folded row is listed once (in the recap), not also in the live block' bash -c 'live="$(sed "/recap/,\$d" "$1")"; for l in cxapp1 clcli1 bridge1-1; do ! printf "%s\n" "$live" | grep -q "$l " || exit 1; [ "$(grep -c "$l " "$1")" -eq 1 ] || exit 1; done' _ "$WORK/tight"
check 'tight viewport: folded rows are listed in the recap' bash -c 'sed -n "/recap/,\$p" "$1" | grep -q cxapp1' _ "$WORK/tight"
check 'tiny viewport: running rows still win over ended rows' bash -c 'for l in '"$RUN"'; do grep -q "$l" "$1" || exit 1; done' _ "$WORK/tiny"
printf 'Fold fit: %s passed\n' "$PASS"
test_guard_gate
