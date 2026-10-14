#!/usr/bin/env bash
# shellcheck disable=SC2034  # projection/UI state is read by sourced rendering helpers
# Time the real warm frame (states, render, viewport, paint) after reducer bootstrap.
set -euo pipefail
REPO="$1"; WORK="$2"; ROOT="$WORK/performance"; SCRIPT_DIR="$REPO/scripts"
render_budget="$(command perl "$REPO/tests/fixtures/time-scale.pl" 150)"
list_budget="$(command perl "$REPO/tests/fixtures/time-scale.pl" 120)"
export LC_NUMERIC=C
# Bash times includes this shell and reaped children at OS clock resolution, excluding scheduler waits.
render_start() { times >"$WORK/render-cpu-start"; }
render_check() {
  local phase="$1" budget="$2" elapsed
  times >"$WORK/render-cpu-end"
  if ! elapsed="$(command perl -e '
    sub total {open my $f,"<",$_[0] or die $!; local $/; my $t=<$f>; my ($sum,$count)=(0,0);
      while ($t =~ /(\d+)m([\d.]+)s/g) {$sum+=60*$1+$2; ++$count}
      die "invalid Bash CPU measurement\n" unless $count==4; return $sum}
    my $ms=1000*(total($ARGV[1])-total($ARGV[0])); printf "%.3f",$ms; exit($ms>=$ARGV[2]);
  ' "$WORK/render-cpu-start" "$WORK/render-cpu-end" "$budget")"; then
    printf 'FAIL %s %s render (%s ms CPU, budget <%s ms)\n' "$phase" "$view" "$elapsed" "$budget"; return 1
  fi
  printf 'PASS %s %s render trial %s (%s ms CPU, budget <%s ms)\n' "$phase" "$view" "$trial" "$elapsed" "$budget"
}
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
    render_start
    LV_FRAME=""; LV_NOW=$((LV_NOW+1)); loomy_live_states; loomy_native_render
    loomy_live_viewport "$LV_FRAME" 170 0
    UI_HDR_TITLE="$LV_HEADER"; UI_FTR_KEYS="q quit"; UI_FTR_NOTE=""; UI_BODY_TOP=0
    _ui_page_draw 0 2>"$WORK/render-screen"
    render_check warm "$render_budget"
    indexed="$(declare -p UI_PAGE_L)"; frame_copy="$LV_FRAME"; LV_FRAME=""
    loomy_live_viewport "$frame_copy" 170 0
    [[ "$indexed" == "$(declare -p UI_PAGE_L)" ]] || { printf 'FAIL indexed viewport differs from text path\n'; exit 1; }
    LV_FRAME="$frame_copy"
    cached="$LV_FRAME"; NS_DRAW_KEY=""; LV_FRAME=""; loomy_native_render
    [[ "$cached" == "$LV_FRAME" ]] || { printf 'FAIL cached %s frame differs from rebuild\n' "$view"; exit 1; }
  done
done

# Projection changes invalidate ownership, layout and row inputs together.
for view in tree list; do
  LOOMY_WATCH_VIEW=$view
  LV_FRAME=""; loomy_native_render
  for trial in 1 2 3 4 5; do
    s5_id=""; s5_group=""; s5_parent=""; s5_state=""; s5_role=""; s5_tail=""
    loomy_native_read "${NS_A[0]}" s5_n s5_kind s5_id s5_group s5_parent s5_state s5_role s5_task s5_tail
    loomy_native_accept "N|A|$s5_id|$s5_group|$s5_parent|$s5_state|$s5_role|Changed title $trial|$s5_tail"
    render_start
    LV_FRAME=""; loomy_live_states; loomy_native_render
    loomy_live_viewport "$LV_FRAME" 170 0
    UI_HDR_TITLE="$LV_HEADER"; UI_FTR_KEYS="q quit"; UI_FTR_NOTE=""; UI_BODY_TOP=0
    _ui_page_draw 0 2>"$WORK/render-screen"
    budget="$render_budget"; [[ "$view" != list ]] || budget="$list_budget"
    render_check changed "$budget"
    cached="$LV_FRAME"; NS_DRAW_KEY=""; LV_FRAME=""
    render_start
    loomy_native_render
    loomy_live_viewport "$LV_FRAME" 170 0; _ui_page_draw 0 2>"$WORK/render-screen"
    render_check rebuild "$render_budget"
    [[ "$cached" == "$LV_FRAME" ]] || { printf 'FAIL changed %s frame differs from rebuild\n' "$view"; exit 1; }
  done
done

