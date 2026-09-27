#!/usr/bin/env bash
# Project and bootstrap status for Loomy. Bash 3.2 compatible.
#   ai-status.sh                 prints the status
#   ai-status.sh set <phase>     records the current bootstrap phase (used by the agents)
#   ai-status.sh --watch [N]     refreshes every N seconds (1 by default); q c l s (see the footer)
#   --compact / --full           tight view (for a narrow pane) or full view; watch picks one from the terminal size
#   ai-status.sh --root <dir>    works on another project folder
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=lib/privacy.sh
source "$SCRIPT_DIR/lib/privacy.sh"

PHASES="brief discover interview propose approve build verify document commit retire done"

ROOT=""
CMD="show"
PHASE_ARG=""
WATCH=0
INTERVAL=1
COMPACT=""
JOURNAL_VIEW=0
UNTIL=""
IN_PANE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --watch|-w) WATCH=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then INTERVAL="$2"; shift; fi ;;
    --compact) COMPACT=1 ;;
    --journal) JOURNAL_VIEW=1 ;;
    --until-exit) UNTIL="${2:-}"; shift ;;
    --pane) IN_PANE=1 ;;
    --full) COMPACT=0 ;;
    set) CMD="set"; PHASE_ARG="${2:-}"; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$ROOT" ]]; then
  if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then
    ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
  else
    ROOT="$(ai_project_root)"
  fi
fi
ROOT="$(cd "$ROOT" && pwd)"
STATE="$ROOT/.loomy/state"
BRIEF="$ROOT/.loomy/brief.md"

if [[ "$CMD" == "set" ]]; then
  case " $PHASES " in
    *" $PHASE_ARG "*) ;;
    *) t "Unknown phase: \"%s\". Phases: %s" "$PHASE_ARG" "$PHASES" >&2; echo >&2; exit 2 ;;
  esac
  mkdir -p "$ROOT/.loomy"
  now="$(date '+%Y-%m-%d %H:%M')"
  history=""
  [[ -f "$STATE" ]] && history="$(grep '^log=' "$STATE" || true)"
  {
    echo "phase=$PHASE_ARG"
    echo "updated=$now"
    [[ -n "$history" ]] && echo "$history"
    echo "log=$now $PHASE_ARG"
  } >"$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  ai_journal_write "$ROOT" "\"type\":\"phase\",\"phase\":\"$PHASE_ARG\""
  t "Phase recorded: %s (%s)" "$(loomy_phase_label "$PHASE_ARG")" "$PHASE_ARG"; echo
  exit 0
fi

brief_get() {
  _ai_brief_get "$BRIEF" "$1"
}

label_of() {
  case "$1" in
    web) t "Web app / SaaS"; echo ;; api) t "API / backend"; echo ;; mobile) t "Mobile app"; echo ;;
    desktop) t "Desktop app"; echo ;; cli) t "CLI / library"; echo ;; ai) t "AI / LLM app"; echo ;;
    prototype) t "Prototype"; echo ;; other) t "Other"; echo ;; mvp) t "MVP"; echo ;; production) t "Production"; echo ;;
    econome) t "Thrifty"; echo ;; equilibre) t "Balanced"; echo ;; qualite) t "Max quality"; echo ;;
    codex) t "Codex"; echo ;; claude) t "Claude Code"; echo ;;
    yes) t "yes"; echo ;; no) t "no"; echo ;; "") echo "?" ;; *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- mode surveillance
# Full screen, redrawn in place every second (nothing piles up in the history). Between two frames, tracking
# spots what changes (phase, delegation finished or failed, session closed): it highlights it for a few
# seconds and notifies (macOS) with a beep. Keys: q quit, c compact/full view,
# l log, s open the session.
watch_notify() {
  [[ "$(loomy_config_get notify 2>/dev/null || true)" == "no" ]] && return 0
  printf '\a' >&2
  if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    local t="${1//\"/\'}" m="${2//\"/\'}"
    osascript -e "display notification \"$m\" with title \"Loomy · ${NAME_W//\"/\'}\" subtitle \"$t\"" >/dev/null 2>&1 &
  fi
  return 0
}

