#!/usr/bin/env bash
# Agent tree: the lead agent, its advisor and every routed role with its model, effort and live state, then the session
# log and a status line. Shown by loomy watch (key t); loomy tree prints it once. Bash 3.2 compatible.
#   loomy-tree.sh [--root <dir>]
set -uo pipefail

# Read the native-agent timeout once; malformed values use the two-hour default.
LOOMY_SUBAGENT_MAX_S="${LOOMY_SUBAGENT_MAX_S:-7200}"
if [[ "$LOOMY_SUBAGENT_MAX_S" =~ ^[0-9]+$ ]]; then
  LOOMY_SUBAGENT_MAX_S="$(printf '%s' "$LOOMY_SUBAGENT_MAX_S" | sed 's/^0*//')"
  [[ -n "$LOOMY_SUBAGENT_MAX_S" ]] || LOOMY_SUBAGENT_MAX_S=0
else
  LOOMY_SUBAGENT_MAX_S=7200
fi

# Live reducer: kept in the watch process, updated only from complete new JSON lines.
loomy_live_init() {
  LV_SELECTION=""; LV_SELECTED_SEQ=0; LV_ROLE_WIDTH=12; LV_OFFSET=0; LV_FILE_KEY=""; LV_SEQ=0; LV_SESSION_SEQ=0; LV_SESSION=""; LV_SESSION_PID=0; LV_SESSION_TOOL=""; LV_SESSION_OPEN=0; LV_ACTIVITY=0; LV_USAGE=0; LV_SESSION_MODEL=""; LV_SESSION_EFFORT=""; LV_META_READY=0
  LV_TOOL=(); LV_BRIDGE=(); LV_REQUESTED=(); LV_OFF=(); LV_LABEL=(); LV_BAR=(); LV_WORD=(); LV_MODELSHORT=(); LV_FLAGS=(); LV_ID=(); LV_ROLE=(); LV_MODEL=(); LV_EFFORT=(); LV_TASK=(); LV_PID=(); LV_TS=(); LV_REQ=(); LV_START_SEQ=(); LV_SID=()
  LV_FIN=(); LV_DURATION=(); LV_COST=(); LV_OUTCOME=(); LV_STATUS=(); LV_END_SEQ=(); LV_EVENT_TS=(); LV_AGENT_ID=(); LV_HAS_START=()
  LV_REQ_ID=(); LV_REQ_TEXT=(); LV_REQ_TS=(); LV_REQ_SID=(); LV_REQUEST=-1
  LV_DONE=0; LV_ERRORS=0; LV_ACTIVE=0; LV_RUNNING=(); LV_FINISHED=()
}

