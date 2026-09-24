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
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
  if [[ "${TERM:-}" == *256color* || "${COLORTERM:-}" == truecolor || "${COLORTERM:-}" == 24bit ]]; then
    C_BRAND=$'\033[1;38;5;141m'   # « Loomy » : violet clair
    C_RAIL=$'\033[38;5;98m'       # fil conducteur et repères
    C_BOX=$'\033[38;5;74m'        # encadré des conséquences
  else
    C_BRAND=$'\033[1;35m'; C_RAIL=$'\033[35m'; C_BOX=$'\033[36m'
  fi
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_BRAND=""; C_RAIL=""; C_BOX=""
fi

ui_is_interactive() { [[ "$UI_ASSUME_DEFAULTS" != "1" && -t 0 && -t 2 ]]; }

ui_print() { printf '%s\n' "$*" >&2; }

# ui_clear : efface l'écran avant un affichage Loomy, seulement dans un terminal interactif (LOOMY_NO_CLEAR=1 pour garder l'historique).
ui_clear() {
  if [[ -z "${LOOMY_NO_CLEAR:-}" ]] && ui_is_interactive; then printf '\033[H\033[2J' >&2; fi
  return 0
}

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
  if (( UI_LEN <= $2 )); then UI_FIT="$1"; else UI_FIT="${1:0:$(( $2 - 1 ))}…"; fi
}

# _ui_wrap <texte> <largeur> : découpe en lignes (mots entiers) dans le tableau UI_LINES.
_ui_wrap() {
  local w="$2" line="" word words=()
  UI_LINES=()
  read -r -a words <<<"$1"
  for word in ${words[@]+"${words[@]}"}; do
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
  [[ "$UI_ROWS" =~ ^[0-9]+$ ]] || UI_ROWS=24
  [[ "$UI_COLS" =~ ^[0-9]+$ ]] || UI_COLS=80
  UI_W=$(( UI_COLS - 2 )); (( UI_W > 78 )) && UI_W=78; (( UI_W < 40 )) && UI_W=40
  return 0
}

# ---------------------------------------------------------------- messages simples
# Logo : la grille de pixels de docs/assets/loomy-*.svg, en demi-blocs (deux pixels par caractère).
# {A} = accent violet (invite et curseur), {F} = texte.
UI_LOGO=(
  '         {F}▀█'
  '{A}▀▄        {F}█   ▄▀▀▀▄ ▄▀▀▀▄ █▀▄▀▄ █   █ {A}███'
  ' {A}▄▀       {F}█   █   █ █   █ █ █ █ █   █ {A}███'
  '{A}▀        {F}▀▀▀   ▀▀▀   ▀▀▀  ▀ ▀ ▀  ▀▀▀█ {A}▀▀▀'
  '                                 {F}▀▀▀'
)

# ui_logo_ok : vrai si le terminal est assez large pour le logo.
ui_logo_ok() { _ui_term_size; (( UI_COLS >= 50 )); }

# _ui_logo_lines <préfixe> : lignes colorées du logo dans UI_LINES.
_ui_logo_lines() {
  local l accent="${C_RAIL}" text="${C_BOLD}"
  UI_LINES=()
  for l in "${UI_LOGO[@]}"; do
    l="${l//\{A\}/${C_RESET}${accent}}"; l="${l//\{F\}/${C_RESET}${text}}"
    UI_LINES+=("$1$l${C_RESET}")
  done
  return 0
}

# ui_banner <titre> <sous-titre> : en-tête des commandes Loomy (logo, puis ouverture du fil).
ui_banner() {
  local title="$1" subtitle="$2" l
  ui_print ""
  if ui_logo_ok; then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do ui_print "$l"; done
    ui_print ""
    ui_print "${C_RAIL}┌${C_RESET}  ${C_BOLD}${title}${C_RESET}  ${C_DIM}${subtitle}${C_RESET}"
  else
    ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_BOLD}· ${title}${C_RESET}"
    ui_print "${C_RAIL}│${C_RESET}  ${C_DIM}${subtitle}${C_RESET}"
  fi
}

