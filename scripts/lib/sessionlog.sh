#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Session log for loomy watch and loomy tree: the project's events as one aligned, coloured line each
# (time, actor, action, detail), newest at the bottom. In loomy watch it scrolls smoothly: events that arrive together
# are revealed one per refresh, and the newest line stays highlighted for a few seconds. To be sourced after ui.sh,
# models.sh and journal.sh. Bash 3.2 compatible.

# ai_session_log_rows <root> <lines>: the latest events as "ts|actor|action|detail" (no colour), after the smooth-scroll
# reveal. LOOMY_WATCH_ID (set by loomy watch): per-watcher reveal cursor, so arrivals scroll in one by one.
ai_session_log_rows() {
  local root="$1" n="$2" j all total shown cur
  j="$(ai_journal_file "$root")"
  [[ -s "$j" ]] || return 1
  all="$(_ai_session_events "$j")"
  [[ -n "$all" ]] || return 1
  total="$(printf '%s\n' "$all" | wc -l | tr -d ' ')"
  shown="$total"
  if [[ -n "${LOOMY_WATCH_ID:-}" ]]; then
    cur="${TMPDIR:-/tmp}/loomy-watch-${LOOMY_WATCH_ID}.seen"
    local seen; seen="$(cat "$cur" 2>/dev/null || echo "")"
    if [[ "$seen" =~ ^[0-9]+$ ]] && (( seen < total && seen >= total - 20 )); then shown=$(( seen + 1 )); fi
    echo "$shown" >"$cur" 2>/dev/null || true
  fi
  printf '%s\n' "$all" | head -n "$shown" | tail -n "$n"
}

_ai_session_events() {
  tail -n 400 "$1" | awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
    function dur(d) { d = d + 0; return (d >= 60 ? int(d / 60) " min " (d % 60) " s" : d " s") }
    /"type":"delegation_start"/ { print field("ts") "|" field("role") "|start|" field("model") " · " substr(field("task"), 1, 52); next }
    /"type":"delegation",/ { st = field("status"); oc = field("outcome")
      print field("ts") "|" field("role") "|" (st == "ok" ? (oc == "partial" ? "partial" : (oc == "blocked" ? "blocked" : "done")) : "failed") "|" dur(num("duration_s")) " · " field("model") (field("failover_from") != "" ? " · ⇄ " field("failover_from") : ""); next }
    /"type":"advisor"/ { print field("ts") "|advisor|consulted|" num("calls") " × " field("model") " · " int((num("tokens_in") + 0) / 1000) "k"; next }
    /"type":"(phase|task_phase|audit_phase)"/ { ty = field("type"); sub(/_?phase$/, "", ty); print field("ts") "|phase|" field("phase") "|" ty; next }
    /"type":"session"/ { print field("ts") "|session|" field("event") "|" field("tool"); next }
    /"type":"skill"/ { print field("ts") "|skills|" field("event") "|" field("name") " · " substr(field("reason"), 1, 52); next }
    /"type":"usage"/ { if (field("scope") == "lead") print field("ts") "|lead|replied|" num("messages") " msg · " field("model"); next }'
}

# ai_session_log <root> <lines>: prints the lines (with colours) for the latest events.
ai_session_log() {
  local root="$1" n="$2" rows now ts who what extra rest e col hl mark
  rows="$(ai_session_log_rows "$root" "$n")" || return 1
  now="$(date +%s)"
  printf '%s\n' "$rows" | while IFS='|' read -r ts who what extra; do
    e="$(ai_ts_epoch "$ts")"
    hm="${ts:11:8}"; [[ -n "$e" ]] && hm="$(date -r "$e" +%H:%M:%S 2>/dev/null || date -d "@$e" +%H:%M:%S)"
    case "$who" in
      advisor) col="$C_MAGENTA" ;; phase|session|lead) col="$C_BRAND" ;;
      executor|explorer) col="$C_GREEN" ;; architect|debugger|security) col="$C_MAGENTA" ;; *) col="$C_CYAN" ;;
    esac
    if [[ "$who" == "phase" ]] && declare -F loomy_phase_label >/dev/null; then
      [[ -n "$extra" && "$extra" != "phase" ]] && loomy_phases_mode "$extra"
      what="$(loomy_phase_label "$what")"; loomy_phases_mode project
      case "$extra" in task) extra="$(t "task")" ;; audit) extra="$(t "audit")" ;; *) extra="" ;; esac
    else
      case "$what" in failed) what="${C_RED}$(t "failed")${C_RESET}" ;; partial|blocked) what="${C_YELLOW}$(t "$what")${C_RESET}" ;; *) what="$(t "$what")" ;; esac
    fi
    # The newest line, a few seconds old: highlighted.
    hl=""; mark=" "
    if [[ -n "$e" ]] && (( now - e < 6 )); then hl="$C_BOLD"; mark="${C_BRAND}▸${C_RESET}"; fi
    rest="$(printf '%-11s' "$who")"
    printf '%s %s%s%s  %s%s%s %s %s%s%s\n' "$mark" "$C_DIM" "$hm" "$C_RESET" "$col$hl" "$rest" "$C_RESET" "${hl}${what}${C_RESET}" "$C_DIM" "$extra" "$C_RESET"
  done
}