if (( WATCH )); then
  ui_screen_begin
  trap 'UI_PAGE_L=(); _ui_restore; exit 0' INT TERM
  printf '\033[?25l' >&2
  stty -echo </dev/tty 2>/dev/null || true
  NAME_W="$(brief_get name 2>/dev/null || basename "$ROOT")"
  J="$(ai_journal_file "$ROOT")"
  tick=0; wtop=0; view="status"; first=1; hl_phase=0; hl_deleg_until=0; hl_deleg_n=0
  p_phase=""; p_done=0; p_err=0; p_sess=""
  while true; do
    now="$(date +%s)"
    # ---- what changed since the previous frame
    phase="$(sed -n 's/^phase=//p' "$STATE" 2>/dev/null | head -1 || true)"
    n_done=0; n_err=0
    if [[ -s "$J" ]]; then
      read -r n_done n_err <<<"$(awk 'index($0, "\"type\":\"delegation\",") { n++; if (index($0, "\"status\":\"ok\"") == 0) e++ } END { print n + 0, e + 0 }' "$J")"
    fi
    sess="$(ai_session_state "$ROOT" 2>/dev/null || true)"; sess="${sess%%|*}"
    if (( ! first )); then
      if [[ "$phase" != "$p_phase" && -n "$phase" ]]; then
        hl_phase=$(( now + 8 ))
        if [[ "$phase" == "done" ]]; then watch_notify "✦ $(t "Project ready")" "$(t "Bootstrap done: what comes next happens with the lead agent (loomy start).")"
        else watch_notify "Phase $(loomy_phase_index "$phase")/10 · $(loomy_phase_label "$phase")" "$(loomy_you_now "$phase" "$(ai_session_state "$ROOT" 2>/dev/null || true)")"; fi
      fi
      if (( n_done > p_done )); then hl_deleg_n=$(( n_done - p_done )); hl_deleg_until=$(( now + 8 )); fi
      if (( n_err > p_err )); then watch_notify "$(t "Delegation failed")" "$(t "See the details in loomy watch (key l) or loomy log.")"; fi
      if [[ "$p_sess" == "open" && "$sess" == "closed" && "$phase" != "done" ]]; then
        watch_notify "$(t "Lead agent session closed")" "$(t "Bootstrap in progress: loomy start to resume it.")"
      fi
    fi
    first=0; p_phase="$phase"; p_done=$n_done; p_err=$n_err; p_sess="$sess"
    # ---- image
    _ui_term_size; size="--full"
    if [[ "$COMPACT" == "1" ]] || { [[ -z "$COMPACT" ]] && (( UI_ROWS < 40 || UI_COLS < 90 )); }; then size="--compact"; fi
    keys="q $(t "quit") · c $( [[ "$size" == "--compact" ]] && t "full view" || t "compact view") · l $( [[ "$view" == "log" ]] && t "status" || t "log")"
    [[ -z "$UNTIL" ]] && (( ! IN_PANE )) && keys="$keys · s $(t "session")"
    hl_d=0; (( now < hl_deleg_until )) && hl_d=$hl_deleg_n
    hl_p=0; (( now < hl_phase )) && hl_p=1
    extra=(); [[ "$view" == "log" ]] && extra=(--journal)
    frame="$(LOOMY_NO_CLEAR=1 LOOMY_NO_HEADER=1 LOOMY_FORCE_COLOR=1 LOOMY_TICK=$tick LOOMY_HL_DELEG=$hl_d LOOMY_HL_PHASE=$hl_p \
      "$0" --root "$ROOT" "$size" ${extra[@]+"${extra[@]}"} 2>&1)" || true
    # Each line is cut to the terminal width ("…"), colour sequences included: no line wrap,
    # even in a terminal that ignores turning off automatic wrap.
    frame="$(printf '%s\n' "$frame" | ui_clip "$(( UI_COLS - 1 ))")"
    UI_PAGE_L=()
    while IFS= read -r line; do UI_PAGE_L[${#UI_PAGE_L[@]}]="$line"; done <<<"$frame"
    if [[ "$UI_SCREEN" == "1" ]]; then
      # App frame: header (project, time), body shown from the top (↑↓ to scroll), footer (keys).
      ui_header "$NAME_W" "$(t "live tracking") · $(date '+%H:%M:%S')"
      LOOMY_LOGO_BLINK=$( (( tick % 2 )) && echo off || echo on)
      _ui_term_size; _ui_chrome
      (( ${#UI_PAGE_L[@]} > UI_ROWS - UI_CHROME_H )) && keys="↑↓ $(t "scroll") · $keys"
      UI_FTR_KEYS="$keys"; UI_BODY_TOP=$wtop
      _ui_page_draw; wtop=$UI_BODY_START
    else
      printf '%s\n' "$frame" >&2
    fi
    tick=$(( tick + 1 ))
    key=""
    if [[ -t 0 ]]; then read -rsn1 -t "$INTERVAL" key </dev/tty || true; else sleep "$INTERVAL"; fi
    # Arrows (ESC [ A / B sequence): body scrolling.
    if [[ "$key" == $'\033' ]]; then
      k3=""; read -rsn1 -t 1 _ </dev/tty || true; read -rsn1 -t 1 k3 </dev/tty || true
      case "$k3" in A) wtop=$(( wtop - 1 )) ;; B) wtop=$(( wtop + 1 )) ;; esac
      (( wtop < 0 )) && wtop=0
    fi
    case "$key" in
      q|Q) break ;;
      c|C) if [[ "$size" == "--compact" ]]; then COMPACT=0; else COMPACT=1; fi ;;
      l|L) if [[ "$view" == "log" ]]; then view="status"; else view="log"; fi ;;
      s|S) [[ -z "$UNTIL" ]] && (( ! IN_PANE )) && { UI_PAGE_L=(); ui_exec bash "$SCRIPT_DIR/ai-start.sh" --root "$ROOT"; } ;;
    esac
    # Tracking opened by loomy start --watch: it closes with the agent session.
    [[ -n "$UNTIL" ]] && ! kill -0 "$UNTIL" 2>/dev/null && break
  done
  UI_PAGE_L=()
  exit 0
