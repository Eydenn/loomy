#!/usr/bin/env bash
# shellcheck disable=SC2034  # library: colours and UI_* are read by the scripts that source it
# Terminal interface tools for Loomy's scripts.
# To be sourced, not executed. Bash 3.2 compatible (macOS's), no dependencies.
# Answers are returned in the global UI_VALUE variable.
#
# Questions: ui_input (text), ui_choose (one choice), ui_multi (several choices).
# Each question shows as a card: the question, why it matters, the options, and in a box
# the consequence of the hovered option. Optional context, reset after each question:
#   UI_HINT   why the question matters
#   UI_DESCS  consequence of each option, in option order
#   UI_LABEL  short label of the answer in the recap (default: the question)
#
# Form: ui_form_begin / ui_form_pass / ui_form_end wrap a series of questions grouped by
# ui_group. The screen is redrawn at each question: finished groups folded on one line, answers of the
# current group aligned, current question as a card. The ← key goes back to the previous question:
# the current pass ends without asking anything, then ui_form_again replays it up to that question.
#
#   ui_form_begin "startup brief · project" "PROJECT|REQUIREMENTS|AI TEAM"
#   while :; do ui_form_pass; poser_les_questions; ui_form_again || break; done
#   ui_form_end

# Interface language (English or French) and the t function.
# shellcheck source=i18n.sh
source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"

UI_VALUE=""
UI_ASSUME_DEFAULTS="${UI_ASSUME_DEFAULTS:-0}"
UI_HINT=""; UI_DESCS=(); UI_LABEL=""
UI_KEY=""; UI_CH=""; UI_LEN=0; UI_LINES=()

if [[ -z "${NO_COLOR:-}" ]] && { [[ -n "${LOOMY_FORCE_COLOR:-}" ]] || [[ -t 2 && "${TERM:-dumb}" != "dumb" ]]; }; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_TITLE=$'\033[1;97m'   # titles and project name: bold (brand colour below, visible even without bold, in tmux for example)
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  if [[ "${TERM:-}" == *256color* || "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit ]]; then
    C_BRAND=$'\033[1;38;5;141m'   # "Loomy": light purple
    C_RAIL=$'\033[38;5;98m'       # guide line and markers
    C_BOX=$'\033[38;5;74m'        # consequence box
    C_TITLE=$'\033[1;38;5;141m'  # titles and project name: bold light purple
  else
    C_BRAND=$'\033[1;35m'; C_RAIL=$'\033[35m'; C_BOX=$'\033[36m'; C_TITLE=$'\033[1;35m'
  fi
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_TITLE=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_BRAND=""; C_RAIL=""; C_BOX=""
fi

ui_is_interactive() { [[ "$UI_ASSUME_DEFAULTS" != "1" && -t 0 && -t 2 ]]; }

ui_print() {
  if [[ "$UI_SCREEN" == "1" ]]; then UI_PAGE_L[${#UI_PAGE_L[@]}]="$*"; _ui_page_draw; return 0; fi
  printf '%s\n' "$*" >&2
}

# ---------------------------------------------------------------- screen
# In an interactive terminal, Loomy shows in the alternate screen, like a full-screen app: each update
# redraws the same screen from the top, nothing piles up in the history, and lines that are too long are
# cut instead of wrapping. The "page" (UI_PAGE_L) is what the script printed; only its visible end
# is drawn. On exit, the normal screen comes back and the last page is copied there, once.
# The process that opens the screen owns it (LOOMY_SCREEN_OWNER = its PID). A Loomy subprocess started meanwhile
# draws on the same screen; its page is handed back to the parent through the LOOMY_PAGE_OUT file (see ui_run).
# LOOMY_NO_CLEAR=1: no alternate screen, line by line output.
UI_SCREEN=0; UI_PAGE_L=(); UI_PAGE_BODY=0

# Terminals without a separate screen (the Claude app's, for example): the screen AND the history are cleared on entry and
# on exit, so that Loomy is alone on screen. Setting: LOOMY_SCREEN=alt|clear, or loomy config set screen.
_ui_screen_mode() {
  local m="${LOOMY_SCREEN:-}"
  if [[ -z "$m" ]]; then
    m="$(sed -n 's/^screen=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/config" 2>/dev/null | head -1)"
  fi
  case "$m" in alt|clear) echo "$m"; return 0 ;; esac
  case "${TERM_PROGRAM:-}" in claude-desktop) echo clear ;; *) echo alt ;; esac
}

ui_screen_begin() {
  UI_PAGE_BODY=0
  if [[ "$UI_SCREEN" == "1" ]]; then UI_PAGE_L=(); printf '\033[H\033[2J' >&2; return 0; fi
  [[ -z "${LOOMY_NO_CLEAR:-}" ]] && ui_is_interactive || return 0
  UI_SCREEN=1; UI_PAGE_L=()
  if [[ -z "${LOOMY_SCREEN_OWNER:-}" ]]; then
    export LOOMY_SCREEN_OWNER=$$
    if [[ "$(_ui_screen_mode)" == "clear" ]]; then printf '\033[H\033[2J\033[3J' >&2; else printf '\033[?1049h' >&2; fi
  fi
  printf '\033[?7l\033[H\033[2J' >&2
  trap '_ui_restore' EXIT
  trap '_ui_restore; exit 130' INT TERM
  return 0
}

# ui_clear: opens the Loomy screen, or clears it when already open.
ui_clear() { ui_screen_begin; }

