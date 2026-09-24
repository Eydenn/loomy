#!/usr/bin/env bash
# Statut du projet et du bootstrap pour Loomy. Compatible bash 3.2.
#   ai-status.sh                 affiche le statut
#   ai-status.sh set <phase>     enregistre la phase en cours du bootstrap (utilisé par les agents)
#   ai-status.sh --watch [N]     rafraîchit l'affichage toutes les N secondes (2 par défaut), Ctrl-C pour quitter
#   ai-status.sh --root <dir>    agit sur un autre dossier de projet
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

PHASES="brief discover interview propose approve build verify document commit retire done"
phase_label() {
  case "$1" in
    brief) echo "Brief" ;; discover) echo "Découverte" ;; interview) echo "Entretien" ;;
    propose) echo "Proposition" ;; approve) echo "Validation" ;; build) echo "Construction" ;;
    verify) echo "Vérification" ;; document) echo "Documentation" ;; commit) echo "Commit" ;;
    retire) echo "Clôture" ;; done) echo "Terminé" ;; *) echo "$1" ;;
  esac
}

ROOT=""
CMD="show"
PHASE_ARG=""
WATCH=0
INTERVAL=2
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --watch|-w) WATCH=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then INTERVAL="$2"; shift; fi ;;
    set) CMD="set"; PHASE_ARG="${2:-}"; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argument inconnu : $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -z "$ROOT" ]]; then
  if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then
    ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
  else
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
fi
ROOT="$(cd "$ROOT" && pwd)"
STATE="$ROOT/.loomy/state"
BRIEF="$ROOT/.loomy/brief.md"

if [[ "$CMD" == "set" ]]; then
  case " $PHASES " in
    *" $PHASE_ARG "*) ;;
    *) echo "Phase inconnue : '$PHASE_ARG'. Phases : $PHASES" >&2; exit 2 ;;
  esac
  mkdir -p "$ROOT/.loomy"
  now="$(date '+%Y-%m-%d %H:%M')"
  history=""
  [[ -f "$STATE" ]] && history="$(grep '^log=' "$STATE" || true)"
  {
    echo "phase=$PHASE_ARG"
    echo "updated=$now"
    [[ -n "$history" ]] && echo "$history"
    echo "log=$now $PHASE_ARG"
  } >"$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  ai_journal_write "$ROOT" "\"type\":\"phase\",\"phase\":\"$PHASE_ARG\""
  echo "Phase enregistrée : $(phase_label "$PHASE_ARG") ($PHASE_ARG)"
  exit 0
fi

brief_get() {
  [[ -f "$BRIEF" ]] || return 0
  sed -n '/^---$/,/^---$/p' "$BRIEF" | sed -n "s/^$1:[[:space:]]*//p" | head -1 | sed 's/^"//; s/"$//'
}

label_of() {
  case "$1" in
    web) echo "Application web / SaaS" ;; api) echo "API / backend" ;; mobile) echo "Application mobile" ;;
    desktop) echo "Application desktop" ;; cli) echo "CLI / bibliothèque" ;; ai) echo "Application IA / LLM" ;;
    prototype) echo "Prototype" ;; mvp) echo "MVP" ;; production) echo "Production" ;;
    econome) echo "Économe" ;; equilibre) echo "Équilibré" ;; qualite) echo "Qualité max" ;;
    codex) echo "Codex" ;; claude) echo "Claude Code" ;;
    yes) echo "oui" ;; no) echo "non" ;; "") echo "?" ;; *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- mode surveillance
if (( WATCH )); then
  trap 'printf "\033[?25h\n" >&2; exit 0' INT TERM
  printf '\033[?25l' >&2
  while true; do
    frame="$(LOOMY_FORCE_COLOR=1 LOOMY_STATUS_FOOTER="en direct · mise à jour toutes les ${INTERVAL} s · $(date '+%H:%M:%S') · Ctrl-C pour quitter" "$0" --root "$ROOT" 2>&1)"
    printf '\033[H\033[2J%s\n' "$frame" >&2
    sleep "$INTERVAL"
  done
fi

# ---------------------------------------------------------------- en-tête
ui_banner "Statut du projet" "${ROOT/#$HOME/~}"