# Sortie des commandes : un fil conducteur violet, des sections ◇, une ligne de fin └.
ui_section() { ui_print "${C_RAIL}│${C_RESET}"; ui_print "${C_RAIL}◇${C_RESET}  ${C_BOLD}$1${C_RESET}${2:+  ${C_DIM}$2${C_RESET}}"; }
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
ui_rail_head() { ui_print ""; ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_DIM}$*${C_RESET}"; ui_print "${C_RAIL}│${C_RESET}"; }
ui_rail_group() {
  local right="${2:-}"
  _ui_term_size
  _ui_pad "$1" $(( UI_W - 3 - ${#right} ))
  ui_print "${C_RAIL}◇${C_RESET}  ${C_BOLD}${UI_PADDED}${C_RESET}${C_DIM}${right}${C_RESET}"
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
  printf '\033[?1049h\033[?25l' >&2
  trap 'ui_form_end' EXIT
  trap 'ui_form_end; exit 130' INT TERM
  return 0
}

ui_form_pass() {
  UI_QN=0; UI_BACK=0; UI_GROUP=""
  UI_LOG_G=(); UI_LOG_T=(); UI_LOG_K=(); UI_LOG_V=()
}

ui_form_again() { [[ "$UI_BACK" == "1" ]]; }

ui_form_end() {
  if [[ "$UI_FORM_ACTIVE" == "1" ]]; then printf '\033[?25h\033[?1049l' >&2; fi
  UI_FORM_ACTIVE=0
  trap - INT TERM
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
      if (( logo )) && (( UI_COLS >= 50 )); then
        _ui_logo_lines " "
        for line in "${UI_LINES[@]}"; do _ui_add "$line"; done
        _ui_add ""
        _ui_add "${C_RAIL}┌${C_RESET}  ${C_DIM}${UI_FORM_TITLE}${C_RESET}"
      else
        _ui_add "${C_RAIL}┌${C_RESET}  ${C_BRAND}Loomy${C_RESET} ${C_DIM}${UI_FORM_TITLE}${C_RESET}"
      fi
      _ui_add "${C_RAIL}│${C_RESET}"
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
        _ui_add "${C_RAIL}◇${C_RESET}  ${C_BOLD}${UI_PADDED}${C_RESET}${C_DIM}${text}${C_RESET}${C_RAIL}${bar_on}${C_RESET}${C_DIM}${bar_off}${C_RESET}"
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
    if [[ "$UI_FORM_ACTIVE" != "1" ]] || (( UI_FRAME_N + reserved <= UI_ROWS - 1 )); then break; fi
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
  if [[ "$UI_FORM_ACTIVE" == "1" ]]; then
    printf '\033[H%s%s\033[J' "$UI_STATIC" "$UI_FRAME" >&2
  else
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
_ui_hide_cursor() {
  printf '\033[?25l' >&2
  if [[ "$UI_FORM_ACTIVE" != "1" ]]; then trap 'printf "\033[?25h" >&2' EXIT; fi
  return 0
}

_ui_footer() {
  local keys="$1"
  if ui_can_go_back; then keys="$keys   ← question précédente"; fi
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
  printf '\033[?25h' >&2
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
    _ui_footer "↑↓ choisir   ⏎ valider   s défaut"
    _ui_render
    _ui_read_key
    case "$UI_KEY" in
      up) sel=$(( (sel - 1 + n) % n )) ;;
      down) sel=$(( (sel + 1) % n )) ;;
      char) case "$UI_CH" in k) sel=$(( (sel - 1 + n) % n )) ;; j) sel=$(( (sel + 1) % n )) ;; s) sel="$def"; break ;; esac ;;
      enter) break ;;
      left) if ui_can_go_back; then UI_KEY="back"; break; fi ;;
    esac
  done
  printf '\033[?25h' >&2
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
  printf '\033[?25h' >&2
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
