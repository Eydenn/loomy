#!/usr/bin/env bash
# Statut du projet et du bootstrap pour Loomy. Compatible bash 3.2.
#   ai-status.sh                 affiche le statut
#   ai-status.sh set <phase>     enregistre la phase en cours du bootstrap (utilisé par les agents)
#   ai-status.sh --watch [N]     rafraîchit l'affichage toutes les N secondes (1 par défaut) ; q c l s (voir le pied d'écran)
#   --compact / --full           vue resserrée (pour un panneau étroit) ou complète ; watch choisit selon la taille du terminal
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
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=lib/privacy.sh
source "$SCRIPT_DIR/lib/privacy.sh"

PHASES="brief discover interview propose approve build verify document commit retire done"

ROOT=""
CMD="show"
PHASE_ARG=""
WATCH=0
INTERVAL=1
COMPACT=""
JOURNAL_VIEW=0
UNTIL=""
IN_PANE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --watch|-w) WATCH=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then INTERVAL="$2"; shift; fi ;;
    --compact) COMPACT=1 ;;
    --journal) JOURNAL_VIEW=1 ;;
    --until-exit) UNTIL="${2:-}"; shift ;;
    --pane) IN_PANE=1 ;;
    --full) COMPACT=0 ;;
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
    ROOT="$(ai_project_root)"
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
  echo "Phase enregistrée : $(loomy_phase_label "$PHASE_ARG") ($PHASE_ARG)"
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
    prototype) echo "Prototype" ;; other) echo "Autre" ;; mvp) echo "MVP" ;; production) echo "Production" ;;
    econome) echo "Économe" ;; equilibre) echo "Équilibré" ;; qualite) echo "Qualité max" ;;
    codex) echo "Codex" ;; claude) echo "Claude Code" ;;
    yes) echo "oui" ;; no) echo "non" ;; "") echo "?" ;; *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- mode surveillance
# Écran plein, redessiné sur place chaque seconde (rien ne s'empile dans l'historique). Entre deux images, le suivi
# repère ce qui change (phase, délégation terminée ou en échec, session fermée) : il le met en évidence quelques
# secondes et prévient par une notification (macOS) et un bip. Touches : q quitter, c vue resserrée/complète,
# l journal, s ouvrir la session.
watch_notify() {
  [[ "$(loomy_config_get notify 2>/dev/null || true)" == "no" ]] && return 0
  printf '\a' >&2
  if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    local t="${1//\"/\'}" m="${2//\"/\'}"
    osascript -e "display notification \"$m\" with title \"Loomy · ${NAME_W//\"/\'}\" subtitle \"$t\"" >/dev/null 2>&1 &
  fi
  return 0
}

