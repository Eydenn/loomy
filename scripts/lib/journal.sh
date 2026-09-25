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
# Archive mensuelle : au premier événement d'un nouveau mois, le journal du mois précédent part dans
# .loomy/logs/archive/events-AAAA-MM.jsonl. Les derniers événements de session suivent dans le nouveau journal
# (état ouvert / fermé de la session en cours). Lecture de tout l'historique : ai_journal_all.
_ai_journal_rotate() {
  local file="$1" month now dir mfile
  [[ -s "$file" ]] || return 0
  # Mois du journal courant : noté à part (les événements de session recopiés gardent leur date d'origine).
  mfile="$(dirname "$file")/month"; now="$(date -u +%Y-%m)"
  month="$(cat "$mfile" 2>/dev/null || true)"
  [[ -n "$month" ]] || month="$(head -1 "$file" | sed -n 's/^{"ts":"\([0-9]\{4\}-[0-9]\{2\}\).*/\1/p')"
  if [[ -z "$month" || "$month" == "$now" ]]; then printf '%s\n' "$now" >"$mfile"; return 0; fi
  dir="$(dirname "$file")/archive"; mkdir -p "$dir" 2>/dev/null || return 0
  cat "$file" >>"$dir/events-$month.jsonl" && { grep '"type":"session"' "$file" | tail -4 >"$file.tmp" || true; } && mv "$file.tmp" "$file"
  printf '%s\n' "$now" >"$mfile"
}

# ai_journal_all <racine> : tout le journal, archives comprises, dans l'ordre.
ai_journal_all() {
  local f d="$1/.loomy/logs"
  for f in "$d"/archive/events-*.jsonl; do [[ -f "$f" ]] && cat "$f"; done
  [[ -f "$d/events.jsonl" ]] && cat "$d/events.jsonl"
  return 0
}

ai_journal_write() {
  local root="$1" body="$2" file
  ai_journal_enabled "$root" || return 0
  file="$(ai_journal_file "$root")"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 0
  _ai_journal_rotate "$file" 2>/dev/null || true
  printf '{"ts":"%s",%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$body" >>"$file" 2>/dev/null || true
}

