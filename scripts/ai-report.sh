#!/usr/bin/env bash
# Project report: bootstrap, tasks, delegations by role and model, time, tokens and cost. Bash 3.2 compatible.
#   ai-report.sh              this project, in the terminal
#   ai-report.sh --all        every Loomy project on this machine, side by side
#   ai-report.sh --md [dir]   also writes it as Markdown, to keep in the repository (docs/reports/ by default)
# Figures come from the project log (.loomy/logs); costs are estimates at list price, tokens are exact.
# The file holds the project name, task titles and figures: no code, no prompt, no local path.
set -uo pipefail

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

ROOT=""; ALL=0; MD=0; MD_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --all) ALL=1 ;;
    --md) MD=1; if [[ -n "${2:-}" && "${2:-}" != -* ]]; then MD_DIR="$2"; shift; fi ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//; s/ai-report.sh/loomy report/g' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy report --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || ROOT=""
[[ -n "$ROOT" && -f "$ROOT/.loomy/brief.md" ]] && loomy_project_register "$ROOT"
if (( ! ALL )) && [[ -z "$ROOT" || ! -d "$ROOT/.loomy" ]]; then
  t "No Loomy project here: loomy report --all for every project, or loomy init." >&2; echo >&2; exit 1
fi

# metrics <root>: one line of key=value figures read from the project's log and files.
metrics() {
  local r="$1" name phase tasks=0 tdone=0 audits=0 reviews=0 f st
  name="$(_ai_brief_get "$r/.loomy/brief.md" name)"; name="${name:-$(basename "$r")}"
  phase="$(sed -n 's/^phase=//p' "$r/.loomy/state" 2>/dev/null | head -1)"
  for f in "$r"/.loomy/tasks/*.md; do [[ -f "$f" ]] || continue; tasks=$(( tasks + 1 )); st="$(sed -n 's/^status: //p' "$f" | head -1)"; [[ "$st" == "done" ]] && tdone=$(( tdone + 1 )); done
  for f in "$r"/.loomy/audits/*/; do [[ -d "$f" ]] && audits=$(( audits + 1 )); done
  for f in "$r"/.loomy/reviews/*.md; do [[ -f "$f" ]] && reviews=$(( reviews + 1 )); done
  ai_journal_all "$r" | awk -v name="$name" -v phase="${phase:-?}" -v tasks="$tasks" -v tdone="$tdone" -v audits="$audits" -v reviews="$reviews" '
    function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    { ts = field("ts"); if (ts != "") { if (first == "") first = ts; last = ts } }
    index($0, "\"type\":\"phase\"") { if (bs == "") bs = ts; if (index($0, "\"phase\":\"done\"")) be = ts }
    index($0, "\"type\":\"delegation\",") {
      n++; if (field("status") != "ok") err++
      role[field("role")]++; model[field("model")]++; dur += num("duration_s")
      cost += num("cost_usd"); tok += num("tokens_in") + num("tokens_out") }
    index($0, "\"type\":\"usage\"") { cost += num("cost_usd"); tok += num("tokens_in") + num("tokens_out"); model[field("model")] += 0 }
    index($0, "\"type\":\"advisor\"") { cost += num("cost_usd"); tok += num("tokens_in") + num("tokens_out"); adv += num("calls") }
    END {
      roles = ""; for (k in role) if (k != "") roles = roles (roles == "" ? "" : ",") k ":" role[k]
      models = ""; for (k in model) if (k != "" && model[k] > 0) models = models (models == "" ? "" : ",") k ":" model[k]
      printf "name=%s\tphase=%s\tfirst=%s\tlast=%s\tbs=%s\tbe=%s\tn=%d\terr=%d\tdur=%d\tcost=%.2f\ttok=%d\ttasks=%d\ttdone=%d\taudits=%d\treviews=%d\troles=%s\tmodels=%s\tadv=%d\n", \
        name, phase, first, last, bs, be, n, err, dur, cost, tok, tasks, tdone, audits, reviews, roles, models, adv }'
}
kv() { printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | head -1; }
dur_label() { local d="${1:-0}"; if (( d >= 3600 )); then printf '%d h %02d min' $(( d / 3600 )) $(( d % 3600 / 60 )); elif (( d >= 60 )); then printf '%d min' $(( d / 60 )); else printf '%d s' "$d"; fi; }
span() { local a b; a="$(ai_ts_epoch "$1")"; b="$(ai_ts_epoch "$2")"; [[ -n "$a" && -n "$b" ]] && (( b >= a )) && dur_label $(( b - a )); }

# ---------------------------------------------------------------- projects
PROJECTS=()
if (( ALL )); then
  reg="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/projects"
  while IFS= read -r p; do [[ -n "$p" && -f "$p/.loomy/brief.md" ]] && PROJECTS+=("$p"); done < <(sort -u "$reg" 2>/dev/null)
  (( ${#PROJECTS[@]} )) || { t "No project recorded yet: they are recorded when you use loomy in them." >&2; echo >&2; exit 1; }
else
  PROJECTS=("$ROOT")
fi

ui_clear
if (( ALL )); then ui_banner "$(t "Report")" "${C_RESET}${C_TITLE}$(t "%s project(s)" "${#PROJECTS[@]}")${C_RESET}"
else ui_banner "$(t "Report")" "${C_RESET}${C_TITLE}$(kv "$(metrics "$ROOT")" name)${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"; fi

ROWS=()
for p in "${PROJECTS[@]}"; do ROWS+=("$(metrics "$p")"); done

if (( ALL )); then
  ui_section "$(t "PROJECTS")"
  tn=0; tc=0; tt=0
  for m in "${ROWS[@]}"; do
    ph="$(kv "$m" phase)"; [[ "$ph" == "done" ]] && ph="$(t "set up")" || ph="$(loomy_phase_label "$ph")"
    _ui_pad "$(kv "$m" name)" 22
    ui_rail "${C_BOLD}${UI_PADDED}${C_RESET} $ph · $(t "%s task(s)" "$(kv "$m" tasks)") · $(t "%s delegation(s)" "$(kv "$m" n)") · $(ai_tokens_label "$(kv "$m" tok)") $(t "tokens") · \$$(kv "$m" cost) ${C_DIM}· $(t "last activity %s" "$(kv "$m" last | cut -c1-10)")${C_RESET}"
    tn=$(( tn + $(kv "$m" n) )); tt=$(( tt + $(kv "$m" tok) )); tc="$(awk -v a="$tc" -v b="$(kv "$m" cost)" 'BEGIN { printf "%.2f", a + b }')"
  done
  ui_rail ""
  ui_rail "$(t "Total"): $(t "%s delegation(s)" "$tn") · $(ai_tokens_label "$tt") $(t "tokens") · \$$tc ${C_DIM}($(t "list price, estimate"))${C_RESET}"
else
  m="${ROWS[0]}"
  ui_section "$(t "PROJECT")"
  ph="$(kv "$m" phase)"
  if [[ "$ph" == "done" ]]; then ui_kv "Bootstrap" "${C_GREEN}$(t "done")${C_RESET}$(b="$(span "$(kv "$m" bs)" "$(kv "$m" be)")"; [[ -n "$b" ]] && printf ' · %s' "$(t "in %s" "$b")")"
  else ui_kv "Bootstrap" "$(loomy_phase_label "$ph")"; fi
  ui_kv "$(t "Activity")" "$(t "from %s to %s" "$(kv "$m" first | cut -c1-10)" "$(kv "$m" last | cut -c1-10)")"
  ui_kv "$(t "Tasks")" "$(t "%s, %s done" "$(kv "$m" tasks)" "$(kv "$m" tdone)")"
  ui_kv "$(t "Reviews")" "$(kv "$m" reviews) · $(t "Audits"): $(kv "$m" audits)"
  ui_section "$(t "DELEGATIONS")"
  ui_kv "$(t "Total")" "$(kv "$m" n) · $(t "%s failed" "$(kv "$m" err)") · $(t "working time %s" "$(dur_label "$(kv "$m" dur)")")"
  ui_kv "$(t "By role")" "$(kv "$m" roles | tr ',' '\n' | sort -t: -k2 -rn | head -6 | sed 's/:/ /' | paste -sd ',' - | sed 's/,/ · /g')"
  (( $(kv "$m" adv) > 0 )) && ui_kv "$(t "Advisor")" "$(t "%s consultation(s)" "$(kv "$m" adv)")"
  ui_kv "$(t "By model")" "$(kv "$m" models | tr ',' '\n' | sort -t: -k2 -rn | head -6 | sed 's/:/ /' | paste -sd ',' - | sed 's/,/ · /g')"
  ui_section "$(t "USAGE")"
  ui_kv "Tokens" "$(ai_tokens_label "$(kv "$m" tok)")"
  ui_kv "$(t "Cost")" "\$$(kv "$m" cost) ${C_DIM}($(t "list price, estimate; with a subscription, the quota is what counts: loomy stats"))${C_RESET}"
  if ls "$ROOT"/.loomy/tasks/*.md >/dev/null 2>&1; then
    ui_section "$(t "LATEST TASKS")"
    while IFS= read -r f; do
      st="$(sed -n 's/^status: //p' "$f" | head -1)"; mk="${C_DIM}·${C_RESET}"; [[ "$st" == "done" ]] && mk="${C_GREEN}✓${C_RESET}"
      ui_rail "$mk #$(sed -n 's/^id: //p' "$f" | head -1)  $(sed -n 's/^title: //p' "$f" | head -1)  ${C_DIM}$(loomy_phase_label "$st")${C_RESET}"
    done < <(ls -r "$ROOT"/.loomy/tasks/*.md | head -8)
  fi
fi

# ---------------------------------------------------------------- Markdown file
# A Markdown report, to keep in the repository (docs/reports/ by default) or share as is.
if (( MD )); then
  if [[ -n "$MD_DIR" ]]; then out_dir="$MD_DIR"
  elif (( ALL )); then out_dir="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/reports"
  else out_dir="$ROOT/docs/reports"; fi
  [[ "$out_dir" == /* ]] || out_dir="${ROOT:-$PWD}/$out_dir"
  mkdir -p "$out_dir" || { t "Error: cannot create %s" "$out_dir" >&2; echo >&2; exit 1; }
  OUT="$out_dir/report-$(date +%Y-%m-%d)$( (( ALL )) && echo "-all").md"
  md_cell() { printf '%s' "$1" | tr '|\n' '/ '; }
  {
    if (( ALL )); then
      echo "# $(t "Loomy projects")"; echo
      echo "_$(t "Loomy report") · $(date '+%Y-%m-%d %H:%M')_"; echo
      echo "| $(t "Project") | $(t "Phase") | $(t "Tasks") | $(t "Delegations") | Tokens | $(t "Cost (estimate)") | $(t "Last activity") |"
      echo "|---|---|---|---|---|---|---|"
      for m in "${ROWS[@]}"; do
        ph="$(kv "$m" phase)"; [[ "$ph" == "done" ]] && ph="$(t "set up")" || ph="$(loomy_phase_label "$ph")"
        echo "| $(md_cell "$(kv "$m" name)") | $ph | $(kv "$m" tasks) | $(kv "$m" n) | $(ai_tokens_label "$(kv "$m" tok)") | \$$(kv "$m" cost) | $(kv "$m" last | cut -c1-10) |"
      done
    else
      m="${ROWS[0]}"
      echo "# $(md_cell "$(kv "$m" name)") · $(t "Loomy report")"; echo
      echo "_$(date '+%Y-%m-%d %H:%M') · $(t "from %s to %s" "$(kv "$m" first | cut -c1-10)" "$(kv "$m" last | cut -c1-10)")_"; echo
      ph="$(kv "$m" phase)"; b="$(span "$(kv "$m" bs)" "$(kv "$m" be)")"
      echo "| | |"; echo "|---|---|"
      if [[ "$ph" == "done" ]]; then echo "| Bootstrap | $(t "done")${b:+ ($(t "in %s" "$b"))} |"; else echo "| Bootstrap | $(loomy_phase_label "$ph") |"; fi
      echo "| $(t "Tasks") | $(t "%s, %s done" "$(kv "$m" tasks)" "$(kv "$m" tdone)") |"
      echo "| $(t "Delegations") | $(kv "$m" n) ($(t "%s failed" "$(kv "$m" err)")) |"
      echo "| $(t "Working time") | $(dur_label "$(kv "$m" dur)") |"
      echo "| Tokens | $(ai_tokens_label "$(kv "$m" tok)") |"
      echo "| $(t "Cost (estimate)") | \$$(kv "$m" cost) |"
      echo "| $(t "Reviews · audits") | $(kv "$m" reviews) · $(kv "$m" audits) |"
      (( $(kv "$m" adv) > 0 )) && echo "| $(t "Advisor") | $(t "%s consultation(s)" "$(kv "$m" adv)") |"
      echo
      for dim in roles models; do
        [[ -n "$(kv "$m" "$dim")" ]] || continue
        echo "## $( [[ $dim == roles ]] && t "By role" || t "By model")"; echo
        echo "| $( [[ $dim == roles ]] && t "Role" || t "Model") | $(t "Delegations") |"; echo "|---|---|"
        kv "$m" "$dim" | tr ',' '\n' | sort -t: -k2 -rn | while IFS=: read -r k c; do [[ -n "$k" ]] && echo "| $(md_cell "$k") | $c |"; done
        echo
      done
      if ls "$ROOT"/.loomy/tasks/*.md >/dev/null 2>&1; then
        echo "## $(t "Tasks")"; echo
        echo "| # | $(t "Task") | $(t "Phase") |"; echo "|---|---|---|"
        while IFS= read -r f; do
          st="$(sed -n 's/^status: //p' "$f" | head -1)"
          echo "| $(sed -n 's/^id: //p' "$f" | head -1) | $(md_cell "$(sed -n 's/^title: //p' "$f" | head -1)") | $( [[ "$st" == "done" ]] && echo "✓ ")$(loomy_phase_label "$st") |"
        done < <(ls -r "$ROOT"/.loomy/tasks/*.md | head -30)
        echo
      fi
    fi
    echo "---"; echo
    echo "_$(t "Costs are estimates at list price; with a subscription, the quota is what counts. Generated by Loomy.")_"
  } >"$OUT"
  ui_rail ""
  ui_rail "$(t "Markdown report: %s" "${OUT/#$HOME/~}")"
fi
ui_end "$(t "details by day: loomy stats")"
