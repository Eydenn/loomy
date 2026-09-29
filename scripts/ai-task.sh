#!/usr/bin/env bash
# A named task handed to the lead agent after the bootstrap, followed in loomy watch. Bash 3.2 compatible.
#   ai-task.sh "<what to do>"     creates the task and opens the lead agent session on it
#   ai-task.sh                    lists the tasks (the current one first)
#   ai-task.sh --resume           reopens the session on the current task, at its phase
#   ai-task.sh --print            prepares the task and shows the command instead of opening the session
# Phases: plan, approval, build, verification (tests and loomy review), commit. The lead agent keeps the plan and
# a progress checklist in .loomy/tasks/<n>-<name>.md; .loomy/TASKS.md lists every task.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
loomy_phases_mode task

ROOT=""; RESUME=0; PRINT=0; DESC=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --resume) RESUME=1 ;;
    --print) PRINT=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//; s/ai-task.sh/loomy task/g' | i18n_lines; exit 0 ;;
    -*) t "Unknown argument: %s (loomy task --help)" "$1" >&2; echo >&2; exit 2 ;;
    *) DESC="${DESC:+$DESC }$1" ;;
  esac
  shift
done
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || { t "Error: folder not found: %s" "$ROOT" >&2; echo >&2; exit 1; }
BRIEF="$ROOT/.loomy/brief.md"
[[ -f "$BRIEF" ]] || { t "No Loomy project in %s: create it first with loomy init." "${ROOT/#$HOME/~}" >&2; echo >&2; exit 1; }
loomy_project_register "$ROOT"
TASKS_DIR="$ROOT/.loomy/tasks"; STATE_T="$ROOT/.loomy/task.state"; INDEX="$ROOT/.loomy/TASKS.md"
state_get() { sed -n "s/^$1=//p" "$STATE_T" 2>/dev/null | head -1; }

