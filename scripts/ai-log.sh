#!/usr/bin/env bash
# Journal du projet Loomy, lisible. Compatible bash 3.2.
#   ai-log.sh [-n N]        les N derniers événements (20 par défaut), à l'heure locale
#   ai-log.sh -f            puis suit le journal en continu
#   ai-log.sh --raw         lignes JSON brutes (.loomy/logs/events.jsonl)
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

ROOT=""; N=20; FOLLOW=0; RAW=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -n) N="${2:-20}"; shift ;;
    -f|--follow) FOLLOW=1 ;;
    --raw) RAW=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//; s/ai-log.sh/loomy log/'; exit 0 ;;
    *) echo "Argument inconnu : $1" >&2; exit 2 ;;
  esac
  shift
done
[[ "$N" =~ ^[0-9]+$ ]] || { echo "-n : un nombre" >&2; exit 2; }
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd)"
FILE="$(ai_journal_file "$ROOT")"
[[ -f "$FILE" ]] || { echo "Aucun journal dans ce projet (${FILE/#$HOME/~})." >&2; exit 1; }

if (( RAW )); then
  if (( FOLLOW )); then exec tail -n "$N" -f "$FILE"; else exec tail -n "$N" "$FILE"; fi
fi

# Décalage horaire local en minutes (le journal est en UTC ; awk de macOS n'a ni mktime ni strftime).
z="$(date +%z)"; sign=1; [[ "${z:0:1}" == "-" ]] && sign=-1
OFFSET=$(( sign * (10#${z:1:2} * 60 + 10#${z:3:2}) ))
PHASEMAP=""; i=0
for p in $LOOMY_PHASES "done"; do i=$(( i + 1 )); PHASEMAP="$PHASEMAP$p=$i:$(loomy_phase_label "$p")|"; done

pretty() {
  awk -v off="$OFFSET" -v pm="$PHASEMAP" -v R="$C_RAIL" -v Z="$C_RESET" -v D="$C_DIM" -v B="$C_BOLD" \
      -v G="$C_GREEN" -v Y="$C_YELLOW" -v E="$C_RED" -v P="$C_BRAND" '
    BEGIN { n = split(pm, a, "|"); for (i = 1; i <= n; i++) if (a[i] != "") { split(a[i], kv, "="); split(kv[2], il, ":"); idx[kv[1]] = il[1]; lab[kv[1]] = il[2] } }
    function field(k,   v) { if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/\\"/, "\"", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    function hm(ts,   h, m, t) { h = substr(ts, 12, 2) + 0; m = substr(ts, 15, 2) + 0; t = (h * 60 + m + off + 1440) % 1440; return sprintf("%02d:%02d", int(t / 60), t % 60) }
    function dur(s) { return s < 60 ? s " s" : int(s / 60) " min " sprintf("%02d", s % 60) " s" }
    function cut(s, w) { return length(s) > w ? substr(s, 1, w - 1) "…" : s }
    function tool(t) { return t == "codex" ? "Codex" : "Claude Code" }
    {
      t = D hm(field("ts")) Z; ty = field("type")
      if (ty == "delegation_start") printf "%s  %s◐%s %-10s %s%-16s%s %sdémarre%s  %s%s%s\n", t, Y, Z, field("role"), D, field("model"), Z, D, Z, D, cut(field("task"), 48), Z
      else if (ty == "delegation") {
        ok = field("status") == "ok"
        printf "%s  %s %-10s %s%-16s%s %s%s%s  %s$%.4f%s  %s%s%s\n", t, (ok ? G "✓" Z : E "✗" Z), field("role"), D, field("model"), Z, (ok ? "" : E), (ok ? "en " : "échec après ") dur(num("duration_s")), Z, D, num("cost_usd"), Z, D, cut(field("task"), 36), Z
      }
      else if (ty == "phase") { ph = field("phase"); if (ph == "done") printf "%s  %s✦ Bootstrap terminé%s\n", t, G B, Z; else printf "%s  %s▲ Phase %s/10 · %s%s\n", t, P, idx[ph], lab[ph], Z }
      else if (ty == "session") printf "%s  %s %s\n", t, (field("event") == "start" ? G "●" Z " Session ouverte" : D "○ Session fermée" Z), D "(" tool(field("tool")) ")" Z
      else printf "%s  %s· %s%s\n", t, D, ty, Z
      fflush()
    }'
}

if (( FOLLOW )); then tail -n "$N" -f "$FILE" | pretty; else tail -n "$N" "$FILE" | pretty; fi
