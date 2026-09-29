#!/usr/bin/env bash
# On-demand cross review of the current branch or of uncommitted changes. Bash 3.2 compatible.
#   ai-review.sh                  the current branch against its base (main, or the remote's default branch);
#                                 uncommitted changes when the branch has no commit of its own
#   ai-review.sh <base>           against another base (branch, tag or commit)
#   ai-review.sh --staged         staged changes only        ai-review.sh --working   all uncommitted changes
#   ai-review.sh --tool claude|codex   reviewer's tool (by default the other family in hybrid mode)
#   ai-review.sh --print          shows what would be reviewed and by whom, without calling a model
# The reviewer is read-only; its findings are saved in .loomy/reviews/ and logged like any delegation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

ROOT=""; BASE=""; MODE="branch"; TOOL=""; PRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --staged) MODE="staged" ;;
    --working) MODE="working" ;;
    --tool) TOOL="${2:-}"; shift ;;
    --print) PRINT=1 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//; s/ai-review.sh/loomy review/g' | i18n_lines; exit 0 ;;
    -*) t "Unknown argument: %s (loomy review --help)" "$1" >&2; echo >&2; exit 2 ;;
    *) BASE="$1" ;;
  esac
  shift
done
case "$TOOL" in ""|claude|codex) ;; *) t "%s: claude or codex" "--tool" >&2; echo >&2; exit 2 ;; esac
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || { t "Error: folder not found: %s" "$ROOT" >&2; echo >&2; exit 1; }
git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { t "loomy review works in a Git repository." >&2; echo >&2; exit 1; }
cd "$ROOT" || exit 1

# ---------------------------------------------------------------- what to review
branch="$(git symbolic-ref --short -q HEAD 2>/dev/null || echo HEAD)"
if [[ "$MODE" == "branch" && -z "$BASE" ]]; then
  for c in "$(git symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null)" main master; do
    [[ -n "$c" && "$c" != "$branch" ]] && git rev-parse -q --verify "$c^{commit}" >/dev/null 2>&1 && { BASE="$c"; break; }
  done
fi
if [[ "$MODE" == "branch" && -n "$BASE" ]]; then
  git rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || { t "Unknown base: %s" "$BASE" >&2; echo >&2; exit 2; }
  mb="$(git merge-base "$BASE" HEAD 2>/dev/null || true)"
  if [[ -n "$mb" && "$(git rev-list --count "$mb..HEAD")" -gt 0 ]]; then DIFF_CMD="git diff $mb..HEAD"; LABEL="$(t "branch %s against %s" "$branch" "$BASE")"
  else MODE="working"; fi
elif [[ "$MODE" == "branch" ]]; then MODE="working"; fi
case "$MODE" in
  staged) DIFF_CMD="git diff --cached"; LABEL="$(t "staged changes")" ;;
  working) DIFF_CMD="git diff HEAD"; LABEL="$(t "uncommitted changes")" ;;
esac
# Loomy's own files (.loomy/) are not part of the review.
stat="$($DIFF_CMD --shortstat -- . ':(exclude).loomy' 2>/dev/null | sed 's/^ *//')"
DIFF_CMD="$DIFF_CMD -- . ':(exclude).loomy'"
untracked=""; [[ "$MODE" == "working" ]] && untracked="$(git ls-files --others --exclude-standard | grep -v '^\.loomy/' | head -50)"
if [[ -z "$stat" && -z "$untracked" ]]; then
  t "Nothing to review: %s is empty." "$LABEL"; echo; exit 0
fi

# ---------------------------------------------------------------- reviewer
if [[ -z "$TOOL" ]]; then
  ai_detect_env "$ROOT"
  TOOL="$(ai_family_for_role reviewer "$AI_ENV")"
  case "$TOOL" in claude) ai_has_claude || TOOL=codex ;; codex) ai_has_codex || TOOL=claude ;; *) TOOL=claude ;; esac
fi
ai_detect_env "$ROOT"
ai_route reviewer "$TOOL" "$AI_PROFILE"
tool_label="Claude Code"; [[ "$TOOL" == "codex" ]] && tool_label="Codex"

TASK="GOAL: review $LABEL in this repository, as an independent reviewer.
SCOPE: read-only. See the changes with: $DIFF_CMD$( [[ -n "$untracked" ]] && printf '%s' " (new untracked files too: $(printf '%s' "$untracked" | tr '\n' ' '))"). Read the surrounding code you need.
FILES: the changed files ($stat).
ACCEPTANCE: findings ordered by severity (blocking, important, minor), each with file:line, what is wrong, why it matters and a concrete fix; then missing tests, and what is good and should stay. No finding without evidence in the code. Change no file."

ui_clear
ui_banner "$(t "Cross review")" "${C_RESET}${C_TITLE}$(basename "$ROOT")${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
ui_section "REVIEW"
ui_kv "$(t "Changes")" "$LABEL${stat:+ · $stat}"
ui_kv "$(t "Reviewer")" "$tool_label · $R_MODEL ($R_EFFORT) · $(t "read-only")"
if (( PRINT )); then ui_end "$(t "run without --print to start the review")"; exit 0; fi
ui_end "$(t "review in progress, followed in loomy watch…")"

mkdir -p "$ROOT/.loomy/reviews"
OUTF="$ROOT/.loomy/reviews/$(date +%Y-%m-%d-%H%M)-$(printf '%s' "$branch" | tr -c 'A-Za-z0-9._-' '-').md"
if bash "$SCRIPT_DIR/delegate-to-$TOOL.sh" reviewer "$TASK" >"$OUTF.tmp"; then
  { echo "# $(t "Cross review") · $LABEL"; echo; echo "$tool_label · $R_MODEL · $(date '+%Y-%m-%d %H:%M')"; echo; cat "$OUTF.tmp"; } >"$OUTF"
  rm -f "$OUTF.tmp"
  cat "$OUTF"
  echo
  t "Saved in %s" "${OUTF#"$ROOT"/}"; echo
else
  rc=$?; rm -f "$OUTF.tmp"; t "The review failed (code %s): see loomy log." "$rc" >&2; echo >&2; exit "$rc"
fi