# loomy_live_poll <journal>: inode and offset also detect rotation/truncation. An incomplete append is retried.
loomy_live_poll() {
  local file="$1" kind ts id event sid pid tool role model effort task status duration cost outcome excerpt requested offroute bridge costin scope agentid key off i found selection selected attributed
  while IFS='|' read -r kind ts id event sid pid tool role model effort task status duration cost outcome excerpt requested offroute bridge costin scope agentid; do
    case "$kind" in
      RESET) loomy_live_init; continue ;;
      OFFSET) LV_FILE_KEY="$ts"; LV_OFFSET="$id"; continue ;;
      SELECT) LV_SELECTION="$ts"; LV_SELECTED_SEQ="$id"; continue ;;
    esac
    LV_SEQ=$(( LV_SEQ + 1 ))
    for (( i=0; i<${#LV_ID[@]}; i++ )); do
      [[ -z "$sid" || "${LV_SID[i]:-}" == "$sid" ]] || continue
      attributed=0
      [[ -z "$id" || "$id" != "${LV_ID[i]}" ]] || attributed=1
      [[ -z "$agentid" || -z "${LV_AGENT_ID[i]:-}" || "$agentid" != "${LV_AGENT_ID[i]}" ]] || attributed=1
      if [[ "$kind" == pid_dead || "$kind" == process_dead || "$kind" == delegation_pid_dead ]]; then
        [[ -z "$pid" || "$pid" != "${LV_PID[i]}" ]] || attributed=1
      fi
      if (( attributed )) && [[ "$kind" != delegation_start && "$ts" =~ ^[0-9]+$ ]] && (( ts > 0 )); then
        LV_EVENT_TS[i]="$ts"
        if [[ "${LV_STATUS[i]:-}" == interrupted ]]; then loomy_live_interrupted_duration "$i"; LV_END_SEQ[i]=$LV_SEQ; fi
      fi
      if [[ "$kind" == subagent_link && "$id" == "${LV_ID[i]}" && -n "$agentid" ]]; then LV_AGENT_ID[i]="$agentid"; fi
    done
    case "$kind:$event" in
      session:start) (( LV_SEQ == LV_SELECTED_SEQ )) || continue
        selection=$LV_SELECTION; selected=$LV_SELECTED_SEQ; key=$LV_FILE_KEY; off=$LV_OFFSET; i=$LV_SEQ; loomy_live_init; LV_FILE_KEY=$key; LV_OFFSET=$off; LV_SEQ=$i; LV_SELECTION=$selection; LV_SELECTED_SEQ=$selected; LV_SESSION_SEQ=$LV_SEQ; LV_SESSION="$sid"; LV_SESSION_PID="$pid"; LV_SESSION_TOOL="$tool"; LV_SESSION_MODEL="$model"; LV_SESSION_EFFORT="$effort"; LV_SESSION_OPEN=1; LV_REQUEST=-1 ;;
      session:end)
        [[ "$tool" == "$LV_SESSION_TOOL" ]] || continue
        if [[ -n "$sid" ]]; then [[ "$sid" != "$LV_SESSION" ]] || LV_SESSION_OPEN=0
        elif [[ "$pid" == "$LV_SESSION_PID" ]]; then LV_SESSION_OPEN=0; fi ;;
      usage:*)
        [[ -z "$sid" || -z "$LV_SESSION" || "$sid" == "$LV_SESSION" ]] || continue
        LV_USAGE=$(( LV_USAGE + ${cost:-0} ))
        if [[ "$scope" == lead && "$tool" == "$LV_SESSION_TOOL" ]]; then LV_ACTIVITY=$ts; LV_SESSION_MODEL="$model"; [[ -z "$effort" ]] || LV_SESSION_EFFORT="$effort"; fi ;;
      request:*)
        [[ -z "$sid" || -z "$LV_SESSION" || "$sid" == "$LV_SESSION" ]] || continue
        LV_ACTIVITY=$ts
        ai_task_title "$excerpt" 90; LV_REQ_ID+=("$id"); LV_REQ_TEXT+=("$AI_TASK_TITLE"); LV_REQ_TS+=("$ts"); LV_REQ_SID+=("$sid"); LV_REQUEST=$(( ${#LV_REQ_ID[@]} - 1 )) ;;
      delegation_start:*)
        [[ -z "$sid" || -z "$LV_SESSION" || "$sid" == "$LV_SESSION" ]] || continue
        found=-1
        for (( i=0; i<${#LV_ID[@]}; i++ )); do [[ "${LV_ID[i]}" != "$id" ]] || found=$i; done
        (( found < 0 )) || continue
        LV_ID+=("$id"); LV_ROLE+=("$role"); LV_MODEL+=("$model"); LV_EFFORT+=("$effort"); LV_TASK+=("$task"); LV_PID+=("$pid"); LV_TS+=("$ts"); LV_SID+=("$sid")
        LV_REQ+=("$LV_REQUEST"); LV_START_SEQ+=("$LV_SEQ"); LV_FIN+=(0); LV_DURATION+=(0); LV_COST+=(0); LV_STATUS+=(""); LV_OUTCOME+=(""); LV_END_SEQ+=(0); LV_EVENT_TS+=(""); LV_AGENT_ID+=(""); LV_HAS_START+=(1)
        found=$(( ${#LV_ID[@]} - 1 )); LV_TOOL[found]="$tool"; LV_BRIDGE[found]="$bridge"; LV_REQUESTED[found]="$requested"; LV_OFF[found]="$offroute"; loomy_live_cache_row "$found" ;;
      delegation:*)
        [[ -z "$sid" || -z "$LV_SESSION" || "$sid" == "$LV_SESSION" ]] || continue
        LV_DONE=$(( LV_DONE + 1 )); [[ "$status" == ok ]] || LV_ERRORS=$(( LV_ERRORS + 1 ))
        [[ "$status" != interrupted ]] || outcome=interrupted
        found=-1
        for (( i=0; i<${#LV_ID[@]}; i++ )); do [[ "${LV_ID[i]}" != "$id" ]] || found=$i; done
        if (( found < 0 )); then
          # Older logs may contain an end without its start: still part of this session's recap.
          found=${#LV_ID[@]}; LV_ID+=("$id"); LV_ROLE+=("$role"); LV_MODEL+=("$model"); LV_EFFORT+=("$effort"); LV_TASK+=("$task"); LV_PID+=(0); LV_TS+=("$ts"); LV_SID+=("$sid"); LV_REQ+=("$LV_REQUEST"); LV_START_SEQ+=("$LV_SEQ"); LV_EVENT_TS+=(""); LV_AGENT_ID+=(""); LV_HAS_START+=(0)
        fi
        [[ -z "$model" ]] || LV_MODEL[found]="$model"
        [[ -z "$effort" ]] || LV_EFFORT[found]="$effort"
        [[ -z "$task" ]] || LV_TASK[found]="$task"
        [[ -z "$tool" ]] || LV_TOOL[found]="$tool"
        [[ -z "$bridge" ]] || LV_BRIDGE[found]="$bridge"
        [[ -z "$requested" ]] || LV_REQUESTED[found]="$requested"
        [[ -z "$offroute" ]] || LV_OFF[found]="$offroute"
        [[ "$costin" != usage && "${LV_BRIDGE[found]:-}" != subagent ]] || cost=0
        loomy_live_cache_row "$found"
        LV_FIN[found]=1; LV_DURATION[found]="$duration"; LV_COST[found]="$cost"; LV_STATUS[found]="$status"; LV_OUTCOME[found]="$outcome"; LV_END_SEQ[found]=$LV_SEQ ;;
    esac
  done < <(perl -MJSON::PP -MTime::Local=timegm -MErrno=EPERM -e "$AI_TITLE_PERL"'
    binmode STDOUT, ":encoding(UTF-8)";

    my ($file,$key,$off,$selection,$preferred)=@ARGV; open my $f,"<",$file or exit;
    my @st=stat($f); my $k="$st[0]:$st[1]";
    my (@rows,%sessions,%lead_context); my ($seq,$context)=(0,"");
    while (my $l=<$f>) {
      last unless $l =~ /\n$/;
      my $d=eval { decode_json($l) }; next unless ref($d) eq "HASH";
      my $type=$d->{type}//""; next if ref($type) || $type eq "";
      ++$seq;
      if ($type eq "session") {
        my $id=($d->{tool}//"")."|".($d->{session} || "pid".($d->{pid}//0));
        if (($d->{event}//"") eq "start") { $sessions{$id}={%$d,seq=>$seq}; $context=$id; $lead_context{$d->{tool}//""}=$id }
        elsif ($sessions{$id}) { $sessions{$id}{ended}=1 }
      }
      my $owner=$context;
      if ($type eq "usage" && ($d->{scope}//"") eq "lead") { $owner=$lead_context{$d->{tool}//$d->{family}//""}//$context }
      push @rows,[$d,tell($f),$owner,$seq];
    }
    my @starts=sort { $b->{seq}<=>$a->{seq} } values %sessions;
    my @alive=grep { !$_->{ended} && ($_->{pid}//0)>1 && (kill(0,$_->{pid}) || $! == EPERM) } @starts;
    my ($chosen)=grep { ($_->{tool}//"") eq $preferred } @alive;
    $chosen //= $alive[0] // $starts[0];
    my $chosen_seq=$chosen ? $chosen->{seq} : 0;
    my $token="$k:$chosen_seq";
    if ($k ne $key || $st[7]<$off || $token ne $selection) { print "RESET\n"; $off=0 }
    print "SELECT|$token|$chosen_seq\n";
    my $pos=$off;
    for my $row (@rows) {
      my ($d,$end,$ctx,$n)=@$row; next if $end<=$off; $pos=$end;
      # Sessionless lead usage belongs to the nearest start, never to another tool or session.
      if ($n>$chosen_seq && $d->{type} eq "usage" && ($d->{scope}//"") eq "lead" && !($d->{session}//"")) {
        my $owner=$sessions{$ctx};
        if ($chosen && (!$owner || $owner->{seq}!=$chosen_seq)) { print "IGNORE\n"; next }
      }
      for my $field (qw(task excerpt)) {
        next unless defined $d->{$field};
        $d->{$field}=ai_title($d->{$field});
      }
      my @t=($d->{ts}//"") =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z$/;
      my $ep=@t ? eval { timegm($t[5],$t[4],$t[3],$t[2],$t[1]-1,$t[0]) } : 0;
      $d->{tool}//=$d->{family}//(($d->{bridge}//"") eq "subagent" ? "claude" : "");
      $d->{cost_usd}=int(($d->{cost_usd}//0)*1000000+0.5);
      $d->{requested}=defined $d->{requested} ? ($d->{requested}?"true":"false") : "";
      my @v=($d->{type}//"",$ep//0,map { $d->{$_}//"" } qw(id event session pid tool role model effort task status duration_s cost_usd outcome excerpt requested off_routing bridge cost_in scope agent_id));
      for (@v) { s/[\x00-\x1f|]/ /g } print join("|",@v),"\n";
    }
    print "OFFSET|$k|$pos\n";
  ' "$file" "$LV_FILE_KEY" "$LV_OFFSET" "${LV_SELECTION:-}" "${AI_LEAD:-}" 2>/dev/null)
}

loomy_live_subagent_timeout_elapsed() {
  local age="$1" limit="$LOOMY_SUBAGENT_MAX_S"
  (( ${#age} > ${#limit} )) && return 0
  (( ${#age} < ${#limit} )) && return 1
  # shellcheck disable=SC2071  # Both values are normalized decimal strings; lexical order avoids overflow.
  [[ "$age" > "$limit" ]]
}

# Interrupted durations use journal evidence; a bridge can fall back to the next start in its lead session.
loomy_live_interrupted_duration() {
  local i="$1" end="" next=-1 j seq="${LV_START_SEQ[$1]:-0}" elapsed
  if [[ "${LV_EVENT_TS[i]:-}" =~ ^[0-9]+$ ]] && (( LV_EVENT_TS[i] > 0 )); then end="${LV_EVENT_TS[i]}"
  elif [[ "${LV_BRIDGE[i]:-}" != subagent && -n "${LV_SID[i]:-}" ]]; then
    for (( j=0; j<${#LV_ID[@]}; j++ )); do
      [[ "${LV_HAS_START[j]:-0}" == 1 && "${LV_SID[j]:-}" == "${LV_SID[i]}" ]] || continue
      (( ${LV_START_SEQ[j]:-0} > seq )) || continue
      if (( next < 0 )) || (( ${LV_START_SEQ[j]} < ${LV_START_SEQ[next]} )); then next=$j; fi
    done
    (( next < 0 )) || end="${LV_TS[next]:-}"
  fi
  if [[ "$end" =~ ^[0-9]+$ ]] && (( end > 0 )) && (( ${LV_TS[i]:-0} > 0 )); then
    elapsed=$(( end - ${LV_TS[i]:-0} )); (( elapsed >= 0 )) || elapsed=0; LV_DURATION[i]="$elapsed"
  else LV_DURATION[i]="—"
  fi
}

loomy_live_states() {
  local i pid age parent_pid parent_alive
  # EPERM still proves that a process exists (notably in the Codex sandbox). Check all pids in one fork.
  LV_ALIVE_PIDS="$(perl -MErrno=EPERM -e '
    print "|"; for my $p (@ARGV) { next unless $p =~ /^\d+$/ && $p>1; print "$p|" if kill(0,$p) || $! == EPERM }
  ' "$LV_SESSION_PID" ${LV_PID[@]+"${LV_PID[@]}"})"
  LV_RUNNING=(); LV_FINISHED=()
  for (( i=0; i<${#LV_ID[@]}; i++ )); do
    (( ${LV_START_SEQ[i]:-0} >= LV_SESSION_SEQ )) || continue
    pid="${LV_PID[i]:-0}"
    if [[ "${LV_FIN[i]:-0}" == 0 ]]; then
      if [[ "${LV_BRIDGE[i]:-}" == subagent ]]; then
        parent_pid="$pid"
        if [[ -n "${LV_SID[i]:-}" && "${LV_SID[i]}" == "$LV_SESSION" && "${LV_SESSION_PID:-0}" =~ ^[0-9]+$ ]] && (( LV_SESSION_PID > 1 )); then parent_pid="$LV_SESSION_PID"; fi
        parent_alive=0
        if [[ "$parent_pid" =~ ^[0-9]+$ ]] && (( parent_pid > 1 )) && [[ "$LV_ALIVE_PIDS" == *"|$parent_pid|"* ]]; then parent_alive=1; fi
        if [[ -n "${LV_SID[i]:-}" && "${LV_SID[i]}" == "$LV_SESSION" && "$LV_SESSION_OPEN" == 0 ]] || (( ! parent_alive )); then
          LV_STATUS[i]=interrupted; LV_OUTCOME[i]=interrupted
        elif (( parent_alive )); then
          age=$(( LV_NOW - ${LV_TS[i]:-0} )); (( age >= 0 )) || age=0
          if (( ${LV_TS[i]:-0} > 0 )) && loomy_live_subagent_timeout_elapsed "$age"; then LV_STATUS[i]=lost; LV_OUTCOME[i]=lost
          else LV_RUNNING+=("$i"); continue; fi
        fi
      elif [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )) && [[ "$LV_ALIVE_PIDS" == *"|$pid|"* ]]; then LV_RUNNING+=("$i"); continue
      else LV_STATUS[i]=interrupted; LV_OUTCOME[i]=interrupted
      fi
      LV_FIN[i]=1; LV_END_SEQ[i]=$LV_SEQ
      if [[ "${LV_STATUS[i]}" == interrupted ]]; then loomy_live_interrupted_duration "$i"
      else LV_DURATION[i]=$(( LV_NOW - ${LV_TS[i]:-0} )); (( LV_DURATION[i] >= 0 )) || LV_DURATION[i]=0; fi
    elif [[ "${LV_STATUS[i]:-}" == interrupted && "${LV_DURATION[i]:-}" == "—" ]]; then
      loomy_live_interrupted_duration "$i"
    fi
    if (( ${LV_START_SEQ[i]:-0} >= LV_SESSION_SEQ )) && [[ -z "${LV_SID[i]}" || -z "$LV_SESSION" || "${LV_SID[i]}" == "$LV_SESSION" ]]; then LV_FINISHED+=("$i"); fi
  done
  LV_ACTIVE=0
  if (( LV_SESSION_OPEN )) && [[ "$LV_SESSION_PID" =~ ^[0-9]+$ ]] && (( LV_SESSION_PID > 1 )) && [[ "$LV_ALIVE_PIDS" == *"|$LV_SESSION_PID|"* ]]; then
    (( LV_ACTIVITY > 0 && LV_NOW - LV_ACTIVITY < 120 )) && LV_ACTIVE=1
  fi
  return 0
}

loomy_live_line() {
  local text="$1" plain="$1" pattern=$'\033''\[[0-9;]*[[:alpha:]]'
  while [[ "$plain" =~ $pattern ]]; do plain="${plain//"${BASH_REMATCH[0]}"/}"; done
  if (( ${#plain} > LV_WIDTH )); then printf '%s…%s\n' "${plain:0:$(( LV_WIDTH - 1 ))}" "$C_RESET"
  else printf '%s\n' "$text"; fi
}
loomy_live_time() { ai_display_duration "$1"; LV_TIME="$AI_DURATION"; }
loomy_live_short_model() { LV_SHORT="${1#claude-}"; LV_SHORT="${LV_SHORT#gpt-}"; }

# Cache static columns once per event, never fork per role on timer ticks.
loomy_live_cache_row() {
  local i="$1" label n=0 j flags="" word="${LV_EFFORT[$1]:-?}" tool="${LV_TOOL[$1]:-}" bars=""
  case "${LV_ROLE[i]}" in
    lead) label="Lead agent" ;; architect) label=Architect ;; developer) label=Developer ;;
    debugger) label=Debugger ;; reviewer) label=Reviewer ;; security) label=Security ;;
    executor) label=Executor ;; explorer) label=Explorer ;; documenter) label=Documenter ;; *) label="${LV_ROLE[i]}" ;;
  esac
  tv label "$label"; LV_LABEL[i]="$label"
  ai_task_title "${LV_TASK[i]}" 90; LV_TASK[i]="$AI_TASK_TITLE"
  case "$tool" in claude|Claude) tool=Claude ;; codex|Codex) tool=Codex ;; *)
    case "${LV_MODEL[i]}" in claude-*) tool=Claude ;; gpt-*) tool=Codex ;; *) tool='?' ;; esac ;;
  esac
  LV_TOOL[i]="$tool"
  case "$word" in low) n=1 ;; medium|med) word=med; n=2 ;; high) n=3 ;; xhigh|max|ultra) n=4 ;; esac
  for (( j=0; j<4; j++ )); do if (( j<n )); then bars="${bars}▮"; else bars="${bars}▯"; fi; done
  LV_BAR[i]="$bars"; LV_WORD[i]="$word"
  loomy_live_short_model "${LV_MODEL[i]}"; LV_MODELSHORT[i]="$LV_SHORT"
  if [[ "${LV_REQUESTED[i]:-}" == true ]]; then flags="⚑"; fi
  if [[ -n "${LV_OFF[i]:-}" ]]; then flags="${flags:+$flags }⇢ ${LV_OFF[i]}"; fi
  LV_FLAGS[i]="$flags"
}
loomy_live_row() {
  local i="$1" finished="$2" mark elapsed text outcome="" suffix="" color="$C_CYAN" model="" bars="" label flags="${LV_FLAGS[$1]}" wrap_flags=0 wrap_outcome=0 task="" room
  _ui_pad "${LV_LABEL[i]}" "$LV_ROLE_WIDTH"; label="$UI_PADDED"
  if (( finished )); then
    elapsed="${LV_DURATION[i]:-0}"; mark=✓; outcome="${LV_OUTCOME[i]:-done}"; color="$C_GREEN"
    [[ "${LV_STATUS[i]}" == ok || "$outcome" == unknown || "$outcome" == lost || "$outcome" == interrupted ]] || outcome=failed
    case "$outcome" in blocked) mark=■; color="$C_YELLOW" ;; partial) mark=△; color="$C_YELLOW" ;; failed) mark=✗; color="$C_RED" ;; interrupted) mark=⊘; suffix=" · $(t 'interrupted')"; color="$C_DIM$C_RED" ;; unknown) mark='?'; color="$C_DIM" ;; lost) mark="! $(t 'lost')"; color="$C_YELLOW" ;; esac
  else elapsed=$(( LV_NOW - ${LV_TS[i]:-0} )); (( elapsed >= 0 )) || elapsed=0; mark="${UI_SPIN[$(( ${LOOMY_TICK:-0} % 4 ))]}"; fi
  if [[ "$elapsed" == "—" ]]; then LV_TIME="—"; else loomy_live_time "$elapsed"; fi
  (( LV_WIDTH < 65 )) || model=" ${LV_MODELSHORT[i]}"
  (( LV_WIDTH < 52 )) || bars=" ${LV_BAR[i]}"
  printf -v text '  %s %s %-6s%s%s %s %5s' "$mark" "$label" "${LV_TOOL[i]}" "$model" "$bars" "${LV_WORD[i]}" "$LV_TIME"
  LV_ROW_LINES=1
  if (( LV_WIDTH >= 80 )) && [[ -n "${LV_TASK[i]}" ]]; then
    task="${LV_TASK[i]}"
    room=$(( LV_WIDTH - ${#text} - 2 - ${#flags} - ${#suffix} - 1 )); [[ -n "$flags" ]] || room=$(( room + 1 ))
    if (( LV_WIDTH >= 99 && room < 30 )); then
      # At 100 columns, keep at least 30 columns for the task before dropping optional detail.
      if [[ -n "$model" ]]; then model=" ${LV_MODELSHORT[i]:0:8}"; fi
      printf -v text '  %s %s %-6s%s%s %s %5s' "$mark" "$label" "${LV_TOOL[i]}" "$model" "$bars" "${LV_WORD[i]}" "$LV_TIME"
      room=$(( LV_WIDTH - ${#text} - 2 - ${#flags} - ${#suffix} - 1 )); [[ -n "$flags" ]] || room=$(( room + 1 ))
      if (( room < 30 )) && [[ -n "$bars" ]]; then
        bars=""
        printf -v text '  %s %s %-6s%s%s %s %5s' "$mark" "$label" "${LV_TOOL[i]}" "$model" "$bars" "${LV_WORD[i]}" "$LV_TIME"
        room=$(( LV_WIDTH - ${#text} - 2 - ${#flags} - ${#suffix} - 1 )); [[ -n "$flags" ]] || room=$(( room + 1 ))
      fi
      if (( room < 30 )) && [[ -n "$model" ]]; then
        model=""
        printf -v text '  %s %s %-6s%s%s %s %5s' "$mark" "$label" "${LV_TOOL[i]}" "$model" "$bars" "${LV_WORD[i]}" "$LV_TIME"
        room=$(( LV_WIDTH - ${#text} - 2 - ${#flags} - ${#suffix} - 1 )); [[ -n "$flags" ]] || room=$(( room + 1 ))
      fi
    fi
    ai_task_title "$task" "$room"; task="$AI_TASK_TITLE"
    [[ -z "$task" ]] || text="$text  $task"
    if [[ -n "$suffix" ]]; then
      if (( ${#text} + ${#suffix} <= LV_WIDTH )); then text="$text$suffix"; else wrap_outcome=1; fi
    fi
    if [[ -n "$flags" ]]; then
      if (( ${#text} + 1 + ${#flags} <= LV_WIDTH )); then text="$text $flags"; else wrap_flags=1; fi
    fi
  else
    if [[ -n "$suffix" ]]; then
      if (( ${#text} + ${#suffix} <= LV_WIDTH )); then text="$text$suffix"; else wrap_outcome=1; fi
    fi
    if [[ -n "$flags" ]]; then
      if (( ${#text} + 1 + ${#flags} <= LV_WIDTH )); then text="$text $flags"; else wrap_flags=1; fi
    fi
  fi
  loomy_live_line "$color$text$C_RESET"
  if (( wrap_outcome )); then loomy_live_line "   $suffix"; LV_ROW_LINES=$(( LV_ROW_LINES + 1 )); fi
  if (( wrap_flags )); then loomy_live_line "   $flags"; LV_ROW_LINES=$(( LV_ROW_LINES + 1 )); fi
}

# Resolve the lead/header only when watched state changes, not once per timer tick.
loomy_live_metadata() {
  local line phase="done" master="" acting="" name="" state="${STATE:-$ROOT/.loomy/state}"
  ai_detect_env "$ROOT"; ai_resolve lead "$AI_ENV" "$AI_PROFILE"
  LV_LEAD_TOOL="$R_FAMILY"; LV_LEAD_MODEL="$R_MODEL"; LV_LEAD_EFFORT="$R_EFFORT"; LV_RELAY=""; LV_MANUAL_RELAY=""
  if [[ -f "$ROOT/.loomy/failover" ]]; then
    while IFS= read -r line; do case "$line" in master=*) master="${line#*=}" ;; acting=*) acting="${line#*=}" ;; esac; done <"$ROOT/.loomy/failover"
    [[ -z "$acting" || "$acting" == "$master" ]] || {
      ai_resolve lead "$acting" "$AI_PROFILE"
      LV_LEAD_TOOL="$R_FAMILY"; LV_LEAD_MODEL="$R_MODEL"; LV_LEAD_EFFORT="$R_EFFORT"; LV_RELAY="⇄ "
    }
  fi
  if [[ "$(lf_get "$ROOT" manual)" == 1 ]] && lf_active "$ROOT"; then LV_MANUAL_RELAY="⇄ $(lf_status_text "$ROOT")"; fi
  [[ ! -f "$state" ]] || while IFS= read -r line; do case "$line" in phase=*) phase="${line#*=}" ;; esac; done <"$state"
  LV_PHASE="$phase"; LV_PHASE_LABEL="$(loomy_phase_label "$phase")"
  name="$(_ai_brief_get "$ROOT/.loomy/brief.md" name)"; LV_NAME="${name:-${ROOT##*/}}"
  LV_QUOTA="$(ai_quota_line "$LV_LEAD_TOOL")"
  LV_GROUP="${LOOMY_WATCH_GROUP:-$(loomy_config_get watch_group request)}"; [[ "$LV_GROUP" == model ]] || LV_GROUP=request
  LV_META_READY=1
}
loomy_live_header() {
  local state phase tool word="${LV_SESSION_EFFORT:-$LV_LEAD_EFFORT}"
  if (( LV_ACTIVE )); then tv state active; else tv state idle; fi
  phase="$LV_PHASE_LABEL"; [[ "$LV_PHASE" != "done" ]] || { tv phase "Lead agent"; phase="$phase $state"; }
  LV_HEADER="$LV_NAME · $phase${LV_QUOTA:+ · $LV_QUOTA} · ${LV_CLOCK:-} ↻"
  tv tool Orchestrator
  local leadtool="$LV_LEAD_TOOL" model="$LV_LEAD_MODEL"
  if (( LV_SESSION_SEQ > 0 )); then
    leadtool="$LV_SESSION_TOOL"; model="${LV_SESSION_MODEL:-?}"; word="${LV_SESSION_EFFORT:-$LV_LEAD_EFFORT}"
  fi
  word="${word/medium/med}"
  case "$leadtool" in claude) leadtool=Claude ;; codex) leadtool=Codex ;; esac
  loomy_live_short_model "$model"
  tv LV_LEAD_LINE "%s running" "${#LV_RUNNING[@]}"
  LV_LEAD_LINE="$tool · $LV_RELAY$leadtool $LV_SHORT $word · $state · $LV_LEAD_LINE"
}

loomy_live_group_title() {
  local i="$1" count="$2" recap="$3" req title age running
  if [[ "$LV_GROUP" == model ]]; then
    title="${LV_MODEL[i]:-?}"; if (( ! recap )); then tv running "%s running" "$count"; title="$title · $running"; fi
  else
    req="${LV_REQ[i]}"
    if (( req >= 0 )); then
      title="${LV_REQ_TEXT[req]}"; [[ -n "$title" ]] || tv title "request %s" "$(( req + 1 ))"
      loomy_live_time "$(( LV_NOW - ${LV_REQ_TS[req]} ))"; age="$LV_TIME"
    else tv title "Earlier work"; age=""; fi
    ai_task_title "$title" "$(( LV_WIDTH - 3 - ${#age} - 3 ))"; title="$AI_TASK_TITLE${age:+ · $age}"
  fi
  loomy_live_line "┌─ $title"
}

# All running roles remain above the recap. Height only limits finished lines, never active roles.
loomy_live_render() {
  local i j k key count total=0 cost=$LV_USAGE footer emitted=0 used=0 group_seen="|" indices=() d
  _ui_term_size; LV_WIDTH=$(( UI_COLS - 1 )); LV_HEIGHT=$UI_ROWS
  (( LV_META_READY )) || loomy_live_metadata
  LV_ROLE_WIDTH=0
  for i in ${LV_RUNNING[@]+"${LV_RUNNING[@]}"} ${LV_FINISHED[@]+"${LV_FINISHED[@]}"}; do
    (( ${#LV_LABEL[i]} <= LV_ROLE_WIDTH )) || LV_ROLE_WIDTH=${#LV_LABEL[i]}
  done
  (( LV_ROLE_WIDTH >= 12 )) || LV_ROLE_WIDTH=12
  loomy_live_header
  [[ -n "${LOOMY_NO_HEADER:-}" ]] || { loomy_live_line "$LV_HEADER"; }
  loomy_live_line "$LV_LEAD_LINE"
  if [[ -n "${LV_MANUAL_RELAY:-}" ]]; then loomy_live_line "$LV_MANUAL_RELAY"; used=$(( used + 1 )); fi
  loomy_live_line "$(t "IN PROGRESS")"
  for i in ${LV_RUNNING[@]+"${LV_RUNNING[@]}"}; do
    if [[ "$LV_GROUP" == model ]]; then key="${LV_MODEL[i]}"; else key="${LV_REQ[i]}"; fi
    case "$group_seen" in *"|$key|"*) continue ;; esac
    group_seen="$group_seen$key|"; count=0; indices=()
    for j in ${LV_RUNNING[@]+"${LV_RUNNING[@]}"}; do
      if [[ "$LV_GROUP" == model ]]; then k="${LV_MODEL[j]}"; else k="${LV_REQ[j]}"; fi
      [[ "$key" != "$k" ]] || { indices+=("$j"); count=$(( count + 1 )); }
    done
    loomy_live_group_title "$i" "$count" 0; used=$(( used + 2 + count ))
    for j in "${indices[@]}"; do loomy_live_row "$j" 0; used=$(( used + LV_ROW_LINES - 1 )); done
    loomy_live_line "└─"
  done
  (( ${#LV_RUNNING[@]} )) || { loomy_live_line "  $(t "No roles running")"; used=$(( used + 1 )); }
  for i in ${LV_FINISHED[@]+"${LV_FINISHED[@]}"}; do d="${LV_DURATION[i]%.*}"; [[ "$d" =~ ^[0-9]+$ ]] && total=$(( total + d )); cost=$(( cost + ${LV_COST[i]:-0} )); done
  printf -v cost '%d.%04d' $(( cost / 1000000 )) $(( cost % 1000000 / 100 ))
  loomy_live_time "$total"
  loomy_live_line "$(t "SESSION") · $(t "%s finished" "${#LV_FINISHED[@]}") · $LV_TIME · ~\$$cost"
  # Newest completions first; group order follows the most recent completion.
  indices=()
  for i in ${LV_FINISHED[@]+"${LV_FINISHED[@]}"}; do
    j=${#indices[@]}
    while (( j > 0 )) && (( ${LV_END_SEQ[indices[j-1]]} < ${LV_END_SEQ[i]} )); do indices[j]="${indices[j-1]}"; j=$(( j - 1 )); done
    indices[j]="$i"
  done
  group_seen="|"; used=$(( used + 6 ))
  for i in ${indices[@]+"${indices[@]}"}; do
    (( used + 3 < LV_HEIGHT )) || break
    if [[ "$LV_GROUP" == model ]]; then key="${LV_MODEL[i]}"; else key="${LV_REQ[i]}"; fi
    case "$group_seen" in *"|$key|"*) continue ;; esac
    group_seen="$group_seen$key|"; loomy_live_group_title "$i" 0 1; used=$(( used + 2 ))
    for j in "${indices[@]}"; do
      (( used + 1 < LV_HEIGHT )) || break
      if [[ "$LV_GROUP" == model ]]; then k="${LV_MODEL[j]}"; else k="${LV_REQ[j]}"; fi
      [[ "$key" == "$k" ]] || continue
      loomy_live_row "$j" 1; used=$(( used + LV_ROW_LINES )); emitted=$(( emitted + 1 ))
    done
    loomy_live_line "└─"
  done
  (( emitted == ${#LV_FINISHED[@]} )) || loomy_live_line "  $(t "%s more finished roles" "$(( ${#LV_FINISHED[@]} - emitted ))")"
  [[ -n "${LOOMY_NO_HEADER:-}" ]] || { footer="$(loomy_live_keys)"; loomy_live_line "$footer"; }
  loomy_live_line "⚑ $(t "requested") · ⇢ $(t "off routing")"
}
loomy_live_keys() {
  if (( ${UI_COLS:-100} < 60 )); then
    if [[ "${LV_GROUP:-request}" == model ]]; then t "[o] lead [v] request [l] log [q] quit"
    else t "[o] lead [v] model [l] log [q] quit"; fi
    return 0
  fi
  if [[ "${LV_GROUP:-request}" == model ]]; then t "[o] orchestrator [v] group by request [l] log [q] quit"
  else t "[o] orchestrator [v] group by model [l] log [q] quit"; fi
}

# Both tree layouts and watch use the read-side display formatter with the existing reveal cursor.
loomy_tree_log_enable() {
  _ai_session_events() { ai_journal_display_events "$1"; }
}

# One role selection for both classic layouts: latest running, else latest completed this session.
loomy_tree_role() {
  local i best=-1
  RS_K=idle; RS_I=-1
  for i in ${LV_FINISHED[@]+"${LV_FINISHED[@]}"}; do
    [[ "${LV_ROLE[i]}" == "$1" ]] || continue
    if (( best < 0 )) || (( ${LV_END_SEQ[i]} > ${LV_END_SEQ[best]} )); then best=$i; fi
  done
  if (( best >= 0 )); then RS_K=last; RS_I=$best; fi
  best=-1
  for i in ${LV_RUNNING[@]+"${LV_RUNNING[@]}"}; do
    [[ "${LV_ROLE[i]}" == "$1" ]] || continue
    if (( best < 0 )) || (( ${LV_START_SEQ[i]} > ${LV_START_SEQ[best]} )); then best=$i; fi
  done
  if (( best >= 0 )); then RS_K=run; RS_I=$best; fi
  if (( RS_I >= 0 )); then
    R_MODEL="${LV_MODEL[RS_I]:-?}"; R_EFFORT="${LV_EFFORT[RS_I]:-?}"; R_FAMILY="${LV_TOOL[RS_I]}"
    RS_EL=$(( LV_NOW - ${LV_TS[RS_I]} )); RS_ST="${LV_STATUS[RS_I]}"; RS_OC="${LV_OUTCOME[RS_I]}"; RS_DUR="${LV_DURATION[RS_I]}"
  fi
}

# Watch sources only the reducer; ordinary loomy tree keeps its architectural diagram.
if [[ "${1:-}" == --library ]]; then loomy_tree_log_enable; return 0; fi

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
loomy_tree_log_enable

ROOT=""; LIVE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --once|--live) LIVE=1 ;;
    --root) ROOT="${2:-}"; shift ;;
    -h|--help) sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//; s/loomy-tree.sh/loomy tree/g' | i18n_lines; exit 0 ;;
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
loomy_live_init; loomy_live_poll "$J"; LV_NOW="$now_s"; LV_CLOCK="$(date +%H:%M:%S)"; loomy_live_states; loomy_live_metadata
if (( LIVE )); then loomy_live_render; exit 0; fi

dur() { if [[ "$1" == "—" ]]; then printf '—'; else ai_display_duration "$1"; printf '%s' "$AI_DURATION"; fi; }
hm() { local e; e="$(ai_ts_epoch "$1")"; [[ -n "$e" ]] && { date -r "$e" +%H:%M:%S 2>/dev/null || date -d "@$e" +%H:%M:%S; }; }
color_of() { case "$1" in TOP) printf '%s' "$C_MAGENTA" ;; FAST) printf '%s' "$C_GREEN" ;; *) printf '%s' "$C_CYAN" ;; esac; }

# ---------------------------------------------------------------- lead and advisor, from the same live session
L_MODEL="$LV_LEAD_MODEL"; L_EFFORT="$LV_LEAD_EFFORT"; L_FAM="$LV_LEAD_TOOL"
if (( LV_SESSION_SEQ > 0 )); then L_MODEL="${LV_SESSION_MODEL:-?}"; L_EFFORT="${LV_SESSION_EFFORT:-$LV_LEAD_EFFORT}"; L_FAM="$LV_SESSION_TOOL"; fi
ADV=""; [[ "$L_FAM" == claude ]] && ADV="$(ai_advisor_for "$L_MODEL" "$AI_PROFILE")"
sess=closed; (( LV_SESSION_OPEN )) && [[ "$LV_ALIVE_PIDS" == *"|$LV_SESSION_PID|"* ]] && sess=open
s_txt="${C_DIM}○ $(t "session closed")${C_RESET}"
(( LV_SESSION_SEQ > 0 )) || s_txt="${C_DIM}○ $(t "no session")${C_RESET}"
if [[ "$sess" == open ]]; then
  if (( LV_ACTIVE || ${#LV_RUNNING[@]} > 0 )); then lead_state="$(t "working")"; else lead_state="$(t "idle")"; fi
  s_txt="${C_GREEN}● $(t "session open") · $lead_state${C_RESET}"
fi
phase="$LV_PHASE"
for mf in audit task; do
  p="$(sed -n 's/^phase=//p' "$ROOT/.loomy/$mf.state" 2>/dev/null | head -1)"
  if [[ -n "$p" && "$p" != "done" ]]; then loomy_phases_mode "$mf"; phase="$p"; MISSION="$mf"; break; fi
done
# Bootstrap completion does not describe current delegations.
if (( ${#LV_RUNNING[@]} > 0 )) && [[ "$phase" == "done" ]]; then phase=""; fi
a_n=0; a_last=""; a_tok=0

# ---------------------------------------------------------------- diagram (wide terminals)
_ui_term_size
W=$(( UI_COLS - 7 ))
# Rendering: diagram (boxes and links) or list. tree_view auto (default): the diagram when the window can hold it,
# otherwise the list. LOOMY_TREE (set by key v of loomy watch) overrides for one session.
TREE_MODE="${LOOMY_TREE:-$(sed -n 's/^tree_view=//p' "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/config" 2>/dev/null | tail -1)}"
TREE_NEED_COLS=124; TREE_NEED_ROWS=57
[[ -z "${LOOMY_NO_HEADER:-}" ]] || TREE_NEED_ROWS="$UI_ROWS"
DIAGRAM=0
case "${TREE_MODE:-auto}" in
  diagram) (( UI_COLS >= TREE_NEED_COLS )) && DIAGRAM=1 ;;
  list) DIAGRAM=0 ;;
  *) if (( UI_COLS >= TREE_NEED_COLS )) && { [[ -n "${LOOMY_NO_HEADER:-}" ]] || (( UI_ROWS >= TREE_NEED_ROWS )); }; then DIAGRAM=1; fi ;;
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
  tv TR_6 "model + effort"
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
  tv TR_17 "model + effort"
  tv TR_18 "back to the lead agent"
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
  tv TR_40 "no session"
  # Redrawn every second: helpers that write into variables instead of starting subprocesses.
  _tz="$(date +%z)"; TZOFF=$(( (10#${_tz:1:2} * 3600 + 10#${_tz:3:2} * 60) * ${_tz:0:1}1 ))
  ts2ep() {   # ISO UTC timestamp → EP (epoch), by calendar arithmetic
    local y=$(( 10#${1:0:4} )) m=$(( 10#${1:5:2} )) d=$(( 10#${1:8:2} )) H=$(( 10#${1:11:2} )) M=$(( 10#${1:14:2} )) S=$(( 10#${1:17:2} ))
    (( m <= 2 )) && { y=$(( y - 1 )); m=$(( m + 12 )); }
    EP=$(( (365 * y + y / 4 - y / 100 + y / 400 + (153 * (m - 3) + 2) / 5 + d - 719469) * 86400 + H * 3600 + M * 60 + S ))
  }
  hms() { local x; ts2ep "$1"; x=$(( (EP + TZOFF) % 86400 )); printf -v HMS '%02d:%02d:%02d' $(( x / 3600 )) $(( x % 3600 / 60 )) $(( x % 60 )); }
  toklbl() { local n="${1%.*}"; n="${n:-0}"; if (( n >= 1000000 )); then printf -v TOK '%d.%dM' $(( n / 1000000 )) $(( n % 1000000 / 100000 )); elif (( n >= 1000 )); then printf -v TOK '%d.%dk' $(( n / 1000 )) $(( n % 1000 / 100 )); else TOK="$n"; fi; }
  # Tier counts use the reducer; advisor consultations are separate journal events.
  n_tot=${#LV_FINISHED[@]}; T_TOP=0; T_MID=0; T_FAST=0
  for i in ${LV_FINISHED[@]+"${LV_FINISHED[@]}"}; do
    case " ${LV_MODEL[i]} " in
      " $AI_MODEL_CLAUDE_TOP "|" $AI_MODEL_CODEX_TOP ") T_TOP=$(( T_TOP + 1 )) ;;
      " $AI_MODEL_CLAUDE_MID "|" $AI_MODEL_CODEX_MID ") T_MID=$(( T_MID + 1 )) ;;
      " $AI_MODEL_CLAUDE_FAST "|" $AI_MODEL_CODEX_FAST ") T_FAST=$(( T_FAST + 1 )) ;;
    esac
  done
  if [[ -s "$J" ]]; then
    read -r a_n a_tok a_last <<<"$(awk '
      function num(k) { if (match($0, "\"" k "\":[0-9]+")) { return substr($0, RSTART + length(k) + 3, RLENGTH - length(k) - 3) + 0 } return 0 }
      /"type":"advisor"/ { n += num("calls"); tk += num("tokens_in"); if (match($0, /"ts":"[^"]*"/)) l = substr($0, RSTART + 6, RLENGTH - 7) } END { print n + 0, tk + 0, l }' "$J")"
  fi
  (( W > 140 )) && W=140
  K_LEAD="$C_YELLOW"; K_ROUTE="$C_GREEN"; K_ROLE="$C_CYAN"; K_ADV="$C_MAGENTA"; K_DIM="$C_DIM"; K_TXT=""; K_B="$C_BOLD"
  bars() { case "$1" in low) BARS="▮▯▯▯" ;; medium) BARS="▮▮▯▯" ;; high) BARS="▮▮▮▯" ;; xhigh|max|ultra) BARS="▮▮▮▮" ;; *) BARS="" ;; esac; }
  eff_short() { case "$1" in medium) EFS="med" ;; *) EFS="$1" ;; esac; }
  color_tier() { case "$1" in TOP) CT="$C_MAGENTA" ;; FAST) CT="$C_GREEN" ;; *) CT="$C_CYAN" ;; esac; }
  action_of() {
    case "$1" in
      architect) tv ACT "designs the plan" ;; debugger) tv ACT "finds the cause" ;; security) tv ACT "checks the risks" ;;
      reviewer) tv ACT "reviews the diff" ;; developer) tv ACT "edits + runs tests" ;; executor) tv ACT "runs bounded tasks" ;;
      explorer) tv ACT "reads the code" ;; documenter) tv ACT "writes the docs" ;; *) ACT="$1" ;;
    esac
  }
  # The same in a word or two, for the short list of the roles without a box.
  action_short() {
    case "$1" in
      architect) tv ACT "plan" ;; debugger) tv ACT "root cause" ;; security) tv ACT "risks" ;; reviewer) tv ACT "review" ;;
      developer) tv ACT "code + tests" ;; executor) tv ACT "bounded tasks" ;; explorer) tv ACT "reading" ;; documenter) tv ACT "docs" ;; *) ACT="$1" ;;
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
  for i in ${LV_RUNNING[@]+"${LV_RUNNING[@]}"}; do run_roles="$run_roles ${LV_ROLE[i]}"; n_run=$(( n_run + 1 )); done
  for i in ${LV_FINISHED[@]+"${LV_FINISHED[@]}"}; do last_roles="$last_roles ${LV_END_SEQ[i]}|${LV_ROLE[i]}"; done
  [[ -n "$last_roles" ]] && last_roles="$(printf '%s\n' $last_roles | sort -rn | cut -d'|' -f2)"
  for r in $run_roles $last_roles developer reviewer executor explorer architect $AI_ROLES; do
    case " $pick " in *" $r "*) continue ;; esac
    case " $AI_ROLES " in *" $r "*) [[ "$r" != "lead" ]] && pick="$pick $r" ;; esac
  done
  ADV_W=0; recent=0; [[ -n "$ADV" ]] && ADV_W=26
  CX=$(( ADV_W > 0 ? ADV_W + 6 : 0 )); CWID=$(( W - CX ))
  BW=22; NB=$(( (CWID + 4) / (BW + 4) )); (( NB > 4 )) && NB=4; (( NB < 2 )) && NB=2
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
  # Animations at different paces (the lead box every two seconds, each role shifted by its place), so that the
  # whole diagram doesn't change in step with the seconds.
  lk="$K_LEAD"; [[ "$sess" == open* ]] && (( (TICK / 2) % 2 )) && lk="${C_BOLD}${C_YELLOW}"
  cv_box "$MX" "$MY" "$MW" 6 "$lk"
  cv_center "$MX" $(( MY + 1 )) "$MW" "${C_BOLD}${C_YELLOW}" "$NM_LEAD · ${TR_8}"
  cv_center "$MX" $(( MY + 2 )) "$MW" "$K_TXT" "$LV_RELAY$L_FAM · ${TR_9}"
  bars "$L_EFFORT"; cv_center "$MX" $(( MY + 3 )) "$MW" "$K_TXT" "effort $BARS $L_EFFORT"
  PH_LBL=""; [[ -n "$phase" && "$phase" != "done" ]] && PH_LBL="$(loomy_phase_label "$phase")"
  if [[ "$sess" == open* ]]; then sk="$C_GREEN"; st_txt="● ${TR_10}"; else sk="$K_DIM"; st_txt="○ ${TR_11}"; (( LV_SESSION_SEQ > 0 )) || st_txt="○ ${TR_40}"; fi
  if [[ "$sess" == open* ]]; then
    if (( LV_ACTIVE || ${#LV_RUNNING[@]} > 0 )); then lead_state="$(t "working")"; else lead_state="$(t "idle")"; fi
    st_txt="$st_txt · $lead_state"
  fi
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
    loomy_tree_role "$r"
    bk="$K_ROLE"; stl=""; stk="$K_DIM"
    case "$RS_K" in
      run) el="$RS_EL"; (( el < 0 )) && el=0
            if (( (TICK + b) % 2 )); then bk="${C_BOLD}${C_CYAN}"; else bk="$C_CYAN"; fi
            w_run=""; tv w_run "running"; loomy_live_time "$el"; stl="${UI_SPIN[$(( TICK % 4 ))]} $w_run $LV_TIME"; stk="$C_YELLOW"
            # The dot travels down the arrow of a working role.
            cv_put "$c" $(( SY + 2 + (TICK + b) % 2 )) "$C_YELLOW" "●" ;;
      last) d0="${RS_DUR%.*}"; d0="${d0:-0}"
            if [[ "$RS_OC" == interrupted ]]; then w="$(t "interrupted")"; stl="⊘ $w"; stk="$C_DIM$C_RED"
            elif [[ "$RS_ST" != "ok" ]]; then tv w "failed"; stl="✗ $w"; stk="$C_RED"
            elif [[ "$RS_OC" == "partial" ]]; then tv w "partial"; stl="△ $w"; stk="$C_YELLOW"
            elif [[ "$RS_OC" == "blocked" ]]; then tv w "blocked"; stl="■ $w"; stk="$C_YELLOW"
            else tv w "done"; loomy_live_time "$d0"; stl="✓ $w $LV_TIME"; stk="$C_GREEN"; fi ;;
      *) tv w "planned"; stl="· $w" ;;
    esac
    cv_box "${bx[b]}" "$BY" "$BW" 9 "$bk"
    role_lbl "$r"; color_tier "$R_TIER"; [[ "$RS_K" != idle ]] || CT="$K_DIM"; bars "$R_EFFORT"; eff_short "$R_EFFORT"; action_of "$r"
    if [[ "$RS_K" == idle ]]; then role_tool="$R_FAMILY"; else role_tool="${LV_TOOL[RS_I]}"; fi
    cv_center "${bx[b]}" $(( BY + 1 )) "$BW" "$CT" "$role_tool"
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
  back_state="$(t "reviews + checks")"
  if (( n_run == 1 )); then back_state="$(t "waiting for %s role" "$n_run")"
  elif (( n_run > 1 )); then back_state="$(t "waiting for %s roles" "$n_run")"; fi
  cv_center "$BKX" $(( BKY + 2 )) "$BKW" "$K_TXT" "$back_state"
  # Advisor column, linked to the lead box, the roles and the final check.
  if [[ -n "$ADV" ]]; then
    AH=$(( BKY + 4 - MY ))
    cv_box 0 "$MY" "$ADV_W" "$AH" "$K_ADV"
    cv_center 0 $(( MY + 1 )) "$ADV_W" "${C_BOLD}${C_MAGENTA}" "$adv_up"
    cv_center 0 $(( MY + 2 )) "$ADV_W" "$K_ADV" "${TR_7} · ${TR_20}"
    # The moment the advisor is most likely called now, from the phase and the last results.
    act="plan"
    case "$phase" in verify|commit|document|retire|validate|report|done) act="done" ;; esac
    for i in ${LV_FINISHED[@]+"${LV_FINISHED[@]}"}; do [[ "${LV_STATUS[i]}" != ok || "${LV_OUTCOME[i]}" == partial || "${LV_OUTCOME[i]}" == blocked ]] && act=error; done
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
      log_room=$(( W - 29 - ${#right} - ${#what} ))
      ai_task_title "$left" "$log_room"; left="$AI_TASK_TITLE"
      if [[ "$who" == lead && "$what" == "$(t "request")" ]]; then ai_task_title "$extra" "$(( W - 29 - ${#what} ))"; left="$AI_TASK_TITLE"; right=""; fi
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
  cur=" ▏"
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
  cv_junctions
  printf -v cvp '%s  ' "${C_RAIL}│${C_RESET}"
  cv_print "$cvp"
  [[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "${TR_39}"
  exit 0
fi

# ---------------------------------------------------------------- list rendering
ui_section "$(t "AGENT TREE")" "$(ai_env_label "$AI_ENV") · $(t "%s profile" "$(ai_profile_label "$AI_PROFILE")")"
(( TREE_SMALL )) && ui_rail "${C_DIM}$(t "diagram view: enlarge the window to %s × %s (now %s × %s), or key v" "$TREE_NEED_COLS" "$TREE_NEED_ROWS" "$UI_COLS" "$UI_ROWS")${C_RESET}"
ui_rail ""
lead_line="${C_BRAND}${C_BOLD}$(t "LEAD AGENT")${C_RESET}  $(color_of TOP)${LV_RELAY}${L_FAM} ${L_MODEL}${C_RESET} · $L_EFFORT · $s_txt${phase:+ ${C_DIM}·${C_RESET} ${MISSION:+$MISSION · }$(loomy_phase_label "$phase")}"
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
  loomy_tree_role "$r"
  state=""; conn="━━"; mark="${C_DIM}○${C_RESET}"
  if [[ "$RS_K" == run ]]; then
    n_run=$(( n_run + 1 )); loomy_live_time "$RS_EL"
    state="${C_YELLOW}${UI_SPIN[$(( TICK % 4 ))]} $(t "running") $LV_TIME${C_RESET} ${C_DIM}${LV_TASK[RS_I]}${C_RESET}"
    mark="${C_YELLOW}●${C_RESET}"
  elif [[ "$RS_K" == last ]]; then
    mark="${C_GREEN}✓${C_RESET}"
    if [[ "$RS_OC" == interrupted ]]; then mark="${C_DIM}${C_RED}⊘${C_RESET}"
    elif [[ "$RS_ST" != ok ]]; then mark="${C_RED}✗${C_RESET}"; fi
    [[ "$RS_OC" == partial ]] && mark="${C_YELLOW}△${C_RESET}"
    [[ "$RS_OC" == blocked ]] && mark="${C_YELLOW}■${C_RESET}"
    outcome_word="${RS_OC:-done}"; [[ "$RS_ST" == ok || "$RS_OC" == interrupted ]] || outcome_word=failed
    if [[ "$outcome_word" == interrupted ]]; then state="${C_DIM}${C_RED}$(t "$outcome_word") · $(dur "$RS_DUR")${C_RESET}"
    else state="${C_DIM}$(t "$outcome_word") · $(dur "$RS_DUR")${C_RESET}"; fi
  else state="${C_DIM}$(t "planned")${C_RESET}"; fi
  _ui_pad "$(ai_role_label "$r")" 16; rl="$UI_PADDED"
  _ui_pad "$R_MODEL" 18; ml="$UI_PADDED"
  _ui_pad "$R_EFFORT" 7; el_="$UI_PADDED"
  model_color="$(color_of "$R_TIER")"; [[ "$RS_K" != idle ]] || model_color="$C_DIM"
  ui_rail "${branch}${conn} ${mark} ${C_BOLD}${rl}${C_RESET}${model_color}${ml}${C_RESET}${el_}${state}"
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
  /"type":"delegation",/ { n++ } /"type":"(delegation|usage|advisor)"/ && !/delegation_start/ && !/"bridge":"subagent"|"cost_in":"usage"/ { t += num("tokens_in") + num("tokens_out") } END { print n + 0, t + 0 }' "$J")"
ui_rail ""
ui_rail "${C_BOLD}effort${C_RESET} [${L_EFFORT}]  ${C_BOLD}$(t "roles")${C_RESET} [$n_run/$n_roles $(t "running")]  ${C_BOLD}$(t "advisor")${C_RESET} [${ADV:-off}]  ${C_BOLD}$(t "delegations")${C_RESET} [$n_del]  ${C_BOLD}tokens${C_RESET} [$(ai_tokens_label "$tok")]"
[[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "$(t "live: loomy watch, then t")"
exit 0
