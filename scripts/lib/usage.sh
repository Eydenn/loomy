#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Subscription quotas and usage display for Loomy. To be sourced. Bash 3.2 compatible.
#
# With a subscription (plan other than "api" in loomy config), a dollar cost means little: Loomy shows the share of the
# plan's quota in use instead, and tokens for each piece of work. With the API, the real cost stays.
#
# Where the quotas come from (no network, no credentials read):
#   Codex   the "rate_limits" events Codex writes into its own session logs (${CODEX_HOME:-~/.codex}/sessions)
#   Claude  the documented "rate_limits" field Claude Code gives the status line command; Loomy's status line
#           (scripts/ai-statusline.sh) saves it to ${XDG_CONFIG_HOME:-~/.config}/loomy/claude-limits
if ! declare -F t >/dev/null 2>&1; then source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"; fi
if ! declare -F loomy_plan >/dev/null 2>&1; then source "$(dirname "${BASH_SOURCE[0]}")/config.sh"; fi

# loomy_on_plan <claude|codex>: true when that tool is used through a subscription.
loomy_on_plan() { [[ "$(loomy_plan "$1")" != "api" ]]; }

ai_claude_limits_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/claude-limits"; }

# ai_quota <claude|codex>: one line per quota window still running: "<window_minutes> <used_percent> <resets_at epoch>",
# then possibly "reached <reason>" when the tool reports the limit as reached. Nothing when no reading exists yet.
ai_quota() {
  local now; now="$(date +%s)"
  case "$1" in
    claude)
      local f; f="$(ai_claude_limits_file)"
      [[ -f "$f" ]] || return 0
      awk -F= -v now="$now" '
        /^(five_hour|seven_day)_pct=/ { split($1, a, "_pct"); pct[a[1]] = $2 }
        /^(five_hour|seven_day)_reset=/ { split($1, a, "_reset"); rst[a[1]] = $2 }
        END { if (("five_hour" in pct) && rst["five_hour"] > now) print 300, pct["five_hour"], rst["five_hour"]
              if (("seven_day" in pct) && rst["seven_day"] > now) print 10080, pct["seven_day"], rst["seven_day"] }' "$f"
      ;;
    codex)
      local dir="${CODEX_HOME:-$HOME/.codex}/sessions" f mt cache line
      [[ -d "$dir" ]] || return 0
      # Most recent session log; its last reading is the freshest.
      f="$(find "$dir" -name '*.jsonl' -type f -mtime -14 2>/dev/null | while IFS= read -r p; do printf '%s\t%s\n' "$(stat -f %m "$p" 2>/dev/null || stat -c %Y "$p" 2>/dev/null)" "$p"; done | sort -rn | head -1)"
      [[ -n "$f" ]] || return 0
      mt="${f%%$'\t'*}"; f="${f#*$'\t'}"
      # Cache: the reading only changes when that log changes (loomy watch asks every few seconds).
      cache="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/codex-limits"
      if [[ "$(head -1 "$cache" 2>/dev/null)" == "$mt $f" ]]; then line="$(sed -n '2p' "$cache")"
      else
        # Only the end of the log: readings are frequent, logs can be large.
        line="$(tail -c 400000 "$f" 2>/dev/null | grep -o '"rate_limits":{[^{}]*\({[^{}]*}[^{}]*\)*}' | tail -1)"
        mkdir -p "${cache%/*}" 2>/dev/null && printf '%s\n%s\n' "$mt $f" "$line" >"$cache" 2>/dev/null
      fi
      [[ -n "$line" ]] || return 0
      printf '%s\n' "$line" | awk -v now="$now" '
        function win(name,   s, w, p, r) {
          if (!match($0, "\"" name "\":\\{[^}]*\\}")) return
          s = substr($0, RSTART, RLENGTH)
          w = s; sub(/.*"window_minutes":/, "", w); sub(/[,}].*/, "", w)
          p = s; sub(/.*"used_percent":/, "", p); sub(/[,}].*/, "", p)
          r = s; sub(/.*"resets_at":/, "", r); sub(/[,}].*/, "", r)
          if (r + 0 > now) printf "%d %d %d\n", w, p + 0.5, r }
        { win("primary"); win("secondary")
          if (match($0, /"rate_limit_reached_type":"[a-z_]+"/)) print "reached", substr($0, RSTART + 27, RLENGTH - 28) }'
      ;;
  esac
}

# _ai_window_label <minutes>: "5 h", "week", "N h" or "N d".
_ai_window_label() {
  case "$1" in
    300) t "5 h" ;; 10080) t "week" ;; 1440) t "day" ;;
    *) if (( $1 % 1440 == 0 )); then printf '%s d' "$(( $1 / 1440 ))"; else printf '%s h' "$(( $1 / 60 ))"; fi ;;
  esac
}

# _ai_reset_label <epoch>: local time today, otherwise weekday and time.
_ai_reset_label() {
  local now; now="$(date +%s)"
  local hm dow
  hm="$(date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M)"
  if (( $1 - now < 86400 )); then printf '%s' "$hm"; return 0; fi
  # Weekday through the dictionary (the system locale may not match the interface language).
  dow="$(date -r "$1" +%u 2>/dev/null || date -d "@$1" +%u)"
  case "$dow" in 1) t "Mon" ;; 2) t "Tue" ;; 3) t "Wed" ;; 4) t "Thu" ;; 5) t "Fri" ;; 6) t "Sat" ;; *) t "Sun" ;; esac
  printf ' %s' "$hm"
}

# ai_quota_line <claude|codex>: "5 h 42 % (resets 14:30) · week 18 % (resets Mon 09:00)", coloured from 80 % on;
# empty when there is no reading yet.
ai_quota_line() {
  local out="" w p r c
  while read -r w p r; do
    [[ -n "$w" ]] || continue
    if [[ "$w" == "reached" ]]; then out="${out:+$out · }${C_RED}$(t "limit reached (%s)" "$p")${C_RESET}"; continue; fi
    c=""; (( p >= 80 )) && c="$C_YELLOW"; (( p >= 95 )) && c="$C_RED"
    out="${out:+$out · }$(_ai_window_label "$w") ${c}${C_BOLD}${p} %${C_RESET} ${C_DIM}($(t "resets %s" "$(_ai_reset_label "$r")"))${C_RESET}"
  done < <(ai_quota "$1")
  printf '%s' "$out"
}

# ai_quota_max <claude|codex>: highest share in use across the running windows (empty without a reading).
ai_quota_max() { ai_quota "$1" | awk '$1 != "reached" { if ($2 > m) m = $2; seen = 1 } END { if (seen) print m + 0 }'; }

# ai_tokens_label <n>: 950, 12.3k, 4.1M.
ai_tokens_label() { awk -v n="${1:-0}" 'BEGIN { if (n >= 1e6) printf "%.1fM", n / 1e6; else if (n >= 1e3) printf "%.1fk", n / 1e3; else printf "%d", n }'; }

# ai_quota_hint <claude|codex>: why there is no reading yet.
ai_quota_hint() {
  case "$1" in
    claude) t "quota shown once a Claude Code session has answered in a Loomy project (status line)" ;;
    codex) t "quota shown once a Codex session has run on this machine" ;;
  esac
}
