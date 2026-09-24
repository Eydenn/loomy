#!/usr/bin/env bash
# Accueil de « loomy » sans argument : où en est le projet, ce qui est attendu, et la suite en un choix. Compatible bash 3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"

LOOMY_BIN="$SCRIPT_DIR/../bin/loomy"
ROOT="$(ai_project_root)"
ui_clear

# ---------------------------------------------------------------- hors d'un projet Loomy
if [[ ! -f "$ROOT/.loomy/brief.md" ]]; then
  ui_banner "Bienvenue" "aucun projet Loomy dans ${PWD/#$HOME/~}"
  ui_print "${C_RAIL}│${C_RESET}"
  UI_LABEL="Choix"
  UI_DESCS=("Crée le dossier du projet (ou utilise celui-ci), puis le questionnaire et l'orchestrateur." \
    "Vérifie Claude Code, Codex, les modèles et les prérequis de la machine." \
    "Toutes les commandes.")
  ui_choose "Que veux-tu faire ?" 0 "Créer un projet" "Vérifier la machine" "Aide"
  case "$UI_VALUE" in
    Créer*) exec "$LOOMY_BIN" init ;;
    Vérifier*) exec "$LOOMY_BIN" doctor ;;
    *) exec "$LOOMY_BIN" help ;;
  esac
fi

# ---------------------------------------------------------------- dans un projet
brief() { _ai_brief_get "$ROOT/.loomy/brief.md" "$1"; }
PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
[[ -z "$PHASE" && ! -f "$ROOT/START.md" ]] && PHASE="done"
[[ -z "$PHASE" ]] && PHASE="brief"
idx="$(loomy_phase_index "$PHASE")"
sess="$(ai_session_state "$ROOT")"

ui_banner "$(brief name)" "${ROOT/#$HOME/~}"
ui_section "OÙ EN EST LE PROJET"
if [[ "$PHASE" == "done" ]]; then ui_kv "Bootstrap" "${C_GREEN}terminé${C_RESET} · développement au quotidien"
else ui_kv "Phase" "${C_BOLD}$(loomy_phase_label "$PHASE")${C_RESET} ${C_DIM}(étape $idx sur 10)${C_RESET}"; fi
case "$sess" in
  open*) ui_kv "Session" "${C_GREEN}ouverte${C_RESET} depuis $(printf '%s' "$sess" | cut -d'|' -f2)" ;;
  closed*) ui_kv "Session" "${C_DIM}fermée à $(printf '%s' "$sess" | cut -d'|' -f2)${C_RESET}" ;;
  *) ui_kv "Session" "${C_DIM}pas encore ouverte${C_RESET}" ;;
esac
you="$(loomy_you_now "$PHASE" "$sess")"
ui_kv "À toi" "$you"
ui_print "${C_RAIL}│${C_RESET}"

opts=("Ouvrir ou reprendre la session de l'orchestrateur" "Suivre en direct" "Statut détaillé" "Visibilité des fichiers IA" "Aide")
descs=("loomy start : reprend la dernière session de ce projet, ou en ouvre une nouvelle au bon endroit." \
  "loomy watch : phases, délégations en cours et activité, rafraîchis toutes les 2 secondes." \
  "loomy status : phases, brief, activité, coûts, fichiers IA et Git." \
  "loomy privacy : fichiers IA versionnés, locaux ou dans un dépôt privé." \
  "Toutes les commandes.")
default=0; [[ "$sess" == open* ]] && default=1
UI_DESCS=("${descs[@]}"); UI_LABEL="Choix"
ui_choose "Que veux-tu faire ?" "$default" "${opts[@]}"
case "$UI_VALUE" in
  Ouvrir*) exec "$LOOMY_BIN" start ;;
  Suivre*) exec "$LOOMY_BIN" watch ;;
  Statut*) exec "$LOOMY_BIN" status ;;
  Visibilité*) exec "$LOOMY_BIN" privacy ;;
  *) exec "$LOOMY_BIN" help ;;
esac
