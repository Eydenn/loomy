#!/usr/bin/env bash
# Starts or resumes the lead agent session of a Loomy project. Bash 3.2 compatible.
#   ai-start.sh              menu: resume the last session, new session, or show the commands
#   ai-start.sh --resume     resumes the last session of this folder directly (on this machine)
#   ai-start.sh --new        opens a new session with the prompt suited to the project phase
#   ai-start.sh --print      only shows the commands
#   ai-start.sh --watch      also opens live tracking next to the session (tmux, iTerm2 or a new window)
#                            (default when loomy config start_watch yes; --no-watch to skip it)
#   ai-start.sh --root <dir> works on another project folder
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"

ROOT=""; MODE="menu"; WATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --resume|-r) MODE="resume" ;;
    --new|-n) MODE="new" ;;
    --print|-p) MODE="print" ;;
    --watch|-w) WATCH=1 ;;
    --no-watch) WATCH=0 ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//; s/ai-start.sh/loomy start/' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
# Real path (links resolved): the one Claude and Codex record for their sessions.
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd -P)"
BRIEF="$ROOT/.loomy/brief.md"
if [[ ! -f "$BRIEF" ]]; then
  t "No Loomy brief in %s: run loomy init first (new project) or loomy brief." "${ROOT/#$HOME/~}" >&2; echo >&2
  exit 1
fi

# ---------------------------------------------------------------- project and lead agent
ai_detect_env "$ROOT"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
TOOL="$R_FAMILY"; MODEL="$R_MODEL"; EFFORT="$R_EFFORT"
# The lead tool's subscription quota nearly exhausted, the other tool available with room left: this session runs
# on the other tool, with its lead agent model (the brief is unchanged; the next start goes back once it resets).
SWITCHED_FROM=""
if [[ "${LOOMY_NO_SWITCH:-}" != "1" ]] && sw="$(ai_switch_family "$TOOL")" && [[ -n "$sw" ]]; then
  SWITCHED_FROM="$TOOL"; SWITCH_STATE="$(ai_quota_state "$TOOL")"
  ai_route lead "$sw" "$AI_PROFILE"
  TOOL="$sw"; MODEL="$R_MODEL"; EFFORT="$R_EFFORT"; AI_LEAD="$sw"
fi
PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
NAME="$(_ai_brief_get "$BRIEF" name)"


# Prompt of the new session, depending on progress.
if [[ -f "$ROOT/START.md" && ( -z "$PHASE" || "$PHASE" == "brief" || "$PHASE" == "discover" ) ]]; then
  PROMPT="$(ai_start_prompt "$AI_MODE" "$AI_LEAD")"; KIND="$(t "bootstrap start")"
elif [[ -f "$ROOT/START.md" ]]; then
  PROMPT="$(t "Resume this project's setup by following START.md, where it stopped: phase \"%s\". First run .loomy/scripts/ai-context.sh for the context (phase, expectations, latest delegations). Start by summarizing where we are and what remains, then wait for my approval before going on." "$(loomy_phase_label "$PHASE")")"
  KIND="$(t "resuming at phase %s" "$(loomy_phase_label "$PHASE")")"
else
  PROMPT="$(t "Resume work on this project: run .loomy/scripts/ai-context.sh for the context, read AGENTS.md (or CLAUDE.md) and .ai/AI_WORKFLOW.md, summarize the current state of the repository and suggest what comes next. Delegate each role according to .loomy/scripts/ai-route.sh.")"
  KIND="$(t "everyday work (bootstrap done)")"
fi

# Previous session on this machine: Claude stores its conversations per folder, Codex records each session's folder.
HAS_SESSION=0
if [[ "$TOOL" == "claude" ]]; then
  enc="$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
  if ls "$HOME/.claude/projects/$enc/"*.jsonl >/dev/null 2>&1; then HAS_SESSION=1; fi
  NEW_CMD=(claude --model "$MODEL" --effort "$EFFORT" "$PROMPT")
  RESUME_CMD=(claude --continue --model "$MODEL" --effort "$EFFORT")
  CLI_OK=0; ai_has_claude && CLI_OK=1
  INSTALL="curl -fsSL https://claude.ai/install.sh | bash"
