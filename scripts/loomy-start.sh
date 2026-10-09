#!/usr/bin/env bash
# Starts or resumes the lead agent session of a Loomy project. Bash 3.2 compatible.
#   loomy-start.sh              menu: resume the last session, new session, or show the commands
#   loomy-start.sh --resume     resumes the last session of this folder directly (on this machine)
#   loomy-start.sh --new        opens a new session with the prompt suited to the project phase
#   loomy-start.sh --print      only shows the commands
#   loomy-start.sh --watch      also opens live tracking next to the session (tmux, iTerm2 or a new window)
#                            (the default; loomy config set start_watch no or --no-watch to skip it)
#   loomy-start.sh --app        opens the session in the desktop app (Claude: on this folder, prompt filled in; Codex:
#                            prompt filled in) and live tracking in a terminal window (loomy config set start_in app)
#   loomy-start.sh --root <dir> works on another project folder

# Private watch launcher; deletes itself when started.
watch_script() {
  local f until=""
  f="$(mktemp "${TMPDIR:-/tmp}/loomy-watch-XXXXXXXX")" || return 1
  [[ -n "${1:-}" ]] && until=" --until-exit $1"
  printf '#!/bin/bash\nrm -f -- "$0"\nunset LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT\nexec bash %q --root %q --watch --compact --pane%s\n' "$SCRIPT_DIR/loomy-status.sh" "$ROOT" "$until" >"$f"
  chmod u+x "$f"; echo "$f"
}

# url_encode <text>: percent-encoded for a URL query.
url_encode() {
  perl -e 'use bytes; my $s=$ARGV[0]; $s =~ s/([^A-Za-z0-9_.~-])/sprintf("%%%02X",ord($1))/ge; print $s' "$1"
}

# open_in_app: the desktop app on this project (deep links the apps declare themselves), then live tracking in a
# Terminal window. The app can't open its own terminal panel on loomy watch: the window stands next to it.
open_in_app() {
  local url w
  if [[ "$(uname -s)" != Darwin ]]; then ui_warn "$(t "Desktop apps: macOS only")" "$(t "opening in the terminal")"; return 1; fi
  local ep ef
  ep="$(url_encode "$PROMPT")"; ef="$(url_encode "$ROOT")"
  [[ -n "$ep" && -n "$ef" ]] || { ui_warn "$(t "The app link could not be built")" "$(t "opening in the terminal")"; return 1; }
  if [[ "$TOOL" == codex ]]; then url="codex://threads/new?prompt=$ep"
  else url="claude://code/new?folder=$ef&q=$ep"; fi
  if ! open "$url" >/dev/null 2>&1; then ui_warn "$(t "The app did not open")" "$(t "opening in the terminal")"; return 1; fi
  ui_ok "$(t "%s opened in the app" "$tool_label")" "$(t "pick model %s, effort %s; the Loomy hooks give it the context" "$MODEL" "$EFFORT")"
  [[ "$TOOL" == codex ]] && ui_info "$(t "Codex app: choose this project's folder for the conversation (%s)" "${ROOT/#$HOME/~}")"
  local wt="$WATCH"
  [[ -z "$wt" && "${LOOMY_START_WATCH:-}" == "0" ]] && wt=0
  [[ -z "$wt" ]] && { [[ "$(loomy_config_get start_watch 2>/dev/null || true)" == "no" ]] && wt=0 || wt=1; }
  if (( wt )) && command -v osascript >/dev/null 2>&1; then
    w="$(watch_script)"
    if osascript -e "tell application \"Terminal\" to do script \"/bin/bash $w\"" >/dev/null 2>&1; then ui_ok "$(t "Live tracking")" "$(t "in a Terminal window")"
    else ui_info "$(t "live tracking: loomy watch")"; fi
  fi
  return 0
}

# Resolution is separate from opening so watch can test it without launching any app.
loomy_orchestrator_target() {
  local app
  ai_detect_env "$1"; ai_resolve lead "$AI_ENV" "$AI_PROFILE"
  LOOMY_OPEN_TOOL="$R_FAMILY"; LOOMY_OPEN_TARGET=terminal; LOOMY_OPEN_APP=""
  [[ "$(uname -s)" == Darwin ]] || return 0
  if [[ "$LOOMY_OPEN_TOOL" == claude ]]; then
    if open -Ra Claude >/dev/null 2>&1; then LOOMY_OPEN_APP=Claude; fi
  else
    for app in Codex ChatGPT; do if open -Ra "$app" >/dev/null 2>&1; then LOOMY_OPEN_APP="$app"; break; fi; done
  fi
  [[ -z "$LOOMY_OPEN_APP" ]] || LOOMY_OPEN_TARGET=app
  return 0
}

