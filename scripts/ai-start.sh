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
    *) echo "Argument inconnu : $1" >&2; exit 2 ;;
  esac
  shift
done
# Chemin réel (liens résolus) : c'est celui que Claude et Codex enregistrent pour leurs sessions.
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd -P)"
BRIEF="$ROOT/.loomy/brief.md"
if [[ ! -f "$BRIEF" ]]; then
  echo "Pas de brief Loomy dans ${ROOT/#$HOME/~} : lancez d'abord loomy init (nouveau projet) ou loomy brief." >&2
  exit 1
fi

# ---------------------------------------------------------------- projet et orchestrateur
ai_detect_env "$ROOT"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
TOOL="$R_FAMILY"; MODEL="$R_MODEL"; EFFORT="$R_EFFORT"
PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
NAME="$(_ai_brief_get "$BRIEF" name)"

phase_label() {
  case "$1" in
    brief) echo "Brief" ;; discover) echo "Découverte" ;; interview) echo "Entretien" ;; propose) echo "Proposition" ;;
    approve) echo "Validation" ;; build) echo "Construction" ;; verify) echo "Vérification" ;; document) echo "Documentation" ;;
    commit) echo "Commit" ;; retire) echo "Clôture" ;; done) echo "Terminé" ;; *) echo "${1:-inconnue}" ;;
  esac
}

# Prompt de la nouvelle session selon l'avancement.
if [[ -f "$ROOT/START.md" && ( -z "$PHASE" || "$PHASE" == "brief" || "$PHASE" == "discover" ) ]]; then
  PROMPT="$(ai_start_prompt "$AI_MODE" "$AI_LEAD")"; KIND="démarrage du bootstrap"
elif [[ -f "$ROOT/START.md" ]]; then
  PROMPT="Reprends l'initialisation de ce projet en suivant START.md, là où elle s'est arrêtée : phase « $(phase_label "$PHASE") ». Lance d'abord .loomy/scripts/ai-context.sh pour le contexte (phase, attentes, dernières délégations). Commence par me résumer où on en est et ce qui reste à faire, puis attends ma validation avant de continuer."
  KIND="reprise à la phase $(phase_label "$PHASE")"
else
  PROMPT="Reprends le travail sur ce projet : lance .loomy/scripts/ai-context.sh pour le contexte, lis AGENTS.md (ou CLAUDE.md) et .ai/AI_WORKFLOW.md, résume l'état actuel du dépôt et propose la suite. Délègue chaque rôle selon .loomy/scripts/ai-route.sh."
  KIND="travail courant (bootstrap terminé)"
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
ui_banner "Démarrer ou reprendre" "${NAME:-$(basename "$ROOT")} · ${ROOT/#$HOME/~}"
ui_section "SESSION"
ui_kv "Phase" "${C_BOLD}$(phase_label "$PHASE")${C_RESET}"
ui_kv "Orchestrateur" "${C_BRAND}${MODEL}${C_RESET} · effort $EFFORT · $tool_label"
if (( HAS_SESSION )); then ui_kv "Session" "${C_GREEN}une session précédente existe sur cette machine${C_RESET}"
else ui_kv "Session" "${C_DIM}aucune session précédente sur cette machine${C_RESET}"; fi
if (( ! CLI_OK )); then
  ui_err "$tool_label introuvable" "installez-le : $INSTALL"
  ui_end "diagnostic complet : loomy doctor"
  exit 1
fi

# ---------------------------------------------------------------- session + suivi en direct, côte à côte
# Côte à côte si le terminal est large (≥ 160 colonnes), sinon l'un au-dessus de l'autre (session en haut, 2/3).
# Le suivi se ferme de lui-même à la fin de la session de l'agent (--until-exit).
watch_script() {
  local f="${TMPDIR:-/tmp}/loomy-watch-$$.sh"
  printf '#!/bin/bash\nexec bash %q --root %q --watch --compact --until-exit %s\n' "$SCRIPT_DIR/ai-status.sh" "$ROOT" "$1" >"$f"
  chmod +x "$f"; echo "$f"
}

