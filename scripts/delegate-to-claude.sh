#!/usr/bin/env bash
# Confie un rôle en lecture seule à la CLI Claude Code (claude -p). Compatible bash 3.2.
# Utilisé par un orchestrateur Codex en mode hybride. Claude inspecte et rend compte ; ses outils de modification sont désactivés.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"

ROLE="${1:-}"
TASK="${2:-}"

if [[ -z "$ROLE" || -z "$TASK" ]]; then
  echo "Usage : $0 <architect|debugger|security|reviewer|explorer> \"tâche\"" >&2
  echo "Anciens noms acceptés : architecture, debug, review, research." >&2
  echo "Surcharges possibles : DELEGATE_CLAUDE_MODEL, DELEGATE_CLAUDE_EFFORT, DELEGATE_CLAUDE_MAX_TURNS, AI_ROUTE_PROFILE" >&2
  exit 2
fi

case "$ROLE" in
  review) ROLE="reviewer" ;; research) ROLE="explorer" ;; debug) ROLE="debugger" ;; architecture) ROLE="architect" ;;
esac

if ! command -v claude >/dev/null 2>&1; then
  echo "Erreur : la CLI Claude Code ('claude') est introuvable dans le PATH. Lancez loomy doctor." >&2
  exit 127
fi

case "$ROLE" in
  reviewer)
    ROLE_GUIDANCE="Agis comme relecteur de code senior et indépendant. Inspecte le dépôt ou le diff concerné par la tâche. Ne signale que des défauts concrets : régressions, tests manquants, hypothèses dangereuses ou complexité inutile. Ne modifie aucun fichier. Rends des constats concis, classés par gravité, avec références de fichiers et preuves." ;;
  architect)
    ROLE_GUIDANCE="Agis comme architecte logiciel indépendant. Critique l'architecture proposée ou actuelle au regard de la tâche et des contraintes du dépôt : arbitrages importants, couplage, maintenabilité, montée en charge et alternatives plus simples. Ne modifie aucun fichier. Rends des recommandations concises et justifiées." ;;
  debugger)
    ROLE_GUIDANCE="Agis comme spécialiste indépendant du débogage. Examine les preuves disponibles dans le dépôt et les logs. Identifie les causes probables, classe les hypothèses et propose les vérifications ou correctifs les plus petits et les plus discriminants. Ne modifie aucun fichier. Évite les listes de correctifs spéculatifs." ;;
  security)
    ROLE_GUIDANCE="Agis comme relecteur sécurité indépendant. N'inspecte que le périmètre concerné par la tâche. Identifie des faiblesses de sécurité concrètes avec leur contexte d'exploitation, les preuves, les fichiers touchés et la correction recommandée. Ne modifie aucun fichier. Distingue les problèmes confirmés des hypothèses." ;;
  explorer)
    ROLE_GUIDANCE="Agis comme chercheur technique ciblé. N'étudie que la question posée, privilégie les preuves de référence disponibles dans l'environnement, et rends des constats concis, les incertitudes et l'action recommandée. Ne modifie aucun fichier." ;;
  *)
    echo "Erreur : rôle non pris en charge '$ROLE'. Les rôles qui écrivent passent par Codex (delegate-to-codex.sh) ou par un sous-agent natif." >&2
    exit 2 ;;
esac

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ai_detect_env "$ROOT"
ai_route "$ROLE" claude "$AI_PROFILE"
# Volontairement pas CLAUDE_MODEL/CLAUDE_EFFORT : Claude Code exporte CLAUDE_EFFORT dans ses propres sessions.
MODEL="${DELEGATE_CLAUDE_MODEL:-$R_MODEL}"
EFFORT="${DELEGATE_CLAUDE_EFFORT:-$R_EFFORT}"
MAX_TURNS="${DELEGATE_CLAUDE_MAX_TURNS:-${CLAUDE_MAX_TURNS:-8}}"

PROMPT="$ROLE_GUIDANCE

Tâche confiée par l'orchestrateur :
$TASK

Tu es un spécialiste. Ne prends pas la direction du projet. Ne modifie aucun fichier du dépôt. Rends ton résultat uniquement à l'orchestrateur. Réponds en français."

run_claude() {
  claude -p "$PROMPT" --output-format json --max-turns "$MAX_TURNS" \
    --model "$1" --effort "$EFFORT" \
    --disallowedTools "Edit,Write,NotebookEdit"
}

echo "delegate-to-claude : rôle=$ROLE modèle=$MODEL effort=$EFFORT tours_max=$MAX_TURNS profil=$AI_PROFILE" >&2

DELEG_ID="$(ai_delegation_id)"
ai_journal_start "$ROOT" "$DELEG_ID" claude "$ROLE" claude "$MODEL" "$EFFORT" read-only "$TASK"
STARTED="$(date +%s)"
set +e
OUT="$(run_claude "$MODEL")"
STATUS=$?
set -e

# Les anciennes versions de Claude Code refusent les identifiants de modèles récents : nouvel essai avec l'alias de la famille.
if printf '%s' "$OUT" | grep -q 'does not support this model'; then
  ALIAS="$(ai_claude_alias "$MODEL")"
  echo "delegate-to-claude : cette version de Claude Code ne connaît pas $MODEL, nouvel essai avec '$ALIAS' (lancez 'claude update')." >&2
  set +e
  OUT="$(run_claude "$ALIAS")"
  STATUS=$?
  set -e
fi

DURATION=$(( $(date +%s) - STARTED ))
# Coût et tokens rapportés par la sortie JSON de claude -p.
T_IN="$(ai_json_num "$OUT" input_tokens)"
T_CACHED="$(ai_json_num "$OUT" cache_read_input_tokens)"
T_CWRITE="$(ai_json_num "$OUT" cache_creation_input_tokens)"
T_OUT="$(ai_json_num "$OUT" output_tokens)"
COST="$(ai_json_num "$OUT" total_cost_usd)"
RESULT="ok"
if [[ $STATUS -ne 0 ]] || printf '%s' "$OUT" | grep -q '"is_error":true'; then RESULT="error"; fi
ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"$DELEG_ID\",\"bridge\":\"claude\",\"role\":\"$ROLE\",\"family\":\"claude\",\"model\":\"$MODEL\",\"effort\":\"$EFFORT\",\"profile\":\"$AI_PROFILE\",\"sandbox\":\"read-only\",\"status\":\"$RESULT\",\"duration_s\":$DURATION,\"tokens_in\":$(( T_IN + T_CACHED + T_CWRITE )),\"tokens_cached\":$T_CACHED,\"tokens_out\":$T_OUT,\"cost_usd\":$COST,\"cost_source\":\"reported\",\"files_changed\":0,\"task\":$(ai_json_str "$(ai_task_excerpt "$TASK")")"
echo "delegate-to-claude : ${DURATION}s · tokens entrée $(( T_IN + T_CACHED + T_CWRITE )) (dont $T_CACHED en cache), sortie $T_OUT · coût \$$(awk -v c="$COST" 'BEGIN { printf "%.4f", c }')" >&2

printf '%s\n' "$OUT"
exit "$STATUS"
