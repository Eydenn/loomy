#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Loomy user configuration: ${XDG_CONFIG_HOME:-~/.config}/loomy/config (key=value lines).
# To be sourced. Bash 3.2 compatible.
#
# Keys:
#   plan_claude        api | pro | max5 | max20 | team | enterprise
#   plan_codex         api | plus | pro100 | pro200 | business | enterprise
#   plan_claude_price  monthly price in $ (replaces the plan's default price)
#   plan_codex_price   same for the ChatGPT/Codex plan

# Translated strings (t): the language layer is loaded if the script hasn't done it already.
if ! declare -F t >/dev/null 2>&1; then
  # shellcheck source=i18n.sh
  source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
fi

loomy_config_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/config"; }

# loomy_config_get <key> [default]
loomy_config_get() {
  local file v
  file="$(loomy_config_file)"
  [[ -f "$file" ]] && v="$(sed -n "s/^$1=//p" "$file" | tail -1)"
  echo "${v:-${2:-}}"
}

# loomy_config_set <key> <value>
loomy_config_set() {
  local file tmp
  file="$(loomy_config_file)"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  tmp="$file.tmp.$$"
  grep -v "^$1=" "$file" >"$tmp" || true
  # "auto": removes the setting (default value or catalog choice).
  [[ "$2" == "auto" ]] || echo "$1=$2" >>"$tmp"
  mv "$tmp" "$file"
}

loomy_config_list() {
  local file
  file="$(loomy_config_file)"
  [[ -f "$file" ]] && grep -E '^[a-z_.]+=' "$file" || true
}

# Default monthly plan prices in $ (checked on 2026-09-23). Empty = pay as you go or on quote.
ai_plan_price() {
  case "$1" in
    pro|plus) echo "20" ;;
    max5|pro100) echo "100" ;;
    max20|pro200) echo "200" ;;
    team|business) echo "25" ;;
    *) echo "" ;;
  esac
}

ai_plan_label() {
  case "$1:$2" in
    claude:api|codex:api) t "API (pay as you go)"; echo ;;
    claude:pro) t "Claude Pro"; echo ;;
    claude:max5) t "Claude Max 5x"; echo ;;
    claude:max20) t "Claude Max 20x"; echo ;;
    claude:team) t "Claude Team"; echo ;;
    claude:enterprise) t "Claude Enterprise"; echo ;;
    codex:plus) t "ChatGPT Plus"; echo ;;
    codex:pro100) echo "ChatGPT Pro (100 $)" ;;
    codex:pro200) echo "ChatGPT Pro (200 $)" ;;
    codex:business) t "ChatGPT Business"; echo ;;
    codex:enterprise) t "ChatGPT Enterprise"; echo ;;
    *) t "not set"; echo ;;
  esac
}

# loomy_plan <claude|codex>: configured plan (api by default).
loomy_plan() { loomy_config_get "plan_$1" "api"; }

# loomy_plan_monthly <claude|codex>: monthly price used (override, otherwise the plan's default price).
loomy_plan_monthly() {
  local p
  p="$(loomy_config_get "plan_$1_price" "")"
  [[ -n "$p" ]] && { echo "$p"; return 0; }
  ai_plan_price "$(loomy_plan "$1")"
}