start_with_watch() {
  local side=0 w agent name
  _ui_term_size; (( UI_COLS >= 160 )) && side=1
  if [[ -n "${TMUX:-}" ]] && command -v tmux >/dev/null 2>&1; then
    # Déjà dans tmux : un panneau de suivi à côté, puis l'agent dans le panneau courant (même processus : exec).
    w="$(watch_script $$)"
    if (( side )); then tmux split-window -d -h -l 40% -c "$ROOT" "bash $w"
    else tmux split-window -d -v -l 35% -c "$ROOT" "bash $w"; fi
    WATCH_NOTE="suivi en direct dans le panneau tmux $( (( side )) && echo "de droite" || echo "du bas"), fermé avec la session"
    return 0
  fi
  if [[ "${TERM_PROGRAM:-}" == "iTerm.app" ]] && command -v osascript >/dev/null 2>&1; then
    w="$(watch_script $$)"
    if osascript -e "tell application \"iTerm2\" to tell current session of current window to split $( (( side )) && echo vertically || echo horizontally ) with default profile command \"/bin/bash $w\"" >/dev/null 2>&1; then
      WATCH_NOTE="suivi en direct dans le panneau iTerm2 voisin, fermé avec la session"
      return 0
    fi
  fi
  if command -v tmux >/dev/null 2>&1; then
    # Session tmux dédiée : l'agent à gauche (ou en haut), le suivi à côté ; tout se ferme avec l'agent.
    name="loomy-$(printf '%s' "$(basename "$ROOT")" | tr -c 'A-Za-z0-9_-' '-')"
    tmux kill-session -t "$name" 2>/dev/null || true
    agent="$(printf '%q ' "${AGENT_CMD[@]}")"
    tmux new-session -d -s "$name" -c "$ROOT" -x "$UI_COLS" -y "$UI_ROWS" "cd $(printf '%q' "$ROOT") && $agent; tmux kill-session -t $name"
    tmux set-option -t "$name" mouse on >/dev/null
    tmux set-option -t "$name" status off >/dev/null
    tmux set-option -t "$name" pane-border-style "fg=colour60" >/dev/null
    tmux set-option -t "$name" pane-active-border-style "fg=colour141" >/dev/null
    w="${TMPDIR:-/tmp}/loomy-watch-$name.sh"
    printf '#!/bin/bash\nexec bash %q --root %q --watch --compact\n' "$SCRIPT_DIR/ai-status.sh" "$ROOT" >"$w"
    if (( side )); then tmux split-window -d -h -l 40% -t "$name" -c "$ROOT" "bash $w"
    else tmux split-window -d -v -l 35% -t "$name" -c "$ROOT" "bash $w"; fi
    ui_end "ouverture de ${tool_label} et du suivi en direct, côte à côte (tmux) · clic ou Ctrl-b + flèche pour changer de panneau"
    ui_exec tmux attach-session -t "$name"
  fi
  if [[ "${TERM_PROGRAM:-}" == "Apple_Terminal" ]] && command -v osascript >/dev/null 2>&1; then
    w="$(watch_script $$)"
    if osascript -e "tell application \"Terminal\" to do script \"/bin/bash $w\"" >/dev/null 2>&1; then
      WATCH_NOTE="suivi en direct dans une nouvelle fenêtre Terminal, fermée avec la session"
      return 0
    fi
  fi
  WATCH_NOTE="suivi côte à côte indisponible ici (brew install tmux) : lance loomy watch dans un autre terminal"
  return 0
}