# ---------------------------------------------------------------- phases du bootstrap
CURRENT=""
[[ -f "$STATE" ]] && CURRENT="$(sed -n 's/^phase=//p' "$STATE" | head -1)"
UPDATED=""
[[ -f "$STATE" ]] && UPDATED="$(sed -n 's/^updated=//p' "$STATE" | head -1)"

ui_section "PHASES"
if [[ -z "$CURRENT" ]]; then
  if [[ -f "$ROOT/START.md" ]]; then
    CURRENT="brief"
    ui_info "START.md présent, brief non rempli : lancez loomy brief"
  elif [[ -f "$ROOT/.ai/bootstrap/START.completed.md" ]]; then
    CURRENT="done"
  fi
fi

if [[ -n "$CURRENT" ]]; then
  # Barre de progression comme dans le questionnaire, puis les phases suivantes.
  total=0; idx=0; next=""
  for p in $PHASES; do
    [[ "$p" == "done" ]] && continue
    total=$(( total + 1 ))
    [[ "$p" == "$CURRENT" ]] && idx=$total
    if (( idx > 0 && total > idx )); then next="${next:+$next → }$(phase_label "$p")"; fi
  done
  [[ "$CURRENT" == "done" ]] && idx=$total
  bar_on=""; bar_off=""; i=0
  while (( i < 20 )); do if (( i < idx * 20 / total )); then bar_on="${bar_on}━"; else bar_off="${bar_off}╌"; fi; i=$(( i + 1 )); done
  if [[ "$CURRENT" == "done" ]]; then
    ui_rail "${C_GREEN}${bar_on}${C_RESET}  ${C_GREEN}✓${C_RESET} ${C_BOLD}Bootstrap terminé${C_RESET}"
  else
    ui_rail "${C_RAIL}${bar_on}${C_RESET}${C_DIM}${bar_off}${C_RESET}  ${C_DIM}${idx}/${total}${C_RESET}  ${C_BOLD}$(phase_label "$CURRENT")${C_RESET}${UPDATED:+  ${C_DIM}depuis ${UPDATED##* }${C_RESET}}"
    if [[ -n "$next" ]]; then
      _ui_term_size; _ui_wrap "ensuite : $next" $(( UI_W - 3 ))
      for l in "${UI_LINES[@]}"; do ui_rail "${C_DIM}${l}${C_RESET}"; done
    fi
  fi
else
  ui_info "aucun bootstrap suivi dans ce dossier"
fi

# ---------------------------------------------------------------- brief
if [[ -f "$BRIEF" ]]; then
  ui_section "BRIEF"
  risk="$(brief_get risk)"
  risk_c="$C_GREEN"; [[ "$risk" == "MEDIUM" ]] && risk_c="$C_YELLOW"; [[ "$risk" == "HIGH" ]] && risk_c="$C_RED"
  ui_kv "Nom" "${C_BOLD}$(brief_get name)${C_RESET} · $(label_of "$(brief_get type)") · $(label_of "$(brief_get stage)")"
  ui_kv "Risque" "${risk_c}${risk:-?}${C_RESET}"
  ui_kv "Mode IA" "${C_MAGENTA}$(brief_get ai_mode)${C_RESET} · lead $(label_of "$(brief_get ai_lead)")"
  ui_kv "Budget" "$(label_of "$(brief_get budget)")"
  ui_kv "Git" "commit auto : $(label_of "$(brief_get commit_after_setup)") · push auto : $(label_of "$(brief_get push_after_commit)")"
fi

