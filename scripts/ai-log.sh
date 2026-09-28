#!/usr/bin/env bash
# Loomy project log, readable. Bash 3.2 compatible.
#   ai-log.sh [-n N]        the last N events (20 by default), in local time
#   ai-log.sh -f            then follows the log continuously
#   ai-log.sh --raw         raw JSON lines (.loomy/logs/events.jsonl)
#   ai-log.sh --since YYYY-MM-DD   from that date (monthly archives included)
#   ai-log.sh --csv         costs as CSV (delegations and Claude Code work, without the task text)
#   ai-log.sh --root <dir>  works on another project folder
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
# shellcheck source=lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"

ROOT=""; N=20; FOLLOW=0; RAW=0; SINCE=""; CSV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -n) N="${2:-20}"; shift ;;
    -f|--follow) FOLLOW=1 ;;
    --raw) RAW=1 ;;
    --since) SINCE="${2:-}"; shift ;;
    --csv) CSV=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//; s/ai-log.sh/loomy log/' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
[[ "$N" =~ ^[0-9]+$ ]] || { t "-n: a number" >&2; echo >&2; exit 2; }
[[ -z "$SINCE" || "$SINCE" =~ ^[0-9]{4}-[0-9]{2}(-[0-9]{2})?$ ]] || { t "--since: a YYYY-MM-DD date" >&2; echo >&2; exit 2; }
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd)"
FILE="$(ai_journal_file "$ROOT")"
[[ -f "$FILE" ]] || { t "No log in this project (%s)." "${FILE/#$HOME/~}" >&2; echo >&2; exit 1; }

# Selected events: the whole history (archives included) from --since; the last N without --since.
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

# Local UTC offset in minutes (the log is in UTC; macOS awk has neither mktime nor strftime).
z="$(date +%z)"; sign=1; [[ "${z:0:1}" == "-" ]] && sign=-1
OFFSET=$(( sign * (10#${z:1:2} * 60 + 10#${z:3:2}) ))
PHASEMAP=""; i=0
for p in $LOOMY_PHASES "done"; do i=$(( i + 1 )); PHASEMAP="$PHASEMAP$p=$i:$(loomy_phase_label "$p")|"; done

pretty() {
  # Subscription: tokens for each piece of work; API: its cost.
  local pc=0 px=0; loomy_on_plan claude && pc=1; loomy_on_plan codex && px=1
  awk -v pc="$pc" -v px="$px" -v off="$OFFSET" -v pm="$PHASEMAP" -v R="$C_RAIL" -v Z="$C_RESET" -v D="$C_DIM" -v B="$C_BOLD" \
      -v G="$C_GREEN" -v Y="$C_YELLOW" -v E="$C_RED" -v P="$C_BRAND" \
      -v T_START="$(t "starts")" -v T_IN="$(t "in ")" -v T_FAIL="$(t "failed after ")" -v T_DONE="$(t "Bootstrap done")" \
      -v T_PHASE="$(t "Phase")" -v T_REPLIES="$(t "reply(ies)")" -v T_SUB="$(t "sub-agent")" \
      -v T_OPEN="$(t "Session opened")" -v T_CLOSED="$(t "Session closed")" '
    BEGIN { n = split(pm, a, "|"); for (i = 1; i <= n; i++) if (a[i] != "") { split(a[i], kv, "="); split(kv[2], il, ":"); idx[kv[1]] = il[1]; lab[kv[1]] = il[2] } }
    function field(k,   v) { if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/\\"/, "\"", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    function hm(ts,   h, m, t) { h = substr(ts, 12, 2) + 0; m = substr(ts, 15, 2) + 0; t = (h * 60 + m + off + 1440) % 1440; return sprintf("%02d:%02d", int(t / 60), t % 60) }
    function dur(s) { return s < 60 ? s " s" : int(s / 60) " min " sprintf("%02d", s % 60) " s" }
    function cut(s, w) { return length(s) > w ? substr(s, 1, w - 1) "…" : s }
    function tool(t) { return t == "codex" ? "Codex" : "Claude Code" }
    function tk(n) { return n >= 1e6 ? sprintf("%.1fM", n / 1e6) : (n >= 1e3 ? sprintf("%.1fk", n / 1e3) : sprintf("%d", n)) }
    function val() { return ((field("family") == "codex" ? px : pc) + 0) ? sprintf("%7s tk", tk(num("tokens_in") + num("tokens_out"))) : sprintf("%10s", sprintf("$%.4f", num("cost_usd"))) }
    {
      t = D hm(field("ts")) Z; ty = field("type")
      if (ty == "delegation_start") printf "%s  %s◐%s %-10s %s%-16s%s %s%s%s  %s%s%s\n", t, Y, Z, field("role"), D, field("model"), Z, D, T_START, Z, D, cut(field("task"), 48), Z
      else if (ty == "delegation") {
        ok = field("status") == "ok"; oc = field("outcome")
        mk = ok ? G "✓" Z : E "✗" Z; if (ok && oc == "partial") mk = Y "◐" Z; if (ok && oc == "blocked") mk = Y "■" Z
        printf "%s  %s %-10s %s%-16s%s %s%s%s  %s%s%s  %s%s%s\n", t, mk, field("role"), D, field("model"), Z, (ok ? "" : E), (ok ? T_IN : T_FAIL) dur(num("duration_s")), Z, D, val(), Z, D, (field("failover_from") != "" ? "⇄ " : "") cut(field("task"), 36), Z
      }
      else if (ty == "phase") { ph = field("phase"); if (ph == "done") printf "%s  %s✦ %s%s\n", t, G B, T_DONE, Z; else printf "%s  %s▲ %s %s/10 · %s%s\n", t, P, T_PHASE, idx[ph], lab[ph], Z }
      else if (ty == "usage") {
        if (field("scope") == "lead") printf "%s  %s◆%s %-10s %s%-16s%s %s%d %s%s  %s%s%s\n", t, P, Z, "lead", D, field("model"), Z, D, num("messages"), T_REPLIES, Z, D, val(), Z
        else printf "%s  %s◇%s %-10s %s%-16s%s %s%s%s  %s%s%s\n", t, P, Z, cut(field("agent"), 10), D, field("model"), Z, D, T_SUB, Z, D, val(), Z
      }
      else if (ty == "session") printf "%s  %s %s\n", t, (field("event") == "start" ? G "●" Z " " T_OPEN : D "○ " T_CLOSED Z), D "(" tool(field("tool")) ")" Z
      else printf "%s  %s· %s%s\n", t, D, ty, Z
      fflush()
    }'
}

if (( FOLLOW )); then tail -n "$N" -f "$FILE" | pretty; else events | pretty; fi