print_cmds() {
  ui_section "COMMANDES" "à lancer à la racine du projet"
  if (( HAS_SESSION )); then
    ui_rail "${C_DIM}reprendre :${C_RESET} ${C_BOLD}$(short_cmd "$( [[ "$TOOL" == claude ]] && echo --continue || echo "resume --last")")${C_RESET}"
  fi
  ui_rail "${C_DIM}nouvelle  :${C_RESET} ${C_BOLD}$(short_cmd)${C_RESET} ${C_DIM}puis colle le prompt :${C_RESET}"
  _ui_term_size; _ui_wrap "$PROMPT" $(( UI_W - 8 ))
  for l in "${UI_LINES[@]}"; do ui_rail "   ${C_DIM}${l}${C_RESET}"; done
  if ui_is_interactive && ui_copy "$PROMPT"; then ui_rail "   ${C_GREEN}✓${C_RESET} ${C_DIM}prompt copié dans le presse-papiers${C_RESET}"; fi
  app="l'app Claude (onglet Code)"; [[ "$TOOL" == "codex" ]] && app="l'app Codex"
  ui_rail "${C_DIM}dans l'app :${C_RESET} ouvre ce dossier dans $app, modèle ${C_BOLD}$MODEL${C_RESET}, effort ${C_BOLD}$EFFORT${C_RESET}, puis colle le prompt"
}

if [[ "$MODE" == "menu" ]]; then
  if ! ui_is_interactive; then MODE="print"
  else
    ui_print "${C_RAIL}│${C_RESET}"
    opts=(); descs=()
    if (( HAS_SESSION )); then
      opts+=("Reprendre la dernière session"); descs+=("Reprend la conversation la plus récente de ce dossier, avec son historique : $(short_cmd "$( [[ "$TOOL" == claude ]] && echo --continue || echo "resume --last")")")
    fi
    opts+=("Nouvelle session"); descs+=("Ouvre $tool_label avec le prompt de $KIND. L'agent relit START.md, le brief et l'état du projet.")
    opts+=("Afficher les commandes"); descs+=("N'ouvre rien : affiche les commandes et copie le prompt, pour les lancer toi-même.")
    UI_DESCS=("${descs[@]}"); UI_LABEL="Choix"
    ui_choose "Que veux-tu faire ?" 0 "${opts[@]}"
    case "$UI_VALUE" in
      Reprendre*) MODE="resume" ;;
      Nouvelle*) MODE="new" ;;
      *) MODE="print" ;;
    esac
  fi
fi

case "$MODE" in
  print)
    print_cmds
    ui_end "suivi en direct : loomy watch"
    ;;
  resume)
    if (( ! HAS_SESSION )); then ui_warn "Aucune session à reprendre" "ouverture d'une nouvelle session"; MODE="new"; fi
    ;;
esac
[[ "$MODE" == "print" ]] && exit 0

# Codex n'exécute les hooks d'un projet (contexte automatique, suivi de session) qu'une fois le dossier jugé de confiance
# et les hooks approuvés : il le demande lui-même au premier lancement.
if [[ "$TOOL" == "codex" ]] && ! grep -qF "[projects.\"$ROOT\"]" "${CODEX_HOME:-$HOME/.codex}/config.toml" 2>/dev/null; then
  ui_info "premier lancement de Codex dans ce projet : accepte de faire confiance au dossier, puis approuve les hooks Loomy (reprise automatique)"
fi
[[ -z "$WATCH" ]] && { [[ "$(loomy_config_get start_watch 2>/dev/null || true)" == "yes" ]] && WATCH=1 || WATCH=0; }
if [[ "$MODE" == "resume" ]]; then AGENT_CMD=("${RESUME_CMD[@]}"); else AGENT_CMD=("${NEW_CMD[@]}"); fi
WATCH_NOTE="suivi en direct dans un autre terminal : loomy watch (ou loomy start --watch)"
if (( WATCH )) && ui_is_interactive; then start_with_watch; fi
ui_end "ouverture de ${tool_label}… · $WATCH_NOTE"
cd "$ROOT"
# Codex n'a pas de hooks par projet : la session est notée ici. Après exec, Codex garde ce pid.
if [[ "$TOOL" == "codex" ]]; then
  ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"codex\",\"pid\":$$"
fi
ui_exec "${AGENT_CMD[@]}"
