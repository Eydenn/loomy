#!/usr/bin/env bash
# Claude Code status line for Loomy projects. Bash 3.2 compatible.
# Claude Code sends a JSON document on stdin at each refresh; subscribers get a documented "rate_limits" field
# (5-hour and 7-day windows). This script saves it for loomy status / watch / stats, then shows the user's own
# status line when one is set (saved by loomy init from ~/.claude/settings.json), otherwise a short Loomy line.
# Never fails and stays silent on errors: a broken status line must not disturb the session.
set -uo pipefail

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
  [[ -n "${p5:-}" && -n "${r5:-}" ]] && new="${new}five_hour_pct=$(printf '%.0f' "$p5")"$'\n'"five_hour_reset=$r5"$'\n'
  [[ -n "${p7:-}" && -n "${r7:-}" ]] && new="${new}seven_day_pct=$(printf '%.0f' "$p7")"$'\n'"seven_day_reset=$r7"$'\n'
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
    run="$(tail -n 300 "$J" 2>/dev/null | awk '
      /"type":"delegation_start"/ { if (match($0, /"id":"[^"]*"/)) { id = substr($0, RSTART, RLENGTH); s[id] = 1 } }
      /"type":"delegation",/ { if (match($0, /"id":"[^"]*"/)) { id = substr($0, RSTART, RLENGTH); delete s[id] } }
      END { n = 0; for (k in s) n++; print n }')"
    [[ "${run:-0}" -gt 0 ]] 2>/dev/null && seg="${seg:+$seg · }⟳ $run"
  fi
fi
user_cmd="$(cat "$CFG/statusline-user" 2>/dev/null || true)"
if [[ -n "$user_cmd" ]]; then
  out="$(printf '%s' "$INPUT" | bash -c "$user_cmd" 2>/dev/null)"
  if [[ -n "$seg" ]]; then printf '%s · Loomy %s\n' "$out" "$seg"; else printf '%s\n' "$out"; fi
  exit 0
fi
model="$(printf '%s' "$flat" | sed -n 's/.*"display_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
line="Loomy${seg:+ $seg}${model:+ · $model}"
[[ -n "${p5:-}" ]] && line="$line · 5h $(printf '%.0f' "$p5")%"
[[ -n "${p7:-}" ]] && line="$line · 7d $(printf '%.0f' "$p7")%"
printf '%s\n' "$line"
exit 0