fi

# ---------------------------------------------------------------- header
# Direct command: the status prints normally (like git status), without full screen.
# In loomy watch, the header and footer are the app frame's (LOOMY_NO_HEADER).
if [[ -n "${LOOMY_NO_HEADER:-}" ]]; then :
elif [[ "$COMPACT" == "1" ]]; then
  # Compact view: the logo too (without blank lines around it), if the terminal is wide enough.
  if ui_logo_ok; then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do ui_print "$l"; done
    ui_print ""
    ui_print "${C_RAIL}┌${C_RESET}  ${C_TITLE}$(brief_get name 2>/dev/null || true)${C_RESET}  ${C_DIM}${ROOT/#$HOME/~}${C_RESET}"
  else
    ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}loomy${C_RESET} ${C_TITLE}$(brief_get name 2>/dev/null || true)${C_RESET}  ${C_DIM}${ROOT/#$HOME/~}${C_RESET}"
  fi
else
  ui_banner "$(t "Project status")" "${C_RESET}${C_TITLE}$(brief_get name 2>/dev/null || basename "$ROOT")${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
fi
# Loomy version copied into the project, compared with the installed one (unless this script is itself the project copy).
proj_v="$(cat "$ROOT/.loomy/VERSION" 2>/dev/null || true)"; inst_v="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || true)"
# Since 0.3, the project only has relays to the installed Loomy: nothing to do on each version.
if [[ -d "$ROOT/.loomy/scripts/lib" ]]; then
  ui_warn "$(t "Loomy scripts copied into this project (before 0.3)")" "$(t "once and for all: loomy init --update")"
elif [[ -n "$proj_v" && -n "$inst_v" ]] && ! ai_version_ge "$inst_v" "$proj_v"; then
  ui_warn "$(t "Loomy %s installed, older than this project (%s)" "$inst_v" "$proj_v")" "loomy update"
fi

# ---------------------------------------------------------------- vue journal (touche l de loomy watch)
if (( JOURNAL_VIEW )); then
  ui_section "$(t "LOG")" "$(t "latest events, local time")"
  _ui_term_size
  jn=$(( UI_ROWS - 9 )); (( jn < 5 )) && jn=5
  if [[ -s "$(ai_journal_file "$ROOT")" ]]; then
    while IFS= read -r l; do ui_rail "$l"; done < <(bash "$SCRIPT_DIR/ai-log.sh" --root "$ROOT" -n "$jn" 2>/dev/null || true)
  else
    ui_info "$(t "log empty for now")"
  fi
  [[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "${LOOMY_STATUS_FOOTER:-$(t "full log: loomy log")}"
  exit 0
fi

# ---------------------------------------------------------------- phases du bootstrap
CURRENT=""
[[ -f "$STATE" ]] && CURRENT="$(sed -n 's/^phase=//p' "$STATE" | head -1)"
UPDATED=""
[[ -f "$STATE" ]] && UPDATED="$(sed -n 's/^updated=//p' "$STATE" | head -1)"

if [[ -z "$CURRENT" && -f "$ROOT/.ai/bootstrap/START.completed.md" ]]; then CURRENT="done"; fi
if [[ -z "$CURRENT" && -f "$ROOT/START.md" && -f "$BRIEF" ]]; then CURRENT="brief"; fi
idx="$(loomy_phase_index "$CURRENT")"
note=""
if [[ "$CURRENT" == "done" ]]; then note="$(t "bootstrap done")"
elif (( idx > 0 )); then note="$(t "step %s of 10" "$idx")${UPDATED:+ · $(t "since %s" "${UPDATED##* }")}"; fi
ui_section "PHASES" "$note"
if [[ -z "$CURRENT" ]]; then
  if [[ -f "$ROOT/START.md" ]]; then ui_info "$(t "START.md present but brief empty: run loomy brief")"
  else ui_info "$(t "no Loomy project here: run loomy init")"; fi
else
  # Wide timeline: one box per phase (█ done, ▓ in progress, ░ upcoming), then ▲ and the name under the current box.
  _ui_term_size
  cw=$(( (UI_W - 3 - 9) / 10 )); (( cw > 7 )) && cw=7; (( cw < 2 )) && cw=2
  cell_done=""; cell_cur=""; cell_todo=""; i=0
  while (( i < cw )); do cell_done="${cell_done}█"; cell_cur="${cell_cur}▓"; cell_todo="${cell_todo}░"; i=$(( i + 1 )); done
  bar=""; i=0
  for p in $LOOMY_PHASES; do
    i=$(( i + 1 ))
    (( i > 1 )) && bar="$bar "
    if (( i < idx )); then bar="${bar}${C_GREEN}${cell_done}${C_RESET}"
    elif (( i == idx )); then bar="${bar}${C_BRAND}${cell_cur}${C_RESET}"
    else bar="${bar}${C_DIM}${cell_todo}${C_RESET}"; fi
  done
  ui_rail "$bar"
  label="▲ $(loomy_phase_label "$CURRENT")"; [[ "$CURRENT" == "done" ]] && label="✓ $(t "Bootstrap done")"
  total=$(( cw * 10 + 9 )); _ui_strlen "$label"
  off=$(( (idx > 10 ? 9 : idx - 1) * (cw + 1) )); (( off < 0 )) && off=0
  (( off + UI_LEN > total )) && off=$(( total - UI_LEN ))
  _ui_pad "" "$off"
  hl=""; [[ "${LOOMY_HL_PHASE:-0}" == "1" ]] && hl="  ${C_BOLD}${C_BRAND}✦ $(t "new phase")${C_RESET}"
  ui_rail "${UI_PADDED}${C_BRAND}${label}${C_RESET}${hl}"
  ui_print "${C_RAIL}│${C_RESET}"
  # Bootstrap finished: the summary (duration, delegations, cost), taken from the log.
  # Bootstrap summary (archives included): duration, delegations, cost of delegations and Claude Code until the end.
  J_DONE="$(ai_journal_file "$ROOT")"
  if [[ "$CURRENT" == "done" && -s "$J_DONE" ]]; then
    read -r b_start b_end b_n b_cost <<<"$(awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      index($0, "\"type\":\"phase\"") { if (s == "") s = field("ts"); if (index($0, "\"phase\":\"done\"")) e = field("ts") }
      e == "" && index($0, "\"type\":\"delegation\",") { n++; if (match($0, /"cost_usd":[0-9.]+/)) c += substr($0, RSTART + 11, RLENGTH - 11) }
      e == "" && index($0, "\"type\":\"usage\"") { if (match($0, /"cost_usd":[0-9.]+/)) c += substr($0, RSTART + 11, RLENGTH - 11) }
      END { printf "%s %s %d %.2f\n", (s == "" ? "-" : s), (e == "" ? "-" : e), n, c }' < <(ai_journal_all "$ROOT"))"
    s_ep="$(ai_ts_epoch "$b_start")"; e_ep="$(ai_ts_epoch "$b_end")"
    took=""
    if [[ -n "$s_ep" && -n "$e_ep" ]] && (( e_ep >= s_ep )); then
      d=$(( e_ep - s_ep )); if (( d >= 3600 )); then took="$(( d / 3600 )) h $(( d % 3600 / 60 )) min"; else took="$(( d / 60 )) min"; fi
    fi
    ui_rail "${C_GREEN}${C_BOLD}✦ $(t "Project ready")${C_RESET}${took:+ ${C_DIM}·${C_RESET} $(t "bootstrap in %s" "${C_BOLD}$took${C_RESET}")} ${C_DIM}·${C_RESET} $(t "%s delegation(s)" "$b_n") ${C_DIM}·${C_RESET} \$${b_cost}"
  fi
  [[ "$COMPACT" == "1" ]] || ui_rail "${C_DIM}$(loomy_phase_agent "$CURRENT")${C_RESET}"
  # Lead agent session: recorded by the Claude Code hooks and by loomy start (Codex).
  sess="$(ai_session_state "$ROOT")"; tool_name="Claude Code"; [[ "$sess" == *"|codex" ]] && tool_name="Codex"
  you="$(loomy_you_now "$CURRENT" "$sess")"
  ui_rail "${C_YELLOW}➜${C_RESET} ${C_BOLD}$(t "Your turn:")${C_RESET} $you"
  case "$sess" in
    open*) ui_rail "${C_GREEN}●${C_RESET} $(t "Lead agent session open since %s" "$(printf '%s' "$sess" | cut -d'|' -f2)") ${C_DIM}($tool_name)${C_RESET}" ;;
    closed*) ui_rail "${C_DIM}○ $(t "Lead agent session closed at %s (%s) → loomy start to resume it" "$(printf '%s' "$sess" | cut -d'|' -f2)" "$tool_name")${C_RESET}" ;;
    *) [[ "$CURRENT" != "done" ]] && ui_rail "${C_DIM}○ $(t "No lead agent session recorded → loomy start")${C_RESET}" ;;
  esac
  if (( idx >= 1 && idx < 10 )) && [[ "$COMPACT" != "1" ]]; then
    next=""; i=0
    for p in $LOOMY_PHASES; do i=$(( i + 1 )); (( i > idx )) && next="${next:+$next → }$(loomy_phase_label "$p")"; done
    _ui_term_size; _ui_fit "$(t "next:") $next" $(( UI_W - 3 ))
    ui_rail "${C_DIM}${UI_FIT}${C_RESET}"
  fi
