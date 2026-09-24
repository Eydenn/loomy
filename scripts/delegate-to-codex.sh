#!/usr/bin/env bash
# Confie un rôle à la CLI Codex (codex exec). Compatible bash 3.2.
# Utilisé par un orchestrateur Claude Code en mode hybride, ou par un orchestrateur Codex pour faire tourner un rôle sur son modèle routé.
#   Rôles qui écrivent (executor, developer, documenter) : sandbox workspace-write, les changements arrivent dans le répertoire de travail.
#   Rôles en lecture seule (reviewer, explorer, debugger, architect, security) : sandbox read-only, constats uniquement.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"

ROLE="${1:-}"
TASK="${2:-}"

if [[ -z "$ROLE" || -z "$TASK" ]]; then
  echo "Usage : $0 <executor|developer|documenter|reviewer|explorer|debugger|architect|security> \"tâche\"" >&2
  echo "Surcharges possibles : DELEGATE_CODEX_MODEL, DELEGATE_CODEX_EFFORT, AI_ROUTE_PROFILE (econome|equilibre|qualite)" >&2
  exit 2
fi

case "$ROLE" in
  review) ROLE="reviewer" ;; research) ROLE="explorer" ;; debug) ROLE="debugger" ;;
  architecture) ROLE="architect" ;; exec|implement) ROLE="executor" ;;
esac

case "$ROLE" in
  executor)
    GUIDANCE="Tu es l'Exécutant. Réalise exactement la tâche bornée ci-dessous, dans le périmètre indiqué. Suis les conventions du dépôt, ajoute ou mets à jour les tests du comportement modifié, lance les vérifications pertinentes, puis arrête-toi. Ne refactore rien hors du périmètre. Si la tâche s'avère ambiguë, transverse ou risquée, arrête-toi sans modifier de fichier et explique pourquoi elle doit remonter d'un cran." ;;
  developer)
    GUIDANCE="Tu es le Développeur. Implémente la feature ou le correctif ci-dessous dans le périmètre indiqué, en suivant les conventions du dépôt, avec des tests. Lance les vérifications pertinentes et indique les commandes exactes et leurs résultats. Arrête-toi et rends compte si le changement devient transverse ou risqué." ;;
  documenter)
    GUIDANCE="Tu es le Documentaliste. Ne mets à jour que la documentation indiquée par la tâche. Sois exact : vérifie chaque affirmation dans le code. Ne modifie pas le code source." ;;
  reviewer)
    GUIDANCE="Tu es un Relecteur indépendant. Relis le diff ou les fichiers indiqués dans la tâche. Ne signale que des défauts concrets : régressions, cas limites oubliés, problèmes de sécurité, tests manquants, complexité inutile, chacun avec gravité, référence de fichier et preuve. Ne modifie aucun fichier. « Aucun constat » est une réponse valable." ;;
  explorer)
    GUIDANCE="Tu es l'Explorateur. Réponds uniquement à la question posée, avec des faits courts et des références chemin:ligne. Ne propose pas de réécriture. Ne modifie aucun fichier." ;;
  debugger)
    GUIDANCE="Tu es le Débogueur. Examine les preuves, classe les hypothèses de cause, et propose les vérifications ou correctifs les plus petits et les plus discriminants. Ne modifie aucun fichier." ;;
  architect)
    GUIDANCE="Tu es l'Architecte. Critique la conception au regard de la tâche et des contraintes du dépôt : arbitrages, couplage, alternatives plus simples. Ne modifie aucun fichier." ;;
  security)
    GUIDANCE="Tu es le Relecteur sécurité. N'inspecte que le périmètre donné. Signale des faiblesses concrètes avec leur exploitabilité, les preuves et la correction, en séparant les problèmes confirmés des hypothèses. Ne modifie aucun fichier." ;;
  *) echo "Erreur : rôle non pris en charge '$ROLE'." >&2; exit 2 ;;
esac

