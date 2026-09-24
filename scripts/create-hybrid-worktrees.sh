#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage : $0 <tâche> [branche-de-base]" >&2
  echo "Exemple : $0 auth-refactor main" >&2
  exit 2
fi

TASK="$1"
BASE="${2:-HEAD}"

if [[ ! "$TASK" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  echo "Erreur : le nom de tâche ne peut contenir que des lettres, chiffres, points, tirets bas et tirets." >&2
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

git worktree add -b "$CODEX_BRANCH" "$CODEX_DIR" "$BASE"
git worktree add -b "$CLAUDE_BRANCH" "$CLAUDE_DIR" "$BASE"

cat <<MSG
Worktrees hybrides créés à partir de : $BASE

Codex :
  branche : $CODEX_BRANCH
  chemin :  $CODEX_DIR

Claude :
  branche : $CLAUDE_BRANCH
  chemin :  $CLAUDE_DIR

Étapes suivantes recommandées :
  1. Ouvrez le chemin Codex dans Codex.
  2. Ouvrez le chemin Claude dans Claude Code.
  3. Donnez à chaque outil un périmètre distinct et les mêmes critères d'acceptation.
  4. Exigez que chaque outil vérifie et committe avant l'intégration.
MSG