# ui_screen_end: closes the screen (owner) and copies the page to the normal screen; subprocess: hands the page to the parent.
ui_screen_end() {
  [[ "$UI_SCREEN" == "1" ]] || return 0
  UI_SCREEN=0
  local l
  if [[ "${LOOMY_SCREEN_OWNER:-}" == "$$" ]]; then
    if [[ "$(_ui_screen_mode)" == "clear" ]]; then printf '\033[?7h\033[?25h\033[H\033[2J\033[3J' >&2
    else printf '\033[?7h\033[?25h\033[?1049l' >&2; fi
    unset LOOMY_SCREEN_OWNER
    # What stays in the history: the content of the last page, without the logo; nothing when moving to another
    # screen (ui_exec), so that screens don't pile up.
    if [[ -z "${UI_NO_DUMP:-}" ]] && (( ${#UI_PAGE_L[@]} > 0 )); then
      local i n=${#UI_PAGE_L[@]}
      [[ -n "$UI_HDR_TITLE" ]] && printf '%s\n%s\n' "${C_RAIL}┌${C_RESET}  ${C_TITLE}${UI_HDR_TITLE}${C_RESET}${UI_HDR_SUB:+  ${C_DIM}${UI_HDR_SUB}${C_RESET}}" "${C_RAIL}│${C_RESET}" >&2
      for (( i = 0; i < n; i++ )); do printf '%s\n' "${UI_PAGE_L[$i]:-}" >&2; done
    fi
  elif [[ -n "${LOOMY_PAGE_OUT:-}" ]]; then
    for l in ${UI_PAGE_L[@]+"${UI_PAGE_L[@]}"}; do printf '%s\n' "$l"; done >>"$LOOMY_PAGE_OUT"
  fi
  UI_PAGE_L=()
  return 0
}

_ui_restore() {
  _ui_tick_stop
  ui_form_end
  ui_screen_end
  printf '\033[?25h' >&2
  stty echo </dev/tty 2>/dev/null || true
}

# ui_external <command>...: runs an interactive command (gh auth login…) outside the Loomy screen, then comes back.
ui_external() {
  local rc=0
  local mode; mode="$(_ui_screen_mode)"
  if [[ "$UI_SCREEN" == "1" ]]; then
    if [[ "$mode" == "clear" ]]; then printf '\033[?7h\033[?25h\033[H\033[2J' >&2; else printf '\033[?7h\033[?25h\033[?1049l' >&2; fi
    stty echo </dev/tty 2>/dev/null || true
  fi
  "$@" || rc=$?
  if [[ "$UI_SCREEN" == "1" ]]; then
    if [[ "$mode" == "clear" ]]; then printf '\033[H\033[2J\033[3J\033[?7l' >&2; else printf '\033[?1049h\033[?7l' >&2; fi
    _ui_page_draw
  fi
  return $rc
}

# ui_pager <title> <file>: shows a text (output of a Loomy command) in the app screen, with
# scrolling; ↑↓ line, space / b page, ⏎ or ← back, q quit. UI_KEY is "back" or "quit" on exit.
# Outside full screen (LOOMY_NO_CLEAR, non-interactive output): the text is simply printed.
# ui_clip <width>: cuts each input line to <width> visible columns ("…"), colour sequences
# included; nothing wraps, even in a terminal that ignores turning off automatic wrap.
ui_clip() {
  perl -CS -Mutf8 -ne '
    chomp; my ($w, $out, $vis) = ('"$1"', "", 0);
    while (length) {
      if (s/^(\e\[[0-9;?]*[A-Za-z])//) { $out .= $1; next }
      s/^(.)//s; if ($vis >= $w - 1 && length) { $out .= "…"; $vis++; last } $out .= $1; $vis++;
    }
    print $out, "\e[0m\n";' 2>/dev/null || cat
}

ui_pager() {
  local title="$1" file="$2" lines=() l top=0 n avail saved_page=() saved_title saved_sub
  if [[ "$UI_SCREEN" != "1" ]]; then cat "$file" >&2; UI_KEY="back"; return 0; fi
  _ui_term_size
  while IFS= read -r l || [[ -n "$l" ]]; do lines[${#lines[@]}]="$l"; done < <(ui_clip "$(( UI_COLS - 1 ))" <"$file")
  n=${#lines[@]}
  saved_page=(${UI_PAGE_L[@]+"${UI_PAGE_L[@]}"}); saved_title="$UI_HDR_TITLE"; saved_sub="$UI_HDR_SUB"
  ui_header "$title" "$saved_title${saved_sub:+ · $saved_sub}"
  UI_PAGE_L=(${lines[@]+"${lines[@]}"})
  _ui_hide_cursor
  while :; do
    _ui_term_size; _ui_chrome
    avail=$(( UI_ROWS - UI_CHROME_H )); (( avail < 3 )) && avail=3
    (( top > n - avail )) && top=$(( n - avail )); (( top < 0 )) && top=0
    UI_FTR_KEYS="$(t "⏎ ← back · q quit")"
    (( n > avail )) && UI_FTR_KEYS="$(t "↑↓ space b scroll") ($(( top + 1 ))–$(( top + avail < n ? top + avail : n ))/$n) · $UI_FTR_KEYS"
    UI_BODY_TOP=$top; _ui_page_draw
    _ui_read_key
    case "$UI_KEY" in
      up) top=$(( top - 1 )) ;;
      down) top=$(( top + 1 )) ;;
      space) top=$(( top + avail )) ;;
      enter|left) UI_KEY="back"; break ;;
      char) case "$UI_CH" in q|Q) UI_KEY="quit"; break ;; b|B) top=$(( top - avail )) ;; j) top=$(( top + 1 )) ;; k) top=$(( top - 1 )) ;; esac ;;
    esac
  done
  UI_BODY_TOP=""; UI_FTR_KEYS=""
  UI_PAGE_L=(${saved_page[@]+"${saved_page[@]}"}); ui_header "$saved_title" "$saved_sub"
  _ui_show_cursor
  return 0
}

# ui_exec <command>...: leaves the Loomy screen (the page stays in the history), then runs the command in its place.
ui_exec() { UI_NO_DUMP=1; _ui_restore; trap - EXIT INT TERM; exec "$@"; }

