#!/usr/bin/env bash
# shellcheck disable=SC2034
# Loomy interface language: English by default, French when detected. Sourced by ui.sh. Bash 3.2 compatible.
#
# Resolution order: LOOMY_LANG, then "loomy config set lang fr|en|auto", then LC_ALL, LC_MESSAGES, LANG, then the
# macOS system language (AppleLocale). French when it starts with "fr", English otherwise, and English when nothing
# can be detected. Computed once, then passed to child processes (LOOMY_UI_LANG).
#
# Strings: t "English sentence" [printf arguments]. The English sentence is the key; its French translation comes
# from the dictionary (scripts/lib/i18n/fr.tsv, compiled into fr.sh by tools/i18n-build.sh). A sentence not yet
# translated is shown in English rather than breaking the display.

_i18n_detect() {
  local l="${LOOMY_LANG:-}" cfg="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/config"
  [[ -z "$l" && -f "$cfg" ]] && l="$(sed -n 's/^lang=//p' "$cfg" 2>/dev/null | tail -1)"
  [[ "$l" == "auto" ]] && l=""
  if [[ -z "$l" ]]; then
    local v
    for v in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
      # C, POSIX and purely technical locales say nothing about the user's language.
      case "$v" in ""|C|POSIX|C.*|POSIX.*) continue ;; esac
      l="$v"; break
    done
  fi
  if [[ -z "$l" && "$(uname -s 2>/dev/null)" == "Darwin" ]] && command -v defaults >/dev/null 2>&1; then
    l="$(defaults read -g AppleLocale 2>/dev/null || true)"
  fi
  case "$l" in fr|fr_*|fr-*|fr.*|FR*) echo fr ;; *) echo en ;; esac
}

if [[ -z "${LOOMY_UI_LANG:-}" ]]; then LOOMY_UI_LANG="$(_i18n_detect)"; export LOOMY_UI_LANG; fi
_T=""
if [[ "$LOOMY_UI_LANG" == "fr" ]]; then
  # shellcheck source=i18n/fr.sh
  source "$(dirname "${BASH_SOURCE[0]}")/i18n/fr.sh" 2>/dev/null || _t_fr() { _T=""; }
fi

# ai_uint <variable name>: runtime files and journals are untrusted input, and Bash evaluates a variable's text
# as an arithmetic expression ((( )), $(( )), [[ -gt ]], array subscripts: a[$(cmd)] runs cmd). Every number read
# from a runtime file goes through here before any arithmetic: digits only (at most 12, normalized to decimal),
# anything else becomes 0.
ai_uint() {
  local __ai_v="${!1-}"
  if [[ "$__ai_v" =~ ^[0-9]{1,12}$ ]]; then printf -v "$1" '%s' "$(( 10#$__ai_v ))"; else printf -v "$1" '%s' 0; fi
}
# ai_pid_ok <value>: a positive process id (more than 1), safe for kill -0 (0 and negatives address groups).
ai_pid_ok() { [[ "${1-}" =~ ^[0-9]{1,12}$ ]] && (( 10#$1 > 1 )); }
# ai_ctl_strip: stdin without C0 controls (newlines included), DEL and UTF-8 C1 controls (C2 80..9F): text from a
# runtime file (state, relay, brief) never drives the terminal. Bytes, whatever the locale.
ai_ctl_strip() { LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C sed $'s/\xc2[\x80-\x9f]//g'; }

# t <sentence> [arguments]: sentence in the interface language (printf when arguments follow).
t() {
  local s="$1"; shift
  if [[ "$LOOMY_UI_LANG" == "fr" ]]; then _t_fr "$s"; [[ -n "$_T" ]] && s="$_T"; fi
  # shellcheck disable=SC2059
  if (( $# )); then printf -- "$s" "$@"; else printf '%s' "$s"; fi
}

# tv <variable> <sentence> [arguments]: like t, into a variable, without a subshell (for screens drawn every second).
tv() {
  local __tv_n="$1" __tv_s="$2"; shift 2
  if [[ "$LOOMY_UI_LANG" == "fr" ]]; then _t_fr "$__tv_s"; [[ -n "$_T" ]] && __tv_s="$_T"; fi
  # shellcheck disable=SC2059
  if (( $# )); then printf -v "$__tv_n" -- "$__tv_s" "$@"; else printf -v "$__tv_n" '%s' "$__tv_s"; fi
}

# ui_lang: interface language (en or fr).
ui_lang() { echo "$LOOMY_UI_LANG"; }

# i18n_lines: translates stdin line by line (help texts).
i18n_lines() { local l; while IFS= read -r l || [[ -n "$l" ]]; do t "$l"; echo; done; }
