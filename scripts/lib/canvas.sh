#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Character canvas for terminal diagrams: each row is a string of characters with a parallel string of colour codes
# (one letter per cell), so drawing replaces whole pieces of a row at once and printing walks colour runs, not cells.
# Used by the agent tree (loomy tree, key t of loomy watch), redrawn every second. Multibyte characters (box drawing,
# ●, ▼) count as one cell: needs a UTF-8 locale. Bash 3.2 compatible.

CV_W=0; CV_H=0; CV_ROW=(); CV_COL=(); CV_VL=()
CV_PAL=(); CV_PALN=0   # colour escape per code; code = letter index
CV_LETTERS="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
_CV_BLANK=""; _CV_DOTS=""

# cv_init <width> <height>
cv_init() {
  local y
  CV_W="$1"; CV_H="$2"; CV_ROW=(); CV_COL=(); CV_VL=(); CV_PAL=(); CV_PALN=0
  printf -v _CV_BLANK '%*s' "$CV_W" ""
  _CV_DOTS="${_CV_BLANK// /.}"
  for (( y = 0; y < CV_H; y++ )); do CV_ROW[y]="$_CV_BLANK"; CV_COL[y]="$_CV_DOTS"; done
}
# _cv_code <colour escape>: its one-letter code in CV_CODE ("." = no colour).
_cv_code() {
  local i
  [[ -z "$1" ]] && { CV_CODE="."; return 0; }
  for (( i = 0; i < CV_PALN; i++ )); do [[ "${CV_PAL[i]}" == "$1" ]] && { CV_CODE="${CV_LETTERS:i:1}"; return 0; }; done
  CV_PAL[CV_PALN]="$1"; CV_CODE="${CV_LETTERS:CV_PALN:1}"; CV_PALN=$(( CV_PALN + 1 ))
}
# cv_put <x> <y> <colour> <text>: writes the text from (x, y), clipped to the canvas.
cv_put() {
  local x="$1" y="$2" s="$4" n fill
  (( y < 0 || y >= CV_H )) && return 0
  (( x < 0 )) && { s="${s:$(( -x ))}"; x=0; }
  (( x >= CV_W )) && return 0
  n=${#s}; (( x + n > CV_W )) && { s="${s:0:$(( CV_W - x ))}"; n=${#s}; }
  (( n == 0 )) && return 0
  _cv_code "$3"; fill="${_CV_DOTS:0:n}"; fill="${fill//./$CV_CODE}"
  CV_ROW[y]="${CV_ROW[y]:0:x}${s}${CV_ROW[y]:$(( x + n ))}"
  CV_COL[y]="${CV_COL[y]:0:x}${fill}${CV_COL[y]:$(( x + n ))}"
}
# cv_get <x> <y>: the character at (x, y), in CV_CH.
cv_get() { CV_CH="${CV_ROW[$2]:$1:1}"; }
# cv_center <x> <y> <width> <colour> <text>: text centred within [x, x+width).
cv_center() { local s="$5"; cv_put $(( $1 + ($3 - ${#s}) / 2 )) "$2" "$4" "$s"; }
# cv_right <x_end> <y> <colour> <text>: text ending at column x_end.
cv_right() { local s="$4"; cv_put $(( $1 - ${#s} + 1 )) "$2" "$3" "$s"; }
# cv_hline <x1> <x2> <y> <colour> [char]
cv_hline() { local n=$(( $2 - $1 + 1 )) s; (( n > 0 )) || return 0; s="${_CV_BLANK:0:n}"; cv_put "$1" "$3" "$4" "${s// /${5:-─}}"; }
# cv_vline <x> <y1> <y2> <colour> [char]: a vertical link; its ends are joined to the lines they meet (cv_junctions).
cv_vline() { local y; for (( y = $2; y <= $3; y++ )); do cv_put "$1" "$y" "$4" "${5:-│}"; done; CV_VL[${#CV_VL[@]}]="$1 $2 $3"; }
# cv_box <x> <y> <w> <h> <colour> [title in the top border]
cv_box() {
  local x="$1" y="$2" w="$3" h="$4" k="$5" title="${6:-}" r mid
  mid="${_CV_BLANK:0:$(( w - 2 ))}"
  cv_put "$x" "$y" "$k" "┌${mid// /─}┐"
  for (( r = y + 1; r < y + h - 1; r++ )); do cv_put "$x" "$r" "$k" "│"; cv_put $(( x + w - 1 )) "$r" "$k" "│"; done
  cv_put "$x" $(( y + h - 1 )) "$k" "└${mid// /─}┘"
  [[ -n "$title" ]] && cv_put $(( x + 3 )) "$y" "$k" "┤ $title ├"
  return 0
}
# cv_junctions: where a vertical link meets a horizontal line (a box border, a split), the proper joint (┴ ┬ ┼).
cv_junctions() {
  local x y1 y2 k n=${#CV_VL[@]} c kc
  for (( k = 0; k < n; k++ )); do
    read -r x y1 y2 <<<"${CV_VL[k]}"
    if (( y1 > 0 )); then cv_get "$x" $(( y1 - 1 )); kc="${CV_COL[y1 - 1]:x:1}"; c=""
      [[ "$CV_CH" == "─" ]] && c="┬"; [[ "$CV_CH" == "┴" ]] && c="┼"
      [[ -n "$c" ]] && { CV_ROW[y1 - 1]="${CV_ROW[y1 - 1]:0:x}${c}${CV_ROW[y1 - 1]:$(( x + 1 ))}"; }; fi
    if (( y2 < CV_H - 1 )); then cv_get "$x" $(( y2 + 1 )); c=""
      [[ "$CV_CH" == "─" ]] && c="┴"; [[ "$CV_CH" == "┬" ]] && c="┼"
      [[ -n "$c" ]] && { CV_ROW[y2 + 1]="${CV_ROW[y2 + 1]:0:x}${c}${CV_ROW[y2 + 1]:$(( x + 1 ))}"; }; fi
  done
  : "$kc"
}
# cv_print <prefix>: every row, one colour escape per run of same-coloured cells.
cv_print() {
  local y row col out pos c run n i esc
  for (( y = 0; y < CV_H; y++ )); do
    row="${CV_ROW[y]}"; col="${CV_COL[y]}"
    # Trailing blanks dropped.
    row="${row%"${row##*[! ]}"}"; col="${col:0:${#row}}"
    out="$1"; pos=0
    while [[ -n "$col" ]]; do
      c="${col:0:1}"; run="${col%%[!$c]*}"; n=${#run}
      if [[ "$c" == "." ]]; then esc="$C_RESET"; else i="${CV_LETTERS%%"$c"*}"; esc="${C_RESET}${CV_PAL[${#i}]}"; fi
      out="${out}${esc}${row:pos:n}"
      pos=$(( pos + n )); col="${col:n}"
    done
    printf '%s%s\n' "$out" "$C_RESET"
  done
}