# ai_usage_record <racine> <transcription .jsonl> <lead|subagent> [type d'agent]
# Coût réel des tours de Claude Code (orchestrateur, sous-agents natifs), lu dans la transcription de la session :
# seules les lignes nouvelles depuis le dernier passage sont lues (index .loomy/logs/usage.idx), chaque message n'est
# compté qu'une fois (identifiant), un événement « usage » est écrit par modèle.
# Prix : entrée, écriture en cache (5 min : 1,25 × entrée ; 1 h : 2 ×), lecture en cache, sortie. Vérifié : identique
# au coût que rapporte Claude Code (claude -p --output-format json) sur une session avec sous-agent.
ai_usage_record() {
  local root="$1" tr="$2" scope="$3" agent="${4:-}" idx done_n total line model tin tcw tcr tout n price cost
  [[ -f "$tr" ]] || return 0
  ai_journal_enabled "$root" || return 0
  idx="$root/.loomy/logs/usage.idx"; mkdir -p "$(dirname "$idx")" 2>/dev/null || return 0
  done_n="$(awk -F '\t' -v p="$tr" '$1 == p { n = $2 } END { print n + 0 }' "$idx" 2>/dev/null || echo 0)"
  total="$(wc -l <"$tr" | tr -d ' ')"
  (( total > done_n )) || return 0
  tail -n +"$(( done_n + 1 ))" "$tr" | head -n "$(( total - done_n ))" | awk '
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    index($0, "\"type\":\"assistant\"") && index($0, "\"usage\"") {
      id = ""; if (match($0, /"id":"msg_[^"]*"/)) id = substr($0, RSTART, RLENGTH)
      if (id != "" && (id in seen)) next; seen[id] = 1
      m = ""; if (match($0, /"model":"[^"]*"/)) { m = substr($0, RSTART + 9, RLENGTH - 10) }
      if (m == "" || m == "<synthetic>") next
      # Écriture en cache : 5 min (1,25 × entrée) ou 1 h (2 ×) ; sans détail : 1 h (session principale).
      cw = num("cache_creation_input_tokens"); w5 = num("ephemeral_5m_input_tokens"); w1 = num("ephemeral_1h_input_tokens")
      if (w5 + w1 == 0) w1 = cw
      i[m] += num("input_tokens"); f[m] += w5; h[m] += w1; r[m] += num("cache_read_input_tokens"); o[m] += num("output_tokens"); c[m]++
    }
    END { for (m in c) print m, i[m], f[m], h[m], r[m], o[m], c[m] }' | while read -r model tin tw5 tw1 tcr tout n; do
      price="$(ai_price "$model")"; cost=""; tcw=$(( tw5 + tw1 ))
      [[ -n "$price" ]] && cost="$(awk -v p="$price" -v a="$tin" -v f="$tw5" -v h="$tw1" -v r="$tcr" -v o="$tout" 'BEGIN { split(p, q, " "); printf "%.6f", (a * q[1] + f * q[1] * 1.25 + h * q[1] * 2 + r * q[3] + o * q[2]) / 1000000 }')"
      ai_journal_write "$root" "\"type\":\"usage\",\"tool\":\"claude\",\"family\":\"claude\",\"scope\":\"$scope\",\"agent\":$(ai_json_str "$agent"),\"model\":\"$model\",\"messages\":$n,\"tokens_in\":$(( tin + tcw )),\"tokens_cached\":$tcr,\"tokens_out\":$tout,\"cost_usd\":${cost:-0},\"cost_source\":\"estimate\""
    done
  { awk -F '\t' -v p="$tr" '$1 != p' "$idx" 2>/dev/null || true; printf '%s\t%s\n' "$tr" "$total"; } >"$idx.tmp" && mv "$idx.tmp" "$idx"
  return 0
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

# ai_session_state <racine> : « open|<heure locale>|<outil> », « closed|<heure>|<outil> » ou « none ».
# Une session est ouverte si elle a commencé, n'a pas fini, et que son processus (Claude Code ou Codex) tourne encore.
# ai_ts_epoch <horodatage ISO UTC> : secondes depuis 1970 (date de macOS ou GNU), vide si illisible.
ai_ts_epoch() {
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || true
}

ai_session_state() {
  local j line pid ts tool state="none" s hhmm
  j="$(ai_journal_file "$1")"
  [[ -s "$j" ]] || { echo "none"; return 0; }
  while IFS='|' read -r kind pid ts tool; do
    [[ -n "$kind" ]] || continue
    if [[ "$kind" == "open" ]]; then
      if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then state="open|$ts|$tool"; break; fi
    elif [[ "$state" == "none" ]]; then state="closed|$ts|$tool"; fi
  done < <(awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "" }
    /"type":"session"/ {
      key = field("session"); if (key == "") key = "pid" num("pid")
      # Une session reprise (claude --continue) garde son identifiant : un nouveau début annule la fin précédente.
      if (index($0, "\"event\":\"start\"")) { n++; order[n] = key; start[key] = num("pid") "|" field("ts") "|" field("tool"); delete ended[key] }
      else { ended[key] = field("ts") "|" field("tool"); last_end = field("ts") "|" field("tool") }
    }
    END {
      for (i = n; i >= 1 && i > n - 10; i--) if (!(order[i] in ended)) print "open|" start[order[i]]
      if (last_end != "") print "end||" last_end
    }' "$j" 2>/dev/null)
  [[ "$state" == "none" ]] && { echo "none"; return 0; }
  ts="$(printf '%s' "$state" | cut -d'|' -f2)"
  s="$(ai_ts_epoch "$ts")"
  hhmm="$( [[ -n "$s" ]] && { date -r "$s" +%H:%M 2>/dev/null || date -d "@$s" +%H:%M 2>/dev/null; } )"
  echo "$(printf '%s' "$state" | cut -d'|' -f1)|${hhmm:-?}|$(printf '%s' "$state" | cut -d'|' -f3)"
}

# ai_delegation_id : identifiant court d'une délégation, relie son événement de début à son événement de fin.
ai_delegation_id() { printf 'd%s%05d' "$(date +%s)" "$$"; }

# ai_journal_start <racine> <id> <pont> <rôle> <famille> <modèle> <effort> <sandbox> <tâche>
# Signale une délégation en cours. Le pid permet à « loomy status » d'écarter une délégation interrompue.
ai_journal_start() {
  ai_journal_write "$1" "\"type\":\"delegation_start\",\"id\":\"$2\",\"pid\":$$,\"bridge\":\"$3\",\"role\":\"$4\",\"family\":\"$5\",\"model\":\"$6\",\"effort\":\"$7\",\"sandbox\":\"$8\",\"task\":$(ai_json_str "$(ai_task_excerpt "$9")")"
}
