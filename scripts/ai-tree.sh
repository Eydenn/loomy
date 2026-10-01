#!/usr/bin/env bash
# Agent tree: the lead agent, its advisor and every routed role with its model, effort and live state, then the session
# log and a status line. Shown by loomy watch (key t); loomy tree prints it once. Bash 3.2 compatible.
#   ai-tree.sh [--root <dir>]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"

ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//; s/ai-tree.sh/loomy tree/g' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || exit 1
J="$(ai_journal_file "$ROOT")"
TICK="${LOOMY_TICK:-0}"
now_s="$(date +%s)"
ai_detect_env "$ROOT"

dur() { local d="${1%.*}"; if (( d >= 60 )); then printf '%d min %02d s' $(( d / 60 )) $(( d % 60 )); else printf '%d s' "$d"; fi; }
hm() { local e; e="$(ai_ts_epoch "$1")"; [[ -n "$e" ]] && { date -r "$e" +%H:%M:%S 2>/dev/null || date -d "@$e" +%H:%M:%S; }; }
color_of() { case "$1" in TOP) printf '%s' "$C_MAGENTA" ;; FAST) printf '%s' "$C_GREEN" ;; *) printf '%s' "$C_CYAN" ;; esac; }

# ---------------------------------------------------------------- state per role, from the log
# Per role: running (a delegation started whose process is alive), or the last finished one.
STATES="$( [[ -s "$J" ]] && awk '
  function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
  function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
  /"type":"delegation_start"/ { id = field("id"); srole[id] = field("role"); sts[id] = field("ts"); spid[id] = num("pid"); stask[id] = substr(field("task"), 1, 50); order[++n] = id }
  /"type":"delegation",/ { id = field("id"); fin[id] = 1; r = field("role")
    last[r] = field("ts") "|" field("status") "|" num("duration_s") "|" (num("tokens_in") + num("tokens_out")) "|" field("outcome") "|" field("model"); cnt[r]++ }
  END {
    for (i = 1; i <= n; i++) { id = order[i]; if (!(id in fin)) print "RUN|" srole[id] "|" spid[id] "|" sts[id] "|" stask[id] }
    for (r in last) print "LAST|" r "|" last[r] "|" cnt[r] }' "$J")"

# ---------------------------------------------------------------- lead and advisor
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
L_MODEL="$R_MODEL"; L_EFFORT="$R_EFFORT"; L_FAM="$R_FAMILY"
ADV=""; [[ "$L_FAM" == "claude" ]] && ADV="$(ai_advisor_for "$L_MODEL" "$AI_PROFILE")"
sess="$(ai_session_state "$ROOT" 2>/dev/null || echo none)"
case "$sess" in
  open*) s_txt="${C_GREEN}● $(t "session open")${C_RESET}" ;;
  closed*) s_txt="${C_DIM}○ $(t "session closed")${C_RESET}" ;;
  *) s_txt="${C_DIM}○ $(t "no session")${C_RESET}" ;;
esac
phase="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1)"
for mf in audit task; do
  p="$(sed -n 's/^phase=//p' "$ROOT/.loomy/$mf.state" 2>/dev/null | head -1)"
  if [[ -n "$p" && "$p" != "done" ]]; then loomy_phases_mode "$mf"; phase="$p"; MISSION="$mf"; break; fi
done