else
  if [[ -d "$HOME/.codex/sessions" ]] && grep -rlqF "\"cwd\":\"$ROOT\"" "$HOME/.codex/sessions" 2>/dev/null; then HAS_SESSION=1; fi
  CODEX="$(ai_codex_bin 2>/dev/null || echo codex)"
  NEW_CMD=("$CODEX" -m "$MODEL" -c "model_reasoning_effort=$EFFORT" "$PROMPT")
  RESUME_CMD=("$CODEX" resume --last -m "$MODEL" -c "model_reasoning_effort=$EFFORT")
  CLI_OK=0; ai_has_codex && CLI_OK=1
  INSTALL="curl -fsSL https://chatgpt.com/codex/install.sh | sh"
fi
tool_label="Claude Code"; [[ "$TOOL" == "codex" ]] && tool_label="Codex"
short_cmd() { if [[ "$TOOL" == "claude" ]]; then echo "claude${1:+ $1} --model $MODEL --effort $EFFORT"; else echo "codex${1:+ $1} -m $MODEL -c model_reasoning_effort=$EFFORT"; fi; }

# ---------------------------------------------------------------- affichage
ui_clear
ui_banner "$(t "Start or resume")" "${C_RESET}${C_TITLE}${NAME:-$(basename "$ROOT")}${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
ui_section "SESSION"
ui_kv "$(t "Phase")" "${C_BOLD}$(loomy_phase_label "$PHASE")${C_RESET}"
ui_kv "$(t "Lead agent")" "${C_BRAND}${MODEL}${C_RESET} · effort $EFFORT · $tool_label"
if [[ -n "$SWITCHED_FROM" ]]; then
  from_label="Claude Code"; [[ "$SWITCHED_FROM" == "codex" ]] && from_label="Codex"
  ui_warn "$(t "%s quota at %s: this session runs on %s" "$from_label" "$SWITCH_STATE" "$tool_label")" "$(t "back to %s once the quota resets · keep it: LOOMY_NO_SWITCH=1 loomy start" "$from_label")"
fi
if (( HAS_SESSION )); then ui_kv "Session" "${C_GREEN}$(t "a previous session exists on this machine")${C_RESET}"
else ui_kv "Session" "${C_DIM}$(t "no previous session on this machine")${C_RESET}"; fi
# Lead agent model missing from Codex's local catalog (renamed or removed): warn before launching.
if [[ "$TOOL" == "codex" && -f "$HOME/.codex/models_cache.json" ]] && ! grep -qF "\"$MODEL\"" "$HOME/.codex/models_cache.json"; then
  ui_warn "$(t "%s missing from Codex's local catalog" "$MODEL")" "$(t "update the Loomy catalog (loomy update --catalog) or Codex, then loomy doctor --live")"
fi
if (( ! CLI_OK )); then
  ui_err "$(t "%s not found" "$tool_label")" "$(t "install it: %s" "$INSTALL")"
  ui_end "$(t "full check: loomy doctor")"
  exit 1
fi

# ---------------------------------------------------------------- session + live tracking, side by side
# Side by side when the terminal is wide (≥ 160 columns), otherwise one above the other (session on top, 2/3).
# Tracking closes by itself when the agent session ends (--until-exit).
# Small tracking launch script: it deletes itself as soon as it starts (nothing piles up in the temp folder).
# watch_script [agent pid]: creates the script with mktemp (random name, private, never an existing file or link).
watch_script() {
  local f until=""
  f="$(mktemp "${TMPDIR:-/tmp}/loomy-watch-XXXXXXXX")" || return 1
  [[ -n "${1:-}" ]] && until=" --until-exit $1"
  printf '#!/bin/bash\nrm -f -- "$0"\nunset LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT\nexec bash %q --root %q --watch --compact --pane%s\n' "$SCRIPT_DIR/ai-status.sh" "$ROOT" "$until" >"$f"
  chmod u+x "$f"; echo "$f"
}

