#!/usr/bin/env bash
# Effort de raisonnement des rôles d'un projet Loomy (orchestrateur par défaut). Compatible bash 3.2.
#   ai-effort.sh                      menu : choisir l'effort de l'orchestrateur
#   ai-effort.sh <niveau>             règle l'orchestrateur : low, medium, high, xhigh ou max
#   ai-effort.sh <rôle> <niveau>      règle un autre rôle (executor, reviewer, architect…)
#   ai-effort.sh [<rôle>] --reset     revient à l'effort du profil (tous les rôles avec --reset seul)
#   ai-effort.sh --list               efforts de tous les rôles
# Réglage enregistré dans .loomy/efforts ; pris en compte au prochain loomy start et par les délégations suivantes.
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
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//; s/ai-effort.sh/loomy effort/'; exit 0 ;;
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
    low) echo "rapide et économe : suffit souvent pour orchestrer" ;;
    medium) echo "bon compromis vitesse / réflexion" ;;
    high) echo "réflexion poussée, plus lent et plus coûteux" ;;
    xhigh) echo "très poussé : décisions délicates" ;;
    max) echo "maximum : lent et coûteux, pour les cas difficiles" ;;
  esac
}

# set_effort <rôle> <niveau|""> : écrit (ou retire) le réglage du rôle.
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
  src="profil $(ai_profile_label "$AI_PROFILE")"; (( R_EFFORT_SET )) && src="réglé pour ce projet"
  ui_kv "$role" "${C_BRAND}${R_MODEL}${C_RESET} · effort ${C_BOLD}${R_EFFORT}${C_RESET} ${C_DIM}(${src})${C_RESET}"
}

done_msg() {
  ui_end "pris en compte au prochain loomy start (et par les délégations suivantes) · retour au profil : loomy effort ${1:+$1 }--reset"
}

role="lead"; level=""
case "${#ARGS[@]}" in
  0) ;;
  1) if [[ "${ARGS[0]}" == "--list" ]]; then level="--list"
     elif [[ "${ARGS[0]}" == "--reset" ]]; then level="--reset-all"
     else level="${ARGS[0]}"; fi ;;
  2) role="${ARGS[0]}"; level="${ARGS[1]}" ;;
  *) echo "Usage : loomy effort [<rôle>] [low|medium|high|xhigh|max|--reset]" >&2; exit 2 ;;
esac
valid_role "$role" || { echo "Rôle inconnu : $role ($AI_ROLES)" >&2; exit 2; }

ui_clear
ui_rail_head "effort · $(basename "$ROOT")"
case "$level" in
  --list)
    for r in $AI_ROLES; do show_role "$r"; done
    ui_end "régler : loomy effort [<rôle>] <niveau>" ;;
  --reset-all)
    rm -f "$FILE"
    ui_ok "Efforts revenus à ceux du profil" "tous les rôles"
    show_role lead; done_msg ;;
  --reset)
    set_effort "$role" ""
    ui_ok "Effort de $role revenu à celui du profil"
    show_role "$role"; done_msg "$( [[ "$role" != lead ]] && echo "$role")" ;;
  "")
    show_role lead
    if ! ui_is_interactive; then ui_end "régler : loomy effort <low|medium|high|xhigh|max>"; exit 0; fi
    ui_print "${C_RAIL}│${C_RESET}"
    ai_detect_env "$ROOT"; ai_resolve lead "$AI_ENV" "$AI_PROFILE"
    cur="$R_EFFORT"; def=0; i=0; opts=(); UI_DESCS=()
    for l in $LEVELS; do
      [[ "$l" == "$cur" ]] && def=$i
      opts+=("$l"); UI_DESCS+=("$(label "$l")"); i=$(( i + 1 ))
    done
    opts+=("Revenir au profil"); UI_DESCS+=("Supprime le réglage : l'effort suit le profil du brief ($(ai_profile_label "$AI_PROFILE"))."); UI_LABEL="Effort"
    ui_choose "Effort de l'orchestrateur ($R_MODEL) ?" "$def" "${opts[@]}"
    if [[ "$UI_VALUE" == Revenir* ]]; then set_effort lead ""; else set_effort lead "$UI_VALUE"; fi
    show_role lead; done_msg ;;
  *)
    valid_level "$level" || { echo "Niveau inconnu : $level ($LEVELS)" >&2; exit 2; }
    set_effort "$role" "$level"
    ui_ok "Effort de $role réglé" "$level · $(label "$level")"
    show_role "$role"; done_msg "$( [[ "$role" != lead ]] && echo "$role")" ;;
esac
