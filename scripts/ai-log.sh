#!/usr/bin/env bash
# Journal du projet Loomy, lisible. Compatible bash 3.2.
#   ai-log.sh [-n N]        les N derniers événements (20 par défaut), à l'heure locale
#   ai-log.sh -f            puis suit le journal en continu
#   ai-log.sh --raw         lignes JSON brutes (.loomy/logs/events.jsonl)
#   ai-log.sh --since AAAA-MM-JJ   à partir de cette date (archives mensuelles comprises)
#   ai-log.sh --csv         coûts en CSV (délégations et travail de Claude Code, sans le texte des tâches)
#   ai-log.sh --root <dir>  agit sur un autre dossier de projet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"

ROOT=""; N=20; FOLLOW=0; RAW=0; SINCE=""; CSV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -n) N="${2:-20}"; shift ;;
    -f|--follow) FOLLOW=1 ;;
    --raw) RAW=1 ;;
    --since) SINCE="${2:-}"; shift ;;
    --csv) CSV=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//; s/ai-log.sh/loomy log/'; exit 0 ;;
    *) t "Argument inconnu : %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
[[ "$N" =~ ^[0-9]+$ ]] || { t "-n : un nombre" >&2; echo >&2; exit 2; }
[[ -z "$SINCE" || "$SINCE" =~ ^[0-9]{4}-[0-9]{2}(-[0-9]{2})?$ ]] || { t "--since : une date AAAA-MM-JJ" >&2; echo >&2; exit 2; }
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd)"
FILE="$(ai_journal_file "$ROOT")"
[[ -f "$FILE" ]] || { t "Aucun journal dans ce projet (%s)." "${FILE/#$HOME/~}" >&2; echo >&2; exit 1; }

# Événements choisis : tout l'historique (archives comprises), à partir de --since ; les N derniers sans --since.
events() {
  if [[ -n "$SINCE" ]]; then ai_journal_all "$ROOT" | awk -v s="\"ts\":\"$SINCE" 'substr($0, 2, length(s)) >= s'
  else ai_journal_all "$ROOT" | tail -n "$N"; fi
}

if (( CSV )); then
  echo "date_utc,type,role,agent,family,model,status,duration_s,messages,tokens_in,tokens_cached,tokens_out,cost_usd,cost_source"
  N=1000000000 events | awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/,/, " ", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "" }
    index($0, "\"type\":\"delegation\",") || index($0, "\"type\":\"usage\"") {
      ty = field("type"); role = (ty == "usage" ? (field("scope") == "lead" ? "lead" : "subagent") : field("role"))
      printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", field("ts"), ty, role, field("agent"), field("family"), field("model"), (ty == "usage" ? "ok" : field("status")), num("duration_s"), num("messages"), num("tokens_in"), num("tokens_cached"), num("tokens_out"), num("cost_usd"), field("cost_source") }'
  exit 0
fi

if (( RAW )); then
  if (( FOLLOW )); then exec tail -n "$N" -f "$FILE"; fi
  events; exit 0
fi

# Décalage horaire local en minutes (le journal est en UTC ; awk de macOS n'a ni mktime ni strftime).
z="$(date +%z)"; sign=1; [[ "${z:0:1}" == "-" ]] && sign=-1
OFFSET=$(( sign * (10#${z:1:2} * 60 + 10#${z:3:2}) ))
PHASEMAP=""; i=0
for p in $LOOMY_PHASES "done"; do i=$(( i + 1 )); PHASEMAP="$PHASEMAP$p=$i:$(loomy_phase_label "$p")|"; done

pretty() {
  awk -v off="$OFFSET" -v pm="$PHASEMAP" -v R="$C_RAIL" -v Z="$C_RESET" -v D="$C_DIM" -v B="$C_BOLD" \
      -v G="$C_GREEN" -v Y="$C_YELLOW" -v E="$C_RED" -v P="$C_BRAND" \
      -v T_START="$(t "démarre")" -v T_IN="$(t "en ")" -v T_FAIL="$(t "échec après ")" -v T_DONE="$(t "Bootstrap terminé")" \
      -v T_PHASE="$(t "Phase")" -v T_REPLIES="$(t "réponse(s)")" -v T_SUB="$(t "sous-agent")" \
      -v T_OPEN="$(t "Session ouverte")" -v T_CLOSED="$(t "Session fermée")" '
    BEGIN { n = split(pm, a, "|"); for (i = 1; i <= n; i++) if (a[i] != "") { split(a[i], kv, "="); split(kv[2], il, ":"); idx[kv[1]] = il[1]; lab[kv[1]] = il[2] } }
    function field(k,   v) { if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/\\"/, "\"", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    function hm(ts,   h, m, t) { h = substr(ts, 12, 2) + 0; m = substr(ts, 15, 2) + 0; t = (h * 60 + m + off + 1440) % 1440; return sprintf("%02d:%02d", int(t / 60), t % 60) }
    function dur(s) { return s < 60 ? s " s" : int(s / 60) " min " sprintf("%02d", s % 60) " s" }
    function cut(s, w) { return length(s) > w ? substr(s, 1, w - 1) "…" : s }
    function tool(t) { return t == "codex" ? "Codex" : "Claude Code" }
    {
      t = D hm(field("ts")) Z; ty = field("type")
      if (ty == "delegation_start") printf "%s  %s◐%s %-10s %s%-16s%s %s%s%s  %s%s%s\n", t, Y, Z, field("role"), D, field("model"), Z, D, T_START, Z, D, cut(field("task"), 48), Z
      else if (ty == "delegation") {
        ok = field("status") == "ok"
        printf "%s  %s %-10s %s%-16s%s %s%s%s  %s$%.4f%s  %s%s%s\n", t, (ok ? G "✓" Z : E "✗" Z), field("role"), D, field("model"), Z, (ok ? "" : E), (ok ? T_IN : T_FAIL) dur(num("duration_s")), Z, D, num("cost_usd"), Z, D, cut(field("task"), 36), Z
      }
      else if (ty == "phase") { ph = field("phase"); if (ph == "done") printf "%s  %s✦ %s%s\n", t, G B, T_DONE, Z; else printf "%s  %s▲ %s %s/10 · %s%s\n", t, P, T_PHASE, idx[ph], lab[ph], Z }
      else if (ty == "usage") {
        if (field("scope") == "lead") printf "%s  %s◆%s %-10s %s%-16s%s %s%d %s%s  %s$%.4f%s\n", t, P, Z, "lead", D, field("model"), Z, D, num("messages"), T_REPLIES, Z, D, num("cost_usd"), Z
        else printf "%s  %s◇%s %-10s %s%-16s%s %s%s%s  %s$%.4f%s\n", t, P, Z, cut(field("agent"), 10), D, field("model"), Z, D, T_SUB, Z, D, num("cost_usd"), Z
      }
      else if (ty == "session") printf "%s  %s %s\n", t, (field("event") == "start" ? G "●" Z " " T_OPEN : D "○ " T_CLOSED Z), D "(" tool(field("tool")) ")" Z
      else printf "%s  %s· %s%s\n", t, D, ty, Z
      fflush()
    }'
}

if (( FOLLOW )); then tail -n "$N" -f "$FILE" | pretty; else events | pretty; fi
