#!/usr/bin/env bash
# shellcheck disable=SC2034  # bibliothèque chargée par d'autres scripts
# Journal d'activité de Loomy : <projet>/.loomy/logs/events.jsonl, une ligne JSON par événement.
# Alimente « loomy status » et « loomy watch ». À charger (source). Compatible bash 3.2.
#
# Le journal n'est écrit que dans un projet Loomy (dossier .loomy présent).
# LOOMY_JOURNAL=0 le désactive ; LOOMY_JOURNAL_TASKS=0 n'y enregistre pas le texte des tâches.

ai_journal_file() { echo "$1/.loomy/logs/events.jsonl"; }

ai_journal_enabled() {
  [[ "${LOOMY_JOURNAL:-1}" != "0" && -d "$1/.loomy" ]]
}

# Échappe une chaîne pour JSON (guillemets, antislash, retours à la ligne, tabulations, caractères de contrôle).
ai_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/}"; s="${s//$'\t'/ }"
  printf '"%s"' "$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')"
}

# ai_journal_write <racine> <paires JSON sans accolades, ex. "type":"phase","phase":"build">
ai_journal_write() {
  local root="$1" body="$2" file
  ai_journal_enabled "$root" || return 0
  file="$(ai_journal_file "$root")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  printf '{"ts":"%s",%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$body" >>"$file" 2>/dev/null || true
}

# ai_cost_estimate <modèle> <tokens entrée non cachés> <tokens cachés> <tokens sortie> : coût estimé en $.
ai_cost_estimate() {
  local price
  price="$(ai_price "$1")"
  [[ -z "$price" ]] && { echo ""; return 0; }
  # shellcheck disable=SC2086
  set -- $price "$2" "$3" "$4"
  awk -v pin="$1" -v pout="$2" -v pcache="$3" -v tin="$4" -v tcache="$5" -v tout="$6" \
    'BEGIN { printf "%.6f", (tin*pin + tcache*pcache + tout*pout) / 1000000 }'
}

# ai_json_num <json> <clé> : première valeur numérique de la clé (0 si absente).
ai_json_num() {
  local v
  v="$(printf '%s' "$1" | grep -oE "\"$2\":[0-9.]+" | head -1 | sed 's/.*://')"
  echo "${v:-0}"
}

# ai_task_excerpt <texte> : extrait de la tâche pour le journal (200 caractères), vide si LOOMY_JOURNAL_TASKS=0.
ai_task_excerpt() {
  if [[ "${LOOMY_JOURNAL_TASKS:-1}" == "0" ]]; then echo ""; return 0; fi
  printf '%s' "$1" | tr '\n' ' ' | cut -c1-200
}

# ai_delegation_id : identifiant court d'une délégation, relie son événement de début à son événement de fin.
ai_delegation_id() { printf 'd%s%05d' "$(date +%s)" "$$"; }

# ai_journal_start <racine> <id> <pont> <rôle> <famille> <modèle> <effort> <sandbox> <tâche>
# Signale une délégation en cours. Le pid permet à « loomy status » d'écarter une délégation interrompue.
ai_journal_start() {
  ai_journal_write "$1" "\"type\":\"delegation_start\",\"id\":\"$2\",\"pid\":$$,\"bridge\":\"$3\",\"role\":\"$4\",\"family\":\"$5\",\"model\":\"$6\",\"effort\":\"$7\",\"sandbox\":\"$8\",\"task\":$(ai_json_str "$(ai_task_excerpt "$9")")"
}
