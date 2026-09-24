#!/usr/bin/env bash
# Crée ou initialise un projet Loomy, ou reprend un projet déjà initialisé. Compatible bash 3.2.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOMY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"

usage() {
  cat <<'EOF'
Usage : loomy init [dossier] [options]

Nouveau projet : copie START.md et .loomy/ dans le dossier, puis lance le questionnaire.
Projet déjà initialisé : propose de reprendre, mettre à jour, refaire le questionnaire ou réinitialiser.

Options :
  --update          Met à jour les fichiers Loomy du projet (scripts, modèles) ; garde brief, phase et journal
  --reset           Réinitialise le bootstrap : START.md recopié, phase remise à zéro, questionnaire relancé
  --no-wizard       Installer seulement, sans le questionnaire
  --yes             Remplir le brief sans questions, avec les valeurs par défaut
  --answers FICHIER Reprendre les réponses d'un brief.md existant
  -h, --help        Afficher cette aide
EOF
}

TARGET_INPUT="."; RUN_WIZARD=1; WIZARD_ARGS=(); ACTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wizard) RUN_WIZARD=0 ;;
    --update) ACTION="update" ;;
    --reset) ACTION="reset" ;;
    --yes|-y|--no-clipboard) WIZARD_ARGS+=("$1") ;;
    --answers) WIZARD_ARGS+=("$1" "${2:-}"); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Erreur : option inconnue $1" >&2; usage >&2; exit 2 ;;
    *) TARGET_INPUT="$1" ;;
  esac
  shift
done

if [[ ! -d "$TARGET_INPUT" ]]; then
  echo "Erreur : le dossier cible n'existe pas : $TARGET_INPUT" >&2
  exit 1
fi
TARGET="$(cd "$TARGET_INPUT" && pwd)"
L="$TARGET/.loomy"
NEW_V="$(cat "$LOOMY_ROOT/VERSION")"

# Copie des fichiers gérés par Loomy. Brief, phase (state) et journal (logs) ne sont jamais touchés.
copy_loomy_files() {
  local d
  mkdir -p "$L"
  for d in templates agents skills scripts external-skills; do
    rm -rf "${L:?}/$d"
    cp -R "$LOOMY_ROOT/$d" "$L/"
  done
  cp "$LOOMY_ROOT/VERSION" "$L/VERSION"
  # Le journal d'activité contient le texte des tâches déléguées : il reste local.
  if ! grep -qxF '.loomy/logs/' "$TARGET/.gitignore" 2>/dev/null; then
    printf '\n# Loomy : journal d\x27activité local\n.loomy/logs/\n' >>"$TARGET/.gitignore"
  fi
}

run_wizard() {
  local wants_yes=0 a
  for a in ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}; do [[ "$a" == "--yes" || "$a" == "-y" ]] && wants_yes=1; done
  if [[ -t 0 && -t 2 ]] || (( wants_yes )); then
    exec "$L/scripts/init-wizard.sh" "$TARGET" "$@" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}
  fi
  return 0
}

# ---------------------------------------------------------------- projet déjà initialisé
if [[ -e "$TARGET/START.md" && ! -d "$L" ]]; then
  echo "Erreur : $TARGET/START.md existe mais ne vient pas de Loomy (pas de dossier .loomy). Écrasement refusé." >&2
  exit 1
fi