# ---------------------------------------------------------------- list
if [[ -z "$DESC" ]] && (( ! RESUME )); then
  ui_clear
  ui_banner "$(t "Tasks")" "${C_RESET}${C_TITLE}$(_ai_brief_get "$BRIEF" name)${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
  ui_section "$(t "TASKS")"
  if ! ls "$TASKS_DIR"/*.md >/dev/null 2>&1; then
    ui_info "$(t "no task yet: loomy task \"what to do\"")"
  else
    cur_id="$(state_get id)"; cur_phase="$(state_get phase)"
    while IFS= read -r f; do
      id="$(sed -n 's/^id: //p' "$f" | head -1)"; title="$(sed -n 's/^title: //p' "$f" | head -1)"
      if [[ "$id" == "$cur_id" && "$cur_phase" != "done" ]]; then mark="${C_BRAND}▶${C_RESET}"; st="$(loomy_phase_label "$cur_phase")"
      elif [[ "$id" == "$cur_id" ]]; then mark="${C_GREEN}✓${C_RESET}"; st="$(t "done")"
      else st="$(sed -n 's/^status: //p' "$f" | head -1)"; mark="${C_DIM}·${C_RESET}"; [[ "$st" == "done" ]] && { mark="${C_GREEN}✓${C_RESET}"; st="$(t "done")"; }; fi
      ui_rail "$mark #$id  ${C_BOLD}$title${C_RESET}  ${C_DIM}$st${C_RESET}"
    done < <(ls -r "$TASKS_DIR"/*.md | head -15)
  fi
  ui_end "$(t "new task: loomy task \"…\" · resume: loomy task --resume")"
  exit 0
fi

# ---------------------------------------------------------------- new task
cur_phase="$(state_get phase)"
if (( ! RESUME )); then
  if [[ -n "$cur_phase" && "$cur_phase" != "done" ]] && ui_is_interactive; then
    UI_DESCS=("$(t "The current task stays unfinished in the list; the new one becomes the current task.")" "$(t "Opens nothing.")")
    ui_choose "$(t "Task #%s is not finished (%s). Start the new one anyway?" "$(state_get id)" "$(loomy_phase_label "$cur_phase")")" 1 "$(t "Yes, start it")" "$(t "Cancel")"
    [[ "$UI_INDEX" == "0" ]] || { UI_NO_DUMP=1; _ui_restore; exit 0; }
  fi
  mkdir -p "$TASKS_DIR" "$ROOT/.loomy/logs"
  n=1; for f in "$TASKS_DIR"/*.md; do [[ -f "$f" ]] || continue; k="$(basename "$f" | sed 's/-.*//; s/^0*//')"; [[ "$k" =~ ^[0-9]+$ ]] && (( k >= n )) && n=$(( k + 1 )); done
  ID="$n"
  TITLE="$(printf '%s' "$DESC" | tr '\n\t' '  ' | LC_ALL=C tr -d '\000-\037' | cut -c1-120)"
  slug="$(loomy_slug "$(printf '%s' "$TITLE" | cut -c1-40)")"
  TFILE="$TASKS_DIR/$(printf '%03d' "$ID")-${slug:-task}.md"
  # The previous current task keeps its last phase in its file.
  if [[ -n "$cur_phase" ]]; then
    prev="$(ls "$TASKS_DIR"/"$(printf '%03d' "$(state_get id)")"-*.md 2>/dev/null | head -1)"
    [[ -n "$prev" ]] && sed -i.bak "s/^status: .*/status: $cur_phase/" "$prev" && rm -f "$prev.bak"
  fi
  {
    echo "---"; echo "id: $ID"; echo "title: $TITLE"; echo "started: $(date '+%Y-%m-%d %H:%M')"; echo "status: plan"; echo "---"; echo
    echo "# #$ID · $TITLE"; echo
    echo "## Request"; echo; printf '%s\n' "$DESC"; echo
    echo "## Plan"; echo; echo "_(written by the lead agent during the plan phase)_"; echo
    echo "## Progress"; echo; echo "_(checklist kept up to date by the lead agent)_"; echo
    echo "## Result"; echo
  } >"$TFILE"
  printf 'id=%s\ntitle=%s\nfile=%s\n' "$ID" "$TITLE" "${TFILE#"$ROOT"/}" >"$STATE_T"
  bash "$SCRIPT_DIR/ai-status.sh" --root "$ROOT" --task set plan >/dev/null
  cur_phase="plan"
else
  [[ -n "$cur_phase" ]] || { t "No task to resume here: loomy task \"what to do\"." >&2; echo >&2; exit 1; }
  ID="$(state_get id)"; TITLE="$(state_get title)"; TFILE="$ROOT/$(state_get file)"