start_with_watch() {
  local side=0 w agent name n
  _ui_term_size; (( UI_COLS >= 160 )) && side=1
  # Tracking scripts left by previous versions (before automatic deletion).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'loomy-watch-*' -user "$(id -u)" -mmin +5 -delete 2>/dev/null || true
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    # Already in tmux: a tracking pane alongside, then the agent in the current pane (same process: exec).
    w="$(watch_script $$)"
    if (( side )); then tmux split-window -d -h -l 40% -c "$ROOT" "bash $w"
    else tmux split-window -d -v -l 35% -c "$ROOT" "bash $w"; fi
    WATCH_NOTE="$( (( side )) && t "live tracking in the right tmux pane, closed with the session" || t "live tracking in the bottom tmux pane, closed with the session")"
    return 0
  fi
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && command -v osascript >/dev/null 2>&1; then
    w="$(watch_script $$)"
    if osascript -e "tell application \"iTerm2\" to tell current session of current window to split $( (( side )) && echo vertically || echo horizontally ) with default profile command \"/bin/bash $w\"" >/dev/null 2>&1; then
      WATCH_NOTE="$(t "live tracking in the next iTerm2 pane, closed with the session")"
      return 0
    fi
  fi
  if command -v tmux >/dev/null 2>&1; then
    # Dedicated tmux session: the agent on the left (or on top), tracking alongside; everything closes with the agent.
    name="loomy-$(printf '%s' "$(basename "$ROOT")" | tr -c 'A-Za-z0-9_-' '-')"
    # Session already open (another terminal): join it rather than close it, unless asked otherwise.
    if tmux has-session -t "=$name" 2>/dev/null; then
      UI_LABEL="$(t "Session opened")"
      UI_DESCS=("$(t "This project's agent and tracking already run in a tmux session: you get it back as is, in this terminal.")" \
        "$(t "Opens a second session next to the first (two agents on the same folder: avoid unless you really need it).")" \
        "$(t "Starts nothing.")")
      ui_choose "$(t "A Loomy session is already open for this project. What now?")" 0 "$(t "Join it")" "$(t "Open another one")" "$(t "Cancel")"
      case "$UI_INDEX" in
        0) ui_end "$(t "back in the open session · click or Ctrl-b + arrow to switch panes")"; ui_exec tmux attach-session -t "=$name" ;;
        2) ui_end "$(t "nothing was started")"; exit 0 ;;
      esac
      n=2; while tmux has-session -t "=$name-$n" 2>/dev/null; do n=$(( n + 1 )); done
      name="$name-$n"
    fi
    agent="$(printf '%q ' "${AGENT_CMD[@]}")"
    env -u LOOMY_SCREEN_OWNER -u LOOMY_PAGE_OUT tmux new-session -d -s "$name" -c "$ROOT" -x "$UI_COLS" -y "$UI_ROWS" "cd $(printf '%q' "$ROOT") && $agent; tmux kill-session -t $name"
    tmux set-option -t "$name" mouse on >/dev/null
    tmux set-option -t "$name" status off >/dev/null
    tmux set-option -t "$name" pane-border-style "fg=colour60" >/dev/null
    tmux set-option -t "$name" pane-active-border-style "fg=colour141" >/dev/null
    w="$(watch_script)"
    if (( side )); then tmux split-window -d -h -l 40% -t "$name" -c "$ROOT" "bash $w"
    else tmux split-window -d -v -l 35% -t "$name" -c "$ROOT" "bash $w"; fi
    ui_end "$(t "opening %s and live tracking, side by side (tmux) · click or Ctrl-b + arrow to switch panes" "$tool_label")"
    ui_exec tmux attach-session -t "$name"
  fi
  if [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] && command -v osascript >/dev/null 2>&1; then
    w="$(watch_script $$)"
    if osascript -e "tell application \"Terminal\" to do script \"/bin/bash $w\"" >/dev/null 2>&1; then
      WATCH_NOTE="$(t "live tracking in a new Terminal window, closed with the session")"
      return 0
    fi
  fi
  WATCH_NOTE="$(t "side-by-side tracking unavailable here (brew install tmux): run loomy watch in another terminal")"
  return 0
}