if (( WATCH )); then
  ui_screen_begin
  trap 'UI_PAGE_L=(); _ui_restore; exit 0' INT TERM
  printf '\033[?25l' >&2
  stty -echo </dev/tty 2>/dev/null || true
  NAME_W="$(brief_get name 2>/dev/null || basename "$ROOT")"
  J="$(ai_journal_file "$ROOT")"
  tick=0; view="status"; first=1; hl_phase=0; hl_deleg_until=0; hl_deleg_n=0
  p_phase=""; p_done=0; p_err=0; p_sess=""
  while true; do
    now="$(date +%s)"
    # ---- ce qui a changé depuis l'image précédente
    phase="$(sed -n 's/^phase=//p' "$STATE" 2>/dev/null | head -1 || true)"
    n_done=0; n_err=0
    if [[ -s "$J" ]]; then
      read -r n_done n_err <<<"$(awk 'index($0, "\"type\":\"delegation\",") { n++; if (index($0, "\"status\":\"ok\"") == 0) e++ } END { print n + 0, e + 0 }' "$J")"
    fi
    sess="$(ai_session_state "$ROOT" 2>/dev/null || true)"; sess="${sess%%|*}"
    if (( ! first )); then
      if [[ "$phase" != "$p_phase" && -n "$phase" ]]; then
        hl_phase=$(( now + 8 ))
        if [[ "$phase" == "done" ]]; then watch_notify "✦ Projet prêt" "Bootstrap terminé : la suite se passe avec l'orchestrateur (loomy start)."
        else watch_notify "Phase $(loomy_phase_index "$phase")/10 · $(loomy_phase_label "$phase")" "$(loomy_you_now "$phase" "$(ai_session_state "$ROOT" 2>/dev/null || true)")"; fi
      fi
      if (( n_done > p_done )); then hl_deleg_n=$(( n_done - p_done )); hl_deleg_until=$(( now + 8 )); fi
      if (( n_err > p_err )); then watch_notify "Délégation en échec" "Voir le détail dans loomy watch (touche l) ou loomy log."; fi
      if [[ "$p_sess" == "open" && "$sess" == "closed" && "$phase" != "done" ]]; then
        watch_notify "Session de l'orchestrateur fermée" "Bootstrap en cours : loomy start pour la reprendre."
      fi
    fi
    first=0; p_phase="$phase"; p_done=$n_done; p_err=$n_err; p_sess="$sess"
    # ---- image
    _ui_term_size; size="--full"
    if [[ "$COMPACT" == "1" ]] || { [[ -z "$COMPACT" ]] && (( UI_ROWS < 40 || UI_COLS < 90 )); }; then size="--compact"; fi
    keys="q quitter · c $( [[ "$size" == "--compact" ]] && echo "vue complète" || echo "vue resserrée") · l $( [[ "$view" == "journal" ]] && echo "statut" || echo "journal")"
    [[ -z "$UNTIL" ]] && (( ! IN_PANE )) && keys="$keys · s session"
    hl_d=0; (( now < hl_deleg_until )) && hl_d=$hl_deleg_n
    hl_p=0; (( now < hl_phase )) && hl_p=1
    extra=(); [[ "$view" == "journal" ]] && extra=(--journal)
    frame="$(LOOMY_NO_CLEAR=1 LOOMY_FORCE_COLOR=1 LOOMY_TICK=$tick LOOMY_LOGO_BLINK=$( (( tick % 2 )) && echo off || echo on) LOOMY_HL_DELEG=$hl_d LOOMY_HL_PHASE=$hl_p \
      LOOMY_STATUS_FOOTER="en direct · $(date '+%H:%M:%S') · $keys" "$0" --root "$ROOT" "$size" ${extra[@]+"${extra[@]}"} 2>&1)" || true
    # Chaque ligne est coupée à la largeur du terminal (« … »), séquences de couleur comprises : pas de retour à la
    # ligne, même dans un terminal qui ignore la désactivation du retour automatique.
    frame="$(printf '%s\n' "$frame" | perl -CS -Mutf8 -ne '
      chomp; my ($w, $out, $vis) = ('"$(( UI_COLS - 1 ))"', "", 0);
      while (length) {
        if (s/^(\e\[[0-9;?]*[A-Za-z])//) { $out .= $1; next }
        s/^(.)//s; if ($vis >= $w - 1 && length) { $out .= "…"; $vis++; last } $out .= $1; $vis++;
      }
      print $out, "\e[0m\n";' 2>/dev/null || printf '%s' "$frame")"
    UI_PAGE_L=()
    while IFS= read -r line; do UI_PAGE_L[${#UI_PAGE_L[@]}]="$line"; done <<<"$frame"
    if [[ "$UI_SCREEN" == "1" ]]; then
      # La page commence en haut de l'écran ; ce qui dépasse en bas est coupé (le haut, le plus utile, reste visible).
      # Le pied (heure, touches) reste toujours visible, en bas.
      n_l=${#UI_PAGE_L[@]}
      if (( n_l > UI_ROWS - 1 )); then
        foot="${UI_PAGE_L[$(( n_l - 1 ))]}"
        UI_PAGE_L=("${UI_PAGE_L[@]:0:$(( UI_ROWS - 3 ))}" "${C_RAIL}│${C_RESET}  ${C_DIM}… vue complète plus haute que l'écran : c pour la vue resserrée${C_RESET}" "$foot")
      fi
      _ui_page_draw
    else
      printf '%s\n' "$frame" >&2
    fi
    tick=$(( tick + 1 ))
    key=""
    if [[ -t 0 ]]; then read -rsn1 -t "$INTERVAL" key </dev/tty || true; else sleep "$INTERVAL"; fi
    case "$key" in
      q|Q) break ;;
      c|C) if [[ "$size" == "--compact" ]]; then COMPACT=0; else COMPACT=1; fi ;;
      l|L) if [[ "$view" == "journal" ]]; then view="status"; else view="journal"; fi ;;
      s|S) [[ -z "$UNTIL" ]] && (( ! IN_PANE )) && { UI_PAGE_L=(); ui_exec bash "$SCRIPT_DIR/ai-start.sh" --root "$ROOT"; } ;;
    esac
    # Suivi ouvert par loomy start --watch : il se ferme avec la session de l'agent.
    [[ -n "$UNTIL" ]] && ! kill -0 "$UNTIL" 2>/dev/null && break
  done
  UI_PAGE_L=()
  exit 0
fi

# ---------------------------------------------------------------- en-tête
ui_clear
if [[ "$COMPACT" == "1" ]]; then
  # Vue resserrée : le logo aussi (sans lignes vides autour), si le terminal est assez large.
  if ui_logo_ok; then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do ui_print "$l"; done
    ui_print ""
    ui_print "${C_RAIL}┌${C_RESET}  ${C_TITLE}$(brief_get name 2>/dev/null || true)${C_RESET}  ${C_DIM}${ROOT/#$HOME/~}${C_RESET}"
  else
    ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}loomy${C_RESET} ${C_TITLE}$(brief_get name 2>/dev/null || true)${C_RESET}  ${C_DIM}${ROOT/#$HOME/~}${C_RESET}"
  fi
else
  ui_banner "Statut du projet" "${C_RESET}${C_TITLE}$(brief_get name 2>/dev/null || basename "$ROOT")${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
fi
# Version de Loomy copiée dans le projet, comparée à celle installée (sauf si ce script est lui-même la copie du projet).
proj_v="$(cat "$ROOT/.loomy/VERSION" 2>/dev/null || true)"; inst_v="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || true)"
if [[ -n "$proj_v" && -n "$inst_v" && "$proj_v" != "$inst_v" && "$SCRIPT_DIR" != "$ROOT/.loomy/scripts" ]] && ai_version_ge "$inst_v" "$proj_v"; then
  ui_warn "Loomy $proj_v dans ce projet, $inst_v installé" "mets le projet à jour : loomy init --update"
fi

# ---------------------------------------------------------------- vue journal (touche l de loomy watch)
if (( JOURNAL_VIEW )); then
  ui_section "JOURNAL" "derniers événements, heure locale"
  _ui_term_size
  jn=$(( UI_ROWS - 9 )); (( jn < 5 )) && jn=5
  if [[ -s "$(ai_journal_file "$ROOT")" ]]; then
    while IFS= read -r l; do ui_rail "$l"; done < <(bash "$SCRIPT_DIR/ai-log.sh" --root "$ROOT" -n "$jn" 2>/dev/null || true)
  else
    ui_info "journal vide pour l'instant"
  fi
  ui_end "${LOOMY_STATUS_FOOTER:-journal complet : loomy log}"
  exit 0
fi

# ---------------------------------------------------------------- phases du bootstrap
CURRENT=""
[[ -f "$STATE" ]] && CURRENT="$(sed -n 's/^phase=//p' "$STATE" | head -1)"
UPDATED=""
[[ -f "$STATE" ]] && UPDATED="$(sed -n 's/^updated=//p' "$STATE" | head -1)"

if [[ -z "$CURRENT" && -f "$ROOT/.ai/bootstrap/START.completed.md" ]]; then CURRENT="done"; fi
if [[ -z "$CURRENT" && -f "$ROOT/START.md" && -f "$BRIEF" ]]; then CURRENT="brief"; fi
idx="$(loomy_phase_index "$CURRENT")"
note=""
if [[ "$CURRENT" == "done" ]]; then note="bootstrap terminé"
elif (( idx > 0 )); then note="étape $idx sur 10${UPDATED:+ · depuis ${UPDATED##* }}"; fi
ui_section "PHASES" "$note"
if [[ -z "$CURRENT" ]]; then
  if [[ -f "$ROOT/START.md" ]]; then ui_info "START.md présent mais brief vide : lance loomy brief"
  else ui_info "aucun projet Loomy ici : lance loomy init"; fi
else
  # Frise large : une case par phase (█ fait, ▓ en cours, ░ à venir), puis ▲ et le nom sous la case en cours.
  _ui_term_size
  cw=$(( (UI_W - 3 - 9) / 10 )); (( cw > 7 )) && cw=7; (( cw < 2 )) && cw=2
  cell_done=""; cell_cur=""; cell_todo=""; i=0
  while (( i < cw )); do cell_done="${cell_done}█"; cell_cur="${cell_cur}▓"; cell_todo="${cell_todo}░"; i=$(( i + 1 )); done
  bar=""; i=0
  for p in $LOOMY_PHASES; do
    i=$(( i + 1 ))
    (( i > 1 )) && bar="$bar "
    if (( i < idx )); then bar="${bar}${C_GREEN}${cell_done}${C_RESET}"
    elif (( i == idx )); then bar="${bar}${C_BRAND}${cell_cur}${C_RESET}"
    else bar="${bar}${C_DIM}${cell_todo}${C_RESET}"; fi
  done
  ui_rail "$bar"
  label="▲ $(loomy_phase_label "$CURRENT")"; [[ "$CURRENT" == "done" ]] && label="✓ Bootstrap terminé"
  total=$(( cw * 10 + 9 )); _ui_strlen "$label"
  off=$(( (idx > 10 ? 9 : idx - 1) * (cw + 1) )); (( off < 0 )) && off=0
  (( off + UI_LEN > total )) && off=$(( total - UI_LEN ))
  _ui_pad "" "$off"
  hl=""; [[ "${LOOMY_HL_PHASE:-0}" == "1" ]] && hl="  ${C_BOLD}${C_BRAND}✦ nouvelle phase${C_RESET}"
  ui_rail "${UI_PADDED}${C_BRAND}${label}${C_RESET}${hl}"
  ui_print "${C_RAIL}│${C_RESET}"
  # Bootstrap terminé : le bilan (durée, délégations, coût), tiré du journal.
  J_DONE="$(ai_journal_file "$ROOT")"
  if [[ "$CURRENT" == "done" && -s "$J_DONE" ]]; then
    read -r b_start b_end b_n b_cost <<<"$(awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      index($0, "\"type\":\"phase\"") { if (s == "") s = field("ts"); if (index($0, "\"phase\":\"done\"")) e = field("ts") }
      index($0, "\"type\":\"delegation\",") { n++; if (match($0, /"cost_usd":[0-9.]+/)) c += substr($0, RSTART + 11, RLENGTH - 11) }
      END { printf "%s %s %d %.2f\n", (s == "" ? "-" : s), (e == "" ? "-" : e), n, c }' "$J_DONE")"
    s_ep="$(ai_ts_epoch "$b_start")"; e_ep="$(ai_ts_epoch "$b_end")"
    took=""
    if [[ -n "$s_ep" && -n "$e_ep" ]] && (( e_ep >= s_ep )); then
      d=$(( e_ep - s_ep )); if (( d >= 3600 )); then took="$(( d / 3600 )) h $(( d % 3600 / 60 )) min"; else took="$(( d / 60 )) min"; fi
    fi
    ui_rail "${C_GREEN}${C_BOLD}✦ Projet prêt${C_RESET}${took:+ ${C_DIM}·${C_RESET} bootstrap en ${C_BOLD}$took${C_RESET}} ${C_DIM}·${C_RESET} ${b_n} délégation(s) ${C_DIM}·${C_RESET} \$${b_cost}"
  fi
  [[ "$COMPACT" == "1" ]] || ui_rail "${C_DIM}$(loomy_phase_agent "$CURRENT")${C_RESET}"
  # Session de l'orchestrateur : notée par les hooks Claude Code et par loomy start (Codex).
  sess="$(ai_session_state "$ROOT")"; tool_name="Claude Code"; [[ "$sess" == *"|codex" ]] && tool_name="Codex"
  you="$(loomy_you_now "$CURRENT" "$sess")"
  ui_rail "${C_YELLOW}➜${C_RESET} ${C_BOLD}À toi :${C_RESET} $you"
  case "$sess" in
    open*) ui_rail "${C_GREEN}●${C_RESET} Session de l'orchestrateur ouverte depuis $(printf '%s' "$sess" | cut -d'|' -f2) ${C_DIM}($tool_name)${C_RESET}" ;;
    closed*) ui_rail "${C_DIM}○ Session de l'orchestrateur fermée à $(printf '%s' "$sess" | cut -d'|' -f2) ($tool_name) → loomy start pour la reprendre${C_RESET}" ;;
    *) [[ "$CURRENT" != "done" ]] && ui_rail "${C_DIM}○ Aucune session de l'orchestrateur enregistrée → loomy start${C_RESET}" ;;
  esac
  if (( idx >= 1 && idx < 10 )) && [[ "$COMPACT" != "1" ]]; then
    next=""; i=0
    for p in $LOOMY_PHASES; do i=$(( i + 1 )); (( i > idx )) && next="${next:+$next → }$(loomy_phase_label "$p")"; done
    _ui_term_size; _ui_fit "ensuite : $next" $(( UI_W - 3 ))
    ui_rail "${C_DIM}${UI_FIT}${C_RESET}"
  fi
