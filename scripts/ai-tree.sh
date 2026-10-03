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
# (computed below only for the list rendering; the diagram reads the log in its own single pass)

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

a_n=0; a_last=""; a_tok=0
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
TREE_NEED_COLS=124; TREE_NEED_ROWS=57; [[ -n "${LOOMY_NO_HEADER:-}" ]] && TREE_NEED_ROWS=64
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
  # Interface texts translated once per frame (no subshell per label).
  tv TR_0 "LOOMY AGENT TREE"
  tv TR_1 "LEADS"
  tv TR_2 "ON CALL"
  tv TR_3 "lead"
  tv TR_4 "routing"
  tv TR_5 "roles"
  tv TR_6 "by profile"
  tv TR_7 "advisor"
  tv TR_8 "main session"
  tv TR_9 "plans + decides"
  tv TR_10 "session open"
  tv TR_11 "session closed"
  tv TR_12 "delegations"
  tv TR_13 "top"
  tv TR_14 "standard"
  tv TR_15 "fast"
  tv TR_16 "delegate to roles"
  tv TR_17 "effort by profile"
  tv TR_18 "back to the lead agent"
  tv TR_19 "review + verify"
  tv TR_20 "on call"
  tv TR_21 "before a plan"
  tv TR_22 "reads the whole"
  tv TR_23 "session, every"
  tv TR_24 "tool call and"
  tv TR_25 "every result"
  tv TR_26 "calls"
  tv TR_27 "tokens read"
  tv TR_28 "last"
  tv TR_29 "silent on every"
  tv TR_30 "routine turn"
  tv TR_31 "error repeats"
  tv TR_32 "never writes"
  tv TR_33 "code itself; the"
  tv TR_34 "lead agent applies"
  tv TR_35 "the advice."
  tv TR_36 "before done"
  tv TR_37 "session log"
  tv TR_38 "log empty for now"
  tv TR_39 "live: loomy watch, then t"
  tv TR_40 "other roles"
  # Redrawn every second: helpers that write into variables instead of starting subprocesses.
  _tz="$(date +%z)"; TZOFF=$(( (10#${_tz:1:2} * 3600 + 10#${_tz:3:2} * 60) * ${_tz:0:1}1 ))
  ts2ep() {   # ISO UTC timestamp → EP (epoch), by calendar arithmetic
    local y=$(( 10#${1:0:4} )) m=$(( 10#${1:5:2} )) d=$(( 10#${1:8:2} )) H=$(( 10#${1:11:2} )) M=$(( 10#${1:14:2} )) S=$(( 10#${1:17:2} ))
    (( m <= 2 )) && { y=$(( y - 1 )); m=$(( m + 12 )); }
    EP=$(( (365 * y + y / 4 - y / 100 + y / 400 + (153 * (m - 3) + 2) / 5 + d - 719469) * 86400 + H * 3600 + M * 60 + S ))
  }
  hms() { local x; ts2ep "$1"; x=$(( (EP + TZOFF) % 86400 )); printf -v HMS '%02d:%02d:%02d' $(( x / 3600 )) $(( x % 3600 / 60 )) $(( x % 60 )); }
  toklbl() { local n="${1%.*}"; n="${n:-0}"; if (( n >= 1000000 )); then printf -v TOK '%d.%dM' $(( n / 1000000 )) $(( n % 1000000 / 100000 )); elif (( n >= 1000 )); then printf -v TOK '%d.%dk' $(( n / 1000 )) $(( n % 1000 / 100 )); else TOK="$n"; fi; }
  # One pass over the log: running and last delegation per role, delegations per tier, advisor consultations.
  RS_ROLE=(); RS_KIND=(); RS_A=(); RS_B=(); RS_C=(); RS_D=(); n_tot=0; T_TOP=0; T_MID=0; T_FAST=0
  if [[ -s "$J" ]]; then
    while IFS='|' read -r kind a b c d e; do
      case "$kind" in
        RUN|LAST) RS_ROLE+=("$a"); RS_KIND+=("$kind"); RS_A+=("$b"); RS_B+=("$c"); RS_C+=("$d"); RS_D+=("$e") ;;
        TOT) n_tot="$a"; T_TOP="$b"; T_MID="$c"; T_FAST="$d" ;;
        ADV) a_n="$a"; a_tok="$b"; a_last="$c" ;;
      esac
    done < <(awk -v ta=" $AI_MODEL_CLAUDE_TOP $AI_MODEL_CODEX_TOP " -v tb=" $AI_MODEL_CLAUDE_MID $AI_MODEL_CODEX_MID " -v tc=" $AI_MODEL_CLAUDE_FAST $AI_MODEL_CODEX_FAST " '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
      /"type":"delegation_start"/ { id = field("id"); srole[id] = field("role"); sts[id] = field("ts"); spid[id] = num("pid"); stask[id] = substr(field("task"), 1, 50); order[++n] = id }
      /"type":"delegation",/ { id = field("id"); fin[id] = 1; r = field("role"); m = " " field("model") " "
        last[r] = field("status") "|" field("outcome") "|" num("duration_s") "|" field("ts"); tot++
        if (index(ta, m)) t1++; else if (index(tb, m)) t2++; else if (index(tc, m)) t3++ }
      /"type":"advisor"/ { an += num("calls"); at += num("tokens_in"); al = field("ts") }
      END {
        for (i = 1; i <= n; i++) { id = order[i]; if (!(id in fin)) print "RUN|" srole[id] "|" spid[id] "|" sts[id] "|" stask[id] "|" }
        for (r in last) print "LAST|" r "|" last[r]
        print "TOT|" tot + 0 "|" t1 + 0 "|" t2 + 0 "|" t3 + 0 "||"
        print "ADV|" an + 0 "|" at + 0 "|" al "|||" }' "$J")
  fi
  # role_state_fast <role>: RS_K (run, last or idle) and its fields, without subprocess.
  role_state_fast() {
    local i n=${#RS_ROLE[@]}
    RS_K="idle"
    for (( i = n - 1; i >= 0; i-- )); do
      [[ "${RS_ROLE[i]}" == "$1" ]] || continue
      if [[ "${RS_KIND[i]}" == "RUN" ]]; then
        if [[ -n "${RS_A[i]}" && "${RS_A[i]}" != "0" ]] && kill -0 "${RS_A[i]}" 2>/dev/null; then
          ts2ep "${RS_B[i]}"; RS_EL=$(( now_s - EP )); RS_K="run"; return 0
        fi
      elif [[ "$RS_K" == "idle" ]]; then
        RS_K="last"; RS_ST="${RS_A[i]}"; RS_OC="${RS_B[i]}"; RS_DUR="${RS_C[i]}"
      fi
    done
  }
  # Wide terminals show more role boxes (up to every role), never stretched past what they need.
  (( W > 216 )) && W=216
  K_LEAD="$C_YELLOW"; K_ROUTE="$C_GREEN"; K_ROLE="$C_CYAN"; K_ADV="$C_MAGENTA"; K_DIM="$C_DIM"; K_TXT=""; K_B="$C_BOLD"
  bars() { case "$1" in low) BARS="▮▯▯▯" ;; medium) BARS="▮▮▯▯" ;; high) BARS="▮▮▮▯" ;; *) BARS="▮▮▮▮" ;; esac; }
  eff_short() { case "$1" in medium) EFS="med" ;; *) EFS="$1" ;; esac; }
  color_tier() { case "$1" in TOP) CT="$C_MAGENTA" ;; FAST) CT="$C_GREEN" ;; *) CT="$C_CYAN" ;; esac; }
  action_of() {
    case "$1" in
      architect) tv ACT "designs the plan" ;; debugger) tv ACT "finds the cause" ;; security) tv ACT "checks the risks" ;;
      reviewer) tv ACT "reviews the diff" ;; developer) tv ACT "edits + runs tests" ;; executor) tv ACT "runs bounded tasks" ;;
      explorer) tv ACT "reads the code" ;; documenter) tv ACT "writes the docs" ;; *) ACT="$1" ;;
    esac
  }
  role_lbl() {
    case "$1" in
      architect) tv RL "Architect" ;; debugger) tv RL "Debugger" ;; security) tv RL "Security" ;; reviewer) tv RL "Reviewer" ;;
      developer) tv RL "Developer" ;; executor) tv RL "Executor" ;; explorer) tv RL "Explorer" ;; documenter) tv RL "Documenter" ;; *) RL="$1" ;;
    esac
    # First letter in lower case, as in the boxes.
    local f="${RL:0:1}" up="ABCDEFGHIJKLMNOPQRSTUVWXYZ" lo="abcdefghijklmnopqrstuvwxyz" i
    case "$f" in [A-Z]) i="${up%%"$f"*}"; RL="${lo:${#i}:1}${RL:1}" ;; É) RL="é${RL:1}" ;; esac
  }
  NROLES=0; for r in $AI_ROLES; do [[ "$r" == lead ]] || NROLES=$(( NROLES + 1 )); done
  # Roles shown as boxes: running ones first, then the most recently used, then the usual workers.
  pick=""
  run_roles=""; last_roles=""; n_run=0
  for (( i = 0; i < ${#RS_ROLE[@]}; i++ )); do
    if [[ "${RS_KIND[i]}" == RUN ]]; then
      if [[ -n "${RS_A[i]}" && "${RS_A[i]}" != 0 ]] && kill -0 "${RS_A[i]}" 2>/dev/null; then run_roles="$run_roles ${RS_ROLE[i]}"; n_run=$(( n_run + 1 )); fi
    else last_roles="$last_roles ${RS_D[i]}|${RS_ROLE[i]}"; fi
  done
  # Most recent first (one sort for the whole frame).
  [[ -n "$last_roles" ]] && last_roles="$(printf '%s\n' $last_roles | sort -r | cut -d'|' -f2)"
  for r in $run_roles $last_roles developer reviewer executor explorer architect $AI_ROLES; do
    case " $pick " in *" $r "*) continue ;; esac
    case " $AI_ROLES " in *" $r "*) [[ "$r" != "lead" ]] && pick="$pick $r" ;; esac
  done
  ADV_W=0; recent=0; [[ -n "$ADV" ]] && ADV_W=26
  CX=$(( ADV_W > 0 ? ADV_W + 6 : 0 )); CWID=$(( W - CX ))
  BW=22; NB=$(( (CWID + 4) / (BW + 4) )); (( NB > NROLES )) && NB=$NROLES; (( NB < 2 )) && NB=2
  read -r -a SHOWN <<<"$pick"; SHOWN=("${SHOWN[@]:0:$NB}")
  NB=${#SHOWN[@]}
  _ui_term_size
  LOGN=$(( UI_ROWS - 53 )); (( LOGN < 4 )) && LOGN=4; (( LOGN > 8 )) && LOGN=8
  H=$(( 57 + LOGN ))
  cv_init "$W" "$H"
  # Title, rule, legend.
  # Advisor alias → the model it stands for (opus → Opus 5.5).
  case "$ADV" in opus) adv_model="$AI_MODEL_CLAUDE_TOP" ;; sonnet) adv_model="$AI_MODEL_CLAUDE_MID" ;; fable) adv_model="claude-fable-5-1" ;; *) adv_model="$ADV" ;; esac
  nice_model() { printf '%s' "$1" | sed 's/^claude-//; s/-\([0-9]\)-\([0-9]\)$/ \1.\2/; s/^gpt-/GPT-/' | tr 'a-z' 'A-Z'; }
  adv_up="$(nice_model "$adv_model")"
  NM_LEAD="$(nice_model "$L_MODEL")"
  title="${TR_0}  ·  $NM_LEAD ${TR_1}${ADV:+  ·  $adv_up ${TR_2}}"
  # A blank row above the title, then the title and its rule.
  cv_center 0 1 "$W" "$K_B" "$title"
  cv_hline 2 $(( W - 3 )) 2 "$K_DIM"
  litems=("$K_LEAD|${TR_3} · $L_EFFORT" "$K_ROUTE|${TR_4} · $(ai_profile_label "$AI_PROFILE")" "$K_ROLE|${TR_5} · ${TR_6}")
  [[ -n "$ADV" ]] && litems+=("$K_ADV|${TR_7} · $ADV")
  ltot=0; for it in "${litems[@]}"; do lt="${it#*|}"; ltot=$(( ltot + ${#lt} + 5 )); done
  lp=$(( (W - ltot) / 2 ))
  for it in "${litems[@]}"; do lt="${it#*|}"; cv_put "$lp" 4 "${it%%|*}" "■"; cv_put $(( lp + 2 )) 4 "$K_DIM" "$lt"; lp=$(( lp + ${#lt} + 5 )); done
  # Lead agent box.
  # One vertical axis for the lead, routing and back boxes and the links between them: every box is centred on it.
  CC=$(( CX + CWID / 2 ))
  MW=38; MX=$(( CC - MW / 2 )); MY=6
  mcx=$CC
  lk="$K_LEAD"; [[ "$sess" == open* ]] && (( TICK % 2 )) && lk="${C_BOLD}${C_YELLOW}"
  cv_box "$MX" "$MY" "$MW" 6 "$lk"
  cv_center "$MX" $(( MY + 1 )) "$MW" "${C_BOLD}${C_YELLOW}" "$NM_LEAD · ${TR_8}"
  cv_center "$MX" $(( MY + 2 )) "$MW" "$K_TXT" "${TR_9}"
  bars "$L_EFFORT"; cv_center "$MX" $(( MY + 3 )) "$MW" "$K_TXT" "effort $BARS $L_EFFORT"
  PH_LBL=""; [[ -n "$phase" ]] && PH_LBL="$(loomy_phase_label "$phase")"
  if [[ "$sess" == open* ]]; then sk="$C_GREEN"; st_txt="● ${TR_10}"; else sk="$K_DIM"; st_txt="○ ${TR_11}"; fi
  cv_center "$MX" $(( MY + 4 )) "$MW" "$sk" "$st_txt${PH_LBL:+ · $PH_LBL}"
  # Connector lead → routing, with a travelling dot.
  cv_vline "$mcx" $(( MY + 6 )) $(( MY + 7 )) "$K_DIM"
  cv_put "$mcx" $(( MY + 6 + TICK % 2 )) "$K_LEAD" "●"
  # Routing layer: delegations per tier (Loomy's routing, where the video has Jev).
  RW=56; RX=$(( CC - RW / 2 )); RY=$(( MY + 8 ))
  cv_box "$RX" "$RY" "$RW" 6 "$K_ROUTE"
  cv_put $(( RX + 2 )) $(( RY + 1 )) "${C_BOLD}${C_GREEN}" "LOOMY · ${TR_4}"
  cv_right $(( RX + RW - 3 )) $(( RY + 1 )) "$K_TXT" "${TR_12} $n_tot"
  ry=$(( RY + 2 ))
  for tier in TOP MID FAST; do
    cnt=0; case "$tier" in TOP) cnt="$T_TOP" ;; MID) cnt="$T_MID" ;; *) cnt="$T_FAST" ;; esac
    if [[ "$tier" == TOP ]]; then lbl="${TR_13}"; elif [[ "$tier" == MID ]]; then lbl="${TR_14}"; else lbl="${TR_15}"; fi
    fill=0; (( n_tot > 0 )) && fill=$(( cnt * 10 / n_tot ))
    bar=""; for (( q = 0; q < 10; q++ )); do if (( q < fill )); then bar="${bar}█"; else bar="${bar}░"; fi; done
    cv_put $(( RX + 2 )) "$ry" "$K_TXT" "$lbl"
    cv_put $(( RX + 13 )) "$ry" "$K_ROUTE" "$bar"
    cv_put $(( RX + 25 )) "$ry" "$K_TXT" "$cnt"
    v1="AI_MODEL_CLAUDE_${tier}"; v2="AI_MODEL_CODEX_${tier}"; m1="${!v1}"; m2="${!v2}"; mods="${m1#claude-} · ${m2#gpt-}"
    cv_right $(( RX + RW - 3 )) "$ry" "$K_DIM" "$mods"
    ry=$(( ry + 1 ))
  done
  # Delegate to roles: label, split with nodes, arrows.
  cv_vline "$mcx" $(( RY + 6 )) $(( RY + 7 )) "$K_DIM"; cv_put "$mcx" $(( RY + 7 )) "$K_DIM" "●"
  SY=$(( RY + 9 ))
  cv_center "$CX" "$SY" "$CWID" "$K_TXT" "${TR_16} · ${TR_17}"
  # Role boxes spread symmetrically around the axis (an even step keeps every centre on a whole column).
  GAP=$(( (CWID - NB * BW) / (NB + 1) )); (( GAP < 2 )) && GAP=2; (( GAP % 2 )) && GAP=$(( GAP - 1 ))
  STEP=$(( BW + GAP ))
  bx=(); for (( b = 0; b < NB; b++ )); do bx[b]=$(( CC + (2 * b - (NB - 1)) * STEP / 2 - BW / 2 )); done
  first_c=$(( bx[0] + BW / 2 )); last_c=$(( bx[NB - 1] + BW / 2 ))
  cv_hline "$first_c" "$last_c" $(( SY + 2 )) "$K_DIM"
  cv_vline "$mcx" $(( SY + 1 )) $(( SY + 1 )) "$K_DIM"
  BY=$(( SY + 4 ))
  for (( b = 0; b < NB; b++ )); do
    c=$(( bx[b] + BW / 2 )); r="${SHOWN[b]}"
    cv_put "$c" $(( SY + 2 )) "$K_DIM" "●"; cv_put "$c" $(( SY + 3 )) "$K_DIM" "▼"
    ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
    role_state_fast "$r"
    bk="$K_ROLE"; stl=""; stk="$K_DIM"
    case "$RS_K" in
      run) el="$RS_EL"; (( el < 0 )) && el=0
            if (( TICK % 2 )); then bk="${C_BOLD}${C_CYAN}"; else bk="$C_CYAN"; fi
            w_run=""; tv w_run "running"; printf -v stl '%s %s %d:%02d' "${UI_SPIN[$(( TICK % 4 ))]}" "$w_run" $(( el / 60 )) $(( el % 60 )); stk="$C_YELLOW"
            # The dot travels down the arrow of a working role.
            cv_put "$c" $(( SY + 2 + TICK % 2 )) "$C_YELLOW" "●" ;;
      last) d0="${RS_DUR%.*}"; d0="${d0:-0}"
            if [[ "$RS_ST" != "ok" ]]; then tv w "failed"; stl="✗ $w"; stk="$C_RED"
            elif [[ "$RS_OC" == "partial" ]]; then tv w "partial"; stl="◐ $w"; stk="$C_YELLOW"
            elif [[ "$RS_OC" == "blocked" ]]; then tv w "blocked"; stl="■ $w"; stk="$C_YELLOW"
            else tv w "done"; printf -v stl '✓ %s %d:%02d' "$w" $(( d0 / 60 )) $(( d0 % 60 )); stk="$C_GREEN"; fi ;;
      *) tv w "idle"; stl="· $w" ;;
    esac
    cv_box "${bx[b]}" "$BY" "$BW" 9 "$bk"
    role_lbl "$r"; color_tier "$R_TIER"; bars "$R_EFFORT"; eff_short "$R_EFFORT"; action_of "$r"
    cv_center "${bx[b]}" $(( BY + 2 )) "$BW" "${C_BOLD}" "$RL"
    cv_center "${bx[b]}" $(( BY + 3 )) "$BW" "$CT" "$R_MODEL"
    cv_center "${bx[b]}" $(( BY + 4 )) "$BW" "$K_DIM" "effort $BARS $EFS"
    cv_center "${bx[b]}" $(( BY + 5 )) "$BW" "$K_TXT" "$ACT"
    cv_center "${bx[b]}" $(( BY + 6 )) "$BW" "$stk" "$stl"
    cv_vline "$c" $(( BY + 9 )) $(( BY + 10 )) "$K_DIM"
  done
  # Merge back to the lead agent.
  MGY=$(( BY + 11 ))
  cv_hline "$first_c" "$last_c" "$MGY" "$K_DIM"
  for (( b = 0; b < NB; b++ )); do cv_put $(( bx[b] + BW / 2 )) "$MGY" "$K_DIM" "●"; done
  :
  cv_vline "$mcx" $(( MGY + 1 )) $(( MGY + 1 )) "$K_DIM"; cv_put "$mcx" $(( MGY + 2 )) "$K_DIM" "▼"
  BKY=$(( MGY + 3 )); BKW=38; BKX=$(( CC - BKW / 2 ))
  cv_box "$BKX" "$BKY" "$BKW" 4 "$K_LEAD"
  cv_center "$BKX" $(( BKY + 1 )) "$BKW" "${C_BOLD}${C_YELLOW}" "${TR_18} · $L_EFFORT"
  cv_center "$BKX" $(( BKY + 2 )) "$BKW" "$K_TXT" "${TR_19}${PH_LBL:+ · $PH_LBL}"
  # The roles without a box, listed beside the final check when there is room (state, name, model), else counted.
  rest=(); for r in $pick; do case " ${SHOWN[*]} " in *" $r "*) ;; *) rest+=("$r") ;; esac; done
  if (( ${#rest[@]} )); then
    OX=$(( BKX + BKW + 4 )); OW=$(( W - 2 - OX )); (( OW > 38 )) && OW=38; OY=$(( MGY + 1 )); orows=$(( BKY + 3 - OY ))
    if (( OW >= 18 )); then
      cv_put "$OX" "$OY" "$K_DIM" "${TR_40} · loomy route"
      oy=$(( OY + 1 )); k=0
      for r in "${rest[@]}"; do
        if (( oy == OY + orows && k < ${#rest[@]} - 1 )); then cv_put "$OX" "$oy" "$K_DIM" "+$(( ${#rest[@]} - k )) ${TR_5}"; break; fi
        ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"; role_state_fast "$r"; role_lbl "$r"; color_tier "$R_TIER"
        case "$RS_K" in
          run) og="${UI_SPIN[$(( TICK % 4 ))]}"; ok_="$C_YELLOW" ;;
          last) if [[ "$RS_ST" != ok ]]; then og="✗"; ok_="$C_RED"; elif [[ "$RS_OC" == partial || "$RS_OC" == blocked ]]; then og="◐"; ok_="$C_YELLOW"; else og="✓"; ok_="$C_GREEN"; fi ;;
          *) og="·"; ok_="$K_DIM" ;;
        esac
        cv_put "$OX" "$oy" "$ok_" "$og"
        cv_put $(( OX + 2 )) "$oy" "$K_TXT" "$RL"
        om="$R_MODEL"; ol=$(( OW - 4 - ${#RL} )); (( ${#om} > ol )) && om="${om:0:$(( ol > 1 ? ol - 1 : 0 ))}…"
        (( ol > 2 )) && cv_right $(( OX + OW - 1 )) "$oy" "$CT" "$om"
        oy=$(( oy + 1 )); k=$(( k + 1 ))
      done
    else
      cv_right $(( W - 1 )) $(( BY + 10 )) "$K_DIM" "+${#rest[@]} ${TR_5} · loomy route"
    fi
  fi
  # Advisor column, linked to the lead box, the roles and the final check.
  if [[ -n "$ADV" ]]; then
    AH=$(( BKY + 4 - MY ))
    cv_box 0 "$MY" "$ADV_W" "$AH" "$K_ADV"
    cv_center 0 $(( MY + 1 )) "$ADV_W" "${C_BOLD}${C_MAGENTA}" "$adv_up"
    cv_center 0 $(( MY + 2 )) "$ADV_W" "$K_ADV" "${TR_7} · ${TR_20}"
    # The moment the advisor is most likely called now, from the phase and the last results.
    act="plan"
    case "$phase" in verify|commit|document|retire|validate|report|done) act="done" ;; esac
    for (( i = 0; i < ${#RS_ROLE[@]}; i++ )); do [[ "${RS_KIND[i]}" == LAST ]] && { [[ "${RS_A[i]}" != ok || "${RS_B[i]}" == partial || "${RS_B[i]}" == blocked ]]; } && act="error"; done
    recent=0; if [[ -n "$a_last" ]]; then ts2ep "$a_last"; (( now_s - EP < 90 )) && recent=1; fi
    trig() {   # trig <code> <y> <label> <target x>
      local mk="◇" k="$K_DIM"
      [[ "$act" == "$1" ]] && { mk="◆"; k="${C_BOLD}${C_MAGENTA}"; }
      cv_put 3 "$2" "$k" "$mk $3"
      cv_hline "$ADV_W" $(( $4 - 2 )) "$2" "$K_DIM" "╌"; cv_put $(( $4 - 1 )) "$2" "$K_DIM" "▶"
      if [[ "$act" == "$1" ]] && (( recent )); then cv_put $(( ADV_W + (TICK * 3) % ( $4 - ADV_W - 2 ) )) "$2" "$C_MAGENTA" "●"; fi
    }
    trig plan $(( MY + 3 )) "${TR_21}" "$MX"
    cv_put 4 $(( MY + 6 )) "$K_DIM" "${TR_22}"; cv_put 4 $(( MY + 7 )) "$K_DIM" "${TR_23}"
    cv_put 4 $(( MY + 8 )) "$K_DIM" "${TR_24}"; cv_put 4 $(( MY + 9 )) "$K_DIM" "${TR_25}"
    cv_put 4 $(( MY + 12 )) "$K_TXT" "${TR_26}"; cv_right $(( ADV_W - 4 )) $(( MY + 12 )) "$K_B" "$a_n"
    toklbl "$a_tok"
    cv_put 4 $(( MY + 13 )) "$K_TXT" "${TR_27}"; cv_right $(( ADV_W - 4 )) $(( MY + 13 )) "$K_B" "$TOK"
    [[ -n "$a_last" ]] && hms "$a_last" && { cv_put 4 $(( MY + 14 )) "$K_TXT" "${TR_28}"; cv_right $(( ADV_W - 4 )) $(( MY + 14 )) "$K_B" "${HMS:0:5}"; }
    cv_put 4 $(( MY + 17 )) "$K_DIM" "${TR_29}"; cv_put 4 $(( MY + 18 )) "$K_DIM" "${TR_30}"
    trig error $(( BY + 4 )) "${TR_31}" "${bx[0]}"
    cv_put 4 $(( BY + 7 )) "$K_DIM" "${TR_32}"; cv_put 4 $(( BY + 8 )) "$K_DIM" "${TR_33}"
    cv_put 4 $(( BY + 9 )) "$K_DIM" "${TR_34}"; cv_put 4 $(( BY + 10 )) "$K_DIM" "${TR_35}"
    trig "done" $(( BKY + 1 )) "${TR_36}" "$BKX"
  fi
  # Session log box.
  LY=$(( BKY + 5 ))
  cv_box 0 "$LY" "$W" $(( LOGN + 2 )) "$K_DIM" "${TR_37}"
  ly=$(( LY + 1 ))
  if rows="$(ai_session_log_rows "$ROOT" "$LOGN")"; then
    while IFS='|' read -r ts who what extra; do
      tm="${ts:11:8}"; e=""
      if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then hms "$ts"; tm="$HMS"; e="$EP"; fi
      case "$who" in advisor) wk="${C_BOLD}${C_MAGENTA}" ;; phase|session|lead) wk="${C_BOLD}${C_YELLOW}" ;; executor|explorer) wk="${C_BOLD}${C_GREEN}" ;; *) wk="${C_BOLD}${C_CYAN}" ;; esac
      if [[ "$who" == "phase" ]]; then [[ -n "$extra" ]] && loomy_phases_mode "$extra"; what="$(loomy_phase_label "$what")"; loomy_phases_mode project; extra=""
      else tv what "$what"; fi
      left="${extra#* · }"; right="${extra%% · *}"; [[ "$left" == "$extra" ]] && left=""
      new=0; [[ -n "$e" ]] && (( now_s - e < 6 )) && new=1
      cv_put 2 "$ly" "$K_DIM" "$tm"
      cv_put 12 "$ly" "$wk" "$who"
      nb=""; (( new )) && nb="$C_BOLD"
      cv_put 24 "$ly" "$nb" "$what${left:+ · $left}"
      cv_right $(( W - 3 )) "$ly" "$K_DIM" "$right"
      (( new )) && cv_put 1 "$ly" "$C_YELLOW" "▸"
      ly=$(( ly + 1 ))
    done <<<"$rows"
  else
    cv_put 2 "$ly" "$K_DIM" "${TR_38}"
  fi
  # Command line and status bar.
  PY=$(( LY + LOGN + 3 ))
  tilde="~"
  pname="${ROOT##*/}"
  cv_put 0 "$PY" "$C_GREEN" "$tilde/$pname \$"
  cur=""; (( TICK % 2 )) && cur=" █"
  cv_put $(( ${#pname} + 5 )) "$PY" "$K_TXT" "loomy watch$cur"
  # Status bar: label, then its value in brackets, coloured like its part of the diagram.
  sx=0
  adv_state="off"; if [[ -n "$ADV" ]]; then if (( recent )); then tv adv_state "advising"; else tv adv_state "on call"; fi; fi
  for seg in "effort|$L_EFFORT|$K_LEAD" "${TR_5}|${n_run}/${NROLES}|$K_ROLE" "${TR_7}|${adv_state}|$K_ADV" "${TR_12}|$n_tot|$K_ROUTE"; do
    IFS='|' read -r sl sv sk <<<"$seg"
    cv_put "$sx" $(( PY + 1 )) "$K_TXT" "$sl ["; sx=$(( sx + ${#sl} + 2 ))
    cv_put "$sx" $(( PY + 1 )) "${C_BOLD}$sk" "$sv"; sx=$(( sx + ${#sv} ))
    cv_put "$sx" $(( PY + 1 )) "$K_TXT" "]"; sx=$(( sx + 3 ))
  done
  CV_H=$(( PY + 2 ))
  cv_junctions
  printf -v cvp '%s  ' "${C_RAIL}│${C_RESET}"
  cv_print "$cvp"
  [[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "${TR_39}"
  exit 0
fi

# ---------------------------------------------------------------- list rendering
STATES="$( [[ -s "$J" ]] && awk '
  function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
  function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
  /"type":"delegation_start"/ { id = field("id"); srole[id] = field("role"); sts[id] = field("ts"); spid[id] = num("pid"); stask[id] = substr(field("task"), 1, 50); order[++n] = id }
  /"type":"delegation",/ { id = field("id"); fin[id] = 1; r = field("role")
    last[r] = field("ts") "|" field("status") "|" num("duration_s") "|" (num("tokens_in") + num("tokens_out")) "|" field("outcome") "|" field("model"); cnt[r]++ }
  END {
    for (i = 1; i <= n; i++) { id = order[i]; if (!(id in fin)) print "RUN|" srole[id] "|" spid[id] "|" sts[id] "|" stask[id] }
    for (r in last) print "LAST|" r "|" last[r] "|" cnt[r] }' "$J")"
if [[ -s "$J" ]]; then
  read -r a_n a_tok a_last <<<"$(awk 'function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    /"type":"advisor"/ { n += num("calls"); tk += num("tokens_in"); if (match($0, /"ts":"[^"]*"/)) l = substr($0, RSTART + 6, RLENGTH - 7) } END { print n + 0, tk + 0, l }' "$J")"
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
