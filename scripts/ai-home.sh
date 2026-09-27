#!/usr/bin/env bash
# Home screen of "loomy" without arguments: where the project stands, what's expected, and the next step in one choice. Bash 3.2 compatible.
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

# The home screen is a full-screen app: what you open there (status, visibility, help, check) is shown
# in the same screen, then you come back; opening the session or live tracking hands over. On exit, nothing is left
# in the terminal history.
TMPV="$(mktemp "${TMPDIR:-/tmp}/loomy-vue.XXXXXX")"
trap 'rm -f "$TMPV"' EXIT
leave() { rm -f "$TMPV"; UI_NO_DUMP=1; _ui_restore; trap - EXIT INT TERM; exit 0; }
view() {   # view <title> <command>...: command output in the viewer; q quits Loomy
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
    ui_banner "$(t "Welcome")" "$(t "no Loomy project in %s" "${PWD/#$HOME/~}")"
    ui_print "${C_RAIL}│${C_RESET}"
    UI_LABEL="$(t "Choice")"
    UI_DESCS=("$(t "Creates the project folder (or uses this one), then the questionnaire and the lead agent.")" \
      "$(t "Checks Claude Code, Codex, the models and the machine's prerequisites (fixes are done with loomy doctor --fix).")" \
      "$(t "All commands.")" "$(t "Closes Loomy.")")
    ui_choose "$(t "What do you want to do?")" 0 "$(t "Create a project")" "$(t "Check the machine")" "$(t "Help")" "$(t "Quit")"
    case "$UI_INDEX" in
      0) ui_exec "$LOOMY_BIN" init ;;
      1) view "$(t "Machine check")" bash "$SCRIPT_DIR/ai-doctor.sh" ;;
      2) view "$(t "Help")" bash "$LOOMY_BIN" help ;;
      *) leave ;;
    esac
  done
fi

# ---------------------------------------------------------------- inside a project
brief() { _ai_brief_get "$ROOT/.loomy/brief.md" "$1"; }
while true; do
  PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
  [[ -z "$PHASE" && ! -f "$ROOT/START.md" ]] && PHASE="done"
  [[ -z "$PHASE" ]] && PHASE="brief"
  idx="$(loomy_phase_index "$PHASE")"
  sess="$(ai_session_state "$ROOT")"

  ui_clear
  ui_banner "$(brief name)" "${ROOT/#$HOME/~}"
  ui_section "$(t "WHERE THE PROJECT STANDS")"
  if [[ "$PHASE" == "done" ]]; then ui_kv "Bootstrap" "${C_GREEN}$(t "done")${C_RESET} · $(t "day-to-day development")"
  else ui_kv "$(t "Phase")" "${C_BOLD}$(loomy_phase_label "$PHASE")${C_RESET} ${C_DIM}($(t "step %s of 10" "$idx"))${C_RESET}"; fi
  case "$sess" in
    open*) ui_kv "Session" "${C_GREEN}$(t "open")${C_RESET} $(t "since %s" "$(printf '%s' "$sess" | cut -d'|' -f2)")" ;;
    closed*) ui_kv "Session" "${C_DIM}$(t "closed at %s" "$(printf '%s' "$sess" | cut -d'|' -f2)")${C_RESET}" ;;
    *) ui_kv "Session" "${C_DIM}$(t "not opened yet")${C_RESET}" ;;
  esac
  ui_kv "$(t "Your turn")" "$(loomy_you_now "$PHASE" "$sess")"
  newcat="$(bash "$SCRIPT_DIR/ai-catalog-check.sh" 2>/dev/null || true)"
  [[ -n "$newcat" ]] && ui_kv "$(t "Models")" "${C_YELLOW}$(t "new catalog from %s" "$newcat")${C_RESET} ${C_DIM}→ loomy update --catalog${C_RESET}"
  ui_print "${C_RAIL}│${C_RESET}"

  opts=("$(t "Open or resume the lead agent session")" "$(t "Live tracking")" "$(t "Detailed status")" "$(t "Log")" "$(t "AI files visibility")" "$(t "Help")" "$(t "Quit")")
  UI_DESCS=("$(t "loomy start: resumes this project's last session, or opens a new one at the right place.")" \
    "$(t "loomy watch: phases, running delegations and activity, live.")" \
    "$(t "loomy status: phases, brief, activity, costs, AI files and Git (here, without leaving home).")" \
    "$(t "loomy log: phases, delegations, sessions and costs, in local time.")" \
    "$(t "loomy privacy: AI files versioned, local or in a private repository.")" \
    "$(t "All commands.")" "$(t "Closes Loomy.")")
  default=0; [[ "$sess" == open* ]] && default=1
  UI_LABEL="$(t "Choice")"
  ui_choose "$(t "What do you want to do?")" "$default" "${opts[@]}"
  case "$UI_INDEX" in
    0) ui_exec "$LOOMY_BIN" start ;;
    1) ui_exec "$LOOMY_BIN" watch ;;
    2) view "$(t "Detailed status")" bash "$SCRIPT_DIR/ai-status.sh" --root "$ROOT" --full ;;
    3) view "$(t "Log")" bash "$SCRIPT_DIR/ai-log.sh" --root "$ROOT" -n 200 ;;
    4) view "$(t "AI files visibility")" bash "$SCRIPT_DIR/ai-privacy.sh" --root "$ROOT" ;;
    5) view "$(t "Help")" bash "$LOOMY_BIN" help ;;
    *) leave ;;
  esac
done