# ---------------------------------------------------------------- activité
JOURNAL="$(ai_journal_file "$ROOT")"
if [[ -s "$JOURNAL" ]]; then
  ui_section "ACTIVITÉ"
  # Délégations en cours : un début sans fin (une seule lecture du journal), dont le processus tourne encore.
  now_s="$(date +%s)"
  awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/\\"/, "\"", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "" }
    /"type":"delegation_start"/ { id = field("id"); order[++n] = id
      line[id] = num("pid") "|" field("ts") "|" field("role") "|" field("model") "|" substr(field("task"), 1, 60); next }
    /"type":"delegation",/ { finished[field("id")] = 1 }
    END { for (i = (n > 20 ? n - 19 : 1); i <= n; i++) if (!(order[i] in finished)) print line[order[i]] }' "$JOURNAL" |
  while IFS='|' read -r pid ts role m task; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || continue
    since="$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || date -u -d "$ts" +%s 2>/dev/null || true)"
    el=""
    if [[ -n "$since" ]]; then
      el=$(( now_s - since ))
      if (( el >= 3600 )); then el="$(( el / 3600 )) h $(( el % 3600 / 60 )) min"; else el="$(( el / 60 )) min $(( el % 60 )) s"; fi
    fi
    ui_rail "${C_YELLOW}◐${C_RESET} ${C_BOLD}en cours${C_RESET}${el:+ ${C_DIM}depuis $el${C_RESET}} $(printf '%-11s %-17s' "$role" "$m")  ${C_DIM}${task}${C_RESET}"
  done
  if ! grep -q '"type":"delegation",' "$JOURNAL"; then
    ui_info "aucune délégation terminée pour l'instant"
  else
    summary="$(grep '"type":"delegation"' "$JOURNAL" | awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
      { m = field("model"); calls[m]++; cost[m] += num("cost_usd"); tok[m] += num("tokens_in") + num("tokens_out")
        n++; total += num("cost_usd"); if (field("status") != "ok") err++ }
      END { printf "TOTAL %d %.4f %d\n", n, total, err
            for (m in calls) printf "MODEL %s %d %.4f %d\n", m, calls[m], cost[m], tok[m] }')"
    read -r _ n_calls total_cost n_err <<<"$(printf '%s\n' "$summary" | grep '^TOTAL')"
    ui_kv "Délégations" "${C_BOLD}${n_calls}${C_RESET} · coût ${C_BOLD}\$${total_cost}${C_RESET}$( [[ "${n_err:-0}" != "0" ]] && printf ' · %s%s en échec%s' "$C_RED" "$n_err" "$C_RESET")"
    printf '%s\n' "$summary" | grep '^MODEL' | sort -k4 -rn | while read -r _ m c cost tok; do
      width=0
      if awk -v t="$total_cost" 'BEGIN{exit !(t>0)}'; then width="$(awk -v c="$cost" -v t="$total_cost" 'BEGIN{printf "%d", (c/t)*24 + 0.5}')"; fi
      bar=""; rest=""; i=0
      while (( i < 24 )); do if (( i < width )); then bar="${bar}█"; else rest="${rest}░"; fi; i=$(( i + 1 )); done
      color="$C_CYAN"; case "$m" in *opus*|*astra*) color="$C_MAGENTA" ;; *luna*|*haiku*) color="$C_GREEN" ;; esac
      line="$(printf '%-17s %3s appel(s)  %9s tokens  $%.4f' "$m" "$c" "$tok" "$cost")"
      ui_rail "${color}${bar}${C_RESET}${C_DIM}${rest}${C_RESET} ${line}"
    done
    # Forfaits : coût réel à l'usage (API) ou valeur API consommée ce mois, rapportée au prix de l'abonnement.
    month="$(date -u +%Y-%m)"
    for fam in claude codex; do
      value="$(awk -v fam="\"family\":\"$fam\"" -v ts="\"ts\":\"$month" '
        index($0, "\"type\":\"delegation\",") && index($0, fam) && index($0, ts) {
          if (match($0, /"cost_usd":[0-9.]+/)) c += substr($0, RSTART+11, RLENGTH-11) }
        END { printf (c >= 1 ? "%.2f" : "%.4f"), c }' "$JOURNAL")"
      plan="$(loomy_plan "$fam")"; monthly="$(loomy_plan_monthly "$fam")"
      name="Claude"; [[ "$fam" == "codex" ]] && name="Codex"
      if [[ "$plan" == "api" ]]; then
        ui_kv "$name" "API · coût ce mois : ${C_BOLD}\$${value}${C_RESET}"
      elif [[ -n "$monthly" ]]; then
        pct="$(awk -v v="$value" -v m="$monthly" 'BEGIN { printf "%d", (m > 0 ? v / m * 100 : 0) }')"
        ui_kv "$name" "$(ai_plan_label "$fam" "$plan") · valeur API ce mois : ${C_BOLD}\$${value}${C_RESET} / \$${monthly} (${pct} %)"
      else
        ui_kv "$name" "$(ai_plan_label "$fam" "$plan") · valeur API ce mois : ${C_BOLD}\$${value}${C_RESET}"
      fi
    done
    ui_info "valeurs issues des délégations journalisées uniquement (le travail direct de l'orchestrateur n'est pas compté)"
    ui_rail ""
    ui_rail "${C_DIM}Dernières délégations${C_RESET}"
    grep '"type":"delegation"' "$JOURNAL" | tail -5 | awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
      { t = substr(field("ts"), 12, 5); printf "%s|%s|%s|%s|%s|%s|%s\n", t, field("status"), field("role"), field("model"), num("duration_s"), num("cost_usd"), substr(field("task"), 1, 40) }' |
    while IFS='|' read -r t st role m d cost task; do
      mark="${C_GREEN}✓${C_RESET}"; [[ "$st" != "ok" ]] && mark="${C_RED}✗${C_RESET}"
      ui_rail "$mark ${C_DIM}${t}${C_RESET} $(printf '%-11s %-17s %4ss  $%.4f' "$role" "$m" "$d" "$cost")  ${C_DIM}${task}${C_RESET}"
    done
  fi
