#!/usr/bin/env bash
# Outils d'interface terminal pour les scripts de Loomy.
# À charger (source), pas à exécuter. Compatible bash 3.2 (celui de macOS).
# Utilise `gum` (https://github.com/charmbracelet/gum) s'il est disponible, sinon de l'ANSI simple.
# Les réponses sont renvoyées dans la variable globale UI_VALUE.

UI_VALUE=""
UI_ASSUME_DEFAULTS="${UI_ASSUME_DEFAULTS:-0}"
# Contexte facultatif par appel, réinitialisé après chaque question :
#   UI_HINT   une ligne qui explique pourquoi la question compte
#   UI_DESCS  tableau des conséquences, une par option (dans le même ordre que les options)
UI_HINT=""
UI_DESCS=()
UI_DESC_LINES=3
UI_KEY=""

if [[ -z "${NO_COLOR:-}" ]] && { [[ -n "${LOOMY_FORCE_COLOR:-}" ]] || [[ -t 2 && "${TERM:-dumb}" != "dumb" ]]; }; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""
fi

UI_USE_GUM=0
if [[ -z "${LOOMY_NO_GUM:-}" && -t 0 && -t 2 ]] && command -v gum >/dev/null 2>&1; then
  UI_USE_GUM=1
fi

ui_is_interactive() { [[ "$UI_ASSUME_DEFAULTS" != "1" && -t 0 && -t 2 ]]; }

ui_print() { printf '%s\n' "$*" >&2; }

ui_banner() {
  local title="$1" subtitle="$2"
  if [[ "$UI_USE_GUM" == "1" ]]; then
    gum style --border rounded --border-foreground 99 --padding "0 2" --margin "1 0" \
      "$(gum style --bold --foreground 255 "◆ $title")" "$(gum style --foreground 245 "$subtitle")" >&2
    return
  fi
  local line="──────────────────────────────────────────────────────"
  ui_print ""
  ui_print "${C_MAGENTA}╭${line}╮${C_RESET}"
  ui_print "${C_MAGENTA}│${C_RESET}  ${C_BOLD}◆ ${title}${C_RESET}"
  ui_print "${C_MAGENTA}│${C_RESET}  ${C_DIM}${subtitle}${C_RESET}"
  ui_print "${C_MAGENTA}╰${line}╯${C_RESET}"
}

ui_section() { ui_print ""; ui_print "${C_BOLD}$*${C_RESET}"; }
ui_ok()      { ui_print "  ${C_GREEN}✓${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_warn()    { ui_print "  ${C_YELLOW}!${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_err()     { ui_print "  ${C_RED}✗${C_RESET} $1 ${C_DIM}${2:-}${C_RESET}"; }
ui_info()    { ui_print "  ${C_DIM}→ $*${C_RESET}"; }
# Largeur visible d'une chaîne UTF-8, indépendamment de la locale.
_ui_len() {
  local bytes cont
  bytes="$(printf '%s' "$1" | LC_ALL=C wc -c | tr -d ' ')"
  cont="$(printf '%s' "$1" | LC_ALL=C tr -cd '\200-\277' | LC_ALL=C wc -c | tr -d ' ')"
  echo $(( bytes - cont ))
}

ui_kv() {
  local k="$1" pad="" len
  len="$(_ui_len "$k")"
  while (( len + ${#pad} < 14 )); do pad="$pad "; done
  printf '  %s%s %s\n' "$k" "$pad" "$2" >&2
}

# ui_step <current> <total>
ui_step() {
  ui_is_interactive || return 0
  local cur="$1" total="$2" width=36 done_n i on="" off=""
  done_n=$(( cur * width / total ))
  for (( i = 0; i < width; i++ )); do
    if (( i < done_n )); then on="${on}━"; else off="${off}━"; fi
  done
  ui_print ""
  ui_print "${C_DIM}Étape ${cur}/${total}${C_RESET}  ${C_MAGENTA}${on}${C_RESET}${C_DIM}${off}${C_RESET}"
}

_ui_cursor_show() { printf '\033[?25h' >&2; }

_ui_hint() {
  if [[ -n "$UI_HINT" ]]; then ui_print "  ${C_DIM}${UI_HINT}${C_RESET}"; fi
}

_ui_width() {
  local cols="${COLUMNS:-}"
  [[ -z "$cols" ]] && cols="$(tput cols 2>/dev/null || echo 80)"
  cols=$(( cols - 8 ))
  (( cols > 100 )) && cols=100
  (( cols < 30 )) && cols=30
  echo "$cols"
}

# _ui_desc_block <texte> : affiche exactement UI_DESC_LINES lignes (retour à la ligne, complétées).
_ui_desc_block() {
  local text="$1" w i=0 line
  w="$(_ui_width)"
  if [[ -n "$text" ]]; then
    while IFS= read -r line; do
      (( i >= UI_DESC_LINES )) && break
      if (( i == 0 )); then printf '\033[2K  %sℹ %s%s\n' "$C_CYAN" "$line" "$C_RESET" >&2
      else printf '\033[2K    %s%s%s\n' "$C_CYAN" "$line" "$C_RESET" >&2; fi
      i=$(( i + 1 ))
    done < <(printf '%s\n' "$text" | fold -s -w "$w")
  fi
  while (( i < UI_DESC_LINES )); do printf '\033[2K\n' >&2; i=$(( i + 1 )); done
}

# _ui_gum_descs <option>... : liste les options et leurs conséquences au-dessus d'un menu gum.
_ui_gum_descs() {
  local i=0 o
  for o in "$@"; do
    if [[ -n "${UI_DESCS[$i]:-}" ]]; then ui_print "  ${C_BOLD}${o}${C_RESET} ${C_DIM}— ${UI_DESCS[$i]}${C_RESET}"; fi
    i=$(( i + 1 ))
  done
}

_ui_reset_ctx() { UI_HINT=""; UI_DESCS=(); }

# _ui_read_key : renseigne UI_KEY avec up|down|enter|space|s|j|k|other.
# Lit les séquences d'échappement octet par octet (ESC [ A, ESC O A) et tolère un ESC perdu.
_ui_read_key() {
  local c="" c2="" c3=""
  IFS= read -rsn1 c </dev/tty || c=""
  if [[ "$c" == $'\033' ]]; then
    IFS= read -rsn1 c2 </dev/tty || c2=""
    if [[ "$c2" == "[" || "$c2" == "O" ]]; then IFS= read -rsn1 c3 </dev/tty || c3=""; fi
  elif [[ "$c" == "[" ]]; then
    IFS= read -rsn1 c3 </dev/tty || c3=""
  fi
  case "$c3" in
    A) UI_KEY="up"; return 0 ;;
    B) UI_KEY="down"; return 0 ;;
  esac
  case "$c" in
    ""|$'\n'|$'\r') UI_KEY="enter" ;;
    " ") UI_KEY="space" ;;
    s) UI_KEY="s" ;; j) UI_KEY="down" ;; k) UI_KEY="up" ;;
    *) UI_KEY="other" ;;
  esac
}

