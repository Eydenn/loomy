#!/usr/bin/env bash
# Démarre ou reprend la session de l'orchestrateur d'un projet Loomy. Compatible bash 3.2.
#   ai-start.sh              menu : reprendre la dernière session, nouvelle session, ou afficher les commandes
#   ai-start.sh --resume     reprend directement la dernière session de ce dossier (sur cette machine)
#   ai-start.sh --new        ouvre une nouvelle session avec le prompt adapté à la phase du projet
#   ai-start.sh --print      affiche seulement les commandes
#   ai-start.sh --watch      ouvre aussi le suivi en direct à côté de la session (tmux, iTerm2 ou nouvelle fenêtre)
#                            (par défaut si loomy config start_watch yes ; --no-watch pour l'éviter)
#   ai-start.sh --root <dir> agit sur un autre dossier de projet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
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
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//; s/ai-start.sh/loomy start/'; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
# Chemin réel (liens résolus) : c'est celui que Claude et Codex enregistrent pour leurs sessions.
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd -P)"
BRIEF="$ROOT/.loomy/brief.md"
if [[ ! -f "$BRIEF" ]]; then
  t "No Loomy brief in %s: run loomy init first (new project) or loomy brief." "${ROOT/#$HOME/~}" >&2; echo >&2
  exit 1
fi

# ---------------------------------------------------------------- projet et orchestrateur
ai_detect_env "$ROOT"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
TOOL="$R_FAMILY"; MODEL="$R_MODEL"; EFFORT="$R_EFFORT"
PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
NAME="$(_ai_brief_get "$BRIEF" name)"


# Prompt de la nouvelle session selon l'avancement.
if [[ -f "$ROOT/START.md" && ( -z "$PHASE" || "$PHASE" == "brief" || "$PHASE" == "discover" ) ]]; then
  PROMPT="$(ai_start_prompt "$AI_MODE" "$AI_LEAD")"; KIND="$(t "bootstrap start")"
elif [[ -f "$ROOT/START.md" ]]; then
  PROMPT="$(t "Resume this project's setup by following START.md, where it stopped: phase \"%s\". First run .loomy/scripts/ai-context.sh for the context (phase, expectations, latest delegations). Start by summarizing where we are and what remains, then wait for my approval before going on." "$(loomy_phase_label "$PHASE")")"
  KIND="$(t "resuming at phase %s" "$(loomy_phase_label "$PHASE")")"
else
  PROMPT="$(t "Resume work on this project: run .loomy/scripts/ai-context.sh for the context, read AGENTS.md (or CLAUDE.md) and .ai/AI_WORKFLOW.md, summarize the current state of the repository and suggest what comes next. Delegate each role according to .loomy/scripts/ai-route.sh.")"
  KIND="$(t "everyday work (bootstrap done)")"
fi

# Session précédente sur cette machine : Claude range ses conversations par dossier, Codex note le dossier de chaque session.
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
if (( HAS_SESSION )); then ui_kv "Session" "${C_GREEN}$(t "a previous session exists on this machine")${C_RESET}"
else ui_kv "Session" "${C_DIM}$(t "no previous session on this machine")${C_RESET}"; fi
# Modèle de l'orchestrateur absent du catalogue local de Codex (renommé ou retiré) : on prévient avant de lancer.
if [[ "$TOOL" == "codex" && -f "$HOME/.codex/models_cache.json" ]] && ! grep -qF "\"$MODEL\"" "$HOME/.codex/models_cache.json"; then
  ui_warn "$(t "%s missing from Codex's local catalog" "$MODEL")" "$(t "update the Loomy catalog (loomy update --catalog) or Codex, then loomy doctor --live")"
fi
if (( ! CLI_OK )); then
  ui_err "$(t "%s not found" "$tool_label")" "$(t "install it: %s" "$INSTALL")"
  ui_end "$(t "full check: loomy doctor")"
  exit 1
fi

# ---------------------------------------------------------------- session + suivi en direct, côte à côte
# Côte à côte si le terminal est large (≥ 160 colonnes), sinon l'un au-dessus de l'autre (session en haut, 2/3).
# Le suivi se ferme de lui-même à la fin de la session de l'agent (--until-exit).
# Petit script de lancement du suivi : il s'efface dès qu'il démarre (rien ne s'accumule dans le dossier temporaire).
# watch_script <fichier> [pid de l'agent]
watch_script() {
  local f="$1" until=""
  [[ -n "${2:-}" ]] && until=" --until-exit $2"
  printf '#!/bin/bash\nrm -f -- "$0"\nunset LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT\nexec bash %q --root %q --watch --compact --pane%s\n' "$SCRIPT_DIR/ai-status.sh" "$ROOT" "$until" >"$f"
  chmod +x "$f"; echo "$f"
}