# Always launch outside the watch pane. The new terminal reuses start's watch split and resume logic.
loomy_open_orchestrator() {
  local root="$1" command launch
  loomy_orchestrator_target "$root"
  if [[ "$LOOMY_OPEN_TARGET" == app ]]; then
    if bash "$SCRIPT_DIR/loomy-start.sh" --root "$root" --app-only; then return 0; fi
  fi
  printf -v command '%q ' env -u LOOMY_SCREEN_OWNER -u LOOMY_PAGE_OUT LOOMY_START_IN=terminal bash "$SCRIPT_DIR/loomy-start.sh" --root "$root" --resume --watch
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    tmux new-window -c "$root" "$command"
  elif [[ "$(uname -s)" == Darwin ]] && command -v osascript >/dev/null 2>&1; then
    launch="$(mktemp "${TMPDIR:-/tmp}/loomy-open-XXXXXXXX")" || return 1
    printf '#!/bin/bash\nrm -f -- "$0"\nexec %s\n' "$command" >"$launch"
    if ! osascript -e "tell application \"Terminal\" to do script \"/bin/bash $launch\"" >/dev/null 2>&1; then rm -f "$launch"; return 1; fi
  else
    return 1
  fi
}
if [[ "${1:-}" == --open-library ]]; then return 0; fi

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
# shellcheck source=lib/failover.sh
source "$SCRIPT_DIR/lib/failover.sh"

ROOT=""; MODE="menu"; WATCH=""; APP_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --resume|-r) MODE="resume" ;;
    --new|-n) MODE="new" ;;
    --print|-p) MODE="print" ;;
    --app|-a) MODE="app" ;;
    --app-only) MODE="app"; WATCH=0; APP_ONLY=1 ;;
    --orchestrator) MODE="orchestrator" ;;
    --watch|-w) WATCH=1 ;;
    --no-watch) WATCH=0 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//; s/loomy-start.sh/loomy start/' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
# Real path (links resolved): the one Claude and Codex record for their sessions.
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd -P)"
BRIEF="$ROOT/.loomy/brief.md"
if [[ "$MODE" == orchestrator ]]; then loomy_open_orchestrator "$ROOT"; exit $?; fi
# A repository with only an audit (loomy audit), no Loomy project: start resumes the audit.
if [[ ! -f "$BRIEF" && -f "$ROOT/.loomy/audit.md" ]]; then exec bash "$SCRIPT_DIR/loomy-audit.sh" --root "$ROOT" --resume; fi
if [[ ! -f "$BRIEF" ]]; then
  t "No Loomy brief in %s: run loomy init first (new project) or loomy brief." "${ROOT/#$HOME/~}" >&2; echo >&2
  exit 1
fi

loomy_project_register "$ROOT"
# ---------------------------------------------------------------- project and lead agent
PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
NAME="$(_ai_brief_get "$BRIEF" name)"

tool_name() { if [[ "$1" == "codex" ]]; then echo "Codex"; else echo "Claude Code"; fi; }

