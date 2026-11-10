#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Character canvas for terminal diagrams: each row is a string of characters with a parallel string of colour codes
# (one letter per cell), so drawing replaces whole pieces of a row at once and printing walks colour runs, not cells.
# Used by the agent tree (loomy tree, key t of loomy watch), redrawn every second. Multibyte characters (box drawing,
# ●, ▼) count as one cell: needs a UTF-8 locale. Bash 3.2 compatible.
# Text with wide or combining characters goes through _cv_prep: it is cut by terminal cells (East Asian wide = 2,
# combining/zero-width = 0, never inside a grapheme) and rewritten so that one canvas slot is exactly one cell: a wide
# character is followed by a filler slot, a multi-codepoint grapheme is one private-use slot; cv_print restores both.

CV_W=0; CV_H=0; CV_ROW=(); CV_COL=(); CV_VL=()
CV_PAL=(); CV_PALN=0   # colour escape per code; code = letter index
CV_LETTERS="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
_CV_BLANK=""; _CV_DOTS=""
CV_SIMPLE_RE='^[ -~…·◐◇▮▯✓✗⇢⚑●▼▲■░█▏▸▶–—─│┌┐└┘├┤┬┴┼┏┓┗┛┣┫┳┻╋━┃═║╔╗╚╝╠╣╦╩╬╭╮╯╰╌╎→←↑↓éèêëàâçôûùîïœÉÈÀÇ]*$'
_CV_FILL=$'\001'; CV_CLU=(); CV_CLV=(); CV_S=""; CV_N=0
CV_P=""; CV_CUT=0; _CV_PK=(); _CV_PV=(); _CV_PIDX=0   # direct-mapped cache (256 slots) of prepared texts: perl runs once per distinct label