fi

# ---------------------------------------------------------------- brief
if [[ -f "$BRIEF" && "$COMPACT" != "1" ]]; then
  ui_section "BRIEF"
  risk="$(brief_get risk)"
  risk_c="$C_GREEN"; [[ "$risk" == "MEDIUM" ]] && risk_c="$C_YELLOW"; [[ "$risk" == "HIGH" ]] && risk_c="$C_RED"
  ui_kv "$(t "Name")" "${C_TITLE}$(brief_get name)${C_RESET} · $(label_of "$(brief_get type)") · $(label_of "$(brief_get stage)")"
  ui_kv "$(t "Risk")" "${risk_c}${risk:-?}${C_RESET}"
  ui_kv "$(t "AI mode")" "${C_MAGENTA}$(brief_get ai_mode)${C_RESET} · lead $(label_of "$(brief_get ai_lead)")"
  ui_kv "Budget" "$(label_of "$(brief_get budget)")"
  ui_kv "Git" "$(t "auto commit: %s · auto push: %s" "$(label_of "$(brief_get commit_after_setup)")" "$(label_of "$(brief_get push_after_commit)")")"
fi

# ---------------------------------------------------------------- activity
JOURNAL="$(ai_journal_file "$ROOT")"
if [[ -s "$JOURNAL" ]]; then
  ui_section "$(t "ACTIVITY")"
  # Running delegations: a start without an end (a single read of the log), whose process is still running.
  now_s="$(date +%s)"
  awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/\\"/, "\"", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "" }
    /"type":"delegation_start"/ { id = field("id"); order[++n] = id
      line[id] = num("pid") "|" field("ts") "|" field("role") "|" field("model") "|" substr(field("task"), 1, 60); next }
    /"type":"delegation",/ { finished[field("id")] = 1; k = field("role") "|" field("model"); tot[k] += num("duration_s"); cnt[k]++ }
    END { for (i = (n > 20 ? n - 19 : 1); i <= n; i++) if (!(order[i] in finished)) { split(line[order[i]], f, "|"); k = f[3] "|" f[4]
            print line[order[i]] "|" (cnt[k] ? int(tot[k] / cnt[k]) : "") } }' "$JOURNAL" |
  while IFS='|' read -r pid ts role m task est; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || continue
    since="$(ai_ts_epoch "$ts")"
    # Spinner (one frame per loomy watch refresh), timer, and progress estimated from past delegations
    # of the same role on the same model.
    spin="${UI_SPIN[$(( ${LOOMY_TICK:-0} % 4 ))]}"
    el_s=0; [[ -n "$since" ]] && el_s=$(( now_s - since )); (( el_s < 0 )) && el_s=0
    _ui_dur $(( el_s * 1000 )); el="${UI_DUR/[.,]? s/ s}"
    prog=""
    if [[ -n "$est" ]] && (( est > 0 )); then
      fill=$(( el_s * 10 / est )); (( fill > 10 )) && fill=10
      bar=""; for (( k = 0; k < 10; k++ )); do if (( k < fill )); then bar="${bar}▰"; else bar="${bar}▱"; fi; done
      _ui_dur $(( est * 1000 )); est_txt="${UI_DUR/[.,]? s/ s}"
      if (( el_s > est * 3 / 2 )); then prog="${C_YELLOW}${bar}${C_RESET} ${el} ${C_DIM}· $(t "longer than usual (~%s)" "$est_txt")${C_RESET}"
      else prog="${C_BRAND}${bar}${C_RESET} ${el} ${C_DIM}/ ~${est_txt}${C_RESET}"; fi
    else
      prog="${el} ${C_DIM}· $(t "first time for this role")${C_RESET}"
    fi
    ui_rail "${C_YELLOW}${spin} $(t "running")${C_RESET} ${C_BOLD}$(printf '%-11s' "$role")${C_RESET}${C_DIM}$(printf '%-17s' "$m")${C_RESET} ${prog}"
    ui_rail "           ${C_DIM}${task}${C_RESET}"
  done
  # Claude Code direct work (lead agent, native subagents): cost measured by the Stop and SubagentStop hooks.
  HAS_USAGE=0
  if grep -q '"type":"usage"' "$JOURNAL"; then
    HAS_USAGE=1
    read -r u_ln u_lc u_sn u_sc <<<"$(awk '
      index($0, "\"type\":\"usage\"") {
        c = 0; if (match($0, /"cost_usd":[0-9.]+/)) c = substr($0, RSTART + 11, RLENGTH - 11)
        m = 0; if (match($0, /"messages":[0-9]+/)) m = substr($0, RSTART + 11, RLENGTH - 11)
        if (index($0, "\"scope\":\"lead\"")) { ln += m; lc += c } else { sn++; sc += c } }
      END { printf "%d %.4f %d %.4f\n", ln, lc, sn, sc }' "$JOURNAL")"
    ui_kv "$(t "Lead agent")" "$(t "%s reply(ies) · cost %s" "${C_BOLD}${u_ln}${C_RESET}" "${C_BOLD}\$${u_lc}${C_RESET}") ${C_DIM}($(t "measured"))${C_RESET}"
    (( u_sn > 0 )) && ui_kv "$(t "Sub-agents")" "$(t "%s · cost %s" "${C_BOLD}${u_sn}${C_RESET}" "${C_BOLD}\$${u_sc}${C_RESET}") ${C_DIM}($(t "measured"))${C_RESET}"
  fi
  if ! grep -q '"type":"delegation",' "$JOURNAL"; then
    ui_info "$(t "no finished delegation yet")"
    ui_rail "${C_DIM}  $(t "they show up here as soon as the lead agent hands a task to Claude or Codex")${C_RESET}"
  else
    summary="$(grep '"type":"delegation"' "$JOURNAL" | awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
      { m = field("model"); calls[m]++; cost[m] += num("cost_usd"); tok[m] += num("tokens_in") + num("tokens_out")
        n++; total += num("cost_usd"); if (field("status") != "ok") err++ }
      END { printf "TOTAL %d %.4f %d\n", n, total, err
            for (m in calls) printf "MODEL %s %d %.4f %d\n", m, calls[m], cost[m], tok[m] }')"
    read -r _ n_calls total_cost n_err <<<"$(printf '%s\n' "$summary" | grep '^TOTAL')"
    ui_kv "$(t "Delegations")" "$(t "%s · cost %s" "${C_BOLD}${n_calls}${C_RESET}" "${C_BOLD}\$${total_cost}${C_RESET}")$( [[ "${n_err:-0}" != "0" ]] && printf ' · %s%s%s' "$C_RED" "$(t "%s failed" "$n_err")" "$C_RESET")"
    last_n=5
    if [[ "$COMPACT" == "1" ]]; then last_n=3; else
    printf '%s\n' "$summary" | grep '^MODEL' | sort -k4 -rn | while read -r _ m c cost tok; do
      width=0
      if awk -v t="$total_cost" 'BEGIN{exit !(t>0)}'; then width="$(awk -v c="$cost" -v t="$total_cost" 'BEGIN{printf "%d", (c/t)*24 + 0.5}')"; fi
      bar=""; rest=""; i=0
      while (( i < 24 )); do if (( i < width )); then bar="${bar}█"; else rest="${rest}░"; fi; i=$(( i + 1 )); done
      color="$C_CYAN"; case "$m" in *opus*|*astra*) color="$C_MAGENTA" ;; *luna*|*haiku*) color="$C_GREEN" ;; esac
      line="$(printf '%-17s %3s appel(s)  %9s tokens  $%.4f' "$m" "$c" "$tok" "$cost")"
      ui_rail "${color}${bar}${C_RESET}${C_DIM}${rest}${C_RESET} ${line}"
    done
    # Plans: real pay-as-you-go cost (API) or API value consumed this month, compared with the subscription price.
    month="$(date -u +%Y-%m)"
    for fam in claude codex; do
      value="$(awk -v fam="\"family\":\"$fam\"" -v ts="\"ts\":\"$month" '
        (index($0, "\"type\":\"delegation\",") || index($0, "\"type\":\"usage\"")) && index($0, fam) && index($0, ts) {
          if (match($0, /"cost_usd":[0-9.]+/)) c += substr($0, RSTART+11, RLENGTH-11) }
        END { printf (c >= 1 ? "%.2f" : "%.4f"), c }' "$JOURNAL")"
      plan="$(loomy_plan "$fam")"; monthly="$(loomy_plan_monthly "$fam")"
      name="Claude"; [[ "$fam" == "codex" ]] && name="Codex"
      if [[ "$plan" == "api" ]]; then
        ui_kv "$name" "API · $(t "cost this month:") ${C_BOLD}\$${value}${C_RESET}"
      elif [[ -n "$monthly" ]]; then
        pct="$(awk -v v="$value" -v m="$monthly" 'BEGIN { printf "%d", (m > 0 ? v / m * 100 : 0) }')"
        ui_kv "$name" "$(ai_plan_label "$fam" "$plan") · $(t "API value this month:") ${C_BOLD}\$${value}${C_RESET} / \$${monthly} (${pct} %)"
      else
        ui_kv "$name" "$(ai_plan_label "$fam" "$plan") · $(t "API value this month:") ${C_BOLD}\$${value}${C_RESET}"
      fi
    done
    if (( HAS_USAGE )); then ui_info "$(t "delegations and Claude Code work (lead agent, sub-agents), at list price")"
    else ui_info "$(t "values from logged delegations (lead agent counted from loomy 0.3 on, Stop and SubagentStop hooks)")"; fi
    ui_rail ""
    ui_rail "${C_DIM}$(t "Latest delegations")${C_RESET}"
    fi
    n_shown="$(grep -c '"type":"delegation",' "$JOURNAL" || true)"; (( n_shown > last_n )) && n_shown=$last_n
    row=0
    grep '"type":"delegation"' "$JOURNAL" | tail -"$last_n" | awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
      { printf "%s|%s|%s|%s|%s|%s|%s\n", field("ts"), field("status"), field("role"), field("model"), num("duration_s"), num("cost_usd"), substr(field("task"), 1, 40) }' |
    while IFS='|' read -r t st role m d cost task; do
      row=$(( row + 1 ))
      # Log in UTC, shown in local time.
      ep="$(ai_ts_epoch "$t")"
      if [[ -n "$ep" ]]; then t="$(date -r "$ep" +%H:%M 2>/dev/null || date -d "@$ep" +%H:%M)"; else t="${t:11:5}"; fi
      mark="${C_GREEN}✓${C_RESET}"; [[ "$st" != "ok" ]] && mark="${C_RED}✗${C_RESET}"
      # Delegation just finished (loomy watch): highlighted for a few seconds.
      if (( row > n_shown - ${LOOMY_HL_DELEG:-0} )); then mark="${mark}${C_BRAND}${C_BOLD}✦${C_RESET}"; t="${C_BOLD}${t}"; else mark="${mark} "; fi
      ui_rail "$mark ${C_DIM}${t}${C_RESET} $(printf '%-11s %-17s %4ss  $%.4f' "$role" "$m" "$d" "$cost")  ${C_DIM}${task}${C_RESET}"
    done
  fi