# ui_run <command>...: runs a Loomy subprocess drawing on the same screen, then adds its page to the current page.
ui_run() {
  local out rc=0 l
  if [[ "$UI_SCREEN" != "1" ]]; then "$@"; return $?; fi
  out="$(mktemp "${TMPDIR:-/tmp}/loomy-page.XXXXXX")"
  LOOMY_PAGE_OUT="$out" "$@" || rc=$?
  while IFS= read -r l || [[ -n "$l" ]]; do UI_PAGE_L[${#UI_PAGE_L[@]}]="$l"; done <"$out"
  rm -f "$out"
  _ui_page_draw
  return $rc
}

# _ui_page_draw [reserved-lines] [tail]: draws the end of the page that fits on screen, then <tail> (current question).
# ---------------------------------------------------------------- cadre de l'application
# In the Loomy screen, everything shows in a fixed frame:
#   header: logo, then "┌ title  context" (set by ui_banner: project, current screen, state)
#   body  : the page (UI_PAGE_L) and, at the bottom, the current question; the only area that changes
#   footer: the useful keys (ui_choose, ui_input, viewer, tracking) and the Loomy version
# Loomy subprocesses reuse the same header (LOOMY_HDR_TITLE / LOOMY_HDR_SUB).
UI_HDR_TITLE="${LOOMY_HDR_TITLE:-}"; UI_HDR_SUB="${LOOMY_HDR_SUB:-}"; UI_FTR_KEYS=""; UI_BODY_TOP=""; UI_CHROME_H=0
UI_LOOMY_V="$(cat "$(dirname "${BASH_SOURCE[0]}")/../../VERSION" 2>/dev/null || true)"

# ui_header <title> <context>: frame header (and subprocesses').
ui_header() {
  UI_HDR_TITLE="$1"; UI_HDR_SUB="${2:-}"
  export LOOMY_HDR_TITLE="$UI_HDR_TITLE" LOOMY_HDR_SUB="$UI_HDR_SUB"
}

# _ui_chrome: header lines (UI_HDR_LINES, UI_CHROME_H) and footer (UI_FOOTER) for the terminal size.
_ui_chrome() {
  local l left right pad
  UI_HDR_LINES=()
  local head="${C_RAIL}┌${C_RESET}  ${C_TITLE}${UI_HDR_TITLE:-loomy}${C_RESET}${UI_HDR_SUB:+  ${C_DIM}${UI_HDR_SUB}${C_RESET}}"
  if (( UI_ROWS >= 20 && UI_COLS >= 40 )); then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do UI_HDR_LINES[${#UI_HDR_LINES[@]}]="$l"; done
    UI_HDR_LINES[${#UI_HDR_LINES[@]}]=""
  fi
  UI_HDR_LINES[${#UI_HDR_LINES[@]}]="$head"
  UI_CHROME_H=$(( ${#UI_HDR_LINES[@]} + 1 ))
  left="${UI_FTR_KEYS:-$(t "Ctrl-C to interrupt")}"; right="loomy${UI_LOOMY_V:+ $UI_LOOMY_V}"
  _ui_strlen "$left$right"; pad=$(( UI_COLS - 6 - UI_LEN )); (( pad < 2 )) && pad=2
  UI_FOOTER="${C_RAIL}└${C_RESET}  ${C_DIM}${left}$(printf '%*s' "$pad" '')${right}${C_RESET}"
}

# _ui_page_draw [reserved-lines] [tail]: draws the frame, then in the body the page and <tail> (current question).
# The body shows the end of the page (what just arrived), or from line UI_BODY_TOP (tracking, viewer).
_ui_page_draw() {
  local reserved="${1:-0}" tail="${2:-}" n=${#UI_PAGE_L[@]} avail start end i l out=$'\033[H'
  _ui_term_size; _ui_chrome
  for l in "${UI_HDR_LINES[@]}"; do out="${out}${l}"$'\033[K\n'; done
  avail=$(( UI_ROWS - UI_CHROME_H - reserved )); (( avail < 0 )) && avail=0
  if [[ -n "$UI_BODY_TOP" ]]; then start=$UI_BODY_TOP; else start=$(( n - avail )); fi
  (( start > n - avail )) && start=$(( n - avail )); (( start < 0 )) && start=0
  UI_BODY_START=$start; end=$(( start + avail )); (( end > n )) && end=$n
  for (( i = start; i < end; i++ )); do out="${out}${UI_PAGE_L[$i]:-}"$'\033[K\n'; done
  printf '%s%s\033[J\033[%d;1H%s\033[K' "$out" "$tail" "$UI_ROWS" "$UI_FOOTER" >&2
}

# ---------------------------------------------------------------- live activity
# Two components, animated only in the Loomy screen (elsewhere, only the final lines are printed):
#   ui_wait <label> … ui_wait_end        a "◐ label…  1.2 s" line during a check, then erased
#   ui_steps_begin <title> <step>…       a list of steps announced in advance, with a progress bar:
#     ui_step_run <n>                    step n (from 0) running: spinner and timer
#     ui_step_done <n> <ok|warn|fail|skip> <final label> [detail]
#     ui_steps_end                       final bar and total duration
# The animation runs in a separate process that only redraws its line (and the bar): the work stays in the foreground.
UI_SPIN=("◐" "◓" "◑" "◒"); UI_TICK_PID=""; UI_WAIT_IDX=""
UI_ST_L=(); UI_ST_S=(); UI_ST_D=(); UI_ST_T=(); UI_ST_BASE=-1; UI_ST_T0=0; UI_ST_CUR_T0=0

# _ui_now_ms: timestamp in milliseconds in UI_NOW.
_ui_now_ms() {
  UI_NOW="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null)" || UI_NOW=""
  [[ -n "$UI_NOW" ]] || UI_NOW=$(( $(date +%s) * 1000 ))
}

# _ui_dur <ms>: readable duration in UI_DUR ("0,4 s", "12 s", "1 min 05 s").
_ui_dur() {
  local ms=$1 s
  if (( ms < 10000 )); then UI_DUR="$(( ms / 1000 )),$(( ms % 1000 / 100 )) s"
  elif (( ms < 60000 )); then UI_DUR="$(( ms / 1000 )) s"
  else s=$(( ms / 1000 )); UI_DUR="$(( s / 60 )) min $(printf '%02d' $(( s % 60 ))) s"; fi
}

# _ui_row <icon> <label> <detail> <duration>: aligned step line (label, dimmed detail, duration on the right) in UI_LINE.
_ui_row() {
  local icon="$1" label="$2" detail="$3" dur="$4" lw="${UI_ROW_LW:-30}" dw
  _ui_term_size
  dw=$(( UI_W - 3 - 2 - lw - 9 )); (( dw < 8 )) && dw=8
  _ui_fit "$label" "$lw"; _ui_pad "$UI_FIT" "$lw"; label="$UI_PADDED"
  [[ "${UI_ROW_DIM:-}" == "1" ]] && label="${C_DIM}${label}${C_RESET}"
  _ui_fit "$detail" "$dw"; _ui_pad "$UI_FIT" "$dw"; detail="$UI_PADDED"
  _ui_strlen "$dur"; while (( UI_LEN < 8 )); do dur=" $dur"; UI_LEN=$(( UI_LEN + 1 )); done
  UI_LINE="${C_RAIL}│${C_RESET}  ${icon} ${label}${C_DIM}${detail} ${dur}${C_RESET}"
}

# _ui_bar <done> <total> [finished]: progress bar in UI_LINE.
_ui_bar() {
  local done_n=$1 total=$2 fin="${3:-}" bw fill i on="" off="" pct tail
  _ui_term_size
  bw=$(( UI_W - 3 - 22 )); (( bw < 10 )) && bw=10
  (( total < 1 )) && total=1
  fill=$(( done_n * bw / total )); pct=$(( done_n * 100 / total ))
  for (( i = 0; i < bw; i++ )); do if (( i < fill )); then on="${on}━"; else off="${off}╌"; fi; done
  if [[ -n "$fin" ]]; then tail="${C_GREEN}✓${C_RESET} ${C_DIM}${fin}${C_RESET}"; on="${C_GREEN}${on}${C_RESET}"
  else tail="${C_DIM}${done_n}/${total} · ${pct} %${C_RESET}"; on="${C_BRAND}${on}${C_RESET}"; fi
  UI_LINE="${C_RAIL}│${C_RESET}  ${on}${C_DIM}${off}${C_RESET}  ${tail}"
}

# _ui_screen_row <index>: screen line (from 1) showing UI_PAGE_L[index], or 0 when off screen.
_ui_screen_row() {
  local n=${#UI_PAGE_L[@]} start
  _ui_term_size; _ui_chrome
  start=$(( n - (UI_ROWS - UI_CHROME_H) )); (( start < 0 )) && start=0
  UI_ROW=$(( $1 - start + 1 )); (( UI_ROW < 1 )) && UI_ROW=0
  (( UI_ROW > 0 )) && UI_ROW=$(( UI_ROW + ${#UI_HDR_LINES[@]} ))
  return 0
}

# _ui_tick_start <wait|step>: animates the current line (spinner and timer) until _ui_tick_stop.
_ui_tick_start() {
  [[ "$UI_SCREEN" == "1" ]] || return 0
  local kind="$1"
  (
    trap - EXIT INT TERM
    f=0
    while :; do
      _ui_now_ms
      if [[ "$kind" == "wait" ]]; then
        _ui_dur $(( UI_NOW - UI_WAIT_T0 ))
        _ui_row "${C_BRAND}${UI_SPIN[$f]}${C_RESET}" "${UI_WAIT_LABEL}…" "" "$UI_DUR"; idx=$UI_WAIT_IDX
      else
        _ui_dur $(( UI_NOW - UI_ST_CUR_T0 ))
        _ui_row "${C_BRAND}${UI_SPIN[$f]}${C_RESET}" "${UI_ST_L[$UI_ST_CUR]}…" "" "$UI_DUR"; idx=$(( UI_ST_BASE + 1 + UI_ST_CUR ))
      fi
      _ui_screen_row "$idx"
      (( UI_ROW > 0 )) && printf '\033[%d;1H%s\033[K' "$UI_ROW" "$UI_LINE" >&2
      f=$(( (f + 1) % 4 ))
      sleep 0.12
    done
  ) &
  UI_TICK_PID=$!
  return 0
}

_ui_tick_stop() {
  if [[ -n "$UI_TICK_PID" ]]; then kill "$UI_TICK_PID" 2>/dev/null || true; wait "$UI_TICK_PID" 2>/dev/null || true; UI_TICK_PID=""; fi
  return 0
}

ui_wait() {
  [[ "$UI_SCREEN" == "1" ]] || return 0
  _ui_now_ms; UI_WAIT_T0=$UI_NOW; UI_WAIT_LABEL="$1"
  _ui_row "${C_BRAND}${UI_SPIN[0]}${C_RESET}" "$1…" "" ""
  UI_WAIT_IDX=${#UI_PAGE_L[@]}; UI_PAGE_L[$UI_WAIT_IDX]="$UI_LINE"
  _ui_page_draw
  _ui_tick_start wait
}

ui_wait_end() {
  _ui_tick_stop
  [[ -n "$UI_WAIT_IDX" ]] || return 0
  unset "UI_PAGE_L[$UI_WAIT_IDX]"; UI_WAIT_IDX=""
  return 0
}

# _ui_steps_line <n>: redraws step n's line and the bar in the page.
_ui_steps_paint() {
  local i n=${#UI_ST_L[@]} icon done_n=0 label
  for (( i = 0; i < n; i++ )); do
    label="${UI_ST_L[$i]}"
    case "${UI_ST_S[$i]}" in
      ok) icon="${C_GREEN}✓${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      warn) icon="${C_YELLOW}!${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      fail) icon="${C_RED}✗${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      skip) icon="${C_DIM}–${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      run) icon="${C_BRAND}${UI_SPIN[0]}${C_RESET}"; label="${label}…" ;;
      *) icon="${C_DIM}○${C_RESET}"; UI_ROW_DIM=1 ;;
    esac
    _ui_row "$icon" "$label" "${UI_ST_D[$i]}" "${UI_ST_T[$i]}"; UI_ROW_DIM=""
    UI_PAGE_L[$(( UI_ST_BASE + 1 + i ))]="$UI_LINE"
  done
  UI_ST_DONE=$done_n
  _ui_bar "$done_n" "$n" "${1:-}"
  UI_PAGE_L[$UI_ST_BASE]="$UI_LINE"
}

ui_steps_begin() {
  local title="$1" i; shift
  UI_ST_L=("$@"); UI_ST_S=(); UI_ST_D=(); UI_ST_T=()
  for (( i = 0; i < $#; i++ )); do UI_ST_S[$i]="todo"; UI_ST_D[$i]=""; UI_ST_T[$i]=""; done
  _ui_now_ms; UI_ST_T0=$UI_NOW
  # Label column: just wide enough for the longest (running labels, with "…", or final ones).
  UI_ROW_LW=20
  for (( i = 0; i < $#; i++ )); do _ui_strlen "${UI_ST_L[$i]}…"; (( UI_LEN + 2 > UI_ROW_LW )) && UI_ROW_LW=$(( UI_LEN + 2 )); done
  (( UI_ROW_LW > 32 )) && UI_ROW_LW=32
  ui_section "$title"
  [[ "$UI_SCREEN" == "1" ]] || return 0
  UI_ST_BASE=${#UI_PAGE_L[@]}
  _ui_steps_paint
  _ui_page_draw
}

ui_step_run() {
  UI_ST_CUR=$1; UI_ST_S[$1]="run"
  _ui_now_ms; UI_ST_CUR_T0=$UI_NOW
  [[ "$UI_SCREEN" == "1" ]] || return 0
  _ui_steps_paint; _ui_page_draw
  _ui_tick_start step
}

ui_step_done() {
  local n=$1 st="$2" label="$3" detail="${4:-}" icon
  _ui_tick_stop
  _ui_now_ms; _ui_dur $(( UI_NOW - UI_ST_CUR_T0 ))
  UI_ST_S[$n]="$st"; UI_ST_L[$n]="$label"; UI_ST_D[$n]="$detail"; UI_ST_T[$n]="$UI_DUR"
  [[ "$st" == "skip" ]] && UI_ST_T[$n]=""
  if [[ "$UI_SCREEN" == "1" ]]; then _ui_steps_paint; _ui_page_draw; return 0; fi
  case "$st" in ok) icon="${C_GREEN}✓${C_RESET}" ;; warn) icon="${C_YELLOW}!${C_RESET}" ;; fail) icon="${C_RED}✗${C_RESET}" ;; *) icon="${C_DIM}–${C_RESET}" ;; esac
  printf '%s\n' "${C_RAIL}│${C_RESET}  ${icon} ${label} ${C_DIM}${detail}${C_RESET}" >&2
}

ui_steps_end() {
  _ui_tick_stop
  _ui_now_ms; _ui_dur $(( UI_NOW - UI_ST_T0 ))
  if [[ "$UI_SCREEN" == "1" ]]; then _ui_steps_paint "$(t "done in %s" "$UI_DUR")"; _ui_page_draw; fi
  UI_ST_BASE=-1; UI_ROW_LW=""
  return 0
}

# Subprocess started while a Loomy screen is open: it draws on that same screen.
if [[ -n "${LOOMY_SCREEN_OWNER:-}" && "$LOOMY_SCREEN_OWNER" != "$$" && -z "${LOOMY_NO_CLEAR:-}" ]] && ui_is_interactive; then
  UI_SCREEN=1
  trap '_ui_restore' EXIT
  trap '_ui_restore; exit 130' INT TERM
fi

# ---------------------------------------------------------------- text measuring and splitting
# _ui_strlen <text>: visible width (UTF-8) in UI_LEN, without subprocess when the locale is UTF-8.
_ui_strlen() {
  local probe="é"
  if [[ ${#probe} == 1 ]]; then UI_LEN=${#1}; return 0; fi
  local bytes cont
  bytes="$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')"
  cont="$(printf '%s' "$1" | LC_ALL=C tr -cd '\200-\277' | LC_ALL=C wc -c | tr -d ' ')"
  UI_LEN=$(( bytes - cont ))
}
_ui_len() { _ui_strlen "$1"; echo "$UI_LEN"; }

# _ui_pad <text> <width>: text padded with spaces in UI_PADDED.
_ui_pad() {
  local s="$1"
  _ui_strlen "$s"
  while (( UI_LEN < $2 )); do s="$s "; UI_LEN=$(( UI_LEN + 1 )); done
  UI_PADDED="$s"
}

# _ui_fit <text> <width>: text truncated with "…" when too long, in UI_FIT.
_ui_fit() {
  _ui_strlen "$1"
  if (( UI_LEN <= $2 )); then UI_FIT="$1"; return 0; fi
  # Cuts by characters, whatever the locale (otherwise an accented character may be split in two).
  UI_FIT="$(perl -CSA -Mutf8 -e 'print substr($ARGV[0], 0, $ARGV[1]), "…"' "$1" $(( $2 - 1 )) 2>/dev/null)" || UI_FIT="${1:0:$(( $2 - 1 ))}…"
}

# _ui_wrap <text> <width>: splits into lines (whole words) in the UI_LINES array.
_ui_wrap() {
  local w="$2" line="" word words=()
  UI_LINES=()
  read -r -a words <<<"$1"
  for word in ${words[@]+"${words[@]}"}; do
    # Word longer than the width (a path, a URL): cut into pieces.
    _ui_strlen "$word"
    while (( UI_LEN > w )); do
      [[ -n "$line" ]] && { UI_LINES+=("$line"); line=""; }
      UI_LINES+=("${word:0:$w}"); word="${word:$w}"; _ui_strlen "$word"
    done
    [[ -z "$word" ]] && continue
    if [[ -z "$line" ]]; then line="$word"; continue; fi
    _ui_strlen "$line $word"
    if (( UI_LEN <= w )); then line="$line $word"; else UI_LINES+=("$line"); line="$word"; fi
  done
  if [[ -n "$line" ]]; then UI_LINES+=("$line"); fi
  return 0
}

# _ui_term_size: UI_ROWS, UI_COLS, and usable width UI_W (capped to stay readable).
_ui_term_size() {
  local size
  size="$( { stty size </dev/tty; } 2>/dev/null || true)"
  [[ -z "$size" && -n "${COLUMNS:-}" ]] && size="${LINES:-24} $COLUMNS"
  UI_ROWS="${size%% *}"; UI_COLS="${size##* }"
  # Unknown or zero size (some pseudo-terminals): 80 × 24.
  [[ "$UI_ROWS" =~ ^[0-9]+$ ]] && (( UI_ROWS > 0 )) || UI_ROWS=24
  [[ "$UI_COLS" =~ ^[0-9]+$ ]] && (( UI_COLS > 0 )) || UI_COLS=80
  UI_W=$(( UI_COLS - 2 )); (( UI_W > 78 )) && UI_W=78; (( UI_W < 40 )) && UI_W=40
  return 0
}

# ---------------------------------------------------------------- messages simples
# Logo: the drawing of docs/assets/loomy-*.svg at two thirds (proportions and style kept), in half blocks
# (two pixels per character), on three lines.
# {A} = purple accent (prompt), {C} = cursor (blinks in loomy watch: LOOMY_LOGO_BLINK=off turns it off), {F} = text.
UI_LOGO=(
  '{A}▀▄ {F}    ▀█   ▄▄   ▄▄  ▄▄ ▄  ▄  ▄ {C}▄▄'
  '{A} ▄▀{F}     █  █  █ █  █ █ █ █ ▀▄▄█ {C}██'
  '{A}▀  {F}    ▀▀▀  ▀▀   ▀▀  ▀ ▀ ▀  ▄▄▀ {C}▀▀'
)

# ui_logo_ok: true when the terminal is wide enough for the logo.
ui_logo_ok() { _ui_term_size; (( UI_COLS >= 40 )); }

# _ui_logo_lines <prefix>: coloured logo lines in UI_LINES.
_ui_logo_lines() {
  local l accent="${C_RAIL}" text="${C_BOLD}" cursor="${C_RAIL}"
  # Cursor off: same place, barely visible tint (the logo doesn't move).
  [[ "${LOOMY_LOGO_BLINK:-on}" == "off" && -n "$C_RESET" ]] && cursor=$'\033[38;5;237m'
  UI_LINES=()
  for l in "${UI_LOGO[@]}"; do
    l="${l//\{A\}/${C_RESET}${accent}}"; l="${l//\{C\}/${C_RESET}${cursor}}"; l="${l//\{F\}/${C_RESET}${text}}"
    UI_LINES+=("$1$l${C_RESET}")
  done
  return 0
}

# ui_banner <title> <subtitle>: header of Loomy commands (logo, then opening of the guide line).
ui_banner() {
  local title="$1" subtitle="$2" l
  # In the Loomy screen: the frame header, nothing in the page. Shown in an app view
  # (LOOMY_NO_HEADER): no header at all, the frame already has one.
  if [[ "$UI_SCREEN" == "1" ]]; then ui_header "$title" "$subtitle"; _ui_page_draw; return 0; fi
  [[ -n "${LOOMY_NO_HEADER:-}" ]] && return 0
  ui_print ""
  if ui_logo_ok; then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do ui_print "$l"; done
    ui_print ""
    UI_PAGE_BODY=${#UI_PAGE_L[@]}   # the logo stays on screen, not in the history
    ui_print "${C_RAIL}┌${C_RESET}  ${C_TITLE}${title}${C_RESET}  ${C_DIM}${subtitle}${C_RESET}"
  else
    ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_TITLE}· ${title}${C_RESET}"
    ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}${subtitle}${C_RESET}"
  fi
}

# Command output: a purple guide line, ◇ sections, a closing └ line.
ui_section() { ui_print "${C_RAIL}│${C_RESET}"; ui_print "${C_RAIL}◇${C_RESET}  ${C_TITLE}$1${C_RESET}${2:+  ${C_DIM}$2${C_RESET}}"; }
ui_ok()   { if _ui_form_note ok "$1${2:+ · $2}"; then return 0; fi; ui_print "${C_RAIL}│${C_RESET}  ${C_GREEN}✓${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_warn() { if _ui_form_note warn "$1${2:+ · $2}"; then return 0; fi; ui_print "${C_RAIL}│${C_RESET}  ${C_YELLOW}!${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_err()  { ui_print "${C_RAIL}│${C_RESET}  ${C_RED}✗${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_info() { if _ui_form_note info "$*"; then return 0; fi; ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}→ $*${C_RESET}"; }
ui_end()  { ui_print "${C_RAIL}│${C_RESET}"; ui_print "${C_RAIL}└${C_RESET}  ${C_DIM}$*${C_RESET}"; ui_print ""; }

ui_kv() {
  local w=16
  _ui_strlen "$1"; (( UI_LEN + 2 > w )) && w=$(( UI_LEN + 2 ))
  _ui_pad "$1" "$w"
  ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}${UI_PADDED}${C_RESET}$2"
}

# ---------------------------------------------------------------- guide line (recaps)
# ui_rail_head <text>: opens a new screen (recap…). In the frame: new header and empty body.
ui_rail_head() {
  if [[ "$UI_SCREEN" == "1" ]]; then UI_PAGE_L=(); ui_header "$*" ""; _ui_page_draw; return 0; fi
  ui_print ""; ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_DIM}$*${C_RESET}"; ui_print "${C_RAIL}│${C_RESET}"
}
ui_rail_group() {
  local right="${2:-}"
  _ui_term_size
  _ui_pad "$1" $(( UI_W - 3 - ${#right} ))
  ui_print "${C_RAIL}◇${C_RESET}  ${C_TITLE}${UI_PADDED}${C_RESET}${C_DIM}${right}${C_RESET}"
}
ui_rail_kv() { _ui_pad "$1" 15; ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}${UI_PADDED}${C_RESET}$2"; }
ui_rail() { ui_print "${C_RAIL}│${C_RESET}  $*"; }
ui_rail_end() { ui_print "${C_RAIL}└${C_RESET}  ${C_DIM}$*${C_RESET}"; }

# ---------------------------------------------------------------- lecture du clavier
# _ui_read_key: UI_KEY = up|down|left|right|enter|space|backspace|clear|char|other; UI_CH = typed character.
_ui_read_key() {
  local c="" c2="" c3=""
  UI_CH=""
  IFS= read -rsn1 c </dev/tty || c=""
  if [[ "$c" == $'\033' ]]; then
    IFS= read -rsn1 c2 </dev/tty || c2=""
    if [[ "$c2" == "[" || "$c2" == "O" ]]; then IFS= read -rsn1 c3 </dev/tty || c3=""; fi
    # Long sequences (Del = ESC [ 3 ~): consume the rest.
    if [[ "$c3" =~ ^[0-9]$ ]]; then IFS= read -rsn1 _ </dev/tty || true; fi
    case "$c3" in A) UI_KEY="up" ;; B) UI_KEY="down" ;; C) UI_KEY="right" ;; D) UI_KEY="left" ;; *) UI_KEY="other" ;; esac
    return 0
  fi
  case "$c" in
    ""|$'\n'|$'\r') UI_KEY="enter" ;;
    " ") UI_KEY="space"; UI_CH=" " ;;
    $'\177'|$'\010') UI_KEY="backspace" ;;
    $'\025') UI_KEY="clear" ;;
    $'\t') UI_KEY="other" ;;
    *) if [[ "$c" < " " ]]; then UI_KEY="other"; else UI_KEY="char"; UI_CH="$c"; fi ;;
  esac
  return 0
}

# ---------------------------------------------------------------- form state
UI_FORM_ACTIVE=0; UI_FORM_TITLE=""; UI_GROUPS=(); UI_GROUP=""
UI_STEP_CUR=0; UI_STEP_TOTAL=0
UI_QN=0; UI_QI=0; UI_TARGET=0; UI_BACK=0; UI_MODE="ask"; UI_PREV=""; UI_HAS_PREV=0
UI_RQ=(); UI_RV=()                               # question and answer already given, by position
UI_LOG_G=(); UI_LOG_T=(); UI_LOG_K=(); UI_LOG_V=() # recap of the pass: group, type, label, value

ui_form_begin() {
  UI_FORM_TITLE="$1"; UI_GROUPS=()
  local IFS='|'
  read -r -a UI_GROUPS <<<"$2"
  UI_RQ=(); UI_RV=(); UI_TARGET=0
  ui_is_interactive || return 0
  UI_FORM_ACTIVE=1
  if [[ "$UI_SCREEN" == "1" ]]; then printf '\033[?25l' >&2; ui_header "Questionnaire" "$UI_FORM_TITLE"; else printf '\033[?1049h\033[?25l' >&2; fi
  stty -echo </dev/tty 2>/dev/null || true
  trap '_ui_restore' EXIT
  trap '_ui_restore; exit 130' INT TERM
  return 0
}

ui_form_pass() {
  UI_QN=0; UI_BACK=0; UI_GROUP=""
  UI_LOG_G=(); UI_LOG_T=(); UI_LOG_K=(); UI_LOG_V=()
}

ui_form_again() { [[ "$UI_BACK" == "1" ]]; }

ui_form_end() {
  if [[ "$UI_FORM_ACTIVE" == "1" ]]; then
    if [[ "$UI_SCREEN" == "1" ]]; then printf '\033[?25h' >&2; _ui_page_draw; else printf '\033[?25h\033[?1049l' >&2; fi
    stty echo </dev/tty 2>/dev/null || true
  fi
  UI_FORM_ACTIVE=0
  [[ "$UI_SCREEN" == "1" ]] || trap - INT TERM
  return 0
}

ui_group() { UI_GROUP="$1"; }

# ui_fact <label> <value>: result derived from the answers (risk, routing…), shown with its group.
ui_fact() {
  if [[ "$UI_FORM_ACTIVE" == "1" ]]; then
    [[ "$UI_BACK" == "1" ]] || _ui_log fact "$1" "$2"
  elif ui_is_interactive; then
    ui_info "$1 : $2"
  fi
  return 0
}
ui_step() { UI_STEP_CUR="$1"; UI_STEP_TOTAL="$2"; }

# _ui_log <type> <label> <value>
_ui_log() {
  UI_LOG_G+=("$UI_GROUP"); UI_LOG_T+=("$1"); UI_LOG_K+=("$2"); UI_LOG_V+=("$3")
}

# During the form, messages become notes of the current group instead of being printed.
_ui_form_note() {
  [[ "$UI_FORM_ACTIVE" == "1" ]] || return 1
  [[ "$UI_BACK" == "1" ]] || _ui_log "$1" "" "$2"
  return 0
}

_ui_reset_ctx() { UI_HINT=""; UI_DESCS=(); UI_LABEL=""; }

# _ui_q_begin <question>: decides whether the question is asked, replayed or skipped (after ←).
_ui_q_begin() {
  UI_QI=$UI_QN; UI_QN=$(( UI_QN + 1 )); UI_INLINE_N=0
  UI_HAS_PREV=0; UI_PREV=""
  if [[ "${UI_RQ[$UI_QI]+set}" == "set" && "${UI_RQ[$UI_QI]}" == "$1" ]]; then UI_HAS_PREV=1; UI_PREV="${UI_RV[$UI_QI]}"; fi
  if [[ "$UI_FORM_ACTIVE" != "1" ]]; then UI_MODE="ask"
  elif [[ "$UI_BACK" == "1" ]]; then UI_MODE="skip"
  elif (( UI_QI < UI_TARGET && UI_HAS_PREV )); then UI_MODE="replay"
  else UI_MODE="ask"; fi
  return 0
}

# _ui_q_end <question>: stores and records the answer (or schedules going back).
_ui_q_end() {
  local label="${UI_LABEL:-$1}"
  label="${label% ?}"; label="${label%\?}"
  if [[ "$UI_KEY" == "back" ]]; then
    UI_BACK=1; UI_TARGET=$(( UI_QI - 1 ))
  elif [[ "$UI_FORM_ACTIVE" == "1" && "$UI_MODE" != "skip" ]]; then
    UI_RQ[$UI_QI]="$1"; UI_RV[$UI_QI]="$UI_VALUE"
    _ui_log answer "$label" "${UI_VALUE% ($(t "recommended"))}"
  fi
  _ui_reset_ctx
  UI_FTR_KEYS=""
  return 0
}

ui_can_go_back() { [[ "$UI_FORM_ACTIVE" == "1" ]] && (( UI_QI > 0 )); }

# ---------------------------------------------------------------- dessin
UI_FRAME=""; UI_FRAME_N=0; UI_INLINE_N=0
_ui_add() { UI_FRAME="${UI_FRAME}$1"$'\033[K\n'; UI_FRAME_N=$(( UI_FRAME_N + 1 )); }
_ui_r() { _ui_add "${C_RAIL}│${C_RESET}  $1"; }

# _ui_static <question>: fixed part of the screen (header, groups, card), adapted to the terminal height.
# Sets UI_STATIC / UI_STATIC_N. <reserved> = lines of the variable part (options, box, footer).
_ui_static() {
  local q="$1" reserved="$2" level g i vals line text bar_on bar_off done_n
  local cw=$(( UI_W - 3 ))
  local pass logo
  for pass in 0 1 2 3 4; do
    # Pass 0: with the logo; then without logo and more and more compact if the terminal is short.
    logo=0; level=$(( pass - 1 )); if (( pass == 0 )); then logo=1; level=0; fi
    UI_FRAME=""; UI_FRAME_N=0
    if [[ "$UI_FORM_ACTIVE" == "1" ]]; then
      # Loomy screen: logo and title are in the frame header; otherwise, at the top of the questionnaire.
      if [[ "$UI_SCREEN" == "1" ]]; then _ui_add "${C_RAIL}│${C_RESET}"
      elif (( logo )) && (( UI_COLS >= 40 )); then
        _ui_logo_lines " "
        for line in "${UI_LINES[@]}"; do _ui_add "$line"; done
        _ui_add ""
        _ui_add "${C_RAIL}┌${C_RESET}  ${C_DIM}${UI_FORM_TITLE}${C_RESET}"
        _ui_add "${C_RAIL}│${C_RESET}"
      else
        _ui_add "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_DIM}${UI_FORM_TITLE}${C_RESET}"
        _ui_add "${C_RAIL}│${C_RESET}"
      fi
      # Finished groups: one line each.
      if (( level < 3 )); then
        for g in ${UI_GROUPS[@]+"${UI_GROUPS[@]}"}; do
          [[ "$g" == "$UI_GROUP" ]] && break
          vals=""
          for (( i = 0; i < ${#UI_LOG_G[@]}; i++ )); do
            [[ "${UI_LOG_G[$i]}" == "$g" && -n "${UI_LOG_V[$i]}" ]] || continue
            case "${UI_LOG_T[$i]}" in answer|fact) vals="${vals:+$vals · }${UI_LOG_V[$i]}" ;; esac
          done
          [[ -z "$vals" ]] && continue
          _ui_pad "$g" 11; _ui_fit "$vals" $(( cw - 13 ))
          _ui_add "${C_RAIL}◇${C_RESET}  ${C_DIM}${UI_PADDED}${C_RESET}  ${C_DIM}${UI_FIT}${C_RESET}"
        done
      fi
      # Current group: title and progress.
      if [[ -n "$UI_GROUP" ]]; then
        text=""; bar_on=""; bar_off=""
        if (( UI_STEP_TOTAL > 0 )); then
          done_n=$(( UI_STEP_CUR * 12 / UI_STEP_TOTAL ))
          for (( i = 0; i < 12; i++ )); do if (( i < done_n )); then bar_on="${bar_on}━"; else bar_off="${bar_off}╌"; fi; done
          text="$(t "question %s/%s" "$UI_STEP_CUR" "$UI_STEP_TOTAL")  "
        fi
        _ui_strlen "$text$bar_on$bar_off"; _ui_pad "$UI_GROUP" $(( cw - UI_LEN ))
        _ui_add "${C_RAIL}◇${C_RESET}  ${C_TITLE}${UI_PADDED}${C_RESET}${C_DIM}${text}${C_RESET}${C_RAIL}${bar_on}${C_RESET}${C_DIM}${bar_off}${C_RESET}"
        if (( level == 0 )); then
          for (( i = 0; i < ${#UI_LOG_G[@]}; i++ )); do
            [[ "${UI_LOG_G[$i]}" == "$UI_GROUP" ]] || continue
            case "${UI_LOG_T[$i]}" in
              answer) _ui_pad "${UI_LOG_K[$i]}" 18; _ui_fit "${UI_LOG_V[$i]:-—}" $(( cw - 22 ))
                      _ui_r "${C_GREEN}✓${C_RESET} ${C_DIM}${UI_PADDED}${C_RESET}${UI_FIT}" ;;
              fact)   _ui_pad "${UI_LOG_K[$i]}" 18; _ui_fit "${UI_LOG_V[$i]}" $(( cw - 22 ))
                      _ui_r "${C_RAIL}◦${C_RESET} ${C_DIM}${UI_PADDED}${UI_FIT}${C_RESET}" ;;
              warn)   _ui_fit "${UI_LOG_V[$i]}" $(( cw - 2 )); _ui_r "${C_YELLOW}!${C_RESET} ${C_DIM}${UI_FIT}${C_RESET}" ;;
              *)      _ui_fit "${UI_LOG_V[$i]}" $(( cw - 2 )); _ui_r "${C_DIM}→ ${UI_FIT}${C_RESET}" ;;
            esac
          done
        elif (( level < 3 )); then
          vals=""
          for (( i = 0; i < ${#UI_LOG_G[@]}; i++ )); do
            [[ "${UI_LOG_G[$i]}" == "$UI_GROUP" && -n "${UI_LOG_V[$i]}" ]] || continue
            case "${UI_LOG_T[$i]}" in answer|fact) vals="${vals:+$vals · }${UI_LOG_V[$i]}" ;; esac
          done
          if [[ -n "$vals" ]]; then _ui_fit "$vals" $(( cw - 2 )); _ui_r "${C_GREEN}✓${C_RESET} ${C_DIM}${UI_FIT}${C_RESET}"; fi
        fi
      fi
      _ui_add "${C_RAIL}│${C_RESET}"
    fi
    # Question card.
    _ui_wrap "$q" $(( cw ))
    line="${UI_LINES[0]:-$q}"
    _ui_add "${C_RAIL}◆${C_RESET}  ${C_BOLD}${line}${C_RESET}"
    for (( i = 1; i < ${#UI_LINES[@]}; i++ )); do _ui_r "${C_BOLD}${UI_LINES[$i]}${C_RESET}"; done
    if [[ -n "$UI_HINT" ]]; then
      _ui_wrap "$UI_HINT" "$cw"
      for (( i = 0; i < ${#UI_LINES[@]}; i++ )); do
        if (( level == 3 && i >= 1 )); then break; fi
        _ui_r "${C_DIM}${UI_LINES[$i]}${C_RESET}"
      done
    fi
    _ui_add "${C_RAIL}│${C_RESET}"
    local room=$(( UI_ROWS - 1 )); [[ "$UI_SCREEN" == "1" ]] && { _ui_chrome; room=$(( UI_ROWS - UI_CHROME_H )); }
    if [[ "$UI_FORM_ACTIVE" != "1" ]] || (( UI_FRAME_N + reserved <= room )); then break; fi
    if (( pass == 0 && UI_COLS < 50 )); then continue; fi
  done
  UI_STATIC="$UI_FRAME"; UI_STATIC_N=$UI_FRAME_N
}

# _ui_boxes <width>: precomputed consequence boxes, one per option (UI_BOX_0…), common height UI_BOX_H.
_ui_boxes() {
  local cw="$1" n=${#UI_DESCS[@]} i j inner title rule body
  UI_BOX_H=0; UI_BOXES=()
  (( n == 0 )) && return 0
  inner=$(( cw - 4 ))
  for (( i = 0; i < n; i++ )); do
    _ui_wrap "${UI_DESCS[$i]}" "$inner"
    (( ${#UI_LINES[@]} > UI_BOX_H )) && UI_BOX_H=${#UI_LINES[@]}
  done
  (( UI_BOX_H == 0 )) && return 0
  (( UI_BOX_H > 5 )) && UI_BOX_H=5
  title="─ $(t "What it means") "
  _ui_strlen "$title"
  rule="$(printf '%*s' $(( cw - 2 - UI_LEN )) '' | sed 's/ /─/g')"
  UI_BOX_TOP="${C_BOX}╭${title}${rule}╮${C_RESET}"
  UI_BOX_BOTTOM="${C_BOX}╰$(printf '%*s' $(( cw - 2 )) '' | sed 's/ /─/g')╯${C_RESET}"
  for (( i = 0; i < n; i++ )); do
    _ui_wrap "${UI_DESCS[$i]}" "$inner"
    body=""
    for (( j = 0; j < UI_BOX_H; j++ )); do
      _ui_pad "${UI_LINES[$j]:-}" "$inner"
      body="${body}${C_BOX}│${C_RESET} ${UI_PADDED} ${C_BOX}│${C_RESET}"$'\n'
    done
    UI_BOXES[$i]="$body"
  done
  return 0
}

# _ui_render: prints UI_STATIC + UI_FRAME (variable part), full screen or in place.
_ui_render() {
  if [[ "$UI_FORM_ACTIVE" == "1" && "$UI_SCREEN" == "1" ]]; then
    # Questionnaire in the frame: the body only shows the question (the page is hidden during the form).
    local saved=(${UI_PAGE_L[@]+"${UI_PAGE_L[@]}"}); UI_PAGE_L=()
    _ui_page_draw 0 "$UI_STATIC$UI_FRAME"
    UI_PAGE_L=(${saved[@]+"${saved[@]}"})
  elif [[ "$UI_FORM_ACTIVE" == "1" ]]; then
    printf '\033[H%s%s\033[J' "$UI_STATIC" "$UI_FRAME" >&2
  else
    if [[ "$UI_SCREEN" == "1" ]]; then _ui_page_draw $(( UI_STATIC_N + UI_FRAME_N )) "$UI_STATIC$UI_FRAME"; return 0; fi
    if (( UI_INLINE_N > 0 )); then printf '\033[%dA' "$UI_INLINE_N" >&2; fi
    printf '%s%s\033[J' "$UI_STATIC" "$UI_FRAME" >&2
    UI_INLINE_N=$(( UI_STATIC_N + UI_FRAME_N ))
  fi
}

# _ui_inline_done <question>: outside a form, replaces the card with an answer line.
_ui_inline_done() {
  [[ "$UI_FORM_ACTIVE" == "1" ]] && return 0
  if (( UI_INLINE_N > 0 )); then printf '\033[%dA\033[J' "$UI_INLINE_N" >&2; fi
  UI_INLINE_N=0
  local label="${UI_LABEL:-$1}"
  ui_print "${C_RAIL}◇${C_RESET}  ${C_DIM}${label}${C_RESET}  ${C_BOLD}${UI_VALUE:-—}${C_RESET}"
}

# Outside a form, the cursor is hidden during the question: it is restored even on interruption.
# Terminal echo is off during a question: fast typing, arriving between two reads, doesn't print in a mess.
_ui_hide_cursor() {
  printf '\033[?25l' >&2
  stty -echo </dev/tty 2>/dev/null || true
  if [[ "$UI_FORM_ACTIVE" != "1" ]]; then trap '_ui_restore' EXIT; fi
  return 0
}
_ui_show_cursor() { printf '\033[?25h' >&2; [[ "$UI_FORM_ACTIVE" == "1" ]] || stty echo </dev/tty 2>/dev/null || true; return 0; }

_ui_footer() {
  local keys="$1"
  if ui_can_go_back; then keys="$keys   ← $(t "previous question")"; fi
  # Loomy screen: the keys go in the frame footer.
  if [[ "$UI_SCREEN" == "1" ]]; then UI_FTR_KEYS="$keys"; return 0; fi
  _ui_add "${C_RAIL}└${C_RESET}  ${C_DIM}${keys}${C_RESET}"
}

_ui_upcoming() {
  local g seen=0 next=""
  [[ "$UI_FORM_ACTIVE" == "1" ]] || return 0
  for g in ${UI_GROUPS[@]+"${UI_GROUPS[@]}"}; do
    if (( seen )); then next="${next:+$next · }$g"; fi
    [[ "$g" == "$UI_GROUP" ]] && seen=1
  done
  if [[ -n "$next" ]]; then _ui_r "${C_DIM}$(t "next:") ${next}${C_RESET}"; fi
  return 0
}

# ---------------------------------------------------------------- questions
# ui_input <question> <default> [placeholder]
ui_input() {
  local q="$1" def="$2" ph="${3:-}" buf="" shown
  _ui_q_begin "$q"
  if ! ui_is_interactive || [[ "$UI_MODE" == "skip" ]]; then UI_VALUE="$def"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if [[ "$UI_MODE" == "replay" ]]; then UI_VALUE="$UI_PREV"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  (( UI_HAS_PREV )) && def="$UI_PREV"
  _ui_term_size
  _ui_static "$q" 4
  _ui_hide_cursor
  while true; do
    UI_FRAME=""; UI_FRAME_N=0
    if [[ -n "$buf" ]]; then shown="${C_BOLD}${buf}${C_RESET}${C_RAIL}▌${C_RESET}"
    elif [[ -n "$def" ]]; then shown="${C_RAIL}▌${C_RESET}${C_DIM}${def}  ($(t "default"))${C_RESET}"
    else shown="${C_RAIL}▌${C_RESET}${C_DIM}${ph}${C_RESET}"; fi
    _ui_r "${C_RAIL}›${C_RESET} ${shown}"
    _ui_add "${C_RAIL}│${C_RESET}"
    _ui_upcoming
    _ui_footer "$(t "⏎ confirm   ⌫ clear")"
    _ui_render
    _ui_read_key
    case "$UI_KEY" in
      enter) break ;;
      char|space) buf="${buf}${UI_CH}" ;;
      backspace) buf="${buf%?}" ;;
      clear) buf="" ;;
      left) if ui_can_go_back; then UI_KEY="back"; break; fi ;;
    esac
  done
  _ui_show_cursor
  # Extra spaces at the start and end removed.
  buf="${buf#"${buf%%[![:space:]]*}"}"; buf="${buf%"${buf##*[![:space:]]}"}"
  UI_VALUE="${buf:-$def}"
  _ui_inline_done "$q"
  _ui_q_end "$q"
}

# ui_choose <question> <default-index (from 0)> <option>...
ui_choose() {
  local q="$1" def="$2"; shift 2
  local opts=("$@") n=$# i sel mark cw line
  _ui_q_begin "$q"
  UI_INDEX="$def"
  if ! ui_is_interactive || [[ "$UI_MODE" == "skip" ]]; then UI_VALUE="${opts[$def]}"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if [[ "$UI_MODE" == "replay" ]]; then
    UI_VALUE="$UI_PREV"
    for (( i = 0; i < n; i++ )); do [[ "${opts[$i]}" == "$UI_PREV" ]] && UI_INDEX=$i; done
    UI_KEY=""; _ui_q_end "$q"; return 0
  fi
  sel="$def"
  if (( UI_HAS_PREV )); then for (( i = 0; i < n; i++ )); do [[ "${opts[$i]}" == "$UI_PREV" ]] && sel=$i; done; fi
  _ui_term_size; cw=$(( UI_W - 3 ))
  _ui_boxes "$cw"
  # "Quit" or "Cancel" option: the q key picks it directly.
  local quit_i=""
  for (( i = 0; i < n; i++ )); do case "${opts[$i]}" in Quitter|Annuler|Quit|Cancel) quit_i=$i ;; esac; done
  _ui_static "$q" $(( n + (UI_BOX_H > 0 ? UI_BOX_H + 3 : 0) + 3 ))
  _ui_hide_cursor
  while true; do
    UI_FRAME=""; UI_FRAME_N=0
    for (( i = 0; i < n; i++ )); do
      mark=""; if (( i == def && n > 1 )) && [[ "${opts[$i]}" != *"($(t "recommended"))"* ]]; then mark="  ${C_DIM}($(t "default"))${C_RESET}"; fi
      _ui_fit "${opts[$i]}" $(( cw - 18 ))
      if (( i == sel )); then _ui_r "${C_RAIL}❯ ●${C_RESET} ${C_BOLD}${UI_FIT}${C_RESET}${mark}"
      else _ui_r "  ${C_DIM}○${C_RESET} ${UI_FIT}${mark}"; fi
    done
    if (( UI_BOX_H > 0 )); then
      _ui_add "${C_RAIL}│${C_RESET}"
      _ui_r "$UI_BOX_TOP"
      while IFS= read -r line; do _ui_r "$line"; done <<<"${UI_BOXES[$sel]%$'\n'}"
      _ui_r "$UI_BOX_BOTTOM"
    fi
    _ui_add "${C_RAIL}│${C_RESET}"
    _ui_upcoming
    _ui_footer "$(t "↑↓ choose   ⏎ confirm   s default")${quit_i:+   q ${opts[$quit_i]}}"
    _ui_render
    _ui_read_key
    case "$UI_KEY" in
      up) sel=$(( (sel - 1 + n) % n )) ;;
      down) sel=$(( (sel + 1) % n )) ;;
      char) case "$UI_CH" in k) sel=$(( (sel - 1 + n) % n )) ;; j) sel=$(( (sel + 1) % n )) ;; s) sel="$def"; break ;;
              q|Q) if [[ -n "$quit_i" ]]; then sel=$quit_i; break; fi ;; esac ;;
      enter) break ;;
      left) if ui_can_go_back; then UI_KEY="back"; break; fi ;;
    esac
  done
  _ui_show_cursor
  UI_VALUE="${opts[$sel]}"; UI_INDEX=$sel   # UI_INDEX: rank of the chosen option, language-independent
  _ui_inline_done "$q"
  _ui_q_end "$q"
}

# ui_multi <question> <options checked by default, comma separated> <option>...
# UI_VALUE: checked options separated by ", " (empty when none).
ui_multi() {
  local q="$1" defs="$2"; shift 2
  local opts=("$@") n=$# i cur=0 out="" on=() box cw line
  for (( i = 0; i < n; i++ )); do
    case ",$defs," in *",${opts[$i]},"*) on[$i]=1 ;; *) on[$i]=0 ;; esac
  done
  _ui_q_begin "$q"
  if ! ui_is_interactive || [[ "$UI_MODE" == "skip" ]]; then UI_VALUE="${defs//,/, }"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if [[ "$UI_MODE" == "replay" ]]; then UI_VALUE="$UI_PREV"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if (( UI_HAS_PREV )); then
    for (( i = 0; i < n; i++ )); do case ", $UI_PREV," in *", ${opts[$i]},"*) on[$i]=1 ;; *) on[$i]=0 ;; esac; done
  fi
  _ui_term_size; cw=$(( UI_W - 3 ))
  _ui_boxes "$cw"
  _ui_static "$q" $(( n + (UI_BOX_H > 0 ? UI_BOX_H + 3 : 0) + 3 ))
  _ui_hide_cursor
  while true; do
    UI_FRAME=""; UI_FRAME_N=0
    for (( i = 0; i < n; i++ )); do
      if [[ "${on[$i]}" == "1" ]]; then box="${C_GREEN}◼${C_RESET}"; else box="${C_DIM}◻${C_RESET}"; fi
      _ui_fit "${opts[$i]}" $(( cw - 6 ))
      if (( i == cur )); then _ui_r "${C_RAIL}❯${C_RESET} ${box} ${C_BOLD}${UI_FIT}${C_RESET}"
      else _ui_r "  ${box} ${UI_FIT}"; fi
    done
    if (( UI_BOX_H > 0 )); then
      _ui_add "${C_RAIL}│${C_RESET}"
      _ui_r "$UI_BOX_TOP"
      while IFS= read -r line; do _ui_r "$line"; done <<<"${UI_BOXES[$cur]%$'\n'}"
      _ui_r "$UI_BOX_BOTTOM"
    fi
    _ui_add "${C_RAIL}│${C_RESET}"
    _ui_upcoming
    _ui_footer "$(t "↑↓ choose   space toggle   ⏎ confirm")"
    _ui_render
    _ui_read_key
    case "$UI_KEY" in
      up) cur=$(( (cur - 1 + n) % n )) ;;
      down) cur=$(( (cur + 1) % n )) ;;
      char) case "$UI_CH" in k) cur=$(( (cur - 1 + n) % n )) ;; j) cur=$(( (cur + 1) % n )) ;; x) if [[ "${on[$cur]}" == "1" ]]; then on[$cur]=0; else on[$cur]=1; fi ;; esac ;;
      space) if [[ "${on[$cur]}" == "1" ]]; then on[$cur]=0; else on[$cur]=1; fi ;;
      enter) break ;;
      left) if ui_can_go_back; then UI_KEY="back"; break; fi ;;
    esac
  done
  _ui_show_cursor
  for (( i = 0; i < n; i++ )); do
    [[ "${on[$i]}" == "1" ]] && out="${out:+$out, }${opts[$i]}"
  done
  UI_VALUE="$out"
  _ui_inline_done "$q"
  _ui_q_end "$q"
}

# ui_copy <text>: copies to the clipboard when a clipboard tool exists. Returns 0 on success.
ui_copy() {
  if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$1" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
  else return 1
  fi
}
