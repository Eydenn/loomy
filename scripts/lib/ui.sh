#!/usr/bin/env bash
# shellcheck disable=SC2034  # bibliothèque : couleurs et UI_* sont lus par les scripts qui la chargent
# Outils d'interface terminal pour les scripts de Loomy.
# À charger (source), pas à exécuter. Compatible bash 3.2 (celui de macOS), sans dépendance.
# Les réponses sont renvoyées dans la variable globale UI_VALUE.
#
# Questions : ui_input (texte), ui_choose (un choix), ui_multi (plusieurs choix).
# Chaque question s'affiche en carte : la question, pourquoi elle compte, les options, et dans un encadré
# la conséquence de l'option survolée. Contexte facultatif, réinitialisé après chaque question :
#   UI_HINT   pourquoi la question compte
#   UI_DESCS  conséquence de chaque option, dans l'ordre des options
#   UI_LABEL  libellé court de la réponse dans le récapitulatif (défaut : la question)
#
# Formulaire : ui_form_begin / ui_form_pass / ui_form_end encadrent une suite de questions groupées par
# ui_group. L'écran est redessiné à chaque question : groupes terminés repliés sur une ligne, réponses du
# groupe courant alignées, question courante en carte. La touche ← revient à la question précédente :
# la passe en cours se termine sans rien demander, puis ui_form_again la fait rejouer jusqu'à cette question.
#
#   ui_form_begin "brief de démarrage · projet" "PROJET|EXIGENCES|ÉQUIPE IA"
#   while :; do ui_form_pass; poser_les_questions; ui_form_again || break; done
#   ui_form_end

UI_VALUE=""
UI_ASSUME_DEFAULTS="${UI_ASSUME_DEFAULTS:-0}"
UI_HINT=""; UI_DESCS=(); UI_LABEL=""
UI_KEY=""; UI_CH=""; UI_LEN=0; UI_LINES=()