# cv_init <width> <height>
cv_init() {
  local y
  CV_W="$1"; CV_H="$2"; CV_ROW=(); CV_COL=(); CV_VL=(); CV_PAL=(); CV_PALN=0; CV_CLU=(); CV_CLV=()
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
  (( x < 0 )) && { s="${s:$(( -x ))}"; x=0; [[ "${s:0:1}" != "$_CV_FILL" ]] || s=" ${s:1}"; }
  (( x >= CV_W )) && return 0
  n=${#s}; (( x + n > CV_W )) && { _cv_clip "$s" $(( CV_W - x )); s="$CV_S"; n=${#s}; }
  (( n == 0 )) && return 0
  _cv_code "$3"; fill="${_CV_DOTS:0:n}"; fill="${fill//./$CV_CODE}"
  CV_ROW[y]="${CV_ROW[y]:0:x}${s}${CV_ROW[y]:$(( x + n ))}"
  CV_COL[y]="${CV_COL[y]:0:x}${fill}${CV_COL[y]:$(( x + n ))}"
}
# cv_get <x> <y>: the character at (x, y), in CV_CH.
cv_get() { CV_CH="${CV_ROW[$2]:$1:1}"; }
# _cv_clip <slots> <n>: the first n slots in CV_S, never leaving a wide character without its filler slot.
_cv_clip() { CV_S="${1:0:$2}"; [[ "${1:$2:1}" != "$_CV_FILL" ]] || CV_S="${CV_S%?}"; }
# _cv_simple <text>: success when every cell of the text is one codepoint wide (ASCII, accented Latin, Greek, Cyrillic,
# box, arrow and geometric symbols), so no interpreter is needed. Judged on bytes: lead bytes of combining marks (CC CD),
# of CJK, fullwidth, variation selectors and emoji (E3 and above), zero-width/format characters and the wide
# symbol-block emoji mean "measure it".
_cv_simple() {
  # The common rows (ASCII, the UI symbols, French accents) are judged by one regex, without a locale switch.
  [[ "$1" =~ $CV_SIMPLE_RE ]] && return 0
  local p="$1" LC_ALL=C
  case "$p" in
    *[$'\314\315'$'\343'-$'\377']*|*$'\342\200'[$'\213'-$'\217'$'\250'-$'\257']*|*$'\342\201'*|*$'\342\203'*) return 1 ;;
    *$'\342\214\232'*|*$'\342\214\233'*|*$'\342\217\251'*|*$'\342\217\252'*|*$'\342\217\253'*|*$'\342\217\254'*|*$'\342\217\260'*|*$'\342\217\263'*|*$'\342\227\275'*|*$'\342\227\276'*|*$'\342\230\224'*|*$'\342\230\225'*|*$'\342\231\210'*|*$'\342\231\211'*|*$'\342\231\212'*|*$'\342\231\213'*|*$'\342\231\214'*|*$'\342\231\215'*|*$'\342\231\216'*|*$'\342\231\217'*|*$'\342\231\220'*|*$'\342\231\221'*|*$'\342\231\222'*|*$'\342\231\223'*|*$'\342\231\277'*|*$'\342\232\223'*|*$'\342\232\241'*|*$'\342\232\252'*|*$'\342\232\253'*|*$'\342\232\275'*|*$'\342\232\276'*|*$'\342\233\204'*|*$'\342\233\205'*|*$'\342\233\216'*|*$'\342\233\224'*|*$'\342\233\252'*|*$'\342\233\262'*|*$'\342\233\263'*|*$'\342\233\265'*|*$'\342\233\272'*|*$'\342\233\275'*|*$'\342\234\205'*|*$'\342\234\212'*|*$'\342\234\213'*|*$'\342\234\250'*|*$'\342\235\214'*|*$'\342\235\216'*|*$'\342\235\223'*|*$'\342\235\224'*|*$'\342\235\225'*|*$'\342\235\227'*|*$'\342\236\225'*|*$'\342\236\226'*|*$'\342\236\227'*|*$'\342\236\260'*|*$'\342\236\277'*|*$'\342\254\233'*|*$'\342\254\234'*|*$'\342\255\220'*|*$'\342\255\225'*) return 1 ;;
  esac
  return 0
}
# _cv_prep <text> [max cells]: CV_S = slot string (one slot per cell), CV_P = the plain text cut the same way,
# CV_N = its cells; text wider than max is cut by whole graphemes and ends with "…" (CV_CUT=1).
_cv_prep() {
  local t="$1" max="${2:--1}" k i rec pu slot
  CV_CUT=0
  if _cv_simple "$t"; then
    CV_S="$t"; CV_N=${#t}
    if (( max >= 0 && CV_N > max )); then
      CV_CUT=1; if (( max > 0 )); then CV_S="${t:0:$(( max - 1 ))}…"; CV_N=$max; else CV_S=""; CV_N=0; fi
    fi
    CV_P="$CV_S"; return 0
  fi
  k="$max|$t"; rec=""
  # Slot from the key length and three sampled characters: O(1) lookup, a collision only costs one more measurement.
  local n=${#k} a b c
  printf -v a %d "'${k:$(( n / 3 )):1}"; printf -v b %d "'${k:$(( n / 2 )):1}"; printf -v c %d "'${k:$(( n * 2 / 3 )):1}"
  slot=$(( (n * 7 + a + b * 3 + c * 5) % 256 ))
  [[ "${_CV_PK[slot]:-}" != "$k" ]] || rec="${_CV_PV[slot]}"
  if [[ -z "$rec" ]]; then
    rec="$(printf '%s' "$t" | perl -MEncode=decode,FB_CROAK -e '
      binmode STDOUT, ":utf8"; local $/; my ($max,$base)=@ARGV; my $s=decode("UTF-8",scalar(<STDIN>),FB_CROAK);
      $s =~ s/[\x00-\x1f\x7f]/ /g; my (@g,@w,$tot); my $idx=$base;
      for my $g ($s =~ /\X/g) { my $w=0;
        for my $c (split //,$g) { next if $c =~ /[\p{M}\p{Cf}\p{Emoji_Modifier}]/;
          $w+=$c =~ /[\p{East_Asian_Width=Wide}\p{East_Asian_Width=Fullwidth}]/ ? 2 : 1; }
        $w=2 if $w && $g =~ /[\p{Emoji_Presentation}\p{Regional_Indicator}\x{fe0f}\x{20e3}]/;
        next unless $w; push @g,$g; push @w,$w; $tot+=$w; }
      my $cut = $max >= 0 && $tot > $max; my ($out,$plain,$cells,@defs)=("","",0);
      for my $i (0..$#g) { last if $cut && $cells + $w[$i] > $max - 1;
        $plain .= $g[$i];
        if (length($g[$i]) == 1) { $out .= $g[$i] } else { my $p=chr(0xE000 + ($idx++ % 6000)); $out .= $p; push @defs,"$p\t$g[$i]" }
        $out .= "\001" if $w[$i] == 2; $cells += $w[$i]; }
      if ($cut) { if ($max > 0) { $out .= "\x{2026}"; $plain .= "\x{2026}"; $cells++ } else { $out=""; $plain=""; $cells=0 } }
      print "$cells ",scalar(@defs)," ",($cut ? 1 : 0),"\n$out\n$plain\n",join("\n",@defs);
    ' -- "$max" "$_CV_PIDX" 2>/dev/null)" || { CV_S="$t"; CV_P="$t"; CV_N=${#t}; return 0; }
    pu="${rec%%$'\n'*}"; pu="${pu#* }"; _CV_PIDX=$(( _CV_PIDX + ${pu%% *} ))
    _CV_PK[slot]="$k"; _CV_PV[slot]="$rec"
  fi
  pu="${rec%%$'\n'*}"; CV_N="${pu%% *}"; CV_CUT="${pu##* }"; rec="${rec#*$'\n'}"; CV_S="${rec%%$'\n'*}"
  rec="${rec#*$'\n'}"; CV_P="${rec%%$'\n'*}"
  [[ "$rec" == *$'\n'* ]] || return 0
  rec="${rec#*$'\n'}"
  while [[ -n "$rec" ]]; do
    pu="${rec%%$'\n'*}"; k="${pu%%$'\t'*}"
    for (( i = 0; i < ${#CV_CLU[@]}; i++ )); do [[ "${CV_CLU[i]}" != "$k" ]] || break; done
    (( i < ${#CV_CLU[@]} )) || { CV_CLU[i]="$k"; CV_CLV[i]="${pu#*$'\t'}"; }
    [[ "$rec" == *$'\n'* ]] && rec="${rec#*$'\n'}" || rec=""
  done
}
# cv_text <x> <y> <colour> <text> [max cells]: cv_put for a label that may hold wide or combining characters.
cv_text() { _cv_prep "$4" "${5:--1}"; cv_put "$1" "$2" "$3" "$CV_S"; }
# cv_center <x> <y> <width> <colour> <text>: text centred within [x, x+width).
cv_center() {
  (( $3 > 0 )) || return 0
  _cv_prep "$5" "$3"
  cv_put $(( $1 + ($3 - CV_N) / 2 )) "$2" "$4" "$CV_S"
}
# Box text reserves the border and two blank cells on each side.
cv_box_center() { cv_center $(( $1 + 3 )) "$2" $(( $3 - 6 )) "$4" "$5"; }
# Two fixed title rows: wrap even unbroken agent paths without changing box geometry (by cells, whole graphemes).
cv_box_title() {
  local x="$1" y="$2" w="$3" k="$4" room=$(( $3 - 6 )) first rest
  (( room > 0 )) || return 0
  _cv_prep "$5"; first="$CV_S"
  if (( CV_N <= room )); then rest=""; else _cv_clip "$first" "$room"; rest="${first:${#CV_S}}"; first="$CV_S"; fi
  cv_put $(( x + 3 + (room - ${#first}) / 2 )) "$y" "$k" "$first"
  if [[ -n "$rest" ]]; then
    if (( ${#rest} > room )); then _cv_clip "$rest" $(( room - 1 )); rest="${CV_S}…"; fi
    cv_put $(( x + 3 + (room - ${#rest}) / 2 )) $(( y + 1 )) "$k" "$rest"
  fi
}
# cv_right <x_end> <y> <colour> <text>: text ending at column x_end.
cv_right() { _cv_prep "$4"; cv_put $(( $1 - CV_N + 1 )) "$2" "$3" "$CV_S"; }
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
  local y row col out pos c run n i esc pu
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
    # Filler slots dropped, private-use slots restored to their graphemes (unquoted: bash 3.2 keeps quotes in a replacement).
    if [[ "$out" == *"$_CV_FILL"* ]]; then out="${out//$_CV_FILL/}"; fi
    for (( i = 0; i < ${#CV_CLU[@]}; i++ )); do pu="${CV_CLU[i]}"; esc="${CV_CLV[i]}"; [[ "$out" != *"$pu"* ]] || out="${out//$pu/$esc}"; done
    printf '%s%s\n' "$out" "$C_RESET"
  done
}
