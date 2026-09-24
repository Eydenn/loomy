#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOMY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

usage() {
  cat >&2 <<'EOF'
Usage : install-into-project.sh [dossier-cible] [options]

Copie le plan de contrôle du bootstrap (START.md + .loomy/) dans le dossier cible,
puis lance le questionnaire de projet interactif (init-wizard.sh).

Options :
  --no-wizard       Installer seulement, sans le questionnaire
  --yes             Remplir le brief sans questions, avec les valeurs par défaut
  --answers FICHIER Reprendre les réponses d'un brief.md existant
  -h, --help        Afficher cette aide
EOF
}

TARGET_INPUT="."
RUN_WIZARD=1
WIZARD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wizard) RUN_WIZARD=0 ;;
    --yes|-y|--no-clipboard) WIZARD_ARGS+=("$1") ;;
    --answers) WIZARD_ARGS+=("$1" "${2:-}"); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "Erreur : option inconnue $1" >&2; usage; exit 2 ;;
    *) TARGET_INPUT="$1" ;;
  esac
  shift
done

if [[ ! -d "$TARGET_INPUT" ]]; then
  echo "Erreur : le dossier cible n'existe pas : $TARGET_INPUT" >&2
  exit 1
fi
TARGET="$(cd "$TARGET_INPUT" && pwd)"

if [[ -e "$TARGET/START.md" ]]; then
  echo "Erreur : $TARGET/START.md existe déjà. Écrasement refusé." >&2
  exit 1
fi

mkdir -p "$TARGET/.loomy"
cp "$LOOMY_ROOT/START.md" "$TARGET/START.md"
cp -R "$LOOMY_ROOT/templates" "$TARGET/.loomy/"
cp -R "$LOOMY_ROOT/agents" "$TARGET/.loomy/"
cp -R "$LOOMY_ROOT/skills" "$TARGET/.loomy/"
cp -R "$LOOMY_ROOT/scripts" "$TARGET/.loomy/"
cp -R "$LOOMY_ROOT/external-skills" "$TARGET/.loomy/"
cp "$LOOMY_ROOT/VERSION" "$TARGET/.loomy/VERSION"

# Le journal d'activité contient le texte des tâches déléguées : il reste local.
if ! grep -qxF '.loomy/logs/' "$TARGET/.gitignore" 2>/dev/null; then
  printf '\n# Loomy : journal d\x27activité local\n.loomy/logs/\n' >>"$TARGET/.gitignore"
fi

if (( RUN_WIZARD )); then
  wants_yes=0
  for a in ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}; do [[ "$a" == "--yes" || "$a" == "-y" ]] && wants_yes=1; done
  if [[ -t 0 && -t 2 ]] || (( wants_yes )); then
    exec "$TARGET/.loomy/scripts/init-wizard.sh" "$TARGET" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}
  fi
fi

brief_cmd=".loomy/scripts/init-wizard.sh"; command -v loomy >/dev/null 2>&1 && brief_cmd="loomy brief"
ui_banner "Loomy installé" "v$(cat "$LOOMY_ROOT/VERSION") · ${TARGET/#$HOME/~}"
if (( RUN_WIZARD )); then ui_warn "Terminal non interactif" "questionnaire ignoré"; fi
ui_section "ÉTAPE SUIVANTE"
ui_rail "${C_BRAND}1${C_RESET}  Remplis le brief du projet : ${C_BOLD}${brief_cmd}${C_RESET}"
ui_rail "${C_BRAND}2${C_RESET}  Ouvre le dépôt avec Codex ou Claude Code et dis :"
ui_rail "   ${C_DIM}Initialise ce projet en suivant START.md. Reste en mode analyse/plan jusqu'à ma validation.${C_RESET}"
ui_end "START.md, .loomy/ et une ligne de .gitignore ajoutés ; rien d'autre n'est modifié"
