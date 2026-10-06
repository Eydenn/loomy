#!/usr/bin/env bash
# Official agent skills of a Loomy project (github.com/anthropics/skills and github.com/openai/skills only).
#   loomy-skills.sh                    installed skills (why, source, analysis) and the catalog's suggestions
#   loomy-skills.sh suggest "text"     the skills that would help for this task
#   loomy-skills.sh add <name>         installs one (analysed first)
#   loomy-skills.sh remove <name>      removes one
#   loomy-skills.sh update             brings the installed skills to the catalog's commits
#   loomy-skills.sh sync               installs again the skills of the lock missing on this machine
#   loomy-skills.sh catalog            every skill of the catalog
# Policy: loomy config set skills auto|ask|off (auto: installed on their own, each one announced).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/skills.sh
source "$SCRIPT_DIR/lib/skills.sh"

ROOT=""; ACTION="list"; ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//; s/loomy-skills.sh/loomy skills/g' | i18n_lines; exit 0 ;;
    list|suggest|add|remove|update|sync|catalog) ACTION="$1"; ARG="${2:-}"; [[ -n "${2:-}" ]] && shift ;;
    *) t "Unknown argument: %s (loomy skills --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
ROOT="${ROOT:-${LOOMY_PROJECT_ROOT:-$PWD}}"
if [[ "$ACTION" != catalog && ! -f "$ROOT/.loomy/brief.md" ]]; then t "Not a Loomy project: %s" "$ROOT" >&2; echo >&2; exit 1; fi

show_line() {   # show_line <name>: one catalog skill, with its summary
  local line; line="$(skills_line "$1")"
  printf '%s' "$line" | cut -d'|' -f8
}

case "$ACTION" in
  catalog)
    ui_section "$(t "OFFICIAL SKILLS")" "$(t "catalog of %s" "$(sed -n 's/^date=//p' "$(skills_catalog)" | head -1)")"
    grep -v '^#' "$(skills_catalog)" | grep -v '^date=' | while IFS='|' read -r n src _ _ lic auto _ sum; do
      ui_kv "$n" "$sum ${C_DIM}· $src · $lic$( [[ "$auto" != no ]] && printf ' · auto: %s' "$auto")${C_RESET}"
    done
    ui_rail_end "loomy skills add <name>" ;;
  suggest)
    found="$(skills_suggest "$ROOT" "$ARG" 5)"
    if [[ -z "$found" ]]; then t "No official skill matches this task."; echo; exit 0; fi
    while IFS= read -r n; do printf '%s\t%s\n' "$n" "$(show_line "$n")"; done <<<"$found" ;;
  add)
    [[ -n "$ARG" ]] || { t "Usage: loomy skills add <name> (loomy skills catalog)" >&2; echo >&2; exit 2; }
    lic="$(skills_line "$ARG" | cut -d'|' -f5)"
    if [[ "$lic" == proprietary ]]; then
      ui_warn "$(t "Proprietary licence")" "$(t "%s is reserved to the vendor's customers: your agreement with it applies; installed for Claude only, kept out of Git" "$ARG")"
      if ui_is_interactive; then
        ui_choose "$(t "Install it anyway?")" 1 "$(t "Yes, install it")" "$(t "No")"
        [[ "${UI_INDEX:-1}" == 0 ]] || exit 0
      fi
    fi
    if skills_install "$ROOT" "$ARG" "$(t "added by the user")" force; then ui_ok "$(t "Skill installed")" "$SK_LAST"
    else ui_err "$(t "Skill not installed")" "$SK_LAST"; exit 1; fi ;;
  remove)
    [[ -n "$ARG" ]] || { t "Usage: loomy skills remove <name>" >&2; echo >&2; exit 2; }
    if skills_remove "$ROOT" "$ARG"; then ui_ok "$(t "Skill removed")" "$ARG"; else ui_err "$(t "Skill not removed")" "$SK_LAST"; exit 1; fi ;;
  update)
    ups="$(skills_updates "$ROOT")"
    if [[ -z "$ups" ]]; then ui_ok "$(t "Skills up to date")" ""; exit 0; fi
    while read -r n _; do
      reason="$(skills_lock_line "$ROOT" "$n" | cut -d'|' -f7)"
      if skills_install "$ROOT" "$n" "$reason" force; then ui_ok "$(t "Skill updated")" "$n"; else ui_warn "$(t "Skill not updated")" "$SK_LAST"; fi
    done <<<"$ups" ;;
  sync) skills_sync "$ROOT"; ui_ok "$(t "Skills in place")" "" ;;
  list)
    ui_section "$(t "SKILLS")" "$(t "official only · policy %s" "$(skills_policy)")"
    if [[ -s "$ROOT/.loomy/skills.lock" ]]; then
      while IFS='|' read -r n src _ _ lic day reason an; do
        [[ -n "$n" ]] || continue
        ui_kv "$n" "$reason ${C_DIM}· $src · $lic · $day${C_RESET}"
        ui_rail "   ${C_DIM}$(t "analysis: %s" "$an")${C_RESET}"
      done <"$ROOT/.loomy/skills.lock"
    else
      ui_kv "$(t "Installed")" "${C_DIM}$(t "none yet")${C_RESET}"
    fi
    ups="$(skills_updates "$ROOT")"; [[ -n "$ups" ]] && ui_info "$(t "updates available: %s · loomy skills update" "$(printf '%s' "$ups" | tr '\n' ' ')")"
    miss="$(skills_auto_for "$ROOT" | while IFS= read -r n; do skills_installed "$ROOT" "$n" || echo "$n"; done | tr '\n' ' ')"
    [[ -n "${miss// /}" ]] && ui_info "$(t "suggested for this project: %s · loomy skills add <name>" "$miss")"
    ui_rail_end "loomy skills catalog · loomy skills suggest \"…\"" ;;
esac
exit 0