# Sanitizing bucket names must not merge distinct identities or cross group ownership.
loomy_live_init
loomy_native_accept 'N|native|1'
loomy_native_accept 'N|G|claude:g|claude|app|.|live|running|||1000|source lease|'
loomy_native_accept 'N|G|claude:h|claude|app|.|live|running|||1000|source lease|'
loomy_native_accept 'N|A|claude:g:a.b|claude:g|claude:g|running|developer|日本語 title|||1000|||unknown||1000|running|0'
loomy_native_accept 'N|A|claude:g:a-b|claude:g|claude:g|running|developer|Other title|||1000|||unknown||1000|running|0'
loomy_native_accept 'N|A|claude:g:child|claude:g|claude:g:a-b|running|executor|Child|||1000|||unknown||1000|running|0'
loomy_native_accept 'N|A|claude:h:orphan|claude:h|claude:g:a.b|running|executor|Orphan|||1000|||unknown||1000|running|0'
loomy_native_accept 'N|T|old-turn|claude:g|claude:g:a.b|done|unknown|900|999|99||developer'
loomy_native_index
[[ "${NS_CHILDREN[0]}" == '' && "${NS_CHILDREN[1]}" == ' 2' && "${NS_AGENT_TURNS[0]}" == ' 0' && "${NS_AGENT_TURNS[1]}" == '' && "${NS_GROUP_ROOTS[1]}" == ' 3' && "${NS_AI_TASK[0]}" == '日本語 title' ]] || { printf 'FAIL indexed identity collision/group/UTF-8\n'; exit 1; }
printf 'PASS ownership buckets preserve colliding keys, groups and UTF-8\n'

# Timer-only frames must neither decode unchanged wire rows nor fork helpers.
read_def="$(declare -f loomy_native_read)"
eval "${read_def/loomy_native_read/s5_native_read}"
loomy_native_read() { S5_READS=$(( S5_READS + 1 )); s5_native_read "$@"; }
loomy_live_init; S5_READS=0
loomy_native_accept 'N|native|1'
loomy_native_accept 'N|G|claude:g|claude|app|.|live|running|claude-sonnet-5-5|high|1000|source lease|'
loomy_native_accept 'N|A|claude:g:a|claude:g|claude:g|running|developer|A long task title with complete words|claude-sonnet-5-5|high|1000|||unknown|turn-active|1000|running|1'
loomy_native_accept 'N|A|claude:g:b|claude:g|claude:g:a|idle|reviewer|Child task|claude-sonnet-5-5|high|900|999|99|partial|turn-idle|999|done|2'
loomy_native_accept 'N|A|claude:g:c|claude:g|missing|done|executor|Unresolved parent task|claude-haiku-5-5|low|0|||unknown||999|done|0'
loomy_native_accept 'N|A|claude:g:d|claude:g|claude:g|idle|reviewer|Idle unknown duration|claude-sonnet-5-5|high|900|999||unknown|turn-unknown|999|done|1'
loomy_native_accept 'N|T|turn-idle|claude:g|claude:g:b|done|partial|900|999|99|claude-sonnet-5-5|reviewer'
loomy_native_accept 'N|T|turn-old|claude:g|claude:g:b|failed|failed|800|899|99|claude-sonnet-5-5|reviewer'
S5_READS=0; loomy_live_metadata
# The dictionary is needed when switching language inside an already initialized process.
# shellcheck source=../../scripts/lib/i18n/fr.sh
source "$SCRIPT_DIR/lib/i18n/fr.sh"
for lang in en fr; do
  LOOMY_UI_LANG=$lang
  for view in tree list; do
    LOOMY_WATCH_VIEW=$view
    for cols in 30 80 170; do
      _ui_term_size() { UI_ROWS=180; UI_COLS=$cols; UI_W=$(( cols - 2 )); }
      for height in 6 170; do
        LOOMY_WATCH_BODY_HEIGHT=$height
        for LV_NOW in 1000 1059 1060 1599 1600 4600; do
          LV_FRAME=""; loomy_native_render; loomy_live_states
          S5_READS=0; LV_FRAME=""
          # Builtin row fitting must survive a PATH with no external executables.
          PATH=/nonexistent loomy_native_render
          PATH=/nonexistent loomy_live_states
          (( S5_READS == 0 )) || { printf 'FAIL timer decoded unchanged rows\n'; exit 1; }
          cached="$LV_FRAME"; NS_DRAW_KEY=""; LV_FRAME=""; loomy_native_render
          [[ "$cached" == "$LV_FRAME" ]] || { printf 'FAIL timer cache %s/%s/%s/%s/%s\n' "$lang" "$view" "$cols" "$height" "$LV_NOW"; exit 1; }
        done
      done
    done
  done
done
# Invalidation must also cover updated/deleted identities and switching header modes.
loomy_native_accept 'N|A|claude:g:b|claude:g|claude:g|done|reviewer|Updated task|claude-sonnet-5-5|high|900|999|99|partial|turn-idle|999|done|2'
loomy_native_accept 'N|X|claude:g:c'
loomy_native_accept 'N|Y|turn-old'
LV_FRAME=""; LOOMY_NO_HEADER="" loomy_native_render
LV_FRAME=""; loomy_native_render; cached="$LV_FRAME"
NS_DRAW_KEY=""; LV_FRAME=""; loomy_native_render
[[ "$cached" == "$LV_FRAME" ]] || { printf 'FAIL delta/header cache invalidation\n'; exit 1; }
printf 'PASS byte-identical timer frames (EN/FR, tree/list, widths/heights, duration boundaries, idle/ended/unknown, deltas); zero warm decodes/spawns\n'