print_cmds() {
  ui_section "$(t "COMMANDS")" "$(t "to run at the project root")"
  if (( HAS_SESSION )); then
    ui_rail "${C_DIM}$(t "resume:")${C_RESET} ${C_BOLD}$(short_cmd "$( [[ "$TOOL" == claude ]] && echo --continue || echo "resume --last")")${C_RESET}"
  fi
  ui_rail "${C_DIM}$(t "new:   ")${C_RESET} ${C_BOLD}$(short_cmd)${C_RESET} ${C_DIM}$(t "then paste the prompt:")${C_RESET}"
  _ui_term_size; _ui_wrap "$PROMPT" $(( UI_W - 8 ))
  for l in "${UI_LINES[@]}"; do ui_rail "   ${C_DIM}${l}${C_RESET}"; done
  if ui_is_interactive && ui_copy "$PROMPT"; then ui_rail "   ${C_GREEN}✓${C_RESET} ${C_DIM}$(t "prompt copied to the clipboard")${C_RESET}"; fi
  app="$(t "the Claude app (Code tab)")"; [[ "$TOOL" == "codex" ]] && app="$(t "the Codex app")"
  ui_rail "${C_DIM}$(t "in the app:")${C_RESET} $(t "open this folder in %s, model %s, effort %s, then paste the prompt" "$app" "${C_BOLD}$MODEL${C_RESET}" "${C_BOLD}$EFFORT${C_RESET}")"
}

if [[ "$MODE" == "menu" ]]; then
  if ! ui_is_interactive; then MODE="print"
  else
    ui_print "${C_RAIL}│${C_RESET}"
    opts=(); descs=(); codes=()
    if (( HAS_SESSION )); then
      opts+=("$(t "Resume the last session")"); codes+=(resume)
      descs+=("$(t "Resumes this folder's latest conversation, with its history: %s" "$(short_cmd "$( [[ "$TOOL" == claude ]] && echo --continue || echo "resume --last")")")")
    fi
    opts+=("$(t "New session")"); codes+=(new); descs+=("$(t "Opens %s with the %s prompt. The agent rereads START.md, the brief and the project state." "$tool_label" "$KIND")")
    opts+=("$(t "Show the commands")"); codes+=(print); descs+=("$(t "Opens nothing: shows the commands and copies the prompt, so you run them yourself.")")
    opts+=("$(t "Cancel")"); codes+=(cancel); descs+=("$(t "Opens nothing.")")
    UI_DESCS=("${descs[@]}"); UI_LABEL="$(t "Choice")"
    ui_choose "$(t "What do you want to do?")" 0 "${opts[@]}"
    MODE="${codes[$UI_INDEX]:-print}"
  fi
fi

case "$MODE" in
  cancel) UI_NO_DUMP=1; _ui_restore; exit 0 ;;
  print)
    print_cmds
    ui_end "$(t "live tracking: loomy watch")"
    ;;
  resume)
    if (( ! HAS_SESSION )); then ui_warn "$(t "No session to resume")" "$(t "opening a new session")"; MODE="new"; fi
    ;;
esac
[[ "$MODE" == "print" ]] && exit 0

# Codex only runs a project's hooks (automatic context, session tracking) once the folder is trusted
# and the hooks approved: it asks for this itself on first launch.
if [[ "$TOOL" == "codex" ]] && ! grep -qF "[projects.\"$ROOT\"]" "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null; then
  ui_info "$(t "first Codex launch in this project: agree to trust the folder, then approve the Loomy hooks (automatic resume)")"
fi
[[ -z "$WATCH" ]] && { [[ "$(loomy_config_get start_watch 2>/dev/null || true)" == "yes" ]] && WATCH=1 || WATCH=0; }
if [[ "$MODE" == "resume" ]]; then AGENT_CMD=("${RESUME_CMD[@]}"); else AGENT_CMD=("${NEW_CMD[@]}"); fi
WATCH_NOTE="$(t "live tracking in another terminal: loomy watch (or loomy start --watch)")"
if (( WATCH )) && ui_is_interactive; then start_with_watch; fi
ui_end "$(t "opening %s…" "$tool_label") · $WATCH_NOTE"
cd "$ROOT"
# Codex has no per-project hooks: the session is recorded here. After exec, Codex keeps this pid.
if [[ "$TOOL" == "codex" ]]; then
  ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"codex\",\"pid\":$$"
fi
ui_exec "${AGENT_CMD[@]}"
