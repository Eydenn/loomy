#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"

worktrees_usage() {
  t "Usage: loomy worktrees <task> [base-branch]"; echo
  t "Creates two separate worktrees (codex/<task> and claude/<task>) next to the repository, for parallel mode."; echo
  t "Example: loomy worktrees auth-refactor main"; echo
}
case "${1:-}" in -h|--help) worktrees_usage; exit 0 ;; esac
if [[ $# -lt 1 || $# -gt 2 ]]; then
  worktrees_usage >&2
  exit 2
fi

TASK="$1"
BASE="${2:-HEAD}"

if [[ ! "$TASK" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  t "Error: the task name starts with a letter or digit, then letters, digits, dots, underscores and hyphens." >&2; echo >&2
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$ROOT" ]]; then
  t "Error: run this script inside a Git repository." >&2; echo >&2
  exit 1
fi

cd "$ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  t "Error: the working tree must be clean before creating parallel worktrees." >&2; echo >&2
  t "Commit or stash the current changes first." >&2; echo >&2
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
    t "Error: the branch already exists: %s" "$branch" >&2; echo >&2
    exit 1
  fi
done

for dir in "$CODEX_DIR" "$CLAUDE_DIR"; do
  if [[ -e "$dir" ]]; then
    t "Error: the path already exists: %s" "$dir" >&2; echo >&2
    exit 1
  fi
done

git worktree add -q -b "$CODEX_BRANCH" "$CODEX_DIR" "$BASE"
git worktree add -q -b "$CLAUDE_BRANCH" "$CLAUDE_DIR" "$BASE"

ui_banner "$(t "Parallel worktrees")" "$(t "task %s · from %s" "$TASK" "$BASE")"
ui_section "CODEX"
ui_kv "$(t "Branch")" "${C_BOLD}$CODEX_BRANCH${C_RESET}"
ui_kv "$(t "Path")" "${CODEX_DIR/#$HOME/~}"
ui_section "CLAUDE"
ui_kv "$(t "Branch")" "${C_BOLD}$CLAUDE_BRANCH${C_RESET}"
ui_kv "$(t "Path")" "${CLAUDE_DIR/#$HOME/~}"
ui_section "$(t "NEXT STEPS")"
ui_rail "${C_BRAND}1${C_RESET}  $(t "Open the Codex path in Codex, and the Claude path in Claude Code.")"
ui_rail "${C_BRAND}2${C_RESET}  $(t "Give each tool a distinct scope and the same acceptance criteria.")"
ui_rail "${C_BRAND}3${C_RESET}  $(t "Each tool checks and commits before integration.")"
ui_end "$(t "removal after integration: git worktree remove <path>")"