if [[ -d "$L" && ( -f "$L/VERSION" || -f "$L/brief.md" ) ]]; then
  OLD_V="$(cat "$L/VERSION" 2>/dev/null || echo "?")"
  PHASE="$(sed -n 's/^phase=//p' "$L/state" 2>/dev/null | head -1 || true)"
  IN_PROGRESS=0; [[ -f "$TARGET/START.md" ]] && IN_PROGRESS=1
  if (( ! IN_PROGRESS )); then PHASE="done"; fi

  do_update() {
    copy_loomy_files
    if (( IN_PROGRESS )); then cp "$LOOMY_ROOT/START.md" "$TARGET/START.md"; fi
    ui_ok "Loomy mis à jour dans le projet" "v$OLD_V → v$NEW_V · brief, phase et journal conservés"
  }
  do_reset() {
    copy_loomy_files
    cp "$LOOMY_ROOT/START.md" "$TARGET/START.md"
    rm -f "$L/state"
    if [[ -f "$L/brief.md" ]]; then mv "$L/brief.md" "$L/brief.previous.md"; fi
    ui_ok "Bootstrap réinitialisé" "START.md recopié, phase remise à zéro ; ancien brief : .loomy/brief.previous.md"
    ui_warn "Fichiers déjà créés par l'agent conservés" "AGENTS.md, CLAUDE.md, PROJECT.md… l'orchestrateur les reprendra"
  }

  ui_clear
  ui_banner "Projet déjà initialisé" "${TARGET/#$HOME/~}"
  ui_section "ÉTAT"
  ui_kv "Loomy" "v$OLD_V dans le projet · v$NEW_V installé"
  ui_kv "Bootstrap" "$( (( IN_PROGRESS )) && echo "en cours · phase $(loomy_phase_label "$PHASE")" || echo "terminé")"
  if [[ "$OLD_V" != "$NEW_V" ]]; then ui_warn "Version du projet différente" "la mise à jour garde ton brief, ta phase et ton journal"; fi

  if [[ -z "$ACTION" ]]; then
    if ! ui_is_interactive; then
      ui_section "QUE FAIRE ?"
      ui_rail "${C_BOLD}loomy start${C_RESET}           ${C_DIM}reprendre la session de l'orchestrateur${C_RESET}"
      ui_rail "${C_BOLD}loomy init --update${C_RESET}   ${C_DIM}mettre à jour les fichiers Loomy du projet${C_RESET}"
      ui_rail "${C_BOLD}loomy brief${C_RESET}           ${C_DIM}refaire le questionnaire${C_RESET}"
      ui_rail "${C_BOLD}loomy init --reset${C_RESET}    ${C_DIM}réinitialiser le bootstrap${C_RESET}"
      ui_end "rien n'a été modifié"
      exit 1
    fi
    ui_print "${C_RAIL}│${C_RESET}"
    opts=("Reprendre la session de l'orchestrateur"); descs=("Ouvre loomy start : reprend la dernière session de ce dossier, ou en ouvre une nouvelle au bon endroit du projet.")
    if [[ "$OLD_V" != "$NEW_V" ]]; then
      opts+=("Mettre à jour Loomy dans ce projet (v$OLD_V → v$NEW_V)"); descs+=("Recopie scripts et modèles de la version installée. Brief, phase et journal conservés. Recommandé.")
    else
      opts+=("Réinstaller les fichiers Loomy du projet"); descs+=("Recopie scripts et modèles (même version), par exemple s'ils ont été modifiés. Brief, phase et journal conservés.")
    fi
    if (( IN_PROGRESS )); then opts+=("Refaire le questionnaire"); descs+=("Tes réponses actuelles servent de valeurs par défaut ; le brief n'est remplacé qu'après confirmation."); fi
    opts+=("Réinitialiser le projet"); descs+=("Repart du début du bootstrap : START.md recopié, phase remise à zéro, questionnaire relancé. Les fichiers déjà créés par l'agent restent.")
    opts+=("Annuler"); descs+=("Ne modifie rien.")
    UI_DESCS=("${descs[@]}"); UI_LABEL="Choix"
    default=0; [[ "$OLD_V" != "$NEW_V" ]] && default=1
    ui_choose "Que veux-tu faire ?" "$default" "${opts[@]}"
    case "$UI_VALUE" in
      Reprendre*) ui_end "ouverture de loomy start…"; exec bash "$SCRIPT_DIR/ai-start.sh" --root "$TARGET" ;;
      Mettre*|Réinstaller*) ACTION="update" ;;
      Refaire*) ACTION="brief" ;;
      Réinitialiser*)
        UI_DESCS=("Repart de la phase Brief. Rien n'est supprimé en dehors de .loomy/state." "Ne modifie rien.")
        UI_LABEL="Confirmation"
        ui_choose "Réinitialiser le bootstrap de ce projet ?" 1 "Oui, réinitialiser" "Non"
        if [[ "$UI_VALUE" == Oui* ]]; then ACTION="reset"; else ui_end "rien n'a été modifié"; exit 0; fi ;;
      *) ui_end "rien n'a été modifié"; exit 0 ;;
    esac
  fi

  case "$ACTION" in
    update)
      do_update
      ui_end "reprendre : loomy start · suivi : loomy watch"
      exit 0 ;;
    brief)
      ui_end "questionnaire…"
      exec "$L/scripts/init-wizard.sh" "$TARGET" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"} ;;
    reset)
      do_reset
      if (( RUN_WIZARD )); then
        answers=(); [[ -f "$L/brief.previous.md" ]] && answers=(--answers "$L/brief.previous.md")
        ui_end "questionnaire (tes anciennes réponses servent de valeurs par défaut)…"
        run_wizard ${answers[@]+"${answers[@]}"}
      fi
      ui_end "remplis le brief : loomy brief · puis : loomy start"
      exit 0 ;;
  esac
fi

# ---------------------------------------------------------------- nouveau projet
if [[ "$ACTION" == "update" ]]; then
  echo "Erreur : pas de projet Loomy dans $TARGET à mettre à jour. Lancez loomy init pour le créer." >&2
  exit 1
fi
copy_loomy_files
cp "$LOOMY_ROOT/START.md" "$TARGET/START.md"

if (( RUN_WIZARD )); then run_wizard; fi

brief_cmd=".loomy/scripts/init-wizard.sh"; command -v loomy >/dev/null 2>&1 && brief_cmd="loomy brief"
ui_banner "Loomy installé" "v$NEW_V · ${TARGET/#$HOME/~}"
if (( RUN_WIZARD )); then ui_warn "Terminal non interactif" "questionnaire ignoré"; fi
ui_section "ÉTAPE SUIVANTE"
ui_rail "${C_BRAND}1${C_RESET}  Remplis le brief du projet : ${C_BOLD}${brief_cmd}${C_RESET}"
ui_rail "${C_BRAND}2${C_RESET}  Lance l'orchestrateur : ${C_BOLD}loomy start${C_RESET}"
ui_end "START.md, .loomy/ et une ligne de .gitignore ajoutés ; rien d'autre n'est modifié"
