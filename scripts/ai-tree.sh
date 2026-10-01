#!/usr/bin/env bash
# Agent tree: the lead agent, its advisor and every routed role with its model, effort and live state, then the session
# log and a status line. Shown by loomy watch (key t); loomy tree prints it once. Bash 3.2 compatible.
#   ai-tree.sh [--root <dir>]
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
# shellcheck source=lib/sessionlog.sh
source "$SCRIPT_DIR/lib/sessionlog.sh"

ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//; s/ai-tree.sh/loomy tree/g' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd)" || exit 1
J="$(ai_journal_file "$ROOT")"
TICK="${LOOMY_TICK:-0}"
now_s="$(date +%s)"
ai_detect_env "$ROOT"

dur() { local d="${1%.*}"; if (( d >= 60 )); then printf '%d min %02d s' $(( d / 60 )) $(( d % 60 )); else printf '%d s' "$d"; fi; }
hm() { local e; e="$(ai_ts_epoch "$1")"; [[ -n "$e" ]] && { date -r "$e" +%H:%M:%S 2>/dev/null || date -d "@$e" +%H:%M:%S; }; }
color_of() { case "$1" in TOP) printf '%s' "$C_MAGENTA" ;; FAST) printf '%s' "$C_GREEN" ;; *) printf '%s' "$C_CYAN" ;; esac; }

# ---------------------------------------------------------------- state per role, from the log
# Per role: running (a delegation started whose process is alive), or the last finished one.
STATES="$( [[ -s "$J" ]] && awk '
  function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
  function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
  /"type":"delegation_start"/ { id = field("id"); srole[id] = field("role"); sts[id] = field("ts"); spid[id] = num("pid"); stask[id] = substr(field("task"), 1, 50); order[++n] = id }
  /"type":"delegation",/ { id = field("id"); fin[id] = 1; r = field("role")
    last[r] = field("ts") "|" field("status") "|" num("duration_s") "|" (num("tokens_in") + num("tokens_out")) "|" field("outcome") "|" field("model"); cnt[r]++ }
  END {
    for (i = 1; i <= n; i++) { id = order[i]; if (!(id in fin)) print "RUN|" srole[id] "|" spid[id] "|" sts[id] "|" stask[id] }
    for (r in last) print "LAST|" r "|" last[r] "|" cnt[r] }' "$J")"

# ---------------------------------------------------------------- lead and advisor
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
L_MODEL="$R_MODEL"; L_EFFORT="$R_EFFORT"; L_FAM="$R_FAMILY"
ADV=""; [[ "$L_FAM" == "claude" ]] && ADV="$(ai_advisor_for "$L_MODEL" "$AI_PROFILE")"
sess="$(ai_session_state "$ROOT" 2>/dev/null || echo none)"
case "$sess" in
  open*) s_txt="${C_GREEN}● $(t "session open")${C_RESET}" ;;
  closed*) s_txt="${C_DIM}○ $(t "session closed")${C_RESET}" ;;
  *) s_txt="${C_DIM}○ $(t "no session")${C_RESET}" ;;
esac
phase="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1)"
for mf in audit task; do
  p="$(sed -n 's/^phase=//p' "$ROOT/.loomy/$mf.state" 2>/dev/null | head -1)"
  if [[ -n "$p" && "$p" != "done" ]]; then loomy_phases_mode "$mf"; phase="$p"; MISSION="$mf"; break; fi
done

# Advisor consultations (count, last one).
a_n=0; a_last=""; a_tok=0
if [[ -s "$J" ]]; then
  read -r a_n a_tok a_last <<<"$(awk 'function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    /"type":"advisor"/ { n += num("calls"); tk += num("tokens_in"); if (match($0, /"ts":"[^"]*"/)) l = substr($0, RSTART + 6, RLENGTH - 7) } END { print n + 0, tk + 0, l }' "$J")"
