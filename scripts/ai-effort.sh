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
    low) t "rapide et économe : suffit souvent pour orchestrer"; echo ;;
    medium) t "bon compromis vitesse / réflexion"; echo ;;
    high) t "réflexion poussée, plus lent et plus coûteux"; echo ;;
    xhigh) t "très poussé : décisions délicates"; echo ;;
    max) t "maximum : lent et coûteux, pour les cas difficiles"; echo ;;
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
  src="$(t "profil %s" "$(ai_profile_label "$AI_PROFILE")")"; (( R_EFFORT_SET )) && src="$(t "réglé pour ce projet")"
  ui_kv "$role" "${C_BRAND}${R_MODEL}${C_RESET} · effort ${C_BOLD}${R_EFFORT}${C_RESET} ${C_DIM}(${src})${C_RESET}"
}

done_msg() {
  ui_end "$(t "pris en compte au prochain loomy start (et par les délégations suivantes) · retour au profil : %s" "loomy effort ${1:+$1 }--reset")"
}

role="lead"; level=""
case "${#ARGS[@]}" in
  0) ;;
  1) if [[ "${ARGS[0]}" == "--list" ]]; then level="--list"
     elif [[ "${ARGS[0]}" == "--reset" ]]; then level="--reset-all"
     else level="${ARGS[0]}"; fi ;;
  2) role="${ARGS[0]}"; level="${ARGS[1]}" ;;
  *) t "Usage : loomy effort [<rôle>] [low|medium|high|xhigh|max|--reset]" >&2; echo >&2; exit 2 ;;
esac
valid_role "$role" || { t "Rôle inconnu : %s (%s)" "$role" "$AI_ROLES" >&2; echo >&2; exit 2; }

ui_clear
ui_rail_head "effort · $(basename "$ROOT")"
case "$level" in
  --list)
    for r in $AI_ROLES; do show_role "$r"; done
    ui_end "$(t "régler : loomy effort [<rôle>] <niveau>")" ;;
  --reset-all)
    rm -f "$FILE"
    ui_ok "$(t "Efforts revenus à ceux du profil")" "$(t "tous les rôles")"
    show_role lead; done_msg ;;
  --reset)
    set_effort "$role" ""
    ui_ok "$(t "Effort de %s revenu à celui du profil" "$role")"
    show_role "$role"; done_msg "$( [[ "$role" != lead ]] && echo "$role")" ;;
  "")
    show_role lead
    if ! ui_is_interactive; then ui_end "$(t "régler : loomy effort <low|medium|high|xhigh|max>")"; exit 0; fi
    ui_print "${C_RAIL}│${C_RESET}"
    ai_detect_env "$ROOT"; ai_resolve lead "$AI_ENV" "$AI_PROFILE"
    cur="$R_EFFORT"; def=0; i=0; opts=(); UI_DESCS=()
    for l in $LEVELS; do
      [[ "$l" == "$cur" ]] && def=$i
      opts+=("$l"); UI_DESCS+=("$(label "$l")"); i=$(( i + 1 ))
    done
    opts+=("$(t "Revenir au profil")"); UI_DESCS+=("$(t "Supprime le réglage : l'effort suit le profil du brief (%s)." "$(ai_profile_label "$AI_PROFILE")")"); UI_LABEL="Effort"
    ui_choose "$(t "Effort de l'orchestrateur (%s) ?" "$R_MODEL")" "$def" "${opts[@]}"
    # Les niveaux d'abord (mêmes noms dans les deux langues), puis « Revenir au profil ».
    if (( UI_INDEX >= $(set -- $LEVELS; echo $#) )); then set_effort lead ""; else set_effort lead "$UI_VALUE"; fi
    show_role lead; done_msg ;;
  *)
    valid_level "$level" || { t "Niveau inconnu : %s (%s)" "$level" "$LEVELS" >&2; echo >&2; exit 2; }
    set_effort "$role" "$level"
    ui_ok "$(t "Effort de %s réglé" "$role")" "$level · $(label "$level")"
    show_role "$role"; done_msg "$( [[ "$role" != lead ]] && echo "$role")" ;;
esac
