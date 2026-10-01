#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Character canvas for terminal diagrams: a grid of cells (character + colour), drawn with text, boxes and lines,
# then printed row by row with the colour changes. Used by the agent tree (loomy tree, key t of loomy watch).
# Multibyte characters (box drawing, ●, ▼) count as one cell: needs a UTF-8 locale. Bash 3.2 compatible.

CV_W=0; CV_H=0; CV_G=(); CV_K=(); CV_VL=()

# cv_init <width> <height>
cv_init() {
  local n i
  CV_W="$1"; CV_H="$2"; n=$(( CV_W * CV_H )); CV_G=(); CV_K=(); CV_VL=()
  for (( i = 0; i < n; i++ )); do CV_G[i]=" "; CV_K[i]=""; done
}
# cv_put <x> <y> <colour> <text>: writes the text from (x, y), clipped to the canvas.
cv_put() {
  local x="$1" y="$2" k="$3" s="$4" i n c
  (( y < 0 || y >= CV_H )) && return 0
  n=${#s}
  for (( i = 0; i < n; i++ )); do
    c=$(( x + i )); (( c < 0 || c >= CV_W )) && continue
    CV_G[y * CV_W + c]="${s:i:1}"; CV_K[y * CV_W + c]="$k"
  done
}
# cv_center <x> <y> <width> <colour> <text>: text centred within [x, x+width).
cv_center() { local s="$5" l; l=${#s}; cv_put $(( $1 + ($3 - l) / 2 )) "$2" "$4" "$s"; }
# cv_right <x_end> <y> <colour> <text>: text ending at column x_end.
cv_right() { local s="$4"; cv_put $(( $1 - ${#s} + 1 )) "$2" "$3" "$s"; }
# cv_hline <x1> <x2> <y> <colour> [char]
cv_hline() { local x c="${5:-─}"; for (( x = $1; x <= $2; x++ )); do cv_put "$x" "$3" "$4" "$c"; done; }
# cv_vline <x> <y1> <y2> <colour> [char]: a vertical link; its ends are joined to the lines they meet (cv_junctions).
cv_vline() { local y c="${5:-│}"; for (( y = $2; y <= $3; y++ )); do cv_put "$1" "$y" "$4" "$c"; done; CV_VL+=("$1 $2 $3"); }
# cv_box <x> <y> <w> <h> <colour> [title in the top border]
cv_box() {
  local x="$1" y="$2" w="$3" h="$4" k="$5" title="${6:-}"
  cv_put "$x" "$y" "$k" "┌"; cv_hline $(( x + 1 )) $(( x + w - 2 )) "$y" "$k"; cv_put $(( x + w - 1 )) "$y" "$k" "┐"
  cv_vline "$x" $(( y + 1 )) $(( y + h - 2 )) "$k"; cv_vline $(( x + w - 1 )) $(( y + 1 )) $(( y + h - 2 )) "$k"
  cv_put "$x" $(( y + h - 1 )) "$k" "└"; cv_hline $(( x + 1 )) $(( x + w - 2 )) $(( y + h - 1 )) "$k"; cv_put $(( x + w - 1 )) $(( y + h - 1 )) "$k" "┘"
  [[ -n "$title" ]] && cv_put $(( x + 3 )) "$y" "$k" "┤ $title ├"
  return 0
}
# cv_junctions: where a vertical link meets a horizontal line (a box border, a split), the proper joint (┴ ┬ ┼).
# Only the ends of the links drawn with cv_vline are looked at (fast enough for a refresh every second).
cv_junctions() {
  local x y1 y2 i k n=${#CV_VL[@]}
  for (( k = 0; k < n; k++ )); do
    read -r x y1 y2 <<<"${CV_VL[k]}"
    if (( y1 > 0 )); then i=$(( (y1 - 1) * CV_W + x )); [[ "${CV_G[i]}" == "─" ]] && CV_G[i]="┬"; [[ "${CV_G[i]}" == "┴" ]] && CV_G[i]="┼"; fi
    if (( y2 < CV_H - 1 )); then i=$(( (y2 + 1) * CV_W + x )); [[ "${CV_G[i]}" == "─" ]] && CV_G[i]="┴"; [[ "${CV_G[i]}" == "┬" ]] && CV_G[i]="┼"; fi
  done
}
# cv_print <prefix>: every row, colour codes only where they change.
cv_print() {
  local y x i k prev line
  for (( y = 0; y < CV_H; y++ )); do
    line="$1"; prev=""
    for (( x = 0; x < CV_W; x++ )); do
      i=$(( y * CV_W + x )); k="${CV_K[i]}"
      if [[ "$k" != "$prev" ]]; then line="${line}${C_RESET}${k}"; prev="$k"; fi
      line="${line}${CV_G[i]}"
    done
    printf '%s%s\n' "${line%"${line##*[! ]}"}" "$C_RESET"
  done
}