else
  ui_section "$(t "ACTIVITY")"
  ui_info "$(t "no delegation yet")"
  ui_rail "${C_DIM}  $(t "they show up here as soon as the lead agent hands a task to Claude or Codex")${C_RESET}"
fi

# ---------------------------------------------------------------- fichiers IA
if [[ "$COMPACT" != "1" ]]; then
ui_section "$(t "AI FILES")" "$(privacy_label "$(privacy_mode "$ROOT")")"
if [[ "$(privacy_mode "$ROOT")" == "private" ]]; then
  if ! privacy_companion_ready "$ROOT"; then ui_warn "$(t "private repository missing on this machine")" "loomy privacy restore <$(t "account/repo")>"
  elif [[ "$(privacy_pending "$ROOT")" != "0" ]]; then ui_warn "$(t "%s unsaved change(s) in the private repository" "$(privacy_pending "$ROOT")")" "loomy privacy sync"; fi
elif [[ "$(privacy_mode "$ROOT")" == "local" ]] && [[ -n "$(privacy_git_root "$ROOT")" ]] && ! privacy_excluded "$ROOT"; then
  ui_warn "$(t "AI files not excluded on this machine yet")" "loomy privacy local"
fi
check_file() {
  if [[ -e "$ROOT/$1" ]]; then ui_ok "$1" "${2:-}"; else ui_rail "${C_DIM}○ $1${C_RESET}"; fi
}
if [[ ! -e "$ROOT/AGENTS.md" && ! -e "$ROOT/CLAUDE.md" ]]; then
  ui_rail "${C_DIM}$(t "created by the lead agent during Build: it's normal for them to be missing before")${C_RESET}"