fi
# role_state <role>: "run|<elapsed s>|<task>", "last|<status>|<outcome>|<duration>" or "idle".
role_state() {
  local run last pid ts task lts lst ldur loc
  run="$(printf '%s\n' "$STATES" | awk -F'|' -v r="$1" '$1 == "RUN" && $2 == r' | tail -1)"
  if [[ -n "$run" ]]; then
    IFS='|' read -r _ _ pid ts task <<<"$run"
    if [[ -n "$pid" && "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "run|$(( now_s - $(ai_ts_epoch "$ts" || echo "$now_s") ))|$task"; return 0
    fi
  fi
  last="$(printf '%s\n' "$STATES" | awk -F'|' -v r="$1" '$1 == "LAST" && $2 == r' | tail -1)"
  if [[ -n "$last" ]]; then IFS="|" read -r _ _ lts lst ldur _ loc _ _ <<<"$last"; echo "last|$lst|$loc|$ldur|$lts"; else echo "idle"; fi
}

# ---------------------------------------------------------------- diagram (wide terminals)
_ui_term_size
W=$(( UI_COLS - 7 ))
# Rendering: diagram (boxes and links) or list. tree_view auto (default): the diagram when the window can hold it,
# otherwise the list. LOOMY_TREE (set by key v of loomy watch) overrides for one session.
TREE_MODE="${LOOMY_TREE:-$(sed -n 's/^tree_view=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/config" 2>/dev/null | tail -1)}"
TREE_NEED_COLS=124; TREE_NEED_ROWS=56; [[ -n "${LOOMY_NO_HEADER:-}" ]] && TREE_NEED_ROWS=63
DIAGRAM=0
case "${TREE_MODE:-auto}" in
  diagram) (( W >= 96 )) && DIAGRAM=1 ;;
  list) DIAGRAM=0 ;;
  *) (( UI_COLS >= TREE_NEED_COLS && UI_ROWS >= TREE_NEED_ROWS )) && DIAGRAM=1 ;;