# ui_input <question> <défaut> [texte-indicatif]
ui_input() {
  local q="$1" def="$2" ph="${3:-}" ans=""
  if ! ui_is_interactive; then UI_VALUE="$def"; _ui_reset_ctx; return 0; fi
  if [[ "$UI_USE_GUM" == "1" ]]; then
    ui_print "${C_BLUE}?${C_RESET} ${C_BOLD}${q}${C_RESET}"
    _ui_hint; _ui_reset_ctx
    [[ -n "$def" ]] && ui_print "  ${C_DIM}Entrée vide = ${def}${C_RESET}"
    ans="$(gum input --placeholder "${def:-$ph}" --width 70)" || ans=""
    UI_VALUE="${ans:-$def}"
    ui_print "  ${C_CYAN}${UI_VALUE}${C_RESET}"
    return 0
  fi
  local hint=""
  [[ -n "$def" ]] && hint=" ${C_DIM}(${def})${C_RESET}"
  ui_print "${C_BLUE}?${C_RESET} ${C_BOLD}${q}${C_RESET}${hint}"
  _ui_hint; _ui_reset_ctx
  IFS= read -r -e -p "  › " ans </dev/tty || ans=""
  UI_VALUE="${ans:-$def}"
}

# ui_choose <question> <index-par-défaut (à partir de 0)> <option>...
ui_choose() {
  local q="$1" def="$2"; shift 2
  local n=$# i sel="$def" lines
  local opts=("$@")
  if ! ui_is_interactive; then UI_VALUE="${opts[$def]}"; _ui_reset_ctx; return 0; fi
  if [[ "$UI_USE_GUM" == "1" ]]; then
    local ans
    ui_print "${C_BLUE}?${C_RESET} ${C_BOLD}${q}${C_RESET}"
    _ui_hint; _ui_gum_descs "${opts[@]}"; _ui_reset_ctx
    ans="$(gum choose --header "" --selected "${opts[$def]}" "${opts[@]}")" || ans="${opts[$def]}"
    UI_VALUE="${ans:-${opts[$def]}}"
    ui_print "  ${C_CYAN}❯ ${UI_VALUE}${C_RESET}"
    return 0
  fi
  local has_desc=0
  for (( i = 0; i < n; i++ )); do [[ -n "${UI_DESCS[$i]:-}" ]] && has_desc=1; done
  lines=$(( n + 1 )); (( has_desc )) && lines=$(( lines + UI_DESC_LINES ))
  ui_print "${C_BLUE}?${C_RESET} ${C_BOLD}${q}${C_RESET}"
  _ui_hint
  printf '\033[?25l' >&2
  trap _ui_cursor_show EXIT
  while true; do
    for (( i = 0; i < n; i++ )); do
      if (( i == sel )); then
        printf '\033[2K  %s❯ %s%s\n' "$C_MAGENTA$C_BOLD" "${opts[$i]}" "$C_RESET" >&2
      else
        printf '\033[2K    %s\n' "${opts[$i]}" >&2
      fi
    done
    (( has_desc )) && _ui_desc_block "${UI_DESCS[$sel]:-}"
    printf '\033[2K  %s↑↓ déplacer · entrée valider · s valeur par défaut%s\n' "$C_DIM" "$C_RESET" >&2
    _ui_read_key
    case "$UI_KEY" in
      up) sel=$(( (sel - 1 + n) % n )) ;;
      down) sel=$(( (sel + 1) % n )) ;;
      s) sel="$def"; printf '\033[%dA' "$lines" >&2; break ;;
      enter) printf '\033[%dA' "$lines" >&2; break ;;
    esac
    printf '\033[%dA' "$lines" >&2
  done
  for (( i = 0; i < lines; i++ )); do printf '\033[2K\n' >&2; done
  printf '\033[%dA' "$lines" >&2
  _ui_cursor_show
  UI_VALUE="${opts[$sel]}"
  local desc="${UI_DESCS[$sel]:-}"
  _ui_reset_ctx
  ui_print "  ${C_CYAN}❯ ${UI_VALUE}${C_RESET}"
  if [[ -n "$desc" ]]; then ui_print "    ${C_DIM}${desc}${C_RESET}"; fi
}

