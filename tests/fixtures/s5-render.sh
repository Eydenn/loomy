#!/usr/bin/env bash
# shellcheck disable=SC2034  # projection/UI state is read by sourced rendering helpers
# Time the real Bash renderer after reducer bootstrap, including 100 active agents.
set -euo pipefail
REPO="$1"; WORK="$2"; ROOT="$WORK/performance"; SCRIPT_DIR="$REPO/scripts"
# shellcheck source=../../scripts/lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=../../scripts/lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=../../scripts/lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=../../scripts/lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=../../scripts/lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"
# shellcheck source=../../scripts/lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=../../scripts/lib/failover.sh
source "$SCRIPT_DIR/lib/failover.sh"
# shellcheck source=../../scripts/loomy-tree.sh
source "$SCRIPT_DIR/loomy-tree.sh" --library
loomy_live_init
while IFS= read -r line; do loomy_native_accept "$line"; done <"$WORK/perf.rows"
LV_NOW="$(date +%s)"; LV_CLOCK=12:00:00
loomy_live_states; loomy_live_metadata
_ui_term_size() { UI_ROWS=180; UI_COLS=170; UI_W=168; }
export LOOMY_WATCH_CAPTURE=1 LOOMY_WATCH_BODY_HEIGHT=170 LOOMY_NO_HEADER=1
LV_FRAME=""; loomy_native_render
for view in tree list; do
  export LOOMY_WATCH_VIEW="$view"
  loomy_native_render
  for trial in 1 2 3 4 5; do
    start="$(perl -MTime::HiRes=time -e 'print time')"
    LV_FRAME=""; LV_NOW=$((LV_NOW+1)); loomy_native_render
    if ! elapsed="$(perl -MTime::HiRes=time -e 'my $ms=1000*(time-$ARGV[0]); printf "%.3f",$ms; exit($ms>=150)' "$start")"; then printf "FAIL warm %s render (%s ms >=150)\n" "$view" "$elapsed"; exit 1; fi
    printf 'PASS warm %s render trial %s (%s ms)\n' "$view" "$trial" "$elapsed"
  done
done