ui_section "$(t "AGENT TREE")" "$(ai_env_label "$AI_ENV") · $(t "%s profile" "$(ai_profile_label "$AI_PROFILE")")"
ui_rail ""
lead_line="${C_BRAND}${C_BOLD}$(t "LEAD AGENT")${C_RESET}  $(color_of TOP)${L_MODEL}${C_RESET} · $L_EFFORT · $s_txt${phase:+ ${C_DIM}·${C_RESET} ${MISSION:+$MISSION · }$(loomy_phase_label "$phase")}"
ui_rail "┏━ $lead_line"
if [[ -n "$ADV" ]]; then
  a_n=0; a_last=""
  if [[ -s "$J" ]]; then
    read -r a_n a_last <<<"$(awk 'function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
      /"type":"advisor"/ { n += num("calls"); if (match($0, /"ts":"[^"]*"/)) l = substr($0, RSTART + 6, RLENGTH - 7) } END { print n + 0, l }' "$J")"
  fi
  # The advisor glows for a few seconds after a consultation was logged.
  glow="$C_MAGENTA"; [[ -n "$a_last" ]] && (( now_s - $(ai_ts_epoch "$a_last" || echo 0) < 30 )) && glow="${C_BOLD}${C_MAGENTA}"
  ui_rail "┃  ${glow}✦ $(t "advisor %s" "$ADV")${C_RESET} ${C_DIM}· $(t "%s consultation(s)" "$a_n")${a_last:+ · $(t "last %s" "$(hm "$a_last")")} · $(t "before a plan, when an error repeats, before done")${C_RESET}"
fi
ui_rail "┃"

# ---------------------------------------------------------------- roles
roles=(); for r in $AI_ROLES; do [[ "$r" == "lead" ]] || roles+=("$r"); done
n_roles=${#roles[@]}; i=0; n_run=0
for r in "${roles[@]}"; do
  i=$(( i + 1 ))
  ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
  branch="┣"; (( i == n_roles )) && branch="┗"
  run="$(printf '%s\n' "$STATES" | awk -F'|' -v r="$r" '$1 == "RUN" && $2 == r' | tail -1)"
  state=""; conn="━━"
  if [[ -n "$run" ]]; then
    IFS='|' read -r _ _ pid ts task <<<"$run"
    if [[ -n "$pid" && "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
      n_run=$(( n_run + 1 ))
      el=$(( now_s - $(ai_ts_epoch "$ts" || echo "$now_s") )); (( el < 0 )) && el=0
      # A pulse travels along the branch while the role works.
      case $(( TICK % 3 )) in 0) conn="•━" ;; 1) conn="━•" ;; *) conn="━━" ;; esac
      state="${C_YELLOW}${UI_SPIN[$(( TICK % 4 ))]} $(t "running") $(( el / 60 )):$(printf '%02d' $(( el % 60 )))${C_RESET} ${C_DIM}${task}${C_RESET}"
      mark="${C_YELLOW}●${C_RESET}"
    fi
  fi
  if [[ -z "$state" ]]; then
    last="$(printf '%s\n' "$STATES" | awk -F'|' -v r="$r" '$1 == "LAST" && $2 == r' | tail -1)"
    if [[ -n "$last" ]]; then
      IFS="|" read -r _ _ lts lst ldur ltok loc _ lcnt <<<"$last"
      mark="${C_GREEN}✓${C_RESET}"; [[ "$lst" != "ok" ]] && mark="${C_RED}✗${C_RESET}"
      [[ "$lst" == "ok" && "$loc" == "partial" ]] && mark="${C_YELLOW}◐${C_RESET}"
      [[ "$lst" == "ok" && "$loc" == "blocked" ]] && mark="${C_YELLOW}■${C_RESET}"
      state="${C_DIM}$(t "done %s" "$(hm "$lts" | cut -c1-5)") · $(dur "$ldur") · $(ai_tokens_label "${ltok%.*}") tk · ×${lcnt}${C_RESET}"
    else
      mark="${C_DIM}○${C_RESET}"; state="${C_DIM}$(t "idle")${C_RESET}"
    fi
  fi
  _ui_pad "$(ai_role_label "$r")" 16; rl="$UI_PADDED"
  _ui_pad "$R_MODEL" 18; ml="$UI_PADDED"
  _ui_pad "$R_EFFORT" 7; el_="$UI_PADDED"
  ui_rail "${branch}${conn} ${mark} ${C_BOLD}${rl}${C_RESET}$(color_of "$R_TIER")${ml}${C_RESET}${el_}${state}"
done

# ---------------------------------------------------------------- session log
ui_rail ""
ui_rail "${C_DIM}── $(t "session log") ──${C_RESET}"
if [[ -s "$J" ]]; then
  tail -n 200 "$J" | awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
    /"type":"delegation_start"/ { print field("ts") "|" field("role") "|start · " field("model") "|" substr(field("task"), 1, 44); next }
    /"type":"delegation",/ { d = num("duration_s") + 0; print field("ts") "|" field("role") "|" (field("status") == "ok" ? "done" : "failed") " · " (d >= 60 ? int(d / 60) " min " d % 60 " s" : d " s") "|" field("outcome"); next }
    /"type":"advisor"/ { print field("ts") "|advisor|" num("calls") " consultation(s) · " field("model") "|"; next }
    /"type":"(phase|task_phase|audit_phase)"/ { print field("ts") "|phase|" field("phase") "|"; next }
    /"type":"session"/ { print field("ts") "|session|" field("event") " · " field("tool") "|" }' | tail -6 |
  while IFS='|' read -r ts who what extra; do
    ui_rail "${C_DIM}$(hm "$ts")${C_RESET}  $(printf '%-11s' "$who") $what ${C_DIM}${extra}${C_RESET}"
  done
else
  ui_info "$(t "log empty for now")"
fi

# ---------------------------------------------------------------- status line
n_del=0; tok=0
[[ -s "$J" ]] && read -r n_del tok <<<"$(awk 'function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
  /"type":"delegation",/ { n++ } /"type":"(delegation|usage|advisor)"/ && !/delegation_start/ { t += num("tokens_in") + num("tokens_out") } END { print n + 0, t + 0 }' "$J")"
ui_rail ""
ui_rail "${C_BOLD}effort${C_RESET} [${L_EFFORT}]  ${C_BOLD}$(t "roles")${C_RESET} [$n_run/$n_roles $(t "running")]  ${C_BOLD}$(t "advisor")${C_RESET} [${ADV:-off}]  ${C_BOLD}$(t "delegations")${C_RESET} [$n_del]  ${C_BOLD}tokens${C_RESET} [$(ai_tokens_label "$tok")]"
[[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "$(t "live: loomy watch, then t")"
exit 0