CODEX="$(ai_codex_bin)" || { echo "Erreur : CLI Codex introuvable (PATH, Codex.app ou ChatGPT.app). Lancez ai-doctor.sh." >&2; exit 127; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
ai_detect_env "$ROOT"
ai_route "$ROLE" codex "$AI_PROFILE"
MODEL="${DELEGATE_CODEX_MODEL:-$R_MODEL}"
EFFORT="${DELEGATE_CODEX_EFFORT:-$R_EFFORT}"

SANDBOX="read-only"
if ai_role_writes "$ROLE"; then SANDBOX="workspace-write"; fi

PROMPT="$GUIDANCE

Tâche confiée par l'orchestrateur :
$TASK

Tu es un spécialiste. Ne prends pas la direction du projet. Rends un résultat concis à l'orchestrateur : ce que tu as fait ou trouvé, les fichiers concernés, les vérifications lancées et leurs résultats, les risques ouverts. Réponds en français."

TMP="$(mktemp -d "${TMPDIR:-/tmp}/delegate-codex.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BEFORE=""
if [[ "$SANDBOX" == "workspace-write" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BEFORE="$(git -C "$ROOT" status --porcelain)"
fi

echo "delegate-to-codex : rôle=$ROLE modèle=$MODEL effort=$EFFORT sandbox=$SANDBOX profil=$AI_PROFILE" >&2

DELEG_ID="$(ai_delegation_id)"
ai_journal_start "$ROOT" "$DELEG_ID" codex "$ROLE" codex "$MODEL" "$EFFORT" "$SANDBOX" "$TASK"
STARTED="$(date +%s)"
set +e
"$CODEX" exec -m "$MODEL" -c "model_reasoning_effort=$EFFORT" -s "$SANDBOX" -C "$ROOT" \
  --skip-git-repo-check --ephemeral --json -o "$TMP/last.txt" "$PROMPT" </dev/null >"$TMP/log.txt" 2>&1
STATUS=$?
set -e
DURATION=$(( $(date +%s) - STARTED ))

# Consommation rapportée par les événements "turn.completed" de codex exec --json.
read -r T_IN T_CACHED T_OUT < <(grep '"turn.completed"' "$TMP/log.txt" | awk '
  { if (match($0, /"input_tokens":[0-9]+/)) i += substr($0, RSTART+15, RLENGTH-15)
    if (match($0, /"cached_input_tokens":[0-9]+/)) c += substr($0, RSTART+22, RLENGTH-22)
    if (match($0, /"output_tokens":[0-9]+/)) o += substr($0, RSTART+16, RLENGTH-16) }
  END { printf "%d %d %d\n", i, c, o }')
COST="$(ai_cost_estimate "$MODEL" "$(( T_IN - T_CACHED ))" "$T_CACHED" "$T_OUT")"

CHANGED=0
if [[ $STATUS -eq 0 && "$SANDBOX" == "workspace-write" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  AFTER="$(git -C "$ROOT" status --porcelain)"
  CHANGED="$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -c '^> ' || true)"
fi

RESULT="ok"; [[ $STATUS -ne 0 ]] && RESULT="error"
ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"$DELEG_ID\",\"bridge\":\"codex\",\"role\":\"$ROLE\",\"family\":\"codex\",\"model\":\"$MODEL\",\"effort\":\"$EFFORT\",\"profile\":\"$AI_PROFILE\",\"sandbox\":\"$SANDBOX\",\"status\":\"$RESULT\",\"duration_s\":$DURATION,\"tokens_in\":$T_IN,\"tokens_cached\":$T_CACHED,\"tokens_out\":$T_OUT,\"cost_usd\":${COST:-0},\"cost_source\":\"estimate\",\"files_changed\":$CHANGED,\"task\":$(ai_json_str "$(ai_task_excerpt "$TASK")")"

if [[ $STATUS -ne 0 ]]; then
  echo "delegate-to-codex : échec de codex exec (code $STATUS). Dernières lignes du journal :" >&2
  tail -20 "$TMP/log.txt" >&2
  exit "$STATUS"
fi

cat "$TMP/last.txt"
echo

if [[ "$SANDBOX" == "workspace-write" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ "$CHANGED" != "0" ]]; then
    echo "delegate-to-codex : le répertoire de travail a changé — relisez avec 'git diff' avant d'accepter :" >&2
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed -n 's/^> /  /p' >&2 || true
  else
    echo "delegate-to-codex : aucun fichier modifié." >&2
  fi
fi
echo "delegate-to-codex : ${DURATION}s · tokens entrée $T_IN (dont $T_CACHED en cache), sortie $T_OUT · coût estimé \$${COST:-?}" >&2
