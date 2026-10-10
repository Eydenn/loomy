#!/usr/bin/env bash
# Claude Code status line for Loomy projects. Bash 3.2 compatible.
# Claude Code sends a JSON document on stdin at each refresh; subscribers get a documented "rate_limits" field
# (5-hour and 7-day windows). This script saves it for loomy status / watch / stats, then shows the user's own
# status line when one is set (saved by loomy init from ~/.claude/settings.json), otherwise a short Loomy line.
# Never fails and stays silent on errors: a broken status line must not disturb the session.
set -uo pipefail
# round <number>: nearest whole number, in plain bash (printf would depend on the user's locale: 12.5 is invalid in French).
round() { local w="${1%%.*}" f="${1#*.}"; [[ "$1" == *.* ]] || f=0; w="${w:-0}"; [[ "$w" =~ ^[0-9]+$ ]] || { echo 0; return; }; [[ "${f:0:1}" =~ ^[5-9]$ ]] && w=$(( 10#$w + 1 )); echo "$(( 10#$w ))"; }

CFG="${XDG_CONFIG_HOME:-$HOME/.config}/loomy"
INPUT="$(cat 2>/dev/null || true)"
flat="$(printf '%s' "$INPUT" | tr -d '\n\r')"

# ---------------------------------------------------------------- quota
window() {   # window <name>: "<used_percentage> <resets_at>" of that window, if present
  local s
  s="$(printf '%s' "$flat" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*{[^}]*}" | head -1)" || true
  [[ -n "$s" ]] || return 0
  printf '%s %s\n' "$(printf '%s' "$s" | sed -n 's/.*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p')" \
    "$(printf '%s' "$s" | sed -n 's/.*"resets_at"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
}
if [[ "$flat" == *'"rate_limits"'* ]]; then
  read -r p5 r5 <<<"$(window five_hour)"
  read -r p7 r7 <<<"$(window seven_day)"
  new=""
  [[ -n "${p5:-}" && -n "${r5:-}" ]] && new="${new}five_hour_pct=$(round "$p5")"$'\n'"five_hour_reset=$r5"$'\n'
  [[ -n "${p7:-}" && -n "${r7:-}" ]] && new="${new}seven_day_pct=$(round "$p7")"$'\n'"seven_day_reset=$r7"$'\n'
  if [[ -n "$new" ]] && mkdir -p "$CFG" 2>/dev/null; then
    f="$CFG/claude-limits"
    # Written only when it changes (the status line refreshes often), atomically.
    if [[ "$(grep -v '^updated=' "$f" 2>/dev/null || true)"$'\n' != "$new" ]]; then
      tmp="$(mktemp "$CFG/.claude-limits.XXXXXX" 2>/dev/null)" && { printf '%supdated=%s\n' "$new" "$(date +%s)" >"$tmp" && mv "$tmp" "$f"; } || rm -f "${tmp:-}"
    fi
  fi
fi

# ---------------------------------------------------------------- display
# Loomy segment: the project phase while it isn't done, and the delegations running now, so the dispatch stays in
# sight in every session (terminal or app). Read from the end of the log only: the status line refreshes often.
seg=""
R="${LOOMY_PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-}}"
if [[ -n "$R" && -f "$R/.loomy/state" ]]; then
  ph="$(sed -n 's/^phase=//p' "$R/.loomy/state" 2>/dev/null | head -1)"
  [[ -n "$ph" && "$ph" != "done" ]] && seg="$ph"
  J="$R/.loomy/logs/events.jsonl"
  if [[ -f "$J" ]]; then
    # Delegations started without their end event, whose bridge process is still alive (a crashed one isn't counted).
    run=0
    for pid in $(tail -n 2000 "$J" 2>/dev/null | awk '
      /"type":"delegation_start"/ { if (match($0, /"id":"[^"]*"/)) { id = substr($0, RSTART, RLENGTH); p = ""; if (match($0, /"pid":[0-9]+/)) p = substr($0, RSTART + 6, RLENGTH - 6); s[id] = p } }
      /"type":"delegation",/ { if (match($0, /"id":"[^"]*"/)) { id = substr($0, RSTART, RLENGTH); delete s[id] } }
      END { for (k in s) if (s[k] != "") print s[k] }'); do kill -0 "$pid" 2>/dev/null && run=$(( run + 1 )); done
    [[ "${run:-0}" -gt 0 ]] 2>/dev/null && seg="${seg:+$seg · }⟳ $run"
  fi
fi
# Temporary lead relay (quota): the acting tool (state file read with builtins, this refreshes often).
if [[ -n "$R" && -f "$R/.loomy/failover" ]]; then
  fm=""; fa=""; fmanual=""
  while IFS= read -r fl; do
    case "$fl" in master=*) fm="${fl#master=}" ;; acting=*) fa="${fl#acting=}" ;; esac
    case "$fl" in manual=*) fmanual="${fl#manual=}" ;; esac
  done <"$R/.loomy/failover"
  if [[ -n "$fa" && "$fa" != "$fm" ]]; then
    relay_suffix=""
    if [[ "$fmanual" == 1 ]]; then
      _status_lang="${LOOMY_UI_LANG:-${LOOMY_LANG:-}}"
      if [[ -z "$_status_lang" && -f "$CFG/config" ]]; then
        while IFS= read -r _config_line; do case "$_config_line" in lang=*) _status_lang="${_config_line#lang=}" ;; esac; done <"$CFG/config"
      fi
      if [[ -z "$_status_lang" || "$_status_lang" == auto ]]; then _status_lang="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"; fi
      case "$_status_lang" in fr|fr_*|fr-*|fr.*|FR*) relay_suffix=" (manuel)" ;; *) relay_suffix=" (manual)" ;; esac
    fi
    seg="${seg:+$seg · }⇄ $fa$relay_suffix"
  fi
fi
user_cmd="$(cat "$CFG/statusline-user" 2>/dev/null || true)"
if [[ -n "$user_cmd" ]]; then
  tmpo="$(mktemp "${TMPDIR:-/tmp}/loomy-sl.XXXXXX" 2>/dev/null)" || tmpo=""
  out=""
  if [[ -n "$tmpo" ]]; then
    ( printf '%s' "$INPUT" | bash -c "$user_cmd" >"$tmpo" 2>/dev/null ) & upid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$upid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$upid" 2>/dev/null; then kill "$upid" 2>/dev/null; else out="$(cat "$tmpo" 2>/dev/null)"; fi
    rm -f "$tmpo"
  fi
  if [[ -n "$seg" ]]; then printf '%s · Loomy %s\n' "$out" "$seg"; else printf '%s\n' "$out"; fi
  exit 0
fi
model="$(printf '%s' "$flat" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
line="Loomy${seg:+ $seg}${model:+ · $model}"
[[ -n "${p5:-}" ]] && line="$line · 5h $(round "$p5")%"
[[ -n "${p7:-}" ]] && line="$line · 7d $(round "$p7")%"
printf '%s\n' "$line"
exit 0
