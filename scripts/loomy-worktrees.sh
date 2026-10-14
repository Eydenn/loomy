#!/usr/bin/env bash
# Isolate parallel file scopes while sharing the main project's delegation journal.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
worktrees_usage() {
  t "Usage: loomy worktrees <task> [base-branch] [--count N]"; echo
  t "Creates two family worktrees by default, or N independent subtask worktrees sharing the project's .loomy."; echo
  t "Example: loomy worktrees auth-refactor main"; echo
}
case "${1:-}" in -h|--help) worktrees_usage; exit 0 ;; esac
[[ $# -gt 0 ]] || { worktrees_usage >&2; exit 2; }
TASK="$1"; shift
BASE=HEAD; COUNT=2; NUMBERED=0; BASE_SET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --count) COUNT="${2:-}"; NUMBERED=1; [[ $# -gt 1 ]] || { worktrees_usage >&2; exit 2; }; shift ;;
    -*) worktrees_usage >&2; exit 2 ;;
    *) (( BASE_SET == 0 )) || { worktrees_usage >&2; exit 2; }; BASE="$1"; BASE_SET=1 ;;
  esac
  shift
done
[[ "$COUNT" =~ ^[1-9][0-9]*$ && ${#COUNT} -le 3 ]] && (( COUNT <= 128 )) || { worktrees_usage >&2; exit 2; }
if [[ ! "$TASK" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
  t "Error: the task name starts with a letter or digit, then letters, digits, dots, underscores and hyphens." >&2; echo >&2; exit 2
fi
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || { t "Error: run this script inside a Git repository." >&2; echo >&2; exit 1; }
cd "$ROOT"
[[ -z "$(git status --porcelain)" ]] || {
  t "Error: the working tree must be clean before creating parallel worktrees." >&2; echo >&2
  t "Commit or stash the current changes first." >&2; echo >&2; exit 1
}
git rev-parse --verify "$BASE^{commit}" >/dev/null
MAIN="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
SHARED=""; [[ ! -d "$MAIN/.loomy" ]] || SHARED="$(cd "$MAIN/.loomy" && pwd -P)"
# Versioned AI files: every worktree checks out its own tracked .loomy, so only the local journal folder is linked.
# A tracked path where the link goes would conflict with it; never replace it.
SHARE_LOGS=0
if [[ -n "$SHARED" && -n "$(git ls-tree "$BASE" -- .loomy)" ]]; then
  if [[ -n "$(git ls-tree "$BASE" -- .loomy/logs)" ]]; then
    t "Error: .loomy/logs is tracked at the base revision; untrack it before sharing worktrees." >&2; echo >&2; exit 1
  fi
  SHARE_LOGS=1
fi
PARENT="$(dirname "$MAIN")"; NAME="$(basename "$MAIN")"
BRANCHES=(); DIRS=(); LABELS=()
for (( i=1; i<=COUNT; i++ )); do
  if (( NUMBERED )); then label="task-$i"; branch="loomy/$TASK/$i"; dir="$PARENT/${NAME}-$TASK-$i"
  elif (( i == 1 )); then label=codex; branch="codex/$TASK"; dir="$PARENT/${NAME}-codex-$TASK"
  else label=claude; branch="claude/$TASK"; dir="$PARENT/${NAME}-claude-$TASK"; fi
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    t "Error: the branch already exists: %s" "$branch" >&2; echo >&2; exit 1
  fi
  if [[ -e "$dir" || -L "$dir" ]]; then
    t "Error: the path already exists: %s" "$dir" >&2; echo >&2; exit 1
  fi
  BRANCHES+=("$branch"); DIRS+=("$dir"); LABELS+=("$label")
done
ui_banner "$(t "Parallel worktrees")" "$(t "task %s · from %s" "$TASK" "$BASE")"
for (( i=0; i<COUNT; i++ )); do
  git worktree add -q -b "${BRANCHES[i]}" "${DIRS[i]}" "$BASE"
  if [[ -n "$SHARED" ]]; then
    link=/.loomy
    if (( SHARE_LOGS )); then
      link=/.loomy/logs
      mkdir -p "$SHARED/logs"; mkdir -p "${DIRS[i]}/.loomy"
      ln -s "$SHARED/logs" "${DIRS[i]}/.loomy/logs"
    else
      ln -s "$SHARED" "${DIRS[i]}/.loomy"
    fi
    # Per-worktree excludes share the common Git directory.
    exclude="$(git -C "${DIRS[i]}" rev-parse --git-path info/exclude)"
    [[ "$exclude" == /* ]] || exclude="${DIRS[i]}/$exclude"
    mkdir -p "$(dirname "$exclude")"
    grep -qxF "$link" "$exclude" 2>/dev/null || printf '\n%s\n' "$link" >>"$exclude"
  fi
  ui_section "${LABELS[i]}"
  ui_kv "$(t "Branch")" "${C_BOLD}${BRANCHES[i]}${C_RESET}"
  ui_kv "$(t "Path")" "${DIRS[i]/#$HOME/~}"
done
ui_section "$(t "NEXT STEPS")"
ui_rail "$(t "Give each tool a distinct scope and the same acceptance criteria.")"
ui_rail "$(t "Each tool checks and commits before integration.")"
ui_end "$(t "removal after integration: git worktree remove <path>")"