# resolve_session: who leads this session (the brief's lead, or the other tool during a quota relay), its model, prompt
# and commands. Nothing is recorded here (lf_decide --dry): lf_apply does it when the session really starts.
# The relay is temporary: the brief is unchanged and the master takes the lead back once it has room.
resolve_session() {
  local master since=""
  ai_detect_env "$ROOT"
  if lf_active "$ROOT"; then master="$(lf_get "$ROOT" master)"
  else ai_resolve lead "$AI_ENV" "$AI_PROFILE"; master="$R_FAMILY"; fi
  lf_decide "$ROOT" "$master" --dry >/dev/null
  AI_LEAD="$LF_LEAD"
  if [[ -z "${AI_ROUTE_ENV:-}" ]]; then ai_env_for "$AI_MODE" "$LF_LEAD"; fi
  ai_resolve lead "$AI_ENV" "$AI_PROFILE"
  TOOL="$R_FAMILY"; MODEL="$R_MODEL"; EFFORT="$R_EFFORT"

  # Prompt of the new session, depending on progress.
  if [[ -f "$ROOT/START.md" && ( -z "$PHASE" || "$PHASE" == "brief" || "$PHASE" == "discover" ) ]]; then
    PROMPT="$(ai_start_prompt "$AI_MODE" "$AI_LEAD")"; KIND="$(t "bootstrap start")"
  elif [[ -f "$ROOT/START.md" ]]; then
    PROMPT="$(t "Resume this project's setup by following START.md, where it stopped: phase \"%s\". First run .loomy/scripts/loomy-context.sh for the context (phase, expectations, latest delegations). Start by summarizing where we are and what remains, then wait for my approval before going on." "$(loomy_phase_label "$PHASE")")"
    KIND="$(t "resuming at phase %s" "$(loomy_phase_label "$PHASE")")"
  else
    PROMPT="$(t "Resume work on this project: run .loomy/scripts/loomy-context.sh for the context, read AGENTS.md (or CLAUDE.md) and .loomy/docs/AI_WORKFLOW.md, summarize the current state of the repository and suggest what comes next. Delegate each role according to .loomy/scripts/loomy-route.sh.")"
    KIND="$(t "everyday work (bootstrap done)")"
  fi
  case "$LF_KIND" in
    handover)
      if [[ "$LF_RESUME_AT" =~ ^[0-9]+$ ]]; then
        PROMPT="$(t "You are temporarily the lead agent in place of %s (quota %s, back around %s). Read .loomy/docs/HANDOFF.md if present and .loomy/memory/STATE.md first, then continue the current work. Before ending, update STATE.md and HANDOFF.md for %s." "$(tool_name "$LF_MASTER")" "$LF_REASON" "$(lf_time "$LF_RESUME_AT")" "$(tool_name "$LF_MASTER")")"
      else
        PROMPT="$(t "You are temporarily the lead agent in place of %s (quota %s). Read .loomy/docs/HANDOFF.md if present and .loomy/memory/STATE.md first, then continue the current work. Before ending, update STATE.md and HANDOFF.md for %s." "$(tool_name "$LF_MASTER")" "$LF_REASON" "$(tool_name "$LF_MASTER")")"
      fi
      KIND="$(t "temporary lead")" ;;
    return)
      since="$(ai_ts_epoch "$LF_SINCE")"; [[ -n "$since" ]] && since="$(lf_time "$since")"
      PROMPT="$(t "You are the lead agent again; %s led while your quota was low (since %s). Read .loomy/docs/HANDOFF.md and .loomy/memory/STATE.md, check its work (git log since then), then continue." "$(tool_name "$LF_ACTING")" "${since:-?}")"
      KIND="$(t "lead back")" ;;
  esac

  # Previous session on this machine: Claude stores its conversations per folder, Codex records each session's folder.
  HAS_SESSION=0; ADVISOR=""
  if [[ "$TOOL" == "claude" ]]; then
    local enc; enc="$(printf '%s' "$ROOT" | sed 's/[^A-Za-z0-9]/-/g')"
    if ls "$HOME/.claude/projects/$enc/"*.jsonl >/dev/null 2>&1; then HAS_SESSION=1; fi
    ADVISOR="$(ai_advisor_for "$MODEL" "$AI_PROFILE")"
    ADV_ARGS=(); [[ -n "$ADVISOR" ]] && ADV_ARGS=(--advisor "$ADVISOR")
    NEW_CMD=(claude --model "$MODEL" --effort "$EFFORT" ${ADV_ARGS[@]+"${ADV_ARGS[@]}"} "$PROMPT")
    RESUME_CMD=(claude --continue --model "$MODEL" --effort "$EFFORT" ${ADV_ARGS[@]+"${ADV_ARGS[@]}"})
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
  tool_label="$(tool_name "$TOOL")"
}
resolve_session
short_cmd() { if [[ "$TOOL" == "claude" ]]; then echo "claude${1:+ $1} --model $MODEL --effort $EFFORT${ADVISOR:+ --advisor $ADVISOR}"; else echo "codex${1:+ $1} -m $MODEL -c model_reasoning_effort=$EFFORT"; fi; }

