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

# L'accueil est une application plein écran : ce qu'on y consulte (statut, visibilité, aide, diagnostic) s'affiche
# dans le même écran, puis on y revient ; ouvrir la session ou le suivi passe la main. En quittant, rien ne reste
# dans l'historique du terminal.
TMPV="$(mktemp "${TMPDIR:-/tmp}/loomy-vue.XXXXXX")"
trap 'rm -f "$TMPV"' EXIT
leave() { rm -f "$TMPV"; UI_NO_DUMP=1; _ui_restore; trap - EXIT INT TERM; exit 0; }
view() {   # view <titre> <commande>... : sortie de la commande dans la visionneuse ; q quitte Loomy
  local title="$1"; shift
  LOOMY_NO_CLEAR=1 LOOMY_NO_HEADER=1 LOOMY_FORCE_COLOR=1 COLUMNS="$(_ui_term_size; echo "$UI_COLS")" "$@" >"$TMPV" 2>&1 </dev/null || true
  ui_pager "$title" "$TMPV"
  [[ "$UI_KEY" == "quit" ]] && leave
  return 0
}

# ---------------------------------------------------------------- hors d'un projet Loomy
if [[ ! -f "$ROOT/.loomy/brief.md" ]]; then
  while true; do
    ui_clear
    ui_banner "Bienvenue" "aucun projet Loomy dans ${PWD/#$HOME/~}"
    ui_print "${C_RAIL}│${C_RESET}"
    UI_LABEL="Choix"
    UI_DESCS=("Crée le dossier du projet (ou utilise celui-ci), puis le questionnaire et l'orchestrateur." \
      "Vérifie Claude Code, Codex, les modèles et les prérequis de la machine (les corrections se font avec loomy doctor --fix)." \
      "Toutes les commandes." "Ferme Loomy.")
    ui_choose "Que veux-tu faire ?" 0 "Créer un projet" "Vérifier la machine" "Aide" "Quitter"
    case "$UI_VALUE" in
      Créer*) ui_exec "$LOOMY_BIN" init ;;
      Vérifier*) view "Diagnostic de la machine" bash "$SCRIPT_DIR/ai-doctor.sh" ;;
      Aide) view "Aide" bash "$LOOMY_BIN" help ;;
      *) leave ;;
    esac
  done
fi

# ---------------------------------------------------------------- dans un projet
brief() { _ai_brief_get "$ROOT/.loomy/brief.md" "$1"; }
while true; do
  PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
  [[ -z "$PHASE" && ! -f "$ROOT/START.md" ]] && PHASE="done"
  [[ -z "$PHASE" ]] && PHASE="brief"
  idx="$(loomy_phase_index "$PHASE")"
  sess="$(ai_session_state "$ROOT")"

  ui_clear
  ui_banner "$(brief name)" "${ROOT/#$HOME/~}"
  ui_section "OÙ EN EST LE PROJET"
  if [[ "$PHASE" == "done" ]]; then ui_kv "Bootstrap" "${C_GREEN}terminé${C_RESET} · développement au quotidien"
  else ui_kv "Phase" "${C_BOLD}$(loomy_phase_label "$PHASE")${C_RESET} ${C_DIM}(étape $idx sur 10)${C_RESET}"; fi
  case "$sess" in
    open*) ui_kv "Session" "${C_GREEN}ouverte${C_RESET} depuis $(printf '%s' "$sess" | cut -d'|' -f2)" ;;
    closed*) ui_kv "Session" "${C_DIM}fermée à $(printf '%s' "$sess" | cut -d'|' -f2)${C_RESET}" ;;
    *) ui_kv "Session" "${C_DIM}pas encore ouverte${C_RESET}" ;;
  esac
  ui_kv "À toi" "$(loomy_you_now "$PHASE" "$sess")"
  newcat="$(bash "$SCRIPT_DIR/ai-catalog-check.sh" 2>/dev/null || true)"
  [[ -n "$newcat" ]] && ui_kv "Modèles" "${C_YELLOW}nouveau catalogue du $newcat${C_RESET} ${C_DIM}→ loomy update --catalog${C_RESET}"
  ui_print "${C_RAIL}│${C_RESET}"

  opts=("Ouvrir ou reprendre la session de l'orchestrateur" "Suivre en direct" "Statut détaillé" "Journal" "Visibilité des fichiers IA" "Aide" "Quitter")
  UI_DESCS=("loomy start : reprend la dernière session de ce projet, ou en ouvre une nouvelle au bon endroit." \
    "loomy watch : phases, délégations en cours et activité, en direct." \
    "loomy status : phases, brief, activité, coûts, fichiers IA et Git (ici, sans quitter l'accueil)." \
    "loomy log : phases, délégations, sessions et coûts, à l'heure locale." \
    "loomy privacy : fichiers IA versionnés, locaux ou dans un dépôt privé." \
    "Toutes les commandes." "Ferme Loomy.")
  default=0; [[ "$sess" == open* ]] && default=1
  UI_LABEL="Choix"
  ui_choose "Que veux-tu faire ?" "$default" "${opts[@]}"
  case "$UI_VALUE" in
    Ouvrir*) ui_exec "$LOOMY_BIN" start ;;
    Suivre*) ui_exec "$LOOMY_BIN" watch ;;
    Statut*) view "Statut détaillé" bash "$SCRIPT_DIR/ai-status.sh" --root "$ROOT" --full ;;
    Journal) view "Journal" bash "$SCRIPT_DIR/ai-log.sh" --root "$ROOT" -n 200 ;;
    Visibilité*) view "Visibilité des fichiers IA" bash "$SCRIPT_DIR/ai-privacy.sh" --root "$ROOT" ;;
    Aide) view "Aide" bash "$LOOMY_BIN" help ;;
    *) leave ;;
  esac
done
