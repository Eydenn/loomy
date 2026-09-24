#!/usr/bin/env bash
# Démarre ou reprend la session de l'orchestrateur d'un projet Loomy. Compatible bash 3.2.
#   ai-start.sh              menu : reprendre la dernière session, nouvelle session, ou afficher les commandes
#   ai-start.sh --resume     reprend directement la dernière session de ce dossier (sur cette machine)
#   ai-start.sh --new        ouvre une nouvelle session avec le prompt adapté à la phase du projet
#   ai-start.sh --print      affiche seulement les commandes
#   ai-start.sh --root <dir> agit sur un autre dossier de projet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

ROOT=""; MODE="menu"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --resume|-r) MODE="resume" ;;
    --new|-n) MODE="new" ;;
    --print|-p) MODE="print" ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//; s/ai-start.sh/loomy start/'; exit 0 ;;
    *) echo "Argument inconnu : $1" >&2; exit 2 ;;
  esac
  shift
done
# Chemin réel (liens résolus) : c'est celui que Claude et Codex enregistrent pour leurs sessions.
ROOT="$(cd "${ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" && pwd -P)"
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
  PROMPT="Reprends l'initialisation de ce projet en suivant START.md, là où elle s'est arrêtée : phase « $(phase_label "$PHASE") » (voir .loomy/state). Le brief est dans .loomy/brief.md. Commence par me résumer où on en est et ce qui reste à faire, puis attends ma validation avant de continuer."
  KIND="reprise à la phase $(phase_label "$PHASE")"
else
  PROMPT="Reprends le travail sur ce projet : lis AGENTS.md (ou CLAUDE.md) et .ai/AI_WORKFLOW.md, résume l'état actuel du dépôt et propose la suite. Délègue chaque rôle selon .loomy/scripts/ai-route.sh."
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

ui_end "ouverture de ${tool_label}… · suivi en direct dans un autre terminal : loomy watch"
cd "$ROOT"
if [[ "$MODE" == "resume" ]]; then exec "${RESUME_CMD[@]}"; else exec "${NEW_CMD[@]}"; fi
