#!/usr/bin/env bash
# shellcheck disable=SC2034
# Langue de l'interface de Loomy : anglais ou français. À charger (source) ; ui.sh le fait. Compatible bash 3.2.
#
# Langue retenue, dans l'ordre : LOOMY_LANG, puis « loomy config set lang fr|en|auto », puis les variables LC_ALL,
# LC_MESSAGES, LANG, puis la langue du système sous macOS (AppleLocale) ; français si elle commence par « fr »,
# anglais sinon, et anglais quand rien n'est détectable. Calculée une fois, puis transmise aux sous-processus
# (LOOMY_UI_LANG).
#
# Textes : t "phrase en français" [arguments printf]. La phrase française sert de clé ; sa traduction anglaise vient
# du dictionnaire (scripts/lib/i18n/en.tsv, compilé en en.sh par tools/i18n-build.sh). Une phrase pas encore traduite
# s'affiche en français plutôt que de casser l'affichage.

_i18n_detect() {
  local l="${LOOMY_LANG:-}" cfg="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/config"
  [[ -z "$l" && -f "$cfg" ]] && l="$(sed -n 's/^lang=//p' "$cfg" 2>/dev/null | tail -1)"
  [[ "$l" == "auto" ]] && l=""
  if [[ -z "$l" ]]; then
    local v
    for v in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
      # C, POSIX et les locales purement techniques ne disent rien de la langue de l'utilisateur.
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
if [[ "$LOOMY_UI_LANG" == "en" ]]; then
  # shellcheck source=i18n/en.sh
  source "$(dirname "${BASH_SOURCE[0]}")/i18n/en.sh" 2>/dev/null || _t_en() { _T=""; }
fi

# t <phrase> [arguments] : phrase dans la langue de l'interface (printf si des arguments suivent).
t() {
  local s="$1"; shift
  if [[ "$LOOMY_UI_LANG" == "en" ]]; then _t_en "$s"; [[ -n "$_T" ]] && s="$_T"; fi
  # shellcheck disable=SC2059
  if (( $# )); then printf "$s" "$@"; else printf '%s' "$s"; fi
}

# ui_lang : langue de l'interface (fr ou en).
ui_lang() { echo "$LOOMY_UI_LANG"; }
