#!/usr/bin/env bash
# Reasoning effort of a Loomy project's roles (lead agent by default). Bash 3.2 compatible.
#   ai-effort.sh                      menu: pick the lead agent's effort
#   ai-effort.sh <level>              sets the lead agent: low, medium, high, xhigh or max
#   ai-effort.sh <role> <level>       sets another role (executor, reviewer, architect…)
#   ai-effort.sh [<role>] --reset     goes back to the profile's effort (every role with --reset alone)
#   ai-effort.sh --list               effort of every role
# Saved in .loomy/efforts; used from the next loomy start and by the following delegations.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

ROOT=""; ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//; s/ai-effort.sh/loomy effort/' | i18n_lines; exit 0 ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd)"
[[ -f "$ROOT/.loomy/brief.md" ]] || { echo "Pas de projet Loomy ici : lancez loomy init." >&2; exit 1; }
FILE="$ROOT/.loomy/efforts"
LEVELS="low medium high xhigh max"

label() {
  case "$1" in
    low) t "fast and thrifty: often enough to orchestrate"; echo ;;
    medium) t "good speed / reasoning trade-off"; echo ;;
    high) t "deeper reasoning, slower and costlier"; echo ;;
    xhigh) t "very deep: tricky decisions"; echo ;;
    max) t "maximum: slow and costly, for hard cases"; echo ;;
  esac
}

# set_effort <role> <level|"">: writes (or removes) the role's setting.
set_effort() {
  local role="$1" level="$2" tmp
  mkdir -p "$ROOT/.loomy"
  tmp="$(mktemp)"
  { grep -v "^$role=" "$FILE" 2>/dev/null || true; [[ -n "$level" ]] && echo "$role=$level"; } >"$tmp"
  if [[ -s "$tmp" ]]; then mv "$tmp" "$FILE"; else rm -f "$tmp" "$FILE"; fi
}

valid_role() { case " $AI_ROLES " in *" $1 "*) return 0 ;; esac; return 1; }
valid_level() { case " $LEVELS " in *" $1 "*) return 0 ;; esac; return 1; }

show_role() {
  local role="$1"
  ai_detect_env "$ROOT"; ai_resolve "$role" "$AI_ENV" "$AI_PROFILE"
  local src
  src="$(t "%s profile" "$(ai_profile_label "$AI_PROFILE")")"; (( R_EFFORT_SET )) && src="$(t "set for this project")"
  ui_kv "$role" "${C_BRAND}${R_MODEL}${C_RESET} · effort ${C_BOLD}${R_EFFORT}${C_RESET} ${C_DIM}(${src})${C_RESET}"
}

done_msg() {
  ui_end "$(t "applied at the next loomy start (and by the next delegations) · back to the profile: %s" "loomy effort ${1:+$1 }--reset")"
}

role="lead"; level=""
case "${#ARGS[@]}" in
  0) ;;
  1) if [[ "${ARGS[0]}" == "--list" ]]; then level="--list"
     elif [[ "${ARGS[0]}" == "--reset" ]]; then level="--reset-all"
     else level="${ARGS[0]}"; fi ;;
  2) role="${ARGS[0]}"; level="${ARGS[1]}" ;;
  *) t "Usage: loomy effort [<role>] [low|medium|high|xhigh|max|--reset]" >&2; echo >&2; exit 2 ;;
esac
valid_role "$role" || { t "Unknown role: %s (%s)" "$role" "$AI_ROLES" >&2; echo >&2; exit 2; }

ui_clear
ui_rail_head "effort · $(basename "$ROOT")"
case "$level" in
  --list)
    for r in $AI_ROLES; do show_role "$r"; done
    ui_end "$(t "set: loomy effort [<role>] <level>")" ;;
  --reset-all)
    rm -f "$FILE"
    ui_ok "$(t "Efforts back to the profile's")" "$(t "all roles")"
    show_role lead; done_msg ;;
  --reset)
    set_effort "$role" ""
    ui_ok "$(t "%s effort back to the profile's" "$role")"
    show_role "$role"; done_msg "$( [[ "$role" != lead ]] && echo "$role")" ;;
  "")
    show_role lead
    if ! ui_is_interactive; then ui_end "$(t "set: loomy effort <low|medium|high|xhigh|max>")"; exit 0; fi
    ui_print "${C_RAIL}│${C_RESET}"
    ai_detect_env "$ROOT"; ai_resolve lead "$AI_ENV" "$AI_PROFILE"
    cur="$R_EFFORT"; def=0; i=0; opts=(); UI_DESCS=()
    for l in $LEVELS; do
      [[ "$l" == "$cur" ]] && def=$i
      opts+=("$l"); UI_DESCS+=("$(label "$l")"); i=$(( i + 1 ))
    done
    opts+=("$(t "Back to the profile")"); UI_DESCS+=("$(t "Removes the setting: the effort follows the brief's profile (%s)." "$(ai_profile_label "$AI_PROFILE")")"); UI_LABEL="Effort"
    ui_choose "$(t "Lead agent effort (%s)?" "$R_MODEL")" "$def" "${opts[@]}"
    # Levels first (same names in both languages), then "Back to the profile".
    if (( UI_INDEX >= $(set -- $LEVELS; echo $#) )); then set_effort lead ""; else set_effort lead "$UI_VALUE"; fi
    show_role lead; done_msg ;;
  *)
    valid_level "$level" || { t "Unknown level: %s (%s)" "$level" "$LEVELS" >&2; echo >&2; exit 2; }
    set_effort "$role" "$level"
    ui_ok "$(t "%s effort set" "$role")" "$level · $(label "$level")"
    show_role "$role"; done_msg "$( [[ "$role" != lead ]] && echo "$role")" ;;
esac