fi
check_file AGENTS.md
check_file CLAUDE.md
check_file PROJECT.md
check_file ARCHITECTURE.md
check_file .ai/AI_WORKFLOW.md
check_file .ai/AI_ORCHESTRATION.md
check_file .ai/AI_MODEL_ROUTING.md
if [[ -d "$ROOT/.claude/agents" ]]; then
  agents="$(find "$ROOT/.claude/agents" -maxdepth 1 -name '*.md' -exec basename {} .md \; | sort | paste -sd ',' - | sed 's/,/, /g')"
  ui_ok ".claude/agents/" "${agents:-$(t "empty")}"
else
  ui_rail "${C_DIM}○ .claude/agents/${C_RESET}"
fi
if [[ -f "$ROOT/.ai/HANDOFF.md" ]]; then
  ui_warn ".ai/HANDOFF.md" "$(t "active handoff:") $(sed -n 's/^De *: *//p' "$ROOT/.ai/HANDOFF.md" | head -1) → $(sed -n 's/^Vers *: *//p' "$ROOT/.ai/HANDOFF.md" | head -1)"
fi

fi

# ---------------------------------------------------------------- git
ui_section "GIT"
if [[ "$COMPACT" == "1" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || t "detached")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  last="$(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null || true)"
  if [[ "$dirty" == "0" ]]; then ui_ok "$(t "%s clean" "$branch")" "${last:0:48}"; else ui_warn "$branch" "$(t "%s uncommitted file(s)" "$dirty")"; fi
elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || t "detached")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  last="$(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null || true)"
  if [[ "$dirty" == "0" ]]; then ui_ok "$(t "branch %s" "$branch")" "$(t "clean")"
  else ui_warn "$(t "branch %s" "$branch")" "$(t "%s modified file(s) not committed" "$dirty")"; fi
  if [[ -n "$last" ]]; then ui_info "$(t "last commit: %s" "$last")"; else ui_info "$(t "no commit")"; fi
  upstream="$(git -C "$ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    counts="$(git -C "$ROOT" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null || echo "0 0")"
    ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
    if [[ "$ahead" == "0" && "$behind" == "0" ]]; then ui_ok "$(t "in sync with %s" "$upstream")"
    else ui_warn "$upstream" "$(t "%s ahead · %s behind" "$ahead" "$behind")"; fi
  else
    remote="$(git -C "$ROOT" remote 2>/dev/null | head -1)"
    if [[ -n "$remote" ]]; then ui_info "$(t "remote %s set, no tracked branch" "$remote")"
    else ui_info "$(t "no remote set")"; fi
  fi
  wt="$(git -C "$ROOT" worktree list 2>/dev/null | wc -l | tr -d ' ')"
  if (( wt > 1 )); then ui_warn "$(t "%s parallel worktree(s)" "$(( wt - 1 ))")" "git worktree list"; fi
else
  ui_info "$(t "no Git repository")"
fi
[[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "${LOOMY_STATUS_FOOTER:-$(t "start or resume: loomy start · live tracking: loomy watch")}"