fi

# ---------------------------------------------------------------- brief
if [[ -f "$BRIEF" && "$COMPACT" != "1" ]]; then
  ui_section "BRIEF"
  risk="$(brief_get risk)"
  risk_c="$C_GREEN"; [[ "$risk" == "MEDIUM" ]] && risk_c="$C_YELLOW"; [[ "$risk" == "HIGH" ]] && risk_c="$C_RED"
  ui_kv "Nom" "${C_TITLE}$(brief_get name)${C_RESET} · $(label_of "$(brief_get type)") · $(label_of "$(brief_get stage)")"
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
    /"type":"delegation",/ { finished[field("id")] = 1; k = field("role") "|" field("model"); tot[k] += num("duration_s"); cnt[k]++ }
    END { for (i = (n > 20 ? n - 19 : 1); i <= n; i++) if (!(order[i] in finished)) { split(line[order[i]], f, "|"); k = f[3] "|" f[4]
            print line[order[i]] "|" (cnt[k] ? int(tot[k] / cnt[k]) : "") } }' "$JOURNAL" |
  while IFS='|' read -r pid ts role m task est; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || continue
    since="$(ai_ts_epoch "$ts")"
    # Toupie (une image par rafraîchissement de loomy watch), chrono, et avancement estimé d'après les délégations
    # passées du même rôle sur le même modèle.
    spin="${UI_SPIN[$(( ${LOOMY_TICK:-0} % 4 ))]}"
    el_s=0; [[ -n "$since" ]] && el_s=$(( now_s - since )); (( el_s < 0 )) && el_s=0
    _ui_dur $(( el_s * 1000 )); el="${UI_DUR/,? s/ s}"
    prog=""
    if [[ -n "$est" ]] && (( est > 0 )); then
      fill=$(( el_s * 10 / est )); (( fill > 10 )) && fill=10
      bar=""; for (( k = 0; k < 10; k++ )); do if (( k < fill )); then bar="${bar}▰"; else bar="${bar}▱"; fi; done
      _ui_dur $(( est * 1000 )); est_txt="${UI_DUR/,? s/ s}"
      if (( el_s > est * 3 / 2 )); then prog="${C_YELLOW}${bar}${C_RESET} ${el} ${C_DIM}· plus long que d'habitude (~${est_txt})${C_RESET}"
      else prog="${C_BRAND}${bar}${C_RESET} ${el} ${C_DIM}/ ~${est_txt}${C_RESET}"; fi
    else
      prog="${el} ${C_DIM}· première fois pour ce rôle${C_RESET}"
    fi
    ui_rail "${C_YELLOW}${spin} en cours${C_RESET} ${C_BOLD}$(printf '%-11s' "$role")${C_RESET}${C_DIM}$(printf '%-17s' "$m")${C_RESET} ${prog}"
    ui_rail "           ${C_DIM}${task}${C_RESET}"
  done
  if ! grep -q '"type":"delegation",' "$JOURNAL"; then
    ui_info "aucune délégation terminée pour l'instant"
    ui_rail "${C_DIM}  elles s'affichent ici dès que l'orchestrateur confie une tâche à Claude ou à Codex${C_RESET}"
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
    last_n=5
    if [[ "$COMPACT" == "1" ]]; then last_n=3; else
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
    fi
    n_shown="$(grep -c '"type":"delegation",' "$JOURNAL" || true)"; (( n_shown > last_n )) && n_shown=$last_n
    row=0
    grep '"type":"delegation"' "$JOURNAL" | tail -"$last_n" | awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
      { printf "%s|%s|%s|%s|%s|%s|%s\n", field("ts"), field("status"), field("role"), field("model"), num("duration_s"), num("cost_usd"), substr(field("task"), 1, 40) }' |
    while IFS='|' read -r t st role m d cost task; do
      row=$(( row + 1 ))
      # Journal en UTC, affichage à l'heure locale.
      ep="$(ai_ts_epoch "$t")"
      if [[ -n "$ep" ]]; then t="$(date -r "$ep" +%H:%M 2>/dev/null || date -d "@$ep" +%H:%M)"; else t="${t:11:5}"; fi
      mark="${C_GREEN}✓${C_RESET}"; [[ "$st" != "ok" ]] && mark="${C_RED}✗${C_RESET}"
      # Délégation tout juste terminée (loomy watch) : mise en évidence quelques secondes.
      if (( row > n_shown - ${LOOMY_HL_DELEG:-0} )); then mark="${mark}${C_BRAND}${C_BOLD}✦${C_RESET}"; t="${C_BOLD}${t}"; else mark="${mark} "; fi
      ui_rail "$mark ${C_DIM}${t}${C_RESET} $(printf '%-11s %-17s %4ss  $%.4f' "$role" "$m" "$d" "$cost")  ${C_DIM}${task}${C_RESET}"
    done
  fi