fi
# Index of every task (.loomy/TASKS.md), rebuilt from the task files.
{
  echo "# Tasks"; echo
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    id="$(sed -n 's/^id: //p' "$f" | head -1)"; st="$(sed -n 's/^status: //p' "$f" | head -1)"
    [[ "$id" == "$ID" ]] && st="$cur_phase"
    echo "- [$( [[ "$st" == "done" ]] && echo x || echo " ")] #$id $(sed -n 's/^title: //p' "$f" | head -1) ($st) · tasks/$(basename "$f")"
  done < <(ls -r "$TASKS_DIR"/*.md 2>/dev/null)
} >"$INDEX"

# ---------------------------------------------------------------- lead agent
ai_detect_env "$ROOT"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
TOOL="$R_FAMILY"; MODEL="$R_MODEL"; EFFORT="$R_EFFORT"
if [[ "${LOOMY_NO_SWITCH:-}" != "1" ]] && sw="$(ai_switch_family "$TOOL")" && [[ -n "$sw" ]]; then
  ai_route lead "$sw" "$AI_PROFILE"; TOOL="$sw"; MODEL="$R_MODEL"; EFFORT="$R_EFFORT"
fi
tool_label="Claude Code"; [[ "$TOOL" == "codex" ]] && tool_label="Codex"
REL="${TFILE#"$ROOT"/}"
SET=".loomy/scripts/ai-status.sh --task set"
[[ -x "$ROOT/.loomy/scripts/ai-status.sh" ]] || SET="bash \"$SCRIPT_DIR/ai-status.sh\" --root \"$ROOT\" --task set"
REVIEW=".loomy/scripts/ai-review.sh"; [[ -x "$ROOT/$REVIEW" ]] || REVIEW="bash \"$SCRIPT_DIR/ai-review.sh\" --root \"$ROOT\""
if (( RESUME )); then
  PROMPT="Resume task #$ID ($TITLE) where it stopped: phase \"$cur_phase\". Reread $REL (plan and progress), check the repository state, summarise where the task stands in two sentences, then continue with the same rules: record each phase change with: $SET <phase>."
else
  PROMPT="You are the lead agent of this project (follow AGENTS.md or CLAUDE.md and the routing in .loomy/scripts/ai-route.sh). New task #$ID: $TITLE
The task file is $REL: keep it up to date (Plan, Progress checklist, Result).
Record each phase change before acting, with: $SET <phase>   and announce it on one line: \"Task n/5 · Name\".
1. plan: read the code involved, write a short plan in the task file (steps, files, risks, how it will be checked), then present it.
2. approve: wait for the user's go-ahead or changes; do not change code before it.
3. build: do the work, delegating to the roles as usual (bridges in the foreground); tick the Progress checklist as you go, so a long task can be resumed.
4. verify: run the project's tests and checks, then a cross review of the changes: $REVIEW --working (or against the base branch); fix what is blocking.
5. commit: propose the commit (message, files) and commit only once the user agrees; never push unless asked.
Finish with: $SET done, write the Result section (what changed, checks, open points), and give a three-line summary."
fi
if [[ "$TOOL" == "claude" ]]; then AGENT_CMD=(claude --model "$MODEL" --effort "$EFFORT" "$PROMPT")
else CODEX="$(ai_codex_bin 2>/dev/null || echo codex)"; AGENT_CMD=("$CODEX" -m "$MODEL" -c "model_reasoning_effort=$EFFORT" "$PROMPT"); fi

ui_clear
ui_banner "$(t "Task")" "${C_RESET}${C_TITLE}$(_ai_brief_get "$BRIEF" name)${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
ui_section "$(t "TASK")"
ui_kv "Task" "#$ID · ${C_BOLD}$TITLE${C_RESET}"
ui_kv "$(t "File")" "$REL"
ui_kv "$(t "Lead agent")" "$tool_label · $MODEL ($EFFORT)"
ui_kv "$(t "Phase")" "$(loomy_phase_label "$cur_phase") ${C_DIM}($(t "step %s of %s" "$(loomy_phase_index "$cur_phase")" "$LOOMY_PHASE_COUNT"))${C_RESET}"
if (( PRINT )) || ! ui_is_interactive; then
  printf '%s\n' "$PROMPT" >"$ROOT/.loomy/task-prompt.txt"
  ui_rail ""
  ui_rail "$(t "Open the lead agent session in this folder:")"
  ui_rail "   ${C_BOLD}$(printf '%q ' "${AGENT_CMD[@]:0:${#AGENT_CMD[@]}-1}")\"<prompt>\"${C_RESET}"
  ui_rail "   ${C_DIM}$(t "prompt saved in %s" ".loomy/task-prompt.txt")${C_RESET}"
  ui_end "$(t "live tracking: loomy watch")"
  exit 0
fi
ui_end "$(t "opening %s…" "$tool_label") · $(t "live tracking in another terminal: loomy watch")"
cd "$ROOT" || exit 1
if [[ "$TOOL" == "codex" ]] || ! grep -qs "ai-context.sh" "$ROOT/.claude/settings.json"; then
  ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"$TOOL\",\"pid\":$$"
fi
ui_exec "${AGENT_CMD[@]}"
