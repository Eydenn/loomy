#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

worktrees_usage() {
  echo "Usage : loomy worktrees <tâche> [branche-de-base]"
  echo "Crée deux worktrees séparés (codex/<tâche> et claude/<tâche>) à côté du dépôt, pour le mode parallèle."
  echo "Exemple : loomy worktrees auth-refactor main"
}
case "${1:-}" in -h|--help) worktrees_usage; exit 0 ;; esac
if [[ $# -lt 1 || $# -gt 2 ]]; then
  worktrees_usage >&2
  exit 2
fi

TASK="$1"
BASE="${2:-HEAD}"

if [[ ! "$TASK" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  echo "Erreur : le nom de tâche commence par une lettre ou un chiffre, puis lettres, chiffres, points, tirets bas et tirets." >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  echo "Erreur : lancez ce script dans un dépôt Git." >&2
  exit 1
fi

cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Erreur : le répertoire de travail doit être propre avant de créer des worktrees parallèles." >&2
  echo "Committez ou mettez de côté (stash) les changements en cours d'abord." >&2
  exit 1
fi

PARENT="$(dirname "$ROOT")"
NAME="$(basename "$ROOT")"
CODEX_DIR="$PARENT/${NAME}-codex-$TASK"
CLAUDE_DIR="$PARENT/${NAME}-claude-$TASK"
CODEX_BRANCH="codex/$TASK"
CLAUDE_BRANCH="claude/$TASK"

for branch in "$CODEX_BRANCH" "$CLAUDE_BRANCH"; do
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    echo "Erreur : la branche existe déjà : $branch" >&2
    exit 1
  fi
done

for dir in "$CODEX_DIR" "$CLAUDE_DIR"; do
  if [[ -e "$dir" ]]; then
    echo "Erreur : le chemin existe déjà : $dir" >&2
    exit 1
  fi
done

git worktree add -q -b "$CODEX_BRANCH" "$CODEX_DIR" "$BASE"
git worktree add -q -b "$CLAUDE_BRANCH" "$CLAUDE_DIR" "$BASE"

ui_banner "Worktrees parallèles" "tâche $TASK · à partir de $BASE"
ui_section "CODEX"
ui_kv "Branche" "${C_BOLD}$CODEX_BRANCH${C_RESET}"
ui_kv "Chemin" "${CODEX_DIR/#$HOME/~}"
ui_section "CLAUDE"
ui_kv "Branche" "${C_BOLD}$CLAUDE_BRANCH${C_RESET}"
ui_kv "Chemin" "${CLAUDE_DIR/#$HOME/~}"
ui_section "ÉTAPES SUIVANTES"
ui_rail "${C_BRAND}1${C_RESET}  Ouvre le chemin Codex dans Codex, et le chemin Claude dans Claude Code."
ui_rail "${C_BRAND}2${C_RESET}  Donne à chaque outil un périmètre distinct et les mêmes critères d'acceptation."
ui_rail "${C_BRAND}3${C_RESET}  Chaque outil vérifie et committe avant l'intégration."
ui_end "suppression après intégration : git worktree remove <chemin>"