# ---------------------------------------------------------------- affichage
# LOOMY_START_INNER: set by the dedicated tmux session's own run of this script, whose banner is already printed.
if [[ -z "${LOOMY_START_INNER:-}" ]]; then
  ui_clear
  ui_banner "$(t "Start or resume")" "${C_RESET}${C_TITLE}${NAME:-$(basename "$ROOT")}${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
fi
ui_section "SESSION"
ui_kv "$(t "Phase")" "${C_BOLD}$(loomy_phase_label "$PHASE")${C_RESET}"
ui_kv "$(t "Lead agent")" "${C_BRAND}${MODEL}${C_RESET} · effort $EFFORT · $tool_label${ADVISOR:+ · $(t "advisor %s" "$ADVISOR")}"
case "$LF_KIND" in
  handover)
    ui_warn "$(t "%s quota at %s: this session runs on %s" "$(tool_name "$LF_MASTER")" "$(ai_quota_state "$LF_MASTER")" "$tool_label")" "$(t "back to %s once the quota resets · keep it: LOOMY_NO_SWITCH=1 loomy start" "$(tool_name "$LF_MASTER")")" ;;
  continue)
    ui_warn "$(t "%s leads for now in place of %s (quota %s)" "$tool_label" "$(tool_name "$LF_MASTER")" "$LF_REASON")" "$(t "back to %s once the quota resets · keep it: LOOMY_NO_SWITCH=1 loomy start" "$(tool_name "$LF_MASTER")")" ;;
  return) ui_ok "$(t "%s takes the lead back" "$tool_label")" "$(t "%s led while its quota was low" "$(tool_name "$LF_ACTING")")" ;;
  *) if [[ -n "$LF_NOTE" ]]; then ui_warn "$(t "%s quota at %s" "$(tool_name "$LF_MASTER")" "$(ai_quota_state "$LF_MASTER")")" "$LF_NOTE"; fi ;;