start_with_watch() {
  local side=0 w agent name n
  _ui_term_size; (( UI_COLS >= 160 )) && side=1
  # Scripts de suivi laissés par les versions précédentes (avant l'effacement automatique).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'loomy-watch-*.sh' -mmin +5 -delete 2>/dev/null || true
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    # Déjà dans tmux : un panneau de suivi à côté, puis l'agent dans le panneau courant (même processus : exec).
    w="$(watch_script "${TMPDIR:-/tmp}/loomy-watch-$$.sh" $$)"
    if (( side )); then tmux split-window -d -h -l 40% -c "$ROOT" "bash $w"
    else tmux split-window -d -v -l 35% -c "$ROOT" "bash $w"; fi
    WATCH_NOTE="$( (( side )) && t "live tracking in the right tmux pane, closed with the session" || t "live tracking in the bottom tmux pane, closed with the session")"
    return 0
  fi
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && command -v osascript >/dev/null 2>&1; then
    w="$(watch_script "${TMPDIR:-/tmp}/loomy-watch-$$.sh" $$)"
    if osascript -e "tell application \"iTerm2\" to tell current session of current window to split $( (( side )) && echo vertically || echo horizontally ) with default profile command \"/bin/bash $w\"" >/dev/null 2>&1; then
      WATCH_NOTE="$(t "live tracking in the next iTerm2 pane, closed with the session")"
      return 0
    fi
  fi
  if command -v tmux >/dev/null 2>&1; then
    # Session tmux dédiée : l'agent à gauche (ou en haut), le suivi à côté ; tout se ferme avec l'agent.
    name="loomy-$(printf '%s' "$(basename "$ROOT")" | tr -c 'A-Za-z0-9_-' '-')"
    # Session déjà ouverte (autre terminal) : on la rejoint plutôt que de la fermer, sauf demande contraire.
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
    w="$(watch_script "${TMPDIR:-/tmp}/loomy-watch-$name.sh")"
    if (( side )); then tmux split-window -d -h -l 40% -t "$name" -c "$ROOT" "bash $w"
    else tmux split-window -d -v -l 35% -t "$name" -c "$ROOT" "bash $w"; fi
    ui_end "$(t "opening %s and live tracking, side by side (tmux) · click or Ctrl-b + arrow to switch panes" "$tool_label")"
    ui_exec tmux attach-session -t "$name"
  fi
  if [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] && command -v osascript >/dev/null 2>&1; then
    w="$(watch_script "${TMPDIR:-/tmp}/loomy-watch-$$.sh" $$)"
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
    UI_DESCS=("${descs[@]}"); UI_LABEL="$(t "Choice")"
    ui_choose "$(t "What do you want to do?")" 0 "${opts[@]}"
    MODE="${codes[$UI_INDEX]:-print}"
  fi
fi

case "$MODE" in
  print)
    print_cmds
    ui_end "$(t "live tracking: loomy watch")"
    ;;
  resume)
    if (( ! HAS_SESSION )); then ui_warn "$(t "No session to resume")" "$(t "opening a new session")"; MODE="new"; fi
    ;;
esac
[[ "$MODE" == "print" ]] && exit 0

# Codex n'exécute les hooks d'un projet (contexte automatique, suivi de session) qu'une fois le dossier jugé de confiance
# et les hooks approuvés : il le demande lui-même au premier lancement.
if [[ "$TOOL" == "codex" ]] && ! grep -qF "[projects.\"$ROOT\"]" "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null; then
  ui_info "$(t "first Codex launch in this project: agree to trust the folder, then approve the Loomy hooks (automatic resume)")"
fi
[[ -z "$WATCH" ]] && { [[ "$(loomy_config_get start_watch 2>/dev/null || true)" == "yes" ]] && WATCH=1 || WATCH=0; }
if [[ "$MODE" == "resume" ]]; then AGENT_CMD=("${RESUME_CMD[@]}"); else AGENT_CMD=("${NEW_CMD[@]}"); fi
WATCH_NOTE="$(t "live tracking in another terminal: loomy watch (or loomy start --watch)")"
if (( WATCH )) && ui_is_interactive; then start_with_watch; fi
ui_end "$(t "opening %s…" "$tool_label") · $WATCH_NOTE"
cd "$ROOT"
# Codex n'a pas de hooks par projet : la session est notée ici. Après exec, Codex garde ce pid.
if [[ "$TOOL" == "codex" ]]; then
  ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"codex\",\"pid\":$$"
fi
ui_exec "${AGENT_CMD[@]}"