if [[ -z "${NO_COLOR:-}" ]] && { [[ -n "${LOOMY_FORCE_COLOR:-}" ]] || [[ -t 2 && "${TERM:-dumb}" != "dumb" ]]; }; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_TITLE=$'\033[1;97m'   # titres et nom du projet : gras (couleur de la charte ci-dessous, visible même sans gras, dans tmux par exemple)
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  if [[ "${TERM:-}" == *256color* || "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit ]]; then
    C_BRAND=$'\033[1;38;5;141m'   # « Loomy » : violet clair
    C_RAIL=$'\033[38;5;98m'       # fil conducteur et repères
    C_BOX=$'\033[38;5;74m'        # encadré des conséquences
    C_TITLE=$'\033[1;38;5;141m'  # titres et nom du projet : violet clair en gras
  else
    C_BRAND=$'\033[1;35m'; C_RAIL=$'\033[35m'; C_BOX=$'\033[36m'; C_TITLE=$'\033[1;35m'
  fi
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_TITLE=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_BRAND=""; C_RAIL=""; C_BOX=""
fi

ui_is_interactive() { [[ "$UI_ASSUME_DEFAULTS" != "1" && -t 0 && -t 2 ]]; }

ui_print() {
  if [[ "$UI_SCREEN" == "1" ]]; then UI_PAGE_L[${#UI_PAGE_L[@]}]="$*"; _ui_page_draw; return 0; fi
  printf '%s\n' "$*" >&2
}

# ---------------------------------------------------------------- écran
# Dans un terminal interactif, Loomy s'affiche dans l'écran alternatif, comme une application plein écran : chaque mise
# à jour redessine le même écran depuis le haut, rien ne s'empile dans l'historique, et les lignes trop longues sont
# coupées au lieu de passer à la ligne. La « page » (UI_PAGE_L) est ce que le script a affiché ; seule sa fin visible
# est dessinée. En sortant, l'écran normal revient et la dernière page y est recopiée, une seule fois.
# Le processus qui ouvre l'écran le possède (LOOMY_SCREEN_OWNER = son PID). Un sous-processus Loomy lancé pendant ce
# temps dessine sur le même écran ; sa page est rendue au parent par le fichier LOOMY_PAGE_OUT (voir ui_run).
# LOOMY_NO_CLEAR=1 : pas d'écran alternatif, sortie ligne à ligne.
UI_SCREEN=0; UI_PAGE_L=(); UI_PAGE_BODY=0

ui_screen_begin() {
  UI_PAGE_BODY=0
  if [[ "$UI_SCREEN" == "1" ]]; then UI_PAGE_L=(); printf '\033[H\033[2J' >&2; return 0; fi
  [[ -z "${LOOMY_NO_CLEAR:-}" ]] && ui_is_interactive || return 0
  UI_SCREEN=1; UI_PAGE_L=()
  if [[ -z "${LOOMY_SCREEN_OWNER:-}" ]]; then export LOOMY_SCREEN_OWNER=$$; printf '\033[?1049h' >&2; fi
  printf '\033[?7l\033[H\033[2J' >&2
  trap '_ui_restore' EXIT
  trap '_ui_restore; exit 130' INT TERM
  return 0
}

# ui_clear : ouvre l'écran de Loomy, ou le vide s'il est déjà ouvert.
ui_clear() { ui_screen_begin; }

# ui_screen_end : referme l'écran (propriétaire) et recopie la page dans l'écran normal ; sous-processus : rend la page au parent.
ui_screen_end() {
  [[ "$UI_SCREEN" == "1" ]] || return 0
  UI_SCREEN=0
  local l
  if [[ "${LOOMY_SCREEN_OWNER:-}" == "$$" ]]; then
    printf '\033[?7h\033[?25h\033[?1049l' >&2; unset LOOMY_SCREEN_OWNER
    # Ce qui reste dans l'historique : le contenu de la dernière page, sans le logo ; rien quand on passe à un autre
    # écran (ui_exec), pour que les écrans ne s'empilent pas.
    if [[ -z "${UI_NO_DUMP:-}" ]] && (( ${#UI_PAGE_L[@]} > 0 )); then
      local i n=${#UI_PAGE_L[@]}
      [[ -n "$UI_HDR_TITLE" ]] && printf '%s\n%s\n' "${C_RAIL}┌${C_RESET}  ${C_TITLE}${UI_HDR_TITLE}${C_RESET}${UI_HDR_SUB:+  ${C_DIM}${UI_HDR_SUB}${C_RESET}}" "${C_RAIL}│${C_RESET}" >&2
      for (( i = 0; i < n; i++ )); do printf '%s\n' "${UI_PAGE_L[$i]:-}" >&2; done
    fi
  elif [[ -n "${LOOMY_PAGE_OUT:-}" ]]; then
    for l in ${UI_PAGE_L[@]+"${UI_PAGE_L[@]}"}; do printf '%s\n' "$l"; done >>"$LOOMY_PAGE_OUT"
  fi
  UI_PAGE_L=()
  return 0
}

_ui_restore() {
  _ui_tick_stop
  ui_form_end
  ui_screen_end
  printf '\033[?25h' >&2
  stty echo </dev/tty 2>/dev/null || true
}

# ui_external <commande>... : lance une commande interactive (gh auth login…) hors de l'écran de Loomy, puis y revient.
ui_external() {
  local rc=0
  if [[ "$UI_SCREEN" == "1" ]]; then printf '\033[?7h\033[?25h\033[?1049l' >&2; stty echo </dev/tty 2>/dev/null || true; fi
  "$@" || rc=$?
  if [[ "$UI_SCREEN" == "1" ]]; then printf '\033[?1049h\033[?7l' >&2; _ui_page_draw; fi
  return $rc
}

# ui_pager <titre> <fichier> : affiche un texte (sortie d'une commande Loomy) dans l'écran de l'application, avec
# défilement ; ↑↓ ligne, espace / b page, ⏎ ou ← retour, q quitter. UI_KEY vaut « back » ou « quit » en sortie.
# Hors écran plein (LOOMY_NO_CLEAR, sortie non interactive) : le texte est simplement affiché.
# ui_clip <largeur> : coupe chaque ligne de l'entrée à <largeur> colonnes visibles (« … »), séquences de couleur
# comprises ; rien ne passe à la ligne, même dans un terminal qui ignore la désactivation du retour automatique.
ui_clip() {
  perl -CS -Mutf8 -ne '
    chomp; my ($w, $out, $vis) = ('"$1"', "", 0);
    while (length) {
      if (s/^(\e\[[0-9;?]*[A-Za-z])//) { $out .= $1; next }
      s/^(.)//s; if ($vis >= $w - 1 && length) { $out .= "…"; $vis++; last } $out .= $1; $vis++;
    }
    print $out, "\e[0m\n";' 2>/dev/null || cat
}

ui_pager() {
  local title="$1" file="$2" lines=() l top=0 n avail saved_page=() saved_title saved_sub
  if [[ "$UI_SCREEN" != "1" ]]; then cat "$file" >&2; UI_KEY="back"; return 0; fi
  _ui_term_size
  while IFS= read -r l || [[ -n "$l" ]]; do lines[${#lines[@]}]="$l"; done < <(ui_clip "$(( UI_COLS - 1 ))" <"$file")
  n=${#lines[@]}
  saved_page=(${UI_PAGE_L[@]+"${UI_PAGE_L[@]}"}); saved_title="$UI_HDR_TITLE"; saved_sub="$UI_HDR_SUB"
  ui_header "$title" "$saved_title${saved_sub:+ · $saved_sub}"
  UI_PAGE_L=(${lines[@]+"${lines[@]}"})
  _ui_hide_cursor
  while :; do
    _ui_term_size; _ui_chrome
    avail=$(( UI_ROWS - UI_CHROME_H )); (( avail < 3 )) && avail=3
    (( top > n - avail )) && top=$(( n - avail )); (( top < 0 )) && top=0
    UI_FTR_KEYS="⏎ ← retour · q quitter"
    (( n > avail )) && UI_FTR_KEYS="↑↓ espace b défiler ($(( top + 1 ))–$(( top + avail < n ? top + avail : n ))/$n) · $UI_FTR_KEYS"
    UI_BODY_TOP=$top; _ui_page_draw
    _ui_read_key
    case "$UI_KEY" in
      up) top=$(( top - 1 )) ;;
      down) top=$(( top + 1 )) ;;
      space) top=$(( top + avail )) ;;
      enter|left) UI_KEY="back"; break ;;
      char) case "$UI_CH" in q|Q) UI_KEY="quit"; break ;; b|B) top=$(( top - avail )) ;; j) top=$(( top + 1 )) ;; k) top=$(( top - 1 )) ;; esac ;;
    esac
  done
  UI_BODY_TOP=""; UI_FTR_KEYS=""
  UI_PAGE_L=(${saved_page[@]+"${saved_page[@]}"}); ui_header "$saved_title" "$saved_sub"
  _ui_show_cursor
  return 0
}

# ui_exec <commande>... : quitte l'écran de Loomy (la page reste dans l'historique), puis lance la commande à sa place.
ui_exec() { UI_NO_DUMP=1; _ui_restore; trap - EXIT INT TERM; exec "$@"; }

# ui_run <commande>... : lance un sous-processus Loomy qui dessine sur le même écran, puis ajoute sa page à la page courante.
ui_run() {
  local out rc=0 l
  if [[ "$UI_SCREEN" != "1" ]]; then "$@"; return $?; fi
  out="$(mktemp "${TMPDIR:-/tmp}/loomy-page.XXXXXX")"
  LOOMY_PAGE_OUT="$out" "$@" || rc=$?
  while IFS= read -r l || [[ -n "$l" ]]; do UI_PAGE_L[${#UI_PAGE_L[@]}]="$l"; done <"$out"
  rm -f "$out"
  _ui_page_draw
  return $rc
}

# _ui_page_draw [lignes-réservées] [suite] : dessine la fin de la page qui tient à l'écran, puis <suite> (question en cours).
# ---------------------------------------------------------------- cadre de l'application
# Dans l'écran de Loomy, tout s'affiche dans un cadre fixe :
#   en-tête : logo, puis « ┌ titre  contexte » (ui_banner le règle : projet, écran en cours, état)
#   corps   : la page (UI_PAGE_L) et, en bas, la question en cours ; seule zone qui change
#   pied    : les touches utiles (ui_choose, ui_input, visionneuse, suivi) et la version de Loomy
# Les sous-processus Loomy reprennent le même en-tête (LOOMY_HDR_TITLE / LOOMY_HDR_SUB).
UI_HDR_TITLE="${LOOMY_HDR_TITLE:-}"; UI_HDR_SUB="${LOOMY_HDR_SUB:-}"; UI_FTR_KEYS=""; UI_BODY_TOP=""; UI_CHROME_H=0
UI_LOOMY_V="$(cat "$(dirname "${BASH_SOURCE[0]}")/../../VERSION" 2>/dev/null || true)"

# ui_header <titre> <contexte> : en-tête du cadre (et des sous-processus).
ui_header() {
  UI_HDR_TITLE="$1"; UI_HDR_SUB="${2:-}"
  export LOOMY_HDR_TITLE="$UI_HDR_TITLE" LOOMY_HDR_SUB="$UI_HDR_SUB"
}

# _ui_chrome : lignes d'en-tête (UI_HDR_LINES, UI_CHROME_H) et pied (UI_FOOTER) pour la taille du terminal.
_ui_chrome() {
  local l left right pad
  UI_HDR_LINES=()
  local head="${C_RAIL}┌${C_RESET}  ${C_TITLE}${UI_HDR_TITLE:-loomy}${C_RESET}${UI_HDR_SUB:+  ${C_DIM}${UI_HDR_SUB}${C_RESET}}"
  if (( UI_ROWS >= 20 && UI_COLS >= 40 )); then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do UI_HDR_LINES[${#UI_HDR_LINES[@]}]="$l"; done
    UI_HDR_LINES[${#UI_HDR_LINES[@]}]=""
  fi
  UI_HDR_LINES[${#UI_HDR_LINES[@]}]="$head"
  UI_CHROME_H=$(( ${#UI_HDR_LINES[@]} + 1 ))
  left="${UI_FTR_KEYS:-Ctrl-C pour interrompre}"; right="loomy${UI_LOOMY_V:+ $UI_LOOMY_V}"
  _ui_strlen "$left$right"; pad=$(( UI_COLS - 6 - UI_LEN )); (( pad < 2 )) && pad=2
  UI_FOOTER="${C_RAIL}└${C_RESET}  ${C_DIM}${left}$(printf '%*s' "$pad" '')${right}${C_RESET}"
}

# _ui_page_draw [lignes-réservées] [suite] : dessine le cadre, puis dans le corps la page et <suite> (question en cours).
# Le corps montre la fin de la page (ce qui vient d'arriver), ou à partir de la ligne UI_BODY_TOP (suivi, visionneuse).
_ui_page_draw() {
  local reserved="${1:-0}" tail="${2:-}" n=${#UI_PAGE_L[@]} avail start end i l out=$'\033[H'
  _ui_term_size; _ui_chrome
  for l in "${UI_HDR_LINES[@]}"; do out="${out}${l}"$'\033[K\n'; done
  avail=$(( UI_ROWS - UI_CHROME_H - reserved )); (( avail < 0 )) && avail=0
  if [[ -n "$UI_BODY_TOP" ]]; then start=$UI_BODY_TOP; else start=$(( n - avail )); fi
  (( start > n - avail )) && start=$(( n - avail )); (( start < 0 )) && start=0
  UI_BODY_START=$start; end=$(( start + avail )); (( end > n )) && end=$n
  for (( i = start; i < end; i++ )); do out="${out}${UI_PAGE_L[$i]:-}"$'\033[K\n'; done
  printf '%s%s\033[J\033[%d;1H%s\033[K' "$out" "$tail" "$UI_ROWS" "$UI_FOOTER" >&2
}

# ---------------------------------------------------------------- activité en direct
# Deux composants, animés seulement dans l'écran de Loomy (ailleurs, seules les lignes finales s'affichent) :
#   ui_wait <libellé> … ui_wait_end        une ligne « ◐ libellé…  1,2 s » le temps d'une vérification, puis effacée
#   ui_steps_begin <titre> <étape>…        une liste d'étapes annoncées d'avance, avec barre de progression :
#     ui_step_run <n>                      étape n (à partir de 0) en cours : toupie et chrono
#     ui_step_done <n> <ok|warn|fail|skip> <libellé final> [détail]
#     ui_steps_end                         barre finale et durée totale
# L'animation tourne dans un processus à part, qui ne redessine que sa ligne (et la barre) : le travail reste au premier plan.
UI_SPIN=("◐" "◓" "◑" "◒"); UI_TICK_PID=""; UI_WAIT_IDX=""
UI_ST_L=(); UI_ST_S=(); UI_ST_D=(); UI_ST_T=(); UI_ST_BASE=-1; UI_ST_T0=0; UI_ST_CUR_T0=0

# _ui_now_ms : horodatage en millisecondes dans UI_NOW.
_ui_now_ms() {
  UI_NOW="$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null)" || UI_NOW=""
  [[ -n "$UI_NOW" ]] || UI_NOW=$(( $(date +%s) * 1000 ))
}

# _ui_dur <ms> : durée lisible dans UI_DUR (« 0,4 s », « 12 s », « 1 min 05 s »).
_ui_dur() {
  local ms=$1 s
  if (( ms < 10000 )); then UI_DUR="$(( ms / 1000 )),$(( ms % 1000 / 100 )) s"
  elif (( ms < 60000 )); then UI_DUR="$(( ms / 1000 )) s"
  else s=$(( ms / 1000 )); UI_DUR="$(( s / 60 )) min $(printf '%02d' $(( s % 60 ))) s"; fi
}

# _ui_row <icône> <libellé> <détail> <durée> : ligne d'étape alignée (libellé, détail estompé, durée à droite) dans UI_LINE.
_ui_row() {
  local icon="$1" label="$2" detail="$3" dur="$4" lw="${UI_ROW_LW:-30}" dw
  _ui_term_size
  dw=$(( UI_W - 3 - 2 - lw - 9 )); (( dw < 8 )) && dw=8
  _ui_fit "$label" "$lw"; _ui_pad "$UI_FIT" "$lw"; label="$UI_PADDED"
  [[ "${UI_ROW_DIM:-}" == "1" ]] && label="${C_DIM}${label}${C_RESET}"
  _ui_fit "$detail" "$dw"; _ui_pad "$UI_FIT" "$dw"; detail="$UI_PADDED"
  _ui_strlen "$dur"; while (( UI_LEN < 8 )); do dur=" $dur"; UI_LEN=$(( UI_LEN + 1 )); done
  UI_LINE="${C_RAIL}│${C_RESET}  ${icon} ${label}${C_DIM}${detail} ${dur}${C_RESET}"
}

# _ui_bar <fait> <total> [fini] : barre de progression dans UI_LINE.
_ui_bar() {
  local done_n=$1 total=$2 fin="${3:-}" bw fill i on="" off="" pct tail
  _ui_term_size
  bw=$(( UI_W - 3 - 22 )); (( bw < 10 )) && bw=10
  (( total < 1 )) && total=1
  fill=$(( done_n * bw / total )); pct=$(( done_n * 100 / total ))
  for (( i = 0; i < bw; i++ )); do if (( i < fill )); then on="${on}━"; else off="${off}╌"; fi; done
  if [[ -n "$fin" ]]; then tail="${C_GREEN}✓${C_RESET} ${C_DIM}${fin}${C_RESET}"; on="${C_GREEN}${on}${C_RESET}"
  else tail="${C_DIM}${done_n}/${total} · ${pct} %${C_RESET}"; on="${C_BRAND}${on}${C_RESET}"; fi
  UI_LINE="${C_RAIL}│${C_RESET}  ${on}${C_DIM}${off}${C_RESET}  ${tail}"
}

# _ui_screen_row <index> : ligne d'écran (à partir de 1) où s'affiche UI_PAGE_L[index], ou 0 si elle est hors de l'écran.
_ui_screen_row() {
  local n=${#UI_PAGE_L[@]} start
  _ui_term_size; _ui_chrome
  start=$(( n - (UI_ROWS - UI_CHROME_H) )); (( start < 0 )) && start=0
  UI_ROW=$(( $1 - start + 1 )); (( UI_ROW < 1 )) && UI_ROW=0
  (( UI_ROW > 0 )) && UI_ROW=$(( UI_ROW + ${#UI_HDR_LINES[@]} ))
  return 0
}

# _ui_tick_start <wait|step> : anime la ligne en cours (toupie et chrono) jusqu'à _ui_tick_stop.
_ui_tick_start() {
  [[ "$UI_SCREEN" == "1" ]] || return 0
  local kind="$1"
  (
    trap - EXIT INT TERM
    f=0
    while :; do
      _ui_now_ms
      if [[ "$kind" == "wait" ]]; then
        _ui_dur $(( UI_NOW - UI_WAIT_T0 ))
        _ui_row "${C_BRAND}${UI_SPIN[$f]}${C_RESET}" "${UI_WAIT_LABEL}…" "" "$UI_DUR"; idx=$UI_WAIT_IDX
      else
        _ui_dur $(( UI_NOW - UI_ST_CUR_T0 ))
        _ui_row "${C_BRAND}${UI_SPIN[$f]}${C_RESET}" "${UI_ST_L[$UI_ST_CUR]}…" "" "$UI_DUR"; idx=$(( UI_ST_BASE + 1 + UI_ST_CUR ))
      fi
      _ui_screen_row "$idx"
      (( UI_ROW > 0 )) && printf '\033[%d;1H%s\033[K' "$UI_ROW" "$UI_LINE" >&2
      f=$(( (f + 1) % 4 ))
      sleep 0.12
    done
  ) &
  UI_TICK_PID=$!
  return 0
}

_ui_tick_stop() {
  if [[ -n "$UI_TICK_PID" ]]; then kill "$UI_TICK_PID" 2>/dev/null || true; wait "$UI_TICK_PID" 2>/dev/null || true; UI_TICK_PID=""; fi
  return 0
}

ui_wait() {
  [[ "$UI_SCREEN" == "1" ]] || return 0
  _ui_now_ms; UI_WAIT_T0=$UI_NOW; UI_WAIT_LABEL="$1"
  _ui_row "${C_BRAND}${UI_SPIN[0]}${C_RESET}" "$1…" "" ""
  UI_WAIT_IDX=${#UI_PAGE_L[@]}; UI_PAGE_L[$UI_WAIT_IDX]="$UI_LINE"
  _ui_page_draw
  _ui_tick_start wait
}

ui_wait_end() {
  _ui_tick_stop
  [[ -n "$UI_WAIT_IDX" ]] || return 0
  unset "UI_PAGE_L[$UI_WAIT_IDX]"; UI_WAIT_IDX=""
  return 0
}

# _ui_steps_line <n> : redessine la ligne de l'étape n et la barre dans la page.
_ui_steps_paint() {
  local i n=${#UI_ST_L[@]} icon done_n=0 label
  for (( i = 0; i < n; i++ )); do
    label="${UI_ST_L[$i]}"
    case "${UI_ST_S[$i]}" in
      ok) icon="${C_GREEN}✓${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      warn) icon="${C_YELLOW}!${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      fail) icon="${C_RED}✗${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      skip) icon="${C_DIM}–${C_RESET}"; done_n=$(( done_n + 1 )) ;;
      run) icon="${C_BRAND}${UI_SPIN[0]}${C_RESET}"; label="${label}…" ;;
      *) icon="${C_DIM}○${C_RESET}"; UI_ROW_DIM=1 ;;
    esac
    _ui_row "$icon" "$label" "${UI_ST_D[$i]}" "${UI_ST_T[$i]}"; UI_ROW_DIM=""
    UI_PAGE_L[$(( UI_ST_BASE + 1 + i ))]="$UI_LINE"
  done
  UI_ST_DONE=$done_n
  _ui_bar "$done_n" "$n" "${1:-}"
  UI_PAGE_L[$UI_ST_BASE]="$UI_LINE"
}

ui_steps_begin() {
  local title="$1" i; shift
  UI_ST_L=("$@"); UI_ST_S=(); UI_ST_D=(); UI_ST_T=()
  for (( i = 0; i < $#; i++ )); do UI_ST_S[$i]="todo"; UI_ST_D[$i]=""; UI_ST_T[$i]=""; done
  _ui_now_ms; UI_ST_T0=$UI_NOW
  # Colonne des libellés : juste assez large pour le plus long (libellés en cours, avec « … », ou finaux).
  UI_ROW_LW=20
  for (( i = 0; i < $#; i++ )); do _ui_strlen "${UI_ST_L[$i]}…"; (( UI_LEN + 2 > UI_ROW_LW )) && UI_ROW_LW=$(( UI_LEN + 2 )); done
  (( UI_ROW_LW > 32 )) && UI_ROW_LW=32
  ui_section "$title"
  [[ "$UI_SCREEN" == "1" ]] || return 0
  UI_ST_BASE=${#UI_PAGE_L[@]}
  _ui_steps_paint
  _ui_page_draw
}

ui_step_run() {
  UI_ST_CUR=$1; UI_ST_S[$1]="run"
  _ui_now_ms; UI_ST_CUR_T0=$UI_NOW
  [[ "$UI_SCREEN" == "1" ]] || return 0
  _ui_steps_paint; _ui_page_draw
  _ui_tick_start step
}

ui_step_done() {
  local n=$1 st="$2" label="$3" detail="${4:-}" icon
  _ui_tick_stop
  _ui_now_ms; _ui_dur $(( UI_NOW - UI_ST_CUR_T0 ))
  UI_ST_S[$n]="$st"; UI_ST_L[$n]="$label"; UI_ST_D[$n]="$detail"; UI_ST_T[$n]="$UI_DUR"
  [[ "$st" == "skip" ]] && UI_ST_T[$n]=""
  if [[ "$UI_SCREEN" == "1" ]]; then _ui_steps_paint; _ui_page_draw; return 0; fi
  case "$st" in ok) icon="${C_GREEN}✓${C_RESET}" ;; warn) icon="${C_YELLOW}!${C_RESET}" ;; fail) icon="${C_RED}✗${C_RESET}" ;; *) icon="${C_DIM}–${C_RESET}" ;; esac
  printf '%s\n' "${C_RAIL}│${C_RESET}  ${icon} ${label} ${C_DIM}${detail}${C_RESET}" >&2
}

ui_steps_end() {
  _ui_tick_stop
  _ui_now_ms; _ui_dur $(( UI_NOW - UI_ST_T0 ))
  if [[ "$UI_SCREEN" == "1" ]]; then _ui_steps_paint "terminé en $UI_DUR"; _ui_page_draw; fi
  UI_ST_BASE=-1; UI_ROW_LW=""
  return 0
}

# Sous-processus lancé pendant qu'un écran Loomy est ouvert : il dessine sur ce même écran.
if [[ -n "${LOOMY_SCREEN_OWNER:-}" && "$LOOMY_SCREEN_OWNER" != "$$" && -z "${LOOMY_NO_CLEAR:-}" ]] && ui_is_interactive; then
  UI_SCREEN=1
  trap '_ui_restore' EXIT
  trap '_ui_restore; exit 130' INT TERM
fi

# ---------------------------------------------------------------- mesure et découpage du texte
# _ui_strlen <texte> : largeur visible (UTF-8) dans UI_LEN, sans sous-processus si la locale est UTF-8.
_ui_strlen() {
  local probe="é"
  if [[ ${#probe} == 1 ]]; then UI_LEN=${#1}; return 0; fi
  local bytes cont
  bytes="$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')"
  cont="$(printf '%s' "$1" | LC_ALL=C tr -cd '\200-\277' | LC_ALL=C wc -c | tr -d ' ')"
  UI_LEN=$(( bytes - cont ))
}
_ui_len() { _ui_strlen "$1"; echo "$UI_LEN"; }

# _ui_pad <texte> <largeur> : texte complété d'espaces dans UI_PADDED.
_ui_pad() {
  local s="$1"
  _ui_strlen "$s"
  while (( UI_LEN < $2 )); do s="$s "; UI_LEN=$(( UI_LEN + 1 )); done
  UI_PADDED="$s"
}

# _ui_fit <texte> <largeur> : texte tronqué avec « … » s'il dépasse, dans UI_FIT.
_ui_fit() {
  _ui_strlen "$1"
  if (( UI_LEN <= $2 )); then UI_FIT="$1"; return 0; fi
  # Coupe par caractères, quelle que soit la locale (sinon un caractère accentué peut être coupé en deux).
  UI_FIT="$(perl -CSA -Mutf8 -e 'print substr($ARGV[0], 0, $ARGV[1]), "…"' "$1" $(( $2 - 1 )) 2>/dev/null)" || UI_FIT="${1:0:$(( $2 - 1 ))}…"
}

# _ui_wrap <texte> <largeur> : découpe en lignes (mots entiers) dans le tableau UI_LINES.
_ui_wrap() {
  local w="$2" line="" word words=()
  UI_LINES=()
  read -r -a words <<<"$1"
  for word in ${words[@]+"${words[@]}"}; do
    # Mot plus long que la largeur (un chemin, une URL) : coupé en morceaux.
    _ui_strlen "$word"
    while (( UI_LEN > w )); do
      [[ -n "$line" ]] && { UI_LINES+=("$line"); line=""; }
      UI_LINES+=("${word:0:$w}"); word="${word:$w}"; _ui_strlen "$word"
    done
    [[ -z "$word" ]] && continue
    if [[ -z "$line" ]]; then line="$word"; continue; fi
    _ui_strlen "$line $word"
    if (( UI_LEN <= w )); then line="$line $word"; else UI_LINES+=("$line"); line="$word"; fi
  done
  if [[ -n "$line" ]]; then UI_LINES+=("$line"); fi
  return 0
}

# _ui_term_size : UI_ROWS, UI_COLS, et largeur utile UI_W (bornée pour rester lisible).
_ui_term_size() {
  local size
  size="$( { stty size </dev/tty; } 2>/dev/null || true)"
  [[ -z "$size" && -n "${COLUMNS:-}" ]] && size="${LINES:-24} $COLUMNS"
  UI_ROWS="${size%% *}"; UI_COLS="${size##* }"
  # Taille inconnue ou nulle (certains pseudo-terminaux) : 80 × 24.
  [[ "$UI_ROWS" =~ ^[0-9]+$ ]] && (( UI_ROWS > 0 )) || UI_ROWS=24
  [[ "$UI_COLS" =~ ^[0-9]+$ ]] && (( UI_COLS > 0 )) || UI_COLS=80
  UI_W=$(( UI_COLS - 2 )); (( UI_W > 78 )) && UI_W=78; (( UI_W < 40 )) && UI_W=40
  return 0
}

# ---------------------------------------------------------------- messages simples
# Logo : le dessin de docs/assets/loomy-*.svg aux deux tiers (proportions et style conservés), en demi-blocs
# (deux pixels par caractère), sur trois lignes.
# {A} = accent violet (invite), {C} = curseur (clignote dans loomy watch : LOOMY_LOGO_BLINK=off l'éteint), {F} = texte.
UI_LOGO=(
  '{A}▀▄ {F}    ▀█   ▄▄   ▄▄  ▄▄ ▄  ▄  ▄ {C}▄▄'
  '{A} ▄▀{F}     █  █  █ █  █ █ █ █ ▀▄▄█ {C}██'
  '{A}▀  {F}    ▀▀▀  ▀▀   ▀▀  ▀ ▀ ▀  ▄▄▀ {C}▀▀'
)

# ui_logo_ok : vrai si le terminal est assez large pour le logo.
ui_logo_ok() { _ui_term_size; (( UI_COLS >= 40 )); }

# _ui_logo_lines <préfixe> : lignes colorées du logo dans UI_LINES.
_ui_logo_lines() {
  local l accent="${C_RAIL}" text="${C_BOLD}" cursor="${C_RAIL}"
  # Curseur éteint : même place, teinte à peine visible (le logo ne bouge pas).
  [[ "${LOOMY_LOGO_BLINK:-on}" == "off" && -n "$C_RESET" ]] && cursor=$'\033[38;5;237m'
  UI_LINES=()
  for l in "${UI_LOGO[@]}"; do
    l="${l//\{A\}/${C_RESET}${accent}}"; l="${l//\{C\}/${C_RESET}${cursor}}"; l="${l//\{F\}/${C_RESET}${text}}"
    UI_LINES+=("$1$l${C_RESET}")
  done
  return 0
}

# ui_banner <titre> <sous-titre> : en-tête des commandes Loomy (logo, puis ouverture du fil).
ui_banner() {
  local title="$1" subtitle="$2" l
  # Dans l'écran de Loomy : l'en-tête du cadre, rien dans la page. Affiché dans une vue de l'application
  # (LOOMY_NO_HEADER) : pas d'en-tête du tout, le cadre en a déjà un.
  if [[ "$UI_SCREEN" == "1" ]]; then ui_header "$title" "$subtitle"; _ui_page_draw; return 0; fi
  [[ -n "${LOOMY_NO_HEADER:-}" ]] && return 0
  ui_print ""
  if ui_logo_ok; then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do ui_print "$l"; done
    ui_print ""
    UI_PAGE_BODY=${#UI_PAGE_L[@]}   # le logo reste à l'écran, pas dans l'historique
    ui_print "${C_RAIL}┌${C_RESET}  ${C_TITLE}${title}${C_RESET}  ${C_DIM}${subtitle}${C_RESET}"
  else
    ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_TITLE}· ${title}${C_RESET}"
    ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}${subtitle}${C_RESET}"
  fi
}

# Sortie des commandes : un fil conducteur violet, des sections ◇, une ligne de fin └.
ui_section() { ui_print "${C_RAIL}│${C_RESET}"; ui_print "${C_RAIL}◇${C_RESET}  ${C_TITLE}$1${C_RESET}${2:+  ${C_DIM}$2${C_RESET}}"; }
ui_ok()   { if _ui_form_note ok "$1${2:+ · $2}"; then return 0; fi; ui_print "${C_RAIL}│${C_RESET}  ${C_GREEN}✓${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_warn() { if _ui_form_note warn "$1${2:+ · $2}"; then return 0; fi; ui_print "${C_RAIL}│${C_RESET}  ${C_YELLOW}!${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_err()  { ui_print "${C_RAIL}│${C_RESET}  ${C_RED}✗${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_info() { if _ui_form_note info "$*"; then return 0; fi; ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}→ $*${C_RESET}"; }
ui_end()  { ui_print "${C_RAIL}│${C_RESET}"; ui_print "${C_RAIL}└${C_RESET}  ${C_DIM}$*${C_RESET}"; ui_print ""; }

ui_kv() {
  local w=16
  _ui_strlen "$1"; (( UI_LEN + 2 > w )) && w=$(( UI_LEN + 2 ))
  _ui_pad "$1" "$w"
  ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}${UI_PADDED}${C_RESET}$2"
}

# ---------------------------------------------------------------- fil conducteur (récapitulatifs)
# ui_rail_head <texte> : ouvre un nouvel écran (récapitulatif…). Dans le cadre : nouvel en-tête et corps vide.
ui_rail_head() {
  if [[ "$UI_SCREEN" == "1" ]]; then UI_PAGE_L=(); ui_header "$*" ""; _ui_page_draw; return 0; fi
  ui_print ""; ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_DIM}$*${C_RESET}"; ui_print "${C_RAIL}│${C_RESET}"
}
ui_rail_group() {
  local right="${2:-}"
  _ui_term_size
  _ui_pad "$1" $(( UI_W - 3 - ${#right} ))
  ui_print "${C_RAIL}◇${C_RESET}  ${C_TITLE}${UI_PADDED}${C_RESET}${C_DIM}${right}${C_RESET}"
}
ui_rail_kv() { _ui_pad "$1" 15; ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}${UI_PADDED}${C_RESET}$2"; }
ui_rail() { ui_print "${C_RAIL}│${C_RESET}  $*"; }
ui_rail_end() { ui_print "${C_RAIL}└${C_RESET}  ${C_DIM}$*${C_RESET}"; }

# ---------------------------------------------------------------- lecture du clavier
# _ui_read_key : UI_KEY = up|down|left|right|enter|space|backspace|clear|char|other ; UI_CH = caractère saisi.
_ui_read_key() {
  local c="" c2="" c3=""
  UI_CH=""
  IFS= read -rsn1 c </dev/tty || c=""
  if [[ "$c" == $'\033' ]]; then
    IFS= read -rsn1 c2 </dev/tty || c2=""
    if [[ "$c2" == "[" || "$c2" == "O" ]]; then IFS= read -rsn1 c3 </dev/tty || c3=""; fi
    # Séquences longues (Suppr = ESC [ 3 ~) : on consomme la fin.
    if [[ "$c3" =~ ^[0-9]$ ]]; then IFS= read -rsn1 _ </dev/tty || true; fi
    case "$c3" in A) UI_KEY="up" ;; B) UI_KEY="down" ;; C) UI_KEY="right" ;; D) UI_KEY="left" ;; *) UI_KEY="other" ;; esac
    return 0
  fi
  case "$c" in
    ""|$'\n'|$'\r') UI_KEY="enter" ;;
    " ") UI_KEY="space"; UI_CH=" " ;;
    $'\177'|$'\010') UI_KEY="backspace" ;;
    $'\025') UI_KEY="clear" ;;
    $'\t') UI_KEY="other" ;;
    *) if [[ "$c" < " " ]]; then UI_KEY="other"; else UI_KEY="char"; UI_CH="$c"; fi ;;
  esac
  return 0
}

# ---------------------------------------------------------------- état du formulaire
UI_FORM_ACTIVE=0; UI_FORM_TITLE=""; UI_GROUPS=(); UI_GROUP=""
UI_STEP_CUR=0; UI_STEP_TOTAL=0
UI_QN=0; UI_QI=0; UI_TARGET=0; UI_BACK=0; UI_MODE="ask"; UI_PREV=""; UI_HAS_PREV=0
UI_RQ=(); UI_RV=()                               # question et réponse déjà données, par position
UI_LOG_G=(); UI_LOG_T=(); UI_LOG_K=(); UI_LOG_V=() # récapitulatif de la passe : groupe, type, libellé, valeur

ui_form_begin() {
  UI_FORM_TITLE="$1"; UI_GROUPS=()
  local IFS='|'
  read -r -a UI_GROUPS <<<"$2"
  UI_RQ=(); UI_RV=(); UI_TARGET=0
  ui_is_interactive || return 0
  UI_FORM_ACTIVE=1
  if [[ "$UI_SCREEN" == "1" ]]; then printf '\033[?25l' >&2; ui_header "Questionnaire" "$UI_FORM_TITLE"; else printf '\033[?1049h\033[?25l' >&2; fi
  stty -echo </dev/tty 2>/dev/null || true
  trap '_ui_restore' EXIT
  trap '_ui_restore; exit 130' INT TERM
  return 0
}

ui_form_pass() {
  UI_QN=0; UI_BACK=0; UI_GROUP=""
  UI_LOG_G=(); UI_LOG_T=(); UI_LOG_K=(); UI_LOG_V=()
}

ui_form_again() { [[ "$UI_BACK" == "1" ]]; }

ui_form_end() {
  if [[ "$UI_FORM_ACTIVE" == "1" ]]; then
    if [[ "$UI_SCREEN" == "1" ]]; then printf '\033[?25h' >&2; _ui_page_draw; else printf '\033[?25h\033[?1049l' >&2; fi
    stty echo </dev/tty 2>/dev/null || true
  fi
  UI_FORM_ACTIVE=0
  [[ "$UI_SCREEN" == "1" ]] || trap - INT TERM
  return 0
}

ui_group() { UI_GROUP="$1"; }

# ui_fact <libellé> <valeur> : résultat déduit des réponses (risque, routage…), affiché avec son groupe.
ui_fact() {
  if [[ "$UI_FORM_ACTIVE" == "1" ]]; then
    [[ "$UI_BACK" == "1" ]] || _ui_log fact "$1" "$2"
  elif ui_is_interactive; then
    ui_info "$1 : $2"
  fi
  return 0
}
ui_step() { UI_STEP_CUR="$1"; UI_STEP_TOTAL="$2"; }

# _ui_log <type> <libellé> <valeur>
_ui_log() {
  UI_LOG_G+=("$UI_GROUP"); UI_LOG_T+=("$1"); UI_LOG_K+=("$2"); UI_LOG_V+=("$3")
}

# Pendant le formulaire, les messages deviennent des notes du groupe courant au lieu d'être imprimés.
_ui_form_note() {
  [[ "$UI_FORM_ACTIVE" == "1" ]] || return 1
  [[ "$UI_BACK" == "1" ]] || _ui_log "$1" "" "$2"
  return 0
}

_ui_reset_ctx() { UI_HINT=""; UI_DESCS=(); UI_LABEL=""; }

# _ui_q_begin <question> : décide si la question est posée, rejouée ou sautée (après ←).
_ui_q_begin() {
  UI_QI=$UI_QN; UI_QN=$(( UI_QN + 1 )); UI_INLINE_N=0
  UI_HAS_PREV=0; UI_PREV=""
  if [[ "${UI_RQ[$UI_QI]+set}" == "set" && "${UI_RQ[$UI_QI]}" == "$1" ]]; then UI_HAS_PREV=1; UI_PREV="${UI_RV[$UI_QI]}"; fi
  if [[ "$UI_FORM_ACTIVE" != "1" ]]; then UI_MODE="ask"
  elif [[ "$UI_BACK" == "1" ]]; then UI_MODE="skip"
  elif (( UI_QI < UI_TARGET && UI_HAS_PREV )); then UI_MODE="replay"
  else UI_MODE="ask"; fi
  return 0
}

# _ui_q_end <question> : mémorise et consigne la réponse (ou programme le retour en arrière).
_ui_q_end() {
  local label="${UI_LABEL:-$1}"
  label="${label% ?}"; label="${label%\?}"
  if [[ "$UI_KEY" == "back" ]]; then
    UI_BACK=1; UI_TARGET=$(( UI_QI - 1 ))
  elif [[ "$UI_FORM_ACTIVE" == "1" && "$UI_MODE" != "skip" ]]; then
    UI_RQ[$UI_QI]="$1"; UI_RV[$UI_QI]="$UI_VALUE"
    _ui_log answer "$label" "${UI_VALUE% (recommandé)}"
  fi
  _ui_reset_ctx
  UI_FTR_KEYS=""
  return 0
}

ui_can_go_back() { [[ "$UI_FORM_ACTIVE" == "1" ]] && (( UI_QI > 0 )); }

# ---------------------------------------------------------------- dessin
UI_FRAME=""; UI_FRAME_N=0; UI_INLINE_N=0
_ui_add() { UI_FRAME="${UI_FRAME}$1"$'\033[K\n'; UI_FRAME_N=$(( UI_FRAME_N + 1 )); }
_ui_r() { _ui_add "${C_RAIL}│${C_RESET}  $1"; }

# _ui_static <question> : partie fixe de l'écran (en-tête, groupes, carte), adaptée à la hauteur du terminal.
# Renseigne UI_STATIC / UI_STATIC_N. <réservé> = lignes de la partie variable (options, encadré, pied).
_ui_static() {
  local q="$1" reserved="$2" level g i vals line text bar_on bar_off done_n
  local cw=$(( UI_W - 3 ))
  local pass logo
  for pass in 0 1 2 3 4; do
    # Passe 0 : avec le logo ; ensuite, sans logo et de plus en plus compact si le terminal est bas.
    logo=0; level=$(( pass - 1 )); if (( pass == 0 )); then logo=1; level=0; fi
    UI_FRAME=""; UI_FRAME_N=0
    if [[ "$UI_FORM_ACTIVE" == "1" ]]; then
      # Écran de Loomy : logo et titre sont dans l'en-tête du cadre ; sinon, en tête du questionnaire.
      if [[ "$UI_SCREEN" == "1" ]]; then _ui_add "${C_RAIL}│${C_RESET}"
      elif (( logo )) && (( UI_COLS >= 40 )); then
        _ui_logo_lines " "
        for line in "${UI_LINES[@]}"; do _ui_add "$line"; done
        _ui_add ""
        _ui_add "${C_RAIL}┌${C_RESET}  ${C_DIM}${UI_FORM_TITLE}${C_RESET}"
        _ui_add "${C_RAIL}│${C_RESET}"
      else
        _ui_add "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_DIM}${UI_FORM_TITLE}${C_RESET}"
        _ui_add "${C_RAIL}│${C_RESET}"
      fi
      # Groupes terminés : une ligne chacun.
      if (( level < 3 )); then
        for g in ${UI_GROUPS[@]+"${UI_GROUPS[@]}"}; do
          [[ "$g" == "$UI_GROUP" ]] && break
          vals=""
          for (( i = 0; i < ${#UI_LOG_G[@]}; i++ )); do
            [[ "${UI_LOG_G[$i]}" == "$g" && -n "${UI_LOG_V[$i]}" ]] || continue
            case "${UI_LOG_T[$i]}" in answer|fact) vals="${vals:+$vals · }${UI_LOG_V[$i]}" ;; esac
          done
          [[ -z "$vals" ]] && continue
          _ui_pad "$g" 11; _ui_fit "$vals" $(( cw - 13 ))
          _ui_add "${C_RAIL}◇${C_RESET}  ${C_DIM}${UI_PADDED}${C_RESET}  ${C_DIM}${UI_FIT}${C_RESET}"
        done
      fi
      # Groupe courant : titre et progression.
      if [[ -n "$UI_GROUP" ]]; then
        text=""; bar_on=""; bar_off=""
        if (( UI_STEP_TOTAL > 0 )); then
          done_n=$(( UI_STEP_CUR * 12 / UI_STEP_TOTAL ))
          for (( i = 0; i < 12; i++ )); do if (( i < done_n )); then bar_on="${bar_on}━"; else bar_off="${bar_off}╌"; fi; done
          text="question ${UI_STEP_CUR}/${UI_STEP_TOTAL}  "
        fi
        _ui_strlen "$text$bar_on$bar_off"; _ui_pad "$UI_GROUP" $(( cw - UI_LEN ))
        _ui_add "${C_RAIL}◇${C_RESET}  ${C_TITLE}${UI_PADDED}${C_RESET}${C_DIM}${text}${C_RESET}${C_RAIL}${bar_on}${C_RESET}${C_DIM}${bar_off}${C_RESET}"
        if (( level == 0 )); then
          for (( i = 0; i < ${#UI_LOG_G[@]}; i++ )); do
            [[ "${UI_LOG_G[$i]}" == "$UI_GROUP" ]] || continue
            case "${UI_LOG_T[$i]}" in
              answer) _ui_pad "${UI_LOG_K[$i]}" 18; _ui_fit "${UI_LOG_V[$i]:-—}" $(( cw - 22 ))
                      _ui_r "${C_GREEN}✓${C_RESET} ${C_DIM}${UI_PADDED}${C_RESET}${UI_FIT}" ;;
              fact)   _ui_pad "${UI_LOG_K[$i]}" 18; _ui_fit "${UI_LOG_V[$i]}" $(( cw - 22 ))
                      _ui_r "${C_RAIL}◦${C_RESET} ${C_DIM}${UI_PADDED}${UI_FIT}${C_RESET}" ;;
              warn)   _ui_fit "${UI_LOG_V[$i]}" $(( cw - 2 )); _ui_r "${C_YELLOW}!${C_RESET} ${C_DIM}${UI_FIT}${C_RESET}" ;;
              *)      _ui_fit "${UI_LOG_V[$i]}" $(( cw - 2 )); _ui_r "${C_DIM}→ ${UI_FIT}${C_RESET}" ;;
            esac
          done
        elif (( level < 3 )); then
          vals=""
          for (( i = 0; i < ${#UI_LOG_G[@]}; i++ )); do
            [[ "${UI_LOG_G[$i]}" == "$UI_GROUP" && -n "${UI_LOG_V[$i]}" ]] || continue
            case "${UI_LOG_T[$i]}" in answer|fact) vals="${vals:+$vals · }${UI_LOG_V[$i]}" ;; esac
          done
          if [[ -n "$vals" ]]; then _ui_fit "$vals" $(( cw - 2 )); _ui_r "${C_GREEN}✓${C_RESET} ${C_DIM}${UI_FIT}${C_RESET}"; fi
        fi
      fi
      _ui_add "${C_RAIL}│${C_RESET}"
    fi
    # Carte de la question.
    _ui_wrap "$q" $(( cw ))
    line="${UI_LINES[0]:-$q}"
    _ui_add "${C_RAIL}◆${C_RESET}  ${C_BOLD}${line}${C_RESET}"
    for (( i = 1; i < ${#UI_LINES[@]}; i++ )); do _ui_r "${C_BOLD}${UI_LINES[$i]}${C_RESET}"; done
    if [[ -n "$UI_HINT" ]]; then
      _ui_wrap "$UI_HINT" "$cw"
      for (( i = 0; i < ${#UI_LINES[@]}; i++ )); do
        if (( level == 3 && i >= 1 )); then break; fi
        _ui_r "${C_DIM}${UI_LINES[$i]}${C_RESET}"
      done
    fi
    _ui_add "${C_RAIL}│${C_RESET}"
    local room=$(( UI_ROWS - 1 )); [[ "$UI_SCREEN" == "1" ]] && { _ui_chrome; room=$(( UI_ROWS - UI_CHROME_H )); }
    if [[ "$UI_FORM_ACTIVE" != "1" ]] || (( UI_FRAME_N + reserved <= room )); then break; fi
    if (( pass == 0 && UI_COLS < 50 )); then continue; fi
  done
  UI_STATIC="$UI_FRAME"; UI_STATIC_N=$UI_FRAME_N
}

# _ui_boxes <largeur> : encadrés de conséquence pré-calculés, un par option (UI_BOX_0…), hauteur commune UI_BOX_H.
_ui_boxes() {
  local cw="$1" n=${#UI_DESCS[@]} i j inner title rule body
  UI_BOX_H=0; UI_BOXES=()
  (( n == 0 )) && return 0
  inner=$(( cw - 4 ))
  for (( i = 0; i < n; i++ )); do
    _ui_wrap "${UI_DESCS[$i]}" "$inner"
    (( ${#UI_LINES[@]} > UI_BOX_H )) && UI_BOX_H=${#UI_LINES[@]}
  done
  (( UI_BOX_H == 0 )) && return 0
  (( UI_BOX_H > 5 )) && UI_BOX_H=5
  title="─ Ce que ça implique "
  _ui_strlen "$title"
  rule="$(printf '%*s' $(( cw - 2 - UI_LEN )) '' | sed 's/ /─/g')"
  UI_BOX_TOP="${C_BOX}╭${title}${rule}╮${C_RESET}"
  UI_BOX_BOTTOM="${C_BOX}╰$(printf '%*s' $(( cw - 2 )) '' | sed 's/ /─/g')╯${C_RESET}"
  for (( i = 0; i < n; i++ )); do
    _ui_wrap "${UI_DESCS[$i]}" "$inner"
    body=""
    for (( j = 0; j < UI_BOX_H; j++ )); do
      _ui_pad "${UI_LINES[$j]:-}" "$inner"
      body="${body}${C_BOX}│${C_RESET} ${UI_PADDED} ${C_BOX}│${C_RESET}"$'\n'
    done
    UI_BOXES[$i]="$body"
  done
  return 0
}

# _ui_render : affiche UI_STATIC + UI_FRAME (partie variable), plein écran ou sur place.
_ui_render() {
  if [[ "$UI_FORM_ACTIVE" == "1" && "$UI_SCREEN" == "1" ]]; then
    # Questionnaire dans le cadre : le corps ne montre que la question (la page est cachée le temps du formulaire).
    local saved=(${UI_PAGE_L[@]+"${UI_PAGE_L[@]}"}); UI_PAGE_L=()
    _ui_page_draw 0 "$UI_STATIC$UI_FRAME"
    UI_PAGE_L=(${saved[@]+"${saved[@]}"})
  elif [[ "$UI_FORM_ACTIVE" == "1" ]]; then
    printf '\033[H%s%s\033[J' "$UI_STATIC" "$UI_FRAME" >&2
  else
    if [[ "$UI_SCREEN" == "1" ]]; then _ui_page_draw $(( UI_STATIC_N + UI_FRAME_N )) "$UI_STATIC$UI_FRAME"; return 0; fi
    if (( UI_INLINE_N > 0 )); then printf '\033[%dA' "$UI_INLINE_N" >&2; fi
    printf '%s%s\033[J' "$UI_STATIC" "$UI_FRAME" >&2
    UI_INLINE_N=$(( UI_STATIC_N + UI_FRAME_N ))
  fi
}

# _ui_inline_done <question> : hors formulaire, remplace la carte par une ligne de réponse.
_ui_inline_done() {
  [[ "$UI_FORM_ACTIVE" == "1" ]] && return 0
  if (( UI_INLINE_N > 0 )); then printf '\033[%dA\033[J' "$UI_INLINE_N" >&2; fi
  UI_INLINE_N=0
  local label="${UI_LABEL:-$1}"
  ui_print "${C_RAIL}◇${C_RESET}  ${C_DIM}${label}${C_RESET}  ${C_BOLD}${UI_VALUE:-—}${C_RESET}"
}

# Hors formulaire, le curseur est masqué pendant la question : il est rétabli même en cas d'interruption.
# L'écho du terminal est coupé pendant une question : une frappe rapide, arrivée entre deux lectures, ne s'imprime pas en vrac.
_ui_hide_cursor() {
  printf '\033[?25l' >&2
  stty -echo </dev/tty 2>/dev/null || true
  if [[ "$UI_FORM_ACTIVE" != "1" ]]; then trap '_ui_restore' EXIT; fi
  return 0
}
_ui_show_cursor() { printf '\033[?25h' >&2; [[ "$UI_FORM_ACTIVE" == "1" ]] || stty echo </dev/tty 2>/dev/null || true; return 0; }

_ui_footer() {
  local keys="$1"
  if ui_can_go_back; then keys="$keys   ← question précédente"; fi
  # Écran de Loomy : les touches vont dans le pied du cadre.
  if [[ "$UI_SCREEN" == "1" ]]; then UI_FTR_KEYS="$keys"; return 0; fi
  _ui_add "${C_RAIL}└${C_RESET}  ${C_DIM}${keys}${C_RESET}"
}

_ui_upcoming() {
  local g seen=0 next=""
  [[ "$UI_FORM_ACTIVE" == "1" ]] || return 0
  for g in ${UI_GROUPS[@]+"${UI_GROUPS[@]}"}; do
    if (( seen )); then next="${next:+$next · }$g"; fi
    [[ "$g" == "$UI_GROUP" ]] && seen=1
  done
  if [[ -n "$next" ]]; then _ui_r "${C_DIM}ensuite : ${next}${C_RESET}"; fi
  return 0
}

# ---------------------------------------------------------------- questions
# ui_input <question> <défaut> [texte-indicatif]
ui_input() {
  local q="$1" def="$2" ph="${3:-}" buf="" shown
  _ui_q_begin "$q"
  if ! ui_is_interactive || [[ "$UI_MODE" == "skip" ]]; then UI_VALUE="$def"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if [[ "$UI_MODE" == "replay" ]]; then UI_VALUE="$UI_PREV"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  (( UI_HAS_PREV )) && def="$UI_PREV"
  _ui_term_size
  _ui_static "$q" 4
  _ui_hide_cursor
  while true; do
    UI_FRAME=""; UI_FRAME_N=0
    if [[ -n "$buf" ]]; then shown="${C_BOLD}${buf}${C_RESET}${C_RAIL}▌${C_RESET}"
    elif [[ -n "$def" ]]; then shown="${C_RAIL}▌${C_RESET}${C_DIM}${def}  (par défaut)${C_RESET}"
    else shown="${C_RAIL}▌${C_RESET}${C_DIM}${ph}${C_RESET}"; fi
    _ui_r "${C_RAIL}›${C_RESET} ${shown}"
    _ui_add "${C_RAIL}│${C_RESET}"
    _ui_upcoming
    _ui_footer "⏎ valider   ⌫ effacer"
    _ui_render
    _ui_read_key
    case "$UI_KEY" in
      enter) break ;;
      char|space) buf="${buf}${UI_CH}" ;;
      backspace) buf="${buf%?}" ;;
      clear) buf="" ;;
      left) if ui_can_go_back; then UI_KEY="back"; break; fi ;;
    esac
  done
  _ui_show_cursor
  # Espaces en trop au début et à la fin retirés.
  buf="${buf#"${buf%%[![:space:]]*}"}"; buf="${buf%"${buf##*[![:space:]]}"}"
  UI_VALUE="${buf:-$def}"
  _ui_inline_done "$q"
  _ui_q_end "$q"
}

# ui_choose <question> <index-par-défaut (à partir de 0)> <option>...
ui_choose() {
  local q="$1" def="$2"; shift 2
  local opts=("$@") n=$# i sel mark cw line
  _ui_q_begin "$q"
  if ! ui_is_interactive || [[ "$UI_MODE" == "skip" ]]; then UI_VALUE="${opts[$def]}"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if [[ "$UI_MODE" == "replay" ]]; then UI_VALUE="$UI_PREV"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  sel="$def"
  if (( UI_HAS_PREV )); then for (( i = 0; i < n; i++ )); do [[ "${opts[$i]}" == "$UI_PREV" ]] && sel=$i; done; fi
  _ui_term_size; cw=$(( UI_W - 3 ))
  _ui_boxes "$cw"
  # Option « Quitter » ou « Annuler » : la touche q la choisit directement.
  local quit_i=""
  for (( i = 0; i < n; i++ )); do case "${opts[$i]}" in Quitter|Annuler) quit_i=$i ;; esac; done
  _ui_static "$q" $(( n + (UI_BOX_H > 0 ? UI_BOX_H + 3 : 0) + 3 ))
  _ui_hide_cursor
  while true; do
    UI_FRAME=""; UI_FRAME_N=0
    for (( i = 0; i < n; i++ )); do
      mark=""; if (( i == def && n > 1 )) && [[ "${opts[$i]}" != *"(recommandé)"* ]]; then mark="  ${C_DIM}(par défaut)${C_RESET}"; fi
      _ui_fit "${opts[$i]}" $(( cw - 18 ))
      if (( i == sel )); then _ui_r "${C_RAIL}❯ ●${C_RESET} ${C_BOLD}${UI_FIT}${C_RESET}${mark}"
      else _ui_r "  ${C_DIM}○${C_RESET} ${UI_FIT}${mark}"; fi
    done
    if (( UI_BOX_H > 0 )); then
      _ui_add "${C_RAIL}│${C_RESET}"
      _ui_r "$UI_BOX_TOP"
      while IFS= read -r line; do _ui_r "$line"; done <<<"${UI_BOXES[$sel]%$'\n'}"
      _ui_r "$UI_BOX_BOTTOM"
    fi
    _ui_add "${C_RAIL}│${C_RESET}"
    _ui_upcoming
    _ui_footer "↑↓ choisir   ⏎ valider   s défaut${quit_i:+   q ${opts[$quit_i]}}"
    _ui_render
    _ui_read_key
    case "$UI_KEY" in
      up) sel=$(( (sel - 1 + n) % n )) ;;
      down) sel=$(( (sel + 1) % n )) ;;
      char) case "$UI_CH" in k) sel=$(( (sel - 1 + n) % n )) ;; j) sel=$(( (sel + 1) % n )) ;; s) sel="$def"; break ;;
              q|Q) if [[ -n "$quit_i" ]]; then sel=$quit_i; break; fi ;; esac ;;
      enter) break ;;
      left) if ui_can_go_back; then UI_KEY="back"; break; fi ;;
    esac
  done
  _ui_show_cursor
  UI_VALUE="${opts[$sel]}"
  _ui_inline_done "$q"
  _ui_q_end "$q"
}

# ui_multi <question> <options cochées par défaut, séparées par des virgules> <option>...
# UI_VALUE : options cochées séparées par « , » (vide si aucune).
ui_multi() {
  local q="$1" defs="$2"; shift 2
  local opts=("$@") n=$# i cur=0 out="" on=() box cw line
  for (( i = 0; i < n; i++ )); do
    case ",$defs," in *",${opts[$i]},"*) on[$i]=1 ;; *) on[$i]=0 ;; esac
  done
  _ui_q_begin "$q"
  if ! ui_is_interactive || [[ "$UI_MODE" == "skip" ]]; then UI_VALUE="${defs//,/, }"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if [[ "$UI_MODE" == "replay" ]]; then UI_VALUE="$UI_PREV"; UI_KEY=""; _ui_q_end "$q"; return 0; fi
  if (( UI_HAS_PREV )); then
    for (( i = 0; i < n; i++ )); do case ", $UI_PREV," in *", ${opts[$i]},"*) on[$i]=1 ;; *) on[$i]=0 ;; esac; done
  fi
  _ui_term_size; cw=$(( UI_W - 3 ))
  _ui_boxes "$cw"
  _ui_static "$q" $(( n + (UI_BOX_H > 0 ? UI_BOX_H + 3 : 0) + 3 ))
  _ui_hide_cursor
  while true; do
    UI_FRAME=""; UI_FRAME_N=0
    for (( i = 0; i < n; i++ )); do
      if [[ "${on[$i]}" == "1" ]]; then box="${C_GREEN}◼${C_RESET}"; else box="${C_DIM}◻${C_RESET}"; fi
      _ui_fit "${opts[$i]}" $(( cw - 6 ))
      if (( i == cur )); then _ui_r "${C_RAIL}❯${C_RESET} ${box} ${C_BOLD}${UI_FIT}${C_RESET}"
      else _ui_r "  ${box} ${UI_FIT}"; fi
    done
    if (( UI_BOX_H > 0 )); then
      _ui_add "${C_RAIL}│${C_RESET}"
      _ui_r "$UI_BOX_TOP"
      while IFS= read -r line; do _ui_r "$line"; done <<<"${UI_BOXES[$cur]%$'\n'}"
      _ui_r "$UI_BOX_BOTTOM"
    fi
    _ui_add "${C_RAIL}│${C_RESET}"
    _ui_upcoming
    _ui_footer "↑↓ choisir   espace cocher   ⏎ valider"
    _ui_render
    _ui_read_key
    case "$UI_KEY" in
      up) cur=$(( (cur - 1 + n) % n )) ;;
      down) cur=$(( (cur + 1) % n )) ;;
      char) case "$UI_CH" in k) cur=$(( (cur - 1 + n) % n )) ;; j) cur=$(( (cur + 1) % n )) ;; x) if [[ "${on[$cur]}" == "1" ]]; then on[$cur]=0; else on[$cur]=1; fi ;; esac ;;
      space) if [[ "${on[$cur]}" == "1" ]]; then on[$cur]=0; else on[$cur]=1; fi ;;
      enter) break ;;
      left) if ui_can_go_back; then UI_KEY="back"; break; fi ;;
    esac
  done
  _ui_show_cursor
  for (( i = 0; i < n; i++ )); do
    [[ "${on[$i]}" == "1" ]] && out="${out:+$out, }${opts[$i]}"
  done
  UI_VALUE="$out"
  _ui_inline_done "$q"
  _ui_q_end "$q"
}

# ui_copy <texte> : copie dans le presse-papiers si un outil de presse-papiers existe. Renvoie 0 en cas de succès.
ui_copy() {
  if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$1" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
  else return 1
  fi
}