fi

# ---------------------------------------------------------------- fichiers IA
ui_section "FICHIERS IA"
check_file() {
  if [[ -e "$ROOT/$1" ]]; then ui_ok "$1" "${2:-}"; else ui_rail "${C_DIM}○ $1${C_RESET}"; fi
}
check_file AGENTS.md
check_file CLAUDE.md
check_file PROJECT.md
check_file ARCHITECTURE.md
check_file .ai/AI_WORKFLOW.md
check_file .ai/AI_ORCHESTRATION.md
check_file .ai/AI_MODEL_ROUTING.md
if [[ -d "$ROOT/.claude/agents" ]]; then
  agents="$(find "$ROOT/.claude/agents" -maxdepth 1 -name '*.md' -exec basename {} .md \; | sort | paste -sd ',' - | sed 's/,/, /g')"
  ui_ok ".claude/agents/" "${agents:-vide}"
else
  ui_rail "${C_DIM}○ .claude/agents/${C_RESET}"
fi
if [[ -f "$ROOT/.ai/HANDOFF.md" ]]; then
  ui_warn ".ai/HANDOFF.md" "passage de relais actif : $(sed -n 's/^De *: *//p' "$ROOT/.ai/HANDOFF.md" | head -1) → $(sed -n 's/^Vers *: *//p' "$ROOT/.ai/HANDOFF.md" | head -1)"
fi

# ---------------------------------------------------------------- git
ui_section "GIT"
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "détachée")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  last="$(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null || true)"
  if [[ "$dirty" == "0" ]]; then ui_ok "branche $branch" "propre"
  else ui_warn "branche $branch" "$dirty fichier(s) modifié(s) non commité(s)"; fi
  if [[ -n "$last" ]]; then ui_info "dernier commit : $last"; else ui_info "aucun commit"; fi
  upstream="$(git -C "$ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    counts="$(git -C "$ROOT" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null || echo "0 0")"
    ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
    if [[ "$ahead" == "0" && "$behind" == "0" ]]; then ui_ok "synchronisé avec $upstream"
    else ui_warn "$upstream" "$ahead en avance · $behind en retard"; fi
  else
    remote="$(git -C "$ROOT" remote 2>/dev/null | head -1)"
    if [[ -n "$remote" ]]; then ui_info "remote $remote configuré, pas de branche suivie"
    else ui_info "aucun remote configuré"; fi
  fi
  wt="$(git -C "$ROOT" worktree list 2>/dev/null | wc -l | tr -d ' ')"
  if (( wt > 1 )); then ui_warn "$(( wt - 1 )) worktree(s) parallèle(s)" "git worktree list"; fi
else
  ui_info "pas de dépôt Git"
fi
ui_end "${LOOMY_STATUS_FOOTER:-suivi en direct : loomy watch · journal : loomy log}"
