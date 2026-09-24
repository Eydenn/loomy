#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOMY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat >&2 <<'EOF'
Usage : install-into-project.sh [dossier-cible] [options]

Copie le plan de contrôle du bootstrap (START.md + .loomy/) dans le dossier cible,
puis lance le questionnaire de projet interactif (init-wizard.sh).

Options :
  --no-wizard       Installer seulement, sans le questionnaire
  --yes             Remplir le brief sans questions, avec les valeurs par défaut
  --answers FICHIER Reprendre les réponses d'un brief.md existant
  --no-gum          Affichage ANSI simple même si gum est installé
  -h, --help        Afficher cette aide
EOF
}

TARGET_INPUT="."
RUN_WIZARD=1
WIZARD_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wizard) RUN_WIZARD=0 ;;
    --yes|-y|--no-gum|--no-clipboard) WIZARD_ARGS+=("$1") ;;
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

echo "Loomy $(cat "$LOOMY_ROOT/VERSION") installé dans : $TARGET" >&2

if (( RUN_WIZARD )); then
  wants_yes=0
  for a in ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}; do [[ "$a" == "--yes" || "$a" == "-y" ]] && wants_yes=1; done
  if [[ -t 0 && -t 2 ]] || (( wants_yes )); then
    exec "$TARGET/.loomy/scripts/init-wizard.sh" "$TARGET" ${WIZARD_ARGS[@]+"${WIZARD_ARGS[@]}"}
  fi
  echo "Terminal non interactif : questionnaire ignoré. Lancez-le plus tard : .loomy/scripts/init-wizard.sh" >&2
fi

cat <<MSG
Étape suivante :
  Remplissez le brief du projet :   .loomy/scripts/init-wizard.sh
  Puis ouvrez le dépôt avec Codex ou Claude Code et dites :
  "Initialise ce projet en suivant START.md. Reste en mode analyse/plan jusqu'à ma validation."
MSG