esac
TREE_SMALL=0; [[ "${TREE_MODE:-auto}" != "list" ]] && (( ! DIAGRAM )) && TREE_SMALL=1
if (( DIAGRAM )); then
  # shellcheck source=lib/canvas.sh
  source "$SCRIPT_DIR/lib/canvas.sh"
  (( W > 140 )) && W=140
  K_LEAD="$C_YELLOW"; K_ROUTE="$C_GREEN"; K_ROLE="$C_CYAN"; K_ADV="$C_MAGENTA"; K_DIM="$C_DIM"; K_TXT=""; K_B="$C_BOLD"
  bars() { case "$1" in low) echo "▮▯▯▯" ;; medium) echo "▮▮▯▯" ;; high) echo "▮▮▮▯" ;; *) echo "▮▮▮▮" ;; esac; }
  eff_short() { case "$1" in medium) echo "med" ;; *) echo "$1" ;; esac; }
  action_of() {
    case "$1" in
      architect) t "designs the plan" ;; debugger) t "finds the cause" ;; security) t "checks the risks" ;;
      reviewer) t "reviews the diff" ;; developer) t "edits + runs tests" ;; executor) t "runs bounded tasks" ;;
      explorer) t "reads the code" ;; documenter) t "writes the docs" ;; *) echo "$1" ;;
    esac
  }
  # Roles shown as boxes: running ones first, then the most recently used, then the usual workers.
  pick=""
  for r in $(printf '%s\n' "$STATES" | awk -F'|' '$1 == "RUN" { print $2 }') \
           $(printf '%s\n' "$STATES" | awk -F'|' '$1 == "LAST" { print $3 "|" $2 }' | sort -r | cut -d'|' -f2) \
           developer reviewer executor explorer architect; do
    case " $pick " in *" $r "*) continue ;; esac
    case " $AI_ROLES " in *" $r "*) [[ "$r" != "lead" ]] && pick="$pick $r" ;; esac
  done
  ADV_W=0; recent=0; [[ -n "$ADV" ]] && ADV_W=26
  CX=$(( ADV_W > 0 ? ADV_W + 6 : 0 )); CWID=$(( W - CX ))
  BW=22; NB=$(( (CWID + 4) / (BW + 4) )); (( NB > 4 )) && NB=4; (( NB < 2 )) && NB=2
  read -r -a SHOWN <<<"$pick"; SHOWN=("${SHOWN[@]:0:$NB}")
  NB=${#SHOWN[@]}
  _ui_term_size
  LOGN=$(( UI_ROWS - 52 )); (( LOGN < 4 )) && LOGN=4; (( LOGN > 8 )) && LOGN=8
  H=$(( 56 + LOGN ))
  cv_init "$W" "$H"
  # Title, rule, legend.
  # Advisor alias → the model it stands for (opus → Opus 5.5).
  case "$ADV" in opus) adv_model="$AI_MODEL_CLAUDE_TOP" ;; sonnet) adv_model="$AI_MODEL_CLAUDE_MID" ;; fable) adv_model="claude-fable-5-1" ;; *) adv_model="$ADV" ;; esac
  nice_model() { printf '%s' "$1" | sed 's/^claude-//; s/-\([0-9]\)-\([0-9]\)$/ \1.\2/; s/^gpt-/GPT-/' | tr 'a-z' 'A-Z'; }
  adv_up="$(nice_model "$adv_model")"
  title="$(t "LOOMY AGENT TREE")  ·  $(nice_model "$L_MODEL") $(t "LEADS")${ADV:+  ·  $adv_up $(t "ON CALL")}"
  cv_center 0 0 "$W" "$K_B" "$title"
  cv_hline 2 $(( W - 3 )) 1 "$K_DIM"
  litems=("$K_LEAD|$(t "lead") · $L_EFFORT" "$K_ROUTE|$(t "routing") · $(ai_profile_label "$AI_PROFILE")" "$K_ROLE|$(t "roles") · $(t "by profile")")
  [[ -n "$ADV" ]] && litems+=("$K_ADV|$(t "advisor") · $ADV")
  ltot=0; for it in "${litems[@]}"; do lt="${it#*|}"; ltot=$(( ltot + ${#lt} + 5 )); done
  lp=$(( (W - ltot) / 2 ))
  for it in "${litems[@]}"; do lt="${it#*|}"; cv_put "$lp" 3 "${it%%|*}" "■"; cv_put $(( lp + 2 )) 3 "$K_DIM" "$lt"; lp=$(( lp + ${#lt} + 5 )); done
  # Lead agent box.
  MW=38; MX=$(( CX + (CWID - MW) / 2 )); MY=5
  mcx=$(( MX + MW / 2 ))
  lk="$K_LEAD"; [[ "$sess" == open* ]] && (( TICK % 2 )) && lk="${C_BOLD}${C_YELLOW}"
  cv_box "$MX" "$MY" "$MW" 6 "$lk"
  cv_center "$MX" $(( MY + 1 )) "$MW" "${C_BOLD}${C_YELLOW}" "$(nice_model "$L_MODEL") · $(t "main session")"
  cv_center "$MX" $(( MY + 2 )) "$MW" "$K_TXT" "$(t "plans + decides")"
  cv_center "$MX" $(( MY + 3 )) "$MW" "$K_TXT" "effort $(bars "$L_EFFORT") $L_EFFORT"
  cv_center "$MX" $(( MY + 4 )) "$MW" "$( [[ "$sess" == open* ]] && echo "$C_GREEN" || echo "$K_DIM")" "$( [[ "$sess" == open* ]] && echo "● $(t "session open")" || echo "○ $(t "session closed")")${phase:+ · $(loomy_phase_label "$phase")}"
  # Connector lead → routing, with a travelling dot.
  cv_vline "$mcx" $(( MY + 6 )) $(( MY + 7 )) "$K_DIM"
  cv_put "$mcx" $(( MY + 6 + TICK % 2 )) "$K_LEAD" "●"
  # Routing layer: delegations per tier (Loomy's routing, where the video has Jev).
  RW=56; RX=$(( CX + (CWID - RW) / 2 )); RY=$(( MY + 8 ))
  cv_box "$RX" "$RY" "$RW" 6 "$K_ROUTE"
  cv_put $(( RX + 2 )) $(( RY + 1 )) "${C_BOLD}${C_GREEN}" "LOOMY · $(t "routing")"
  n_tot="$( [[ -s "$J" ]] && grep -c '"type":"delegation",' "$J" || echo 0)"
  cv_right $(( RX + RW - 3 )) $(( RY + 1 )) "$K_TXT" "$(t "delegations") $n_tot"
  ry=$(( RY + 2 ))
  for tier in TOP MID FAST; do
    cnt="$( [[ -s "$J" ]] && awk -v tier="$tier" -v a="$AI_MODEL_CLAUDE_TOP $AI_MODEL_CODEX_TOP" -v b="$AI_MODEL_CLAUDE_MID $AI_MODEL_CODEX_MID" -v c="$AI_MODEL_CLAUDE_FAST $AI_MODEL_CODEX_FAST" '
      /"type":"delegation",/ { m = ""; if (match($0, /"model":"[^"]*"/)) m = substr($0, RSTART + 9, RLENGTH - 10)
        s = (tier == "TOP" ? a : (tier == "MID" ? b : c)); if (index(" " s " ", " " m " ")) n++ } END { print n + 0 }' "$J" || echo 0)"
    if [[ "$tier" == TOP ]]; then lbl="$(t "top")"; elif [[ "$tier" == MID ]]; then lbl="$(t "standard")"; else lbl="$(t "fast")"; fi
    fill=0; (( n_tot > 0 )) && fill=$(( cnt * 10 / n_tot ))
    bar=""; for (( q = 0; q < 10; q++ )); do if (( q < fill )); then bar="${bar}█"; else bar="${bar}░"; fi; done
    cv_put $(( RX + 2 )) "$ry" "$K_TXT" "$lbl"
    cv_put $(( RX + 13 )) "$ry" "$K_ROUTE" "$bar"
    cv_put $(( RX + 25 )) "$ry" "$K_TXT" "$cnt"
    mods="$(eval "echo \"\$AI_MODEL_CLAUDE_${tier} · \$AI_MODEL_CODEX_${tier}\"" | sed 's/claude-//; s/gpt-//g')"
    cv_right $(( RX + RW - 3 )) "$ry" "$K_DIM" "$mods"
    ry=$(( ry + 1 ))
  done
  # Delegate to roles: label, split with nodes, arrows.
  cv_vline "$mcx" $(( RY + 6 )) $(( RY + 7 )) "$K_DIM"; cv_put "$mcx" $(( RY + 7 )) "$K_DIM" "●"
  SY=$(( RY + 9 ))
  cv_center "$CX" "$SY" "$CWID" "$K_TXT" "$(t "delegate to roles") · $(t "effort by profile")"
  GAP=$(( (CWID - NB * BW) / (NB + 1) )); (( GAP < 1 )) && GAP=1
  bx=(); for (( b = 0; b < NB; b++ )); do bx[b]=$(( CX + GAP + b * (BW + GAP) )); done
  first_c=$(( bx[0] + BW / 2 )); last_c=$(( bx[NB - 1] + BW / 2 ))
  cv_hline "$first_c" "$last_c" $(( SY + 2 )) "$K_DIM"
  cv_put "$mcx" $(( SY + 2 )) "$K_DIM" "┴"; cv_put "$mcx" $(( SY + 1 )) "$K_DIM" "│"
  BY=$(( SY + 4 ))
  for (( b = 0; b < NB; b++ )); do
    c=$(( bx[b] + BW / 2 )); r="${SHOWN[b]}"
    cv_put "$c" $(( SY + 2 )) "$K_DIM" "●"; cv_put "$c" $(( SY + 3 )) "$K_DIM" "▼"
    ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
    st="$(role_state "$r")"
    bk="$K_ROLE"; stl=""; stk="$K_DIM"
    case "$st" in
      run*) IFS='|' read -r _ el _ <<<"$st"; (( el < 0 )) && el=0
            bk="$( (( TICK % 2 )) && echo "${C_BOLD}${C_CYAN}" || echo "$C_CYAN")"
            stl="${UI_SPIN[$(( TICK % 4 ))]} $(t "running") $(( el / 60 )):$(printf '%02d' $(( el % 60 )))"; stk="$C_YELLOW"
            # The dot travels down the arrow of a working role.
            cv_put "$c" $(( SY + 2 + TICK % 2 )) "$C_YELLOW" "●" ;;
      last*) IFS='|' read -r _ lst loc ldur _ <<<"$st"
            if [[ "$lst" != "ok" ]]; then stl="✗ $(t "failed")"; stk="$C_RED"
            elif [[ "$loc" == "partial" ]]; then stl="◐ $(t "partial")"; stk="$C_YELLOW"
            elif [[ "$loc" == "blocked" ]]; then stl="■ $(t "blocked")"; stk="$C_YELLOW"
            else d0="${ldur%.*}"; stl="✓ $(t "done") $(( ${d0:-0} / 60 )):$(printf '%02d' $(( ${d0:-0} % 60 )))"; stk="$C_GREEN"; fi ;;
      *) stl="· $(t "idle")" ;;
    esac
    cv_box "${bx[b]}" "$BY" "$BW" 9 "$bk"
    cv_center "${bx[b]}" $(( BY + 2 )) "$BW" "${C_BOLD}" "$(ai_role_label "$r" | tr 'A-Z' 'a-z')"
    cv_center "${bx[b]}" $(( BY + 3 )) "$BW" "$(color_of "$R_TIER")" "$R_MODEL"
    cv_center "${bx[b]}" $(( BY + 4 )) "$BW" "$K_DIM" "effort $(bars "$R_EFFORT") $(eff_short "$R_EFFORT")"
    cv_center "${bx[b]}" $(( BY + 5 )) "$BW" "$K_TXT" "$(action_of "$r")"
    cv_center "${bx[b]}" $(( BY + 6 )) "$BW" "$stk" "$stl"
    cv_vline "$c" $(( BY + 9 )) $(( BY + 10 )) "$K_DIM"
  done
  others=$(( $(printf '%s\n' $AI_ROLES | grep -vc '^lead$') - NB ))
  (( others > 0 )) && cv_right $(( W - 1 )) $(( BY + 10 )) "$K_DIM" "+$others $(t "roles") · loomy route"
  # Merge back to the lead agent.
  MGY=$(( BY + 11 ))
  cv_hline "$first_c" "$last_c" "$MGY" "$K_DIM"
  for (( b = 0; b < NB; b++ )); do cv_put $(( bx[b] + BW / 2 )) "$MGY" "$K_DIM" "●"; done
  cv_put "$mcx" "$MGY" "$K_DIM" "┬"
  cv_put "$mcx" $(( MGY + 2 )) "$K_DIM" "▼"; cv_put "$mcx" $(( MGY + 1 )) "$K_DIM" "│"
  BKY=$(( MGY + 3 )); BKW=38; BKX=$(( CX + (CWID - BKW) / 2 ))
  cv_box "$BKX" "$BKY" "$BKW" 4 "$K_LEAD"
  cv_center "$BKX" $(( BKY + 1 )) "$BKW" "${C_BOLD}${C_YELLOW}" "$(t "back to the lead agent") · $L_EFFORT"
  cv_center "$BKX" $(( BKY + 2 )) "$BKW" "$K_TXT" "$(t "review + verify")${phase:+ · $(loomy_phase_label "$phase")}"
  # Advisor column, linked to the lead box, the roles and the final check.
  if [[ -n "$ADV" ]]; then
    AH=$(( BKY + 4 - MY ))
    cv_box 0 "$MY" "$ADV_W" "$AH" "$K_ADV"
    cv_center 0 $(( MY + 1 )) "$ADV_W" "${C_BOLD}${C_MAGENTA}" "$adv_up"
    cv_center 0 $(( MY + 2 )) "$ADV_W" "$K_ADV" "$(t "advisor") · $(t "on call")"
    # The moment the advisor is most likely called now, from the phase and the last results.
    act="plan"
    case "$phase" in verify|commit|document|retire|validate|report|done) act="done" ;; esac
    printf '%s\n' "$STATES" | awk -F'|' '$1 == "LAST" && ($4 != "ok" || $7 == "partial" || $7 == "blocked")' | grep -q . && act="error"
    recent=0; [[ -n "$a_last" ]] && (( now_s - $(ai_ts_epoch "$a_last" || echo 0) < 90 )) && recent=1
    trig() {   # trig <code> <y> <label> <target x>
      local mk="◇" k="$K_DIM"
      [[ "$act" == "$1" ]] && { mk="◆"; k="${C_BOLD}${C_MAGENTA}"; }
      cv_put 3 "$2" "$k" "$mk $3"
      cv_hline "$ADV_W" $(( $4 - 2 )) "$2" "$K_DIM" "╌"; cv_put $(( $4 - 1 )) "$2" "$K_DIM" "▶"
      if [[ "$act" == "$1" ]] && (( recent )); then cv_put $(( ADV_W + (TICK * 3) % ( $4 - ADV_W - 2 ) )) "$2" "$C_MAGENTA" "●"; fi
    }
    trig plan $(( MY + 3 )) "$(t "before a plan")" "$MX"
    cv_put 4 $(( MY + 6 )) "$K_DIM" "$(t "reads the whole")"; cv_put 4 $(( MY + 7 )) "$K_DIM" "$(t "session, every")"
    cv_put 4 $(( MY + 8 )) "$K_DIM" "$(t "tool call and")"; cv_put 4 $(( MY + 9 )) "$K_DIM" "$(t "every result")"
    cv_put 4 $(( MY + 12 )) "$K_TXT" "$(t "calls")"; cv_right $(( ADV_W - 4 )) $(( MY + 12 )) "$K_B" "$a_n"
    cv_put 4 $(( MY + 13 )) "$K_TXT" "$(t "tokens read")"; cv_right $(( ADV_W - 4 )) $(( MY + 13 )) "$K_B" "$(ai_tokens_label "$a_tok")"
    [[ -n "$a_last" ]] && { cv_put 4 $(( MY + 14 )) "$K_TXT" "$(t "last")"; cv_right $(( ADV_W - 4 )) $(( MY + 14 )) "$K_B" "$(hm "$a_last" | cut -c1-5)"; }
    cv_put 4 $(( MY + 17 )) "$K_DIM" "$(t "silent on every")"; cv_put 4 $(( MY + 18 )) "$K_DIM" "$(t "routine turn")"
    trig error $(( BY + 4 )) "$(t "error repeats")" "${bx[0]}"
    cv_put 4 $(( BY + 7 )) "$K_DIM" "$(t "never writes")"; cv_put 4 $(( BY + 8 )) "$K_DIM" "$(t "code itself; the")"
    cv_put 4 $(( BY + 9 )) "$K_DIM" "$(t "lead agent applies")"; cv_put 4 $(( BY + 10 )) "$K_DIM" "$(t "the advice.")"
    trig "done" $(( BKY + 1 )) "$(t "before done")" "$BKX"
  fi
  # Session log box.
  LY=$(( BKY + 5 ))
  cv_box 0 "$LY" "$W" $(( LOGN + 2 )) "$K_DIM" "$(t "session log")"
  ly=$(( LY + 1 ))
  if rows="$(ai_session_log_rows "$ROOT" "$LOGN")"; then
    while IFS='|' read -r ts who what extra; do
      e="$(ai_ts_epoch "$ts")"; tm="${ts:11:8}"; [[ -n "$e" ]] && tm="$(hm "$ts")"
      case "$who" in advisor) wk="${C_BOLD}${C_MAGENTA}" ;; phase|session|lead) wk="${C_BOLD}${C_YELLOW}" ;; executor|explorer) wk="${C_BOLD}${C_GREEN}" ;; *) wk="${C_BOLD}${C_CYAN}" ;; esac
      if [[ "$who" == "phase" ]]; then [[ -n "$extra" ]] && loomy_phases_mode "$extra"; what="$(loomy_phase_label "$what")"; loomy_phases_mode project; extra=""
      else what="$(t "$what")"; fi
      left="${extra#* · }"; right="${extra%% · *}"; [[ "$left" == "$extra" ]] && left=""
      new=0; [[ -n "$e" ]] && (( now_s - e < 6 )) && new=1
      cv_put 2 "$ly" "$K_DIM" "$tm"
      cv_put 12 "$ly" "$wk" "$who"
      cv_put 24 "$ly" "$( (( new )) && echo "$C_BOLD")" "$what${left:+ · $left}"
      cv_right $(( W - 3 )) "$ly" "$K_DIM" "$right"
      (( new )) && cv_put 1 "$ly" "$C_YELLOW" "▸"
      ly=$(( ly + 1 ))
    done <<<"$rows"
  else
    cv_put 2 "$ly" "$K_DIM" "$(t "log empty for now")"
  fi
  # Command line and status bar.
  PY=$(( LY + LOGN + 3 ))
  tilde="~"
  cv_put 0 "$PY" "$C_GREEN" "$tilde/$(basename "$ROOT") \$"
  pname="$(basename "$ROOT")"
  cv_put $(( ${#pname} + 5 )) "$PY" "$K_TXT" "loomy watch$( (( TICK % 2 )) && echo " █")"
  n_run="$(printf '%s\n' "$STATES" | awk -F'|' '$1 == "RUN"' | while IFS='|' read -r _ _ pid _; do [[ -n "$pid" && "$pid" != 0 ]] && kill -0 "$pid" 2>/dev/null && echo x; done | grep -c x || true)"
  # Status bar: label, then its value in brackets, coloured like its part of the diagram.
  sx=0
  for seg in "effort|$L_EFFORT|$K_LEAD" "$(t "roles")|${n_run}/$(printf '%s\n' $AI_ROLES | grep -vc '^lead$')|$K_ROLE" "$(t "advisor")|$( [[ -n "$ADV" ]] && { (( recent )) && t "advising" || t "on call"; } || echo off)|$K_ADV" "$(t "delegations")|$n_tot|$K_ROUTE"; do
    IFS='|' read -r sl sv sk <<<"$seg"
    cv_put "$sx" $(( PY + 1 )) "$K_TXT" "$sl ["; sx=$(( sx + ${#sl} + 2 ))
    cv_put "$sx" $(( PY + 1 )) "${C_BOLD}$sk" "$sv"; sx=$(( sx + ${#sv} ))
    cv_put "$sx" $(( PY + 1 )) "$K_TXT" "]"; sx=$(( sx + 3 ))
  done
  CV_H=$(( PY + 2 ))
  cv_print "$(printf '%s  ' "${C_RAIL}│${C_RESET}")"
  [[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "$(t "live: loomy watch, then t")"
  exit 0
fi

ui_section "$(t "AGENT TREE")" "$(ai_env_label "$AI_ENV") · $(t "%s profile" "$(ai_profile_label "$AI_PROFILE")")"
(( TREE_SMALL )) && ui_rail "${C_DIM}$(t "diagram view: enlarge the window to %s × %s (now %s × %s), or key v" "$TREE_NEED_COLS" "$TREE_NEED_ROWS" "$UI_COLS" "$UI_ROWS")${C_RESET}"
ui_rail ""
lead_line="${C_BRAND}${C_BOLD}$(t "LEAD AGENT")${C_RESET}  $(color_of TOP)${L_MODEL}${C_RESET} · $L_EFFORT · $s_txt${phase:+ ${C_DIM}·${C_RESET} ${MISSION:+$MISSION · }$(loomy_phase_label "$phase")}"
ui_rail "┏━ $lead_line"
if [[ -n "$ADV" ]]; then
  a_n=0; a_last=""
  if [[ -s "$J" ]]; then
    read -r a_n a_last <<<"$(awk 'function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
      /"type":"advisor"/ { n += num("calls"); if (match($0, /"ts":"[^"]*"/)) l = substr($0, RSTART + 6, RLENGTH - 7) } END { print n + 0, l }' "$J")"
  fi
  # The advisor glows for a few seconds after a consultation was logged.
  glow="$C_MAGENTA"; [[ -n "$a_last" ]] && (( now_s - $(ai_ts_epoch "$a_last" || echo 0) < 30 )) && glow="${C_BOLD}${C_MAGENTA}"
  ui_rail "┃  ${glow}✦ $(t "advisor %s" "$ADV")${C_RESET} ${C_DIM}· $(t "%s consultation(s)" "$a_n")${a_last:+ · $(t "last %s" "$(hm "$a_last")")} · $(t "before a plan, when an error repeats, before done")${C_RESET}"
fi
ui_rail "┃"

# ---------------------------------------------------------------- roles
roles=(); for r in $AI_ROLES; do [[ "$r" == "lead" ]] || roles+=("$r"); done
n_roles=${#roles[@]}; i=0; n_run=0
for r in "${roles[@]}"; do
  i=$(( i + 1 ))
  ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
  branch="┣"; (( i == n_roles )) && branch="┗"
  run="$(printf '%s\n' "$STATES" | awk -F'|' -v r="$r" '$1 == "RUN" && $2 == r' | tail -1)"
  state=""; conn="━━"
  if [[ -n "$run" ]]; then
    IFS='|' read -r _ _ pid ts task <<<"$run"
    if [[ -n "$pid" && "$pid" != "0" ]] && kill -0 "$pid" 2>/dev/null; then
      n_run=$(( n_run + 1 ))
      el=$(( now_s - $(ai_ts_epoch "$ts" || echo "$now_s") )); (( el < 0 )) && el=0
      # A pulse travels along the branch while the role works.
      case $(( TICK % 3 )) in 0) conn="•━" ;; 1) conn="━•" ;; *) conn="━━" ;; esac
      state="${C_YELLOW}${UI_SPIN[$(( TICK % 4 ))]} $(t "running") $(( el / 60 )):$(printf '%02d' $(( el % 60 )))${C_RESET} ${C_DIM}${task}${C_RESET}"
      mark="${C_YELLOW}●${C_RESET}"
    fi
  fi
  if [[ -z "$state" ]]; then
    last="$(printf '%s\n' "$STATES" | awk -F'|' -v r="$r" '$1 == "LAST" && $2 == r' | tail -1)"
    if [[ -n "$last" ]]; then
      IFS="|" read -r _ _ lts lst ldur ltok loc _ lcnt <<<"$last"
      mark="${C_GREEN}✓${C_RESET}"; [[ "$lst" != "ok" ]] && mark="${C_RED}✗${C_RESET}"
      [[ "$lst" == "ok" && "$loc" == "partial" ]] && mark="${C_YELLOW}◐${C_RESET}"
      [[ "$lst" == "ok" && "$loc" == "blocked" ]] && mark="${C_YELLOW}■${C_RESET}"
      state="${C_DIM}$(t "done %s" "$(hm "$lts" | cut -c1-5)") · $(dur "$ldur") · $(ai_tokens_label "${ltok%.*}") tk · ×${lcnt}${C_RESET}"
    else
      mark="${C_DIM}○${C_RESET}"; state="${C_DIM}$(t "idle")${C_RESET}"
    fi
  fi
  _ui_pad "$(ai_role_label "$r")" 16; rl="$UI_PADDED"
  _ui_pad "$R_MODEL" 18; ml="$UI_PADDED"
  _ui_pad "$R_EFFORT" 7; el_="$UI_PADDED"
  ui_rail "${branch}${conn} ${mark} ${C_BOLD}${rl}${C_RESET}$(color_of "$R_TIER")${ml}${C_RESET}${el_}${state}"
done

# ---------------------------------------------------------------- session log
ui_rail ""
ui_rail "${C_DIM}── $(t "session log") ──${C_RESET}"
_ui_term_size
sl_n=$(( UI_ROWS - n_roles - 26 )); (( sl_n < 3 )) && sl_n=3; (( sl_n > 12 )) && sl_n=12
if sl="$(ai_session_log "$ROOT" "$sl_n")"; then
  while IFS= read -r l; do ui_rail "$l"; done <<<"$sl"
else
  ui_info "$(t "log empty for now")"
fi

# ---------------------------------------------------------------- status line
n_del=0; tok=0
[[ -s "$J" ]] && read -r n_del tok <<<"$(awk 'function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
  /"type":"delegation",/ { n++ } /"type":"(delegation|usage|advisor)"/ && !/delegation_start/ { t += num("tokens_in") + num("tokens_out") } END { print n + 0, t + 0 }' "$J")"
ui_rail ""
ui_rail "${C_BOLD}effort${C_RESET} [${L_EFFORT}]  ${C_BOLD}$(t "roles")${C_RESET} [$n_run/$n_roles $(t "running")]  ${C_BOLD}$(t "advisor")${C_RESET} [${ADV:-off}]  ${C_BOLD}$(t "delegations")${C_RESET} [$n_del]  ${C_BOLD}tokens${C_RESET} [$(ai_tokens_label "$tok")]"
[[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "$(t "live: loomy watch, then t")"
exit 0