# ui_multi <question> <options par défaut séparées par des virgules> <option>...
# Returns selected options joined by ", " (empty if none).
ui_multi() {
  local q="$1" defs="$2"; shift 2
  local n=$# i cur=0 out="" lines has_desc=0
  local opts=("$@") on=()
  for (( i = 0; i < n; i++ )); do
    case ",$defs," in *",${opts[$i]},"*) on[$i]=1 ;; *) on[$i]=0 ;; esac
    [[ -n "${UI_DESCS[$i]:-}" ]] && has_desc=1
  done
  if ! ui_is_interactive; then UI_VALUE="$defs"; UI_VALUE="${UI_VALUE//,/, }"; _ui_reset_ctx; return 0; fi
  if [[ "$UI_USE_GUM" == "1" ]]; then
    local ans
    ui_print "${C_BLUE}?${C_RESET} ${C_BOLD}${q}${C_RESET}"
    _ui_hint; _ui_gum_descs "${opts[@]}"; _ui_reset_ctx
    ans="$(gum choose --no-limit --header "x ou tab pour cocher · entrée pour valider" --selected "$defs" "${opts[@]}")" || ans=""
    UI_VALUE="$(printf '%s' "$ans" | paste -sd ',' - | sed 's/,/, /g')"
    ui_print "  ${C_CYAN}❯ ${UI_VALUE:-aucun}${C_RESET}"
    return 0
  fi
  lines=$(( n + 1 )); (( has_desc )) && lines=$(( lines + UI_DESC_LINES ))
  ui_print "${C_BLUE}?${C_RESET} ${C_BOLD}${q}${C_RESET}"
  _ui_hint
  printf '\033[?25l' >&2
  trap _ui_cursor_show EXIT
  while true; do
    for (( i = 0; i < n; i++ )); do
      local box="○"; [[ "${on[$i]}" == "1" ]] && box="${C_GREEN}●${C_RESET}"
      if (( i == cur )); then
        printf '\033[2K  %s❯%s %s %s%s%s\n' "$C_MAGENTA" "$C_RESET" "$box" "$C_BOLD" "${opts[$i]}" "$C_RESET" >&2
      else
        printf '\033[2K    %s %s\n' "$box" "${opts[$i]}" >&2
      fi
    done
    (( has_desc )) && _ui_desc_block "${UI_DESCS[$cur]:-}"
    printf '\033[2K  %s↑↓ déplacer · espace cocher · entrée valider%s\n' "$C_DIM" "$C_RESET" >&2
    _ui_read_key
    case "$UI_KEY" in
      up) cur=$(( (cur - 1 + n) % n )) ;;
      down) cur=$(( (cur + 1) % n )) ;;
      space) if [[ "${on[$cur]}" == "1" ]]; then on[$cur]=0; else on[$cur]=1; fi ;;
      enter) printf '\033[%dA' "$lines" >&2; break ;;
    esac
    printf '\033[%dA' "$lines" >&2
  done
  for (( i = 0; i < lines; i++ )); do printf '\033[2K\n' >&2; done
  printf '\033[%dA' "$lines" >&2
  _ui_cursor_show
  for (( i = 0; i < n; i++ )); do
    [[ "${on[$i]}" == "1" ]] && out="${out:+$out, }${opts[$i]}"
  done
  UI_VALUE="$out"
  _ui_reset_ctx
  ui_print "  ${C_CYAN}❯ ${UI_VALUE:-aucun}${C_RESET}"
}

# ui_copy <texte> : copie dans le presse-papiers si un outil de presse-papiers existe. Renvoie 0 en cas de succès.
ui_copy() {
  if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$1" | pbcopy
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy
  elif command -v xclip >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard
  else return 1
  fi
}