esac
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
# watch_script [agent pid] is shared with the desktop launcher above.
start_with_watch() {
  local side=0 w agent name n
  # Agent on the left, tracking on the right; stacked only in a terminal too narrow for two columns.
  _ui_term_size; (( UI_COLS >= 110 )) && side=1
  # Tracking scripts left by previous versions (before automatic deletion).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'loomy-watch-*' -user "$(id -u)" -mmin +5 -delete 2>/dev/null || true
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    # Already in tmux: a tracking pane alongside, then the agent in the current pane (same process: exec).
    w="$(watch_script $$)"
    if (( side )); then tmux split-window -d -h -l 45% -c "$ROOT" "bash $w"
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
    # The dedicated session runs the whole chain (relay included): this script again, without tracking of its own.
    agent="$(printf '%q ' env LOOMY_START_INNER=1 bash "$SCRIPT_DIR/loomy-start.sh" --root "$ROOT" "--$MODE" --no-watch)"
    # tmux that can't start (container, no terminal): the session opens alone rather than failing.
    if ! env -u LOOMY_SCREEN_OWNER -u LOOMY_PAGE_OUT tmux new-session -d -s "$name" -c "$ROOT" -x "$UI_COLS" -y "$UI_ROWS" "cd $(printf '%q' "$ROOT") && $agent; tmux kill-session -t $name" 2>/dev/null \
       || ! tmux has-session -t "=$name" 2>/dev/null; then
      WATCH_NOTE="$(t "tmux could not start here: run loomy watch in another terminal")"
      return 0
    fi
    tmux set-option -t "$name" mouse on >/dev/null
    tmux set-option -t "$name" status off >/dev/null
    tmux set-option -t "$name" pane-border-style "fg=colour60" >/dev/null
    tmux set-option -t "$name" pane-active-border-style "fg=colour141" >/dev/null
    w="$(watch_script)"
    if (( side )); then tmux split-window -d -h -l 45% -t "$name" -c "$ROOT" "bash $w"
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
    if [[ "$(uname -s)" == Darwin ]] && open -Ra "$( [[ "$TOOL" == codex ]] && echo ChatGPT || echo Claude)" >/dev/null 2>&1; then
      opts+=("$(t "Open in the app")"); codes+=(app)
      descs+=("$(t "Opens a %s session in the desktop app with the prompt filled in, and live tracking in a terminal window next to it." "$tool_label")")
    fi
    opts+=("$(t "Show the commands")"); codes+=(print); descs+=("$(t "Opens nothing: shows the commands and copies the prompt, so you run them yourself.")")
    opts+=("$(t "Cancel")"); codes+=(cancel); descs+=("$(t "Opens nothing.")")
    UI_DESCS=("${descs[@]}"); UI_LABEL="$(t "Choice")"
    ui_choose "$(t "What do you want to do?")" 0 "${opts[@]}"
    MODE="${codes[$UI_INDEX]:-print}"
  fi
fi

# Default place to open the session: loomy config set start_in app (a choice from the menu stays a choice).
if [[ "$MODE" == "new" && "$(loomy_config_get start_in 2>/dev/null || true)" == "app" && "${LOOMY_START_IN:-}" != "terminal" ]]; then MODE="app"; fi


case "$MODE" in
  cancel) UI_NO_DUMP=1; _ui_restore; exit 0 ;;
  app)
    if open_in_app; then
      case "$LF_KIND" in
        handover|return)
          lf_apply "$ROOT"
          ui_info "$(t "The automatic chain only runs in the terminal; the master takes the lead back on the next loomy start if its quota allows.")" ;;
      esac
      ui_end "$(t "session in the app · live tracking: loomy watch")"
      exit 0
    fi
    (( APP_ONLY )) && exit 1
    MODE="new" ;;
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
# LOOMY_START_WATCH=0 (scripts, tests) or start_watch no: the session alone.
[[ -z "$WATCH" && "${LOOMY_START_WATCH:-}" == "0" ]] && WATCH=0
[[ -z "$WATCH" ]] && { [[ "$(loomy_config_get start_watch 2>/dev/null || true)" == "no" ]] && WATCH=0 || WATCH=1; }
if [[ "$MODE" == "resume" && "$LF_KIND" != "handover" && "$LF_KIND" != "return" ]]; then AGENT_CMD=("${RESUME_CMD[@]}"); else AGENT_CMD=("${NEW_CMD[@]}"); MODE=new; fi
WATCH_NOTE="$(t "live tracking in another terminal: loomy watch (or loomy start --watch)")"
if (( WATCH )) && ui_is_interactive; then start_with_watch; fi
ui_end "$(t "opening %s…" "$tool_label") · $WATCH_NOTE"
cd "$ROOT"
lf_apply "$ROOT"

# Session chain (6 sessions at most): the agent runs as a child; when it ends and the lead relay is due (its tool's
# quota ran out, or the master has room again), the other tool takes over after a short delay.
UI_NO_DUMP=1; _ui_restore; trap - EXIT INT TERM
CHAIN_STOP=0; trap 'CHAIN_STOP=1' INT
CHAIN_MAX=6; CHAIN_N=0
while :; do
  CHAIN_N=$(( CHAIN_N + 1 ))
  # Codex has no per-project hooks: the session is recorded here (this script's pid lives as long as the session).
  if [[ "$TOOL" == "codex" ]]; then
    ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"codex\",\"pid\":$$"
  fi
  rc=0; "${AGENT_CMD[@]}" || rc=$?
  if [[ "$TOOL" == "codex" ]]; then
    ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"end\",\"tool\":\"codex\",\"pid\":$$"
  fi
  (( CHAIN_STOP )) && break
  (( CHAIN_N >= CHAIN_MAX )) && break
  resolve_session
  [[ "$LF_KIND" == "handover" || "$LF_KIND" == "return" ]] || break
  (( CLI_OK )) || break
  why="$LF_REASON"; [[ "$LF_KIND" == "return" ]] && why="$(t "quota back")"
  delay="${LOOMY_CHAIN_DELAY:-5}"; [[ "$delay" =~ ^[0-9]+$ ]] || delay=5
  printf '%s\n' "$(t "→ %s takes over (%s) in %s s — Ctrl+C to stop" "$tool_label" "$why" "$delay")"
  if (( delay > 0 )); then sleep "$delay" || true; fi
  (( CHAIN_STOP )) && break
  lf_apply "$ROOT"
  AGENT_CMD=("${NEW_CMD[@]}")
done
exit "$rc"
