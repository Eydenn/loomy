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
  local display_root="${LOOMY_DISPLAY_ROOT:-${1%/.loomy/logs/*}}"
  [[ "$1" != */.loomy/logs/* ]] || display_root="${1%/.loomy/logs/*}"
  ai_display_context_init "$display_root"
  ai_journal_tail "$1" 4000 | ai_journal_canonical | tail -n 400 | perl -MJSON::PP -e "$AI_DISPLAY_CONTEXT_PERL"'
    binmode STDOUT;
    while (<STDIN>) {
      my $raw=$_; my $e=eval {decode_json($raw)}; next unless ref($e) eq "HASH";
      if (Loomy::DisplayContext::managed($e)) {
        my $row=Loomy::DisplayContext::session_row($e);
        print Encode::encode("UTF-8",join("|",@$row)."\n") if $row;
      } else {
        my $row=Loomy::DisplayContext::legacy_session_row($raw); print join("|",@$row),"\n" if $row;
      }
    }
  '
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
