#!/usr/bin/env bash
# Contexte de reprise pour l'orchestrateur, en début de session. Compatible bash 3.2.
#   ai-context.sh               affiche le contexte (Codex le lit en début de session, voir AGENTS.md)
#   ai-context.sh --hook start  hook SessionStart de Claude Code : note l'ouverture de la session, puis affiche le contexte
#   ai-context.sh --hook end    hook SessionEnd de Claude Code : note la fermeture ; en mode dépôt privé, sauvegarde les fichiers IA
#   --tool codex                 mêmes hooks pour Codex (.codex/hooks.json)
# Ne bloque jamais une session : en cas de problème, il se tait.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=lib/privacy.sh
source "$SCRIPT_DIR/lib/privacy.sh"

HOOK=""; ROOT=""; TOOL="claude"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hook) HOOK="${2:-}"; shift ;;
    --root) ROOT="${2:-}"; shift ;;
    --tool) TOOL="${2:-claude}"; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
  shift
done
# Script copié dans <projet>/.loomy/scripts : le projet est deux dossiers au-dessus.
if [[ -z "$ROOT" && "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"; fi
ROOT="$(cd "${ROOT:-$(ai_project_root)}" 2>/dev/null && pwd -P)" || exit 0
[[ -f "$ROOT/.loomy/brief.md" ]] || exit 0

# ---------------------------------------------------------------- hooks : ouverture et fermeture de session
if [[ -n "$HOOK" ]]; then
  input=""; [[ -t 0 ]] || input="$(cat 2>/dev/null || true)"
  sid="$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)"
  src="$(printf '%s' "$input" | sed -n 's/.*"source" *: *"\([^"]*\)".*/\1/p' | head -1)"
  # Processus de l'agent (ancêtre du hook) : sa présence dit si la session est encore ouverte.
  pid=$PPID; p=$PPID; i=0
  while (( i < 6 )) && [[ -n "$p" && "$p" != "1" ]]; do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in *"$TOOL"*) pid=$p; break ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; i=$(( i + 1 ))
  done
  case "$HOOK" in
    start)
      ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"$TOOL\",\"session\":$(ai_json_str "$sid"),\"source\":$(ai_json_str "$src"),\"pid\":$pid" ;;
    end)
      ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"end\",\"tool\":\"$TOOL\",\"session\":$(ai_json_str "$sid"),\"pid\":$pid"
      # Budget de fin de session très court : la sauvegarde part en arrière-plan.
      if [[ "$(privacy_mode "$ROOT")" == "private" ]] && privacy_companion_ready "$ROOT"; then
        nohup bash "$SCRIPT_DIR/ai-privacy.sh" --root "$ROOT" sync --quiet >/dev/null 2>&1 &
      fi
      exit 0 ;;
  esac
fi

# ---------------------------------------------------------------- contexte
brief() { _ai_brief_get "$ROOT/.loomy/brief.md" "$1"; }
PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
UPDATED="$(sed -n 's/^updated=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
[[ -z "$PHASE" && ! -f "$ROOT/START.md" ]] && PHASE="done"
[[ -z "$PHASE" ]] && PHASE="brief"
idx="$(loomy_phase_index "$PHASE")"

echo "[Loomy] Contexte de reprise du projet « $(brief name) »$( [[ -n "$(brief slug)" ]] && echo " ($(brief slug))")."
if [[ "$PHASE" == "done" ]]; then
  echo "- Bootstrap terminé : START.md n'a plus d'autorité. Suis AGENTS.md et CLAUDE.md ; tu restes l'orchestrateur."
else
  echo "- Bootstrap en cours, phase $idx sur 10 : $(loomy_phase_label "$PHASE")${UPDATED:+ (depuis $UPDATED)}. $(loomy_phase_agent "$PHASE")"
  echo "- Reprends START.md à partir de cette phase. Enregistre chaque changement de phase, avant toute autre action : .loomy/scripts/ai-status.sh set <phase>."
  echo "- Ce que l'utilisateur doit faire maintenant : $(loomy_phase_you "$PHASE")"
fi
echo "- Brief (.loomy/brief.md) : mode $(brief ai_mode), lead $(brief ai_lead), profil $(brief budget), risque $(brief risk). Routage des rôles : .loomy/scripts/ai-route.sh ; délégations : .loomy/scripts/delegate-to-claude.sh et delegate-to-codex.sh."
J="$(ai_journal_file "$ROOT")"
if [[ -s "$J" ]] && grep -q '"type":"delegation",' "$J" 2>/dev/null; then
  last="$(grep '"type":"delegation",' "$J" | tail -3 | sed -n 's/.*"role":"\([^"]*\)".*"model":"\([^"]*\)".*"status":"\([^"]*\)".*/\1 (\2, \3)/p' | paste -sd ',' - | sed 's/,/, /g')"
  [[ -n "$last" ]] && echo "- Dernières délégations : $last."
fi
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  br="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "détachée")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  echo "- Git : branche $br, $dirty fichier(s) modifié(s) non commité(s)."
fi
case "$(privacy_mode "$ROOT")" in
  local) echo "- Fichiers IA locaux : ne versionne jamais AGENTS.md, CLAUDE.md, .ai/, .claude/, .codex/, .loomy/ ni START.md (jamais de git add -f)." ;;
  private) echo "- Fichiers IA dans un dépôt privé séparé : ne les versionne pas dans le dépôt du projet ; sauvegarde-les en fin d'étape avec .loomy/scripts/ai-privacy.sh sync." ;;
esac
echo "- Délégations : lance toujours les bridges au premier plan et attends leur fin (en arrière-plan, elles s'arrêtent si la session se ferme)."
echo "- Pour commencer : dis à l'utilisateur, en une ou deux phrases, où en est le projet et ce que tu proposes de faire maintenant."
exit 0