else
  ui_section "ACTIVITÉ"
  ui_info "aucune délégation pour l'instant"
  ui_rail "${C_DIM}  elles s'affichent ici dès que l'orchestrateur confie une tâche à Claude ou à Codex${C_RESET}"
fi

# ---------------------------------------------------------------- fichiers IA
if [[ "$COMPACT" != "1" ]]; then
ui_section "FICHIERS IA" "$(privacy_label "$(privacy_mode "$ROOT")")"
if [[ "$(privacy_mode "$ROOT")" == "private" ]]; then
  if ! privacy_companion_ready "$ROOT"; then ui_warn "dépôt privé absent sur cette machine" "loomy privacy restore <compte/dépôt>"
  elif [[ "$(privacy_pending "$ROOT")" != "0" ]]; then ui_warn "$(privacy_pending "$ROOT") changement(s) non sauvegardé(s) dans le dépôt privé" "loomy privacy sync"; fi
elif [[ "$(privacy_mode "$ROOT")" == "local" ]] && [[ -n "$(privacy_git_root "$ROOT")" ]] && ! privacy_excluded "$ROOT"; then
  ui_warn "fichiers IA pas encore exclus sur cette machine" "loomy privacy local"
fi
check_file() {
  if [[ -e "$ROOT/$1" ]]; then ui_ok "$1" "${2:-}"; else ui_rail "${C_DIM}○ $1${C_RESET}"; fi
}
if [[ ! -e "$ROOT/AGENTS.md" && ! -e "$ROOT/CLAUDE.md" ]]; then
  ui_rail "${C_DIM}créés par l'orchestrateur pendant la Construction : c'est normal qu'ils manquent avant${C_RESET}"
fi
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

fi

# ---------------------------------------------------------------- git
ui_section "GIT"
if [[ "$COMPACT" == "1" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "détachée")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  last="$(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null || true)"
  if [[ "$dirty" == "0" ]]; then ui_ok "$branch propre" "${last:0:48}"; else ui_warn "$branch" "$dirty fichier(s) non commité(s)"; fi
elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
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
ui_end "${LOOMY_STATUS_FOOTER:-démarrer ou reprendre : loomy start · suivi en direct : loomy watch}"
