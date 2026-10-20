#!/usr/bin/env bash
# Project and bootstrap status for Loomy. Bash 3.2 compatible.
#   loomy-status.sh                 prints the status
#   loomy-status.sh set <phase>     records the current bootstrap phase (used by the agents)
#   loomy-status.sh --audit set <phase>   records the phase of the running audit (loomy audit)
#   loomy-status.sh --watch [N]     live agents and timers every second; keys depend on the view (see the footer)
#   --compact / --full           tight view (for a narrow pane) or full view; watch picks one from the terminal size
#   loomy-status.sh --root <dir>    works on another project folder
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
# shellcheck source=lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"
# shellcheck source=lib/launch.sh
source "$SCRIPT_DIR/lib/launch.sh"
# Subscription (1) or API (0) per tool: a subscription shows its quota and tokens, the API its cost.
PLAN_C=0; loomy_on_plan claude && PLAN_C=1
PLAN_X=0; loomy_on_plan codex && PLAN_X=1
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=lib/sessionlog.sh
source "$SCRIPT_DIR/lib/sessionlog.sh"
# shellcheck source=lib/privacy.sh
source "$SCRIPT_DIR/lib/privacy.sh"
# shellcheck source=lib/failover.sh
source "$SCRIPT_DIR/lib/failover.sh"

PHASES="brief discover interview propose approve build verify document commit retire done"

ROOT=""
CMD="show"
PHASE_ARG=""
WATCH=0
COMPACT=""
JOURNAL_VIEW=0
TREE_VIEW=0
UNTIL=""
IN_PANE=0
AUDIT=0
TASKM=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --watch|-w) WATCH=1; if [[ "${2:-}" =~ ^[0-9]+$ ]]; then shift; fi ;;
    --compact) COMPACT=1 ;;
    --journal) JOURNAL_VIEW=1 ;;
    --tree) TREE_VIEW=1 ;;
    --until-exit) UNTIL="${2:-}"; shift ;;
    --pane) IN_PANE=1 ;;
    --full) COMPACT=0 ;;
    --audit) AUDIT=1 ;;
    --task) TASKM=1 ;;
    set) CMD="set"; PHASE_ARG="${2:-}"; shift ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; exit 2 ;;
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
# Audit in progress (loomy audit): its own phases and state; shown instead of the bootstrap while it runs, and
# kept on screen once finished when the folder has no Loomy project of its own.
AUDIT_STATE="$ROOT/.loomy/audit.state"
if (( ! AUDIT )) && [[ "$CMD" != "set" && -f "$AUDIT_STATE" ]]; then
  a_phase="$(sed -n 's/^phase=//p' "$AUDIT_STATE" | head -1)"
  [[ "$a_phase" != "done" || ! -f "$STATE" ]] && AUDIT=1
fi
# Task (loomy task): shown once the bootstrap is over (or when the folder has no bootstrap state).
TASK_STATE="$ROOT/.loomy/task.state"
if (( ! AUDIT && ! TASKM )) && [[ "$CMD" != "set" && -f "$TASK_STATE" ]]; then
  p_phase_now="$(sed -n 's/^phase=//p' "$STATE" 2>/dev/null | head -1)"
  [[ "$p_phase_now" == "done" || ! -f "$STATE" || ! -f "$ROOT/START.md" ]] && TASKM=1
fi
PH_TYPE="phase"; MISSION=""
if (( AUDIT )); then
  STATE="$AUDIT_STATE"; PH_TYPE="audit_phase"; loomy_phases_mode audit; MISSION="audit"
  PHASES="$LOOMY_AUDIT_PHASES done"
elif (( TASKM )); then
  STATE="$TASK_STATE"; PH_TYPE="task_phase"; loomy_phases_mode task; MISSION="task"
  PHASES="$LOOMY_TASK_PHASES done"
fi
# Texts that depend on what is followed: the bootstrap, an audit or a task.
m_text() {
  case "$MISSION:$1" in
    audit:title) t "Audit done" ;; task:title) t "Task done" ;; :title) t "Project ready" ;;
    audit:label) t "Audit done" ;; task:label) t "Task done" ;; :label) t "Bootstrap done" ;;
    audit:note) t "audit done" ;; task:note) t "task done" ;; :note) t "bootstrap done" ;;
    audit:section) echo "AUDIT" ;; task:section) echo "TASK" ;; :section) echo "PHASES" ;;
    audit:resume) echo "loomy audit --resume" ;; task:resume) echo "loomy task --resume" ;; :resume) echo "loomy start" ;;
  esac
}
m_took() { case "$MISSION" in audit) t "audit in %s" "$1" ;; task) t "task in %s" "$1" ;; *) t "bootstrap in %s" "$1" ;; esac; }
N_PH="$LOOMY_PHASE_COUNT"

if [[ "$CMD" == "set" ]]; then
  case " $PHASES " in
    *" $PHASE_ARG "*) ;;
    *) t "Unknown phase: \"%s\". Phases: %s" "$PHASE_ARG" "$PHASES" >&2; echo >&2; exit 2 ;;
  esac
  mkdir -p "$ROOT/.loomy"
  now="$(date '+%Y-%m-%d %H:%M')"
  history=""; keep=""
  [[ -f "$STATE" ]] && history="$(grep '^log=' "$STATE" || true)"
  # Other keys (a task's id and title) are kept.
  [[ -f "$STATE" ]] && keep="$(grep -vE '^(phase|updated|log)=' "$STATE" || true)"
  {
    echo "phase=$PHASE_ARG"
    [[ -n "$keep" ]] && echo "$keep"
    echo "updated=$now"
    [[ -n "$history" ]] && echo "$history"
    echo "log=$now $PHASE_ARG"
  } >"$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
  # A task's file follows its phase (status line), for the list of tasks.
  if [[ "$MISSION" == "task" ]]; then
    tf="$(sed -n 's/^file=//p' "$STATE" | head -1)"
    if [[ -n "$tf" && -f "$ROOT/$tf" && "$tf" != *..* ]]; then sed -i.bak "s/^status: .*/status: $PHASE_ARG/" "$ROOT/$tf" && rm -f "$ROOT/$tf.bak"; fi
  fi
  ai_journal_write "$ROOT" "\"type\":\"$PH_TYPE\",\"phase\":\"$PHASE_ARG\""
  t "Phase recorded: %s (%s)" "$(loomy_phase_label "$PHASE_ARG")" "$PHASE_ARG"; echo
  exit 0
fi

brief_get() {
  _ai_brief_get "$BRIEF" "$1"
}

label_of() {
  case "$1" in
    web) t "Web app / SaaS"; echo ;; api) t "API / backend"; echo ;; mobile) t "Mobile app"; echo ;;
    desktop) t "Desktop app"; echo ;; cli) t "CLI / library"; echo ;; ai) t "AI / LLM app"; echo ;;
    site) t "Showcase site / landing page"; echo ;; data) t "Data & analysis"; echo ;; emails) t "Email templates"; echo ;; custom) t "Custom"; echo ;;
    prototype) t "Prototype"; echo ;; other) t "Other"; echo ;; mvp) t "MVP"; echo ;; production) t "Production"; echo ;;
    econome) t "Thrifty"; echo ;; equilibre) t "Balanced"; echo ;; qualite) t "Max quality"; echo ;;
    codex) t "Codex"; echo ;; claude) t "Claude Code"; echo ;;
    yes) t "yes"; echo ;; no) t "no"; echo ;; "") echo "?" ;; *) echo "$1" ;;
  esac
}

# ---------------------------------------------------------------- mode surveillance
# Full screen, redrawn in place every second (nothing piles up in the history). Between two frames, tracking
# spots what changes (phase, delegation finished or failed, session closed): it highlights it for a few
# seconds and notifies (macOS) with a beep. Keys: q quit, c compact/full view,
# l log, s open the session.
watch_notify() {
  [[ "$(loomy_config_get notify 2>/dev/null || true)" == "no" ]] && return 0
  printf '\a' >&2
  if [[ "$(uname -s)" == "Darwin" ]] && command -v osascript >/dev/null 2>&1; then
    local t="${1//\"/\'}" m="${2//\"/\'}"
    osascript -e "display notification \"$m\" with title \"Loomy · ${NAME_W//\"/\'}\" subtitle \"$t\"" >/dev/null 2>&1 &
  fi
  return 0
}

# The sampler owns legacy aggregates too; frames receive snapshots, never read history.
read -r -d '' LOOMY_WATCH_LEGACY_PERL <<'PERL' || true
use utf8;
use Digest::MD5 ();
package Loomy::WatchLegacy;
sub title { my $s=text($_[0]); $s =~ s/^\s*(?:GOAL|TASK|OBJECTIF)\s*:\s*//i; $s =~ s/\bSCOPE\s*:.*//is; $s =~ s/[\r\n].*//s; $s =~ s/([.!?])(?:\s|$).*/$1/s; $s =~ s/\s+/ /g; $s =~ s/^\s+|\s+$//g; $s }
sub alive { my $p=text($_[0]); $p =~ /^\d+$/ && $p>1 && (kill(0,$p) || $! == Errno::EPERM()) }
sub new { bless {seq=>0,rows=>[],log=>[],sessionlog=>[],starts=>[],last=>[],models=>{},phase=>{},usage=>[0,0,0,0,0,0],advisor=>[0,0,0,"-","",0],total=>[0,0,0,0,0,0,0,0,0],monthly=>{},sessions=>{},seen=>{},avg=>{},done=>{}},shift }
sub text { defined $_[0] && !ref($_[0]) ? "$_[0]" : "" }
# Dedup memory is bounded: 16-byte digests of the canonical event, oldest forgotten beyond the cap.
sub once {
  my ($s,$name,$identity)=@_; my $key=Digest::MD5::md5(JSON::PP->new->canonical->utf8->encode($identity));
  my $seen=$s->{$name}//={}; return 1 if $seen->{$key}++;
  my $queue=$s->{"${name}_queue"}//=[]; push @$queue,$key;
  if (@$queue>20000) { delete $seen->{$_} for splice @$queue,0,5000 }
  return 0;
}
sub num { my $s=text($_[0]); $s =~ /^\d+(?:\.\d+)?$/ ? 0+$s : 0 }
sub wire { my @v=@_; for (@v) {$_=text($_); s/[\x00-\x1f|]/ /g} join("|",@v) }
# Archive bootstrap summaries are read once; current-file snapshots cannot add them twice.
sub phase_consume {
  my ($s,$d,$pc,$px)=@_; my $ty=text($d->{type}); my %identity=%$d; delete $identity{snapshot};
  return if $ty =~ /^(delegation(?:_start|_activity)?|session(?:_observed|_context|_activity)?)$/ && $s->once("phase_seen",\%identity);
  my $ts=text($d->{ts}); my $tk=num($d->{tokens_in})+num($d->{tokens_out}); my $cost=num($d->{cost_usd});
  my $plan=text($d->{family}) eq "claude" ? $pc : $px;
  # Every completed event contributes once; bootstrap/task/audit summaries stop at done.
  for my $ph (qw(phase audit_phase task_phase)) {
    my $b=$s->{phase}{$ph}//=["-","-",0,0,0];
    if ($ty eq $ph) {
      if ($ph ne "phase" && text($d->{phase}) eq ($ph eq "audit_phase" ? "scope" : "plan")) { $b=$s->{phase}{$ph}=[$ts,"-",0,0,0] }
      $b->[0]=$ts if $b->[0] eq "-"; $b->[1]=$ts if text($d->{phase}) eq "done";
    }
    if ($b->[1] eq "-" && $ty =~ /^(delegation|usage|advisor)$/) {++$b->[2] if $ty eq "delegation"; $b->[$plan ? 4 : 3]+=$plan ? $tk : $cost}
  }
 }
sub consume {
  my ($s,$d,$pc,$px)=@_; my $ty=text($d->{type}); return if $ty eq "";
  my %identity=%$d; delete $identity{snapshot};
  my $owner=text($d->{tool}//$d->{family})."|".text($d->{owner_pid}//$d->{pid});
  ++$s->{lifetimes}{$owner} if $ty eq "session" && text($d->{event}) eq "end";
  $identity{owner_lifetime}=$s->{lifetimes}{$owner}//0 if $ty =~ /^(delegation_start|delegation_activity|session)$/;
  return if $ty =~ /^(delegation(?:_start|_activity)?|session(?:_observed|_context|_activity)?)$/ && $s->once("seen",\%identity);
  my $ts=text($d->{ts}); my $tk=num($d->{tokens_in})+num($d->{tokens_out}); my $cost=num($d->{cost_usd});
  my $fam=text($d->{family}); my $plan=$fam eq "claude" ? $pc : $px;
  my $id=text($d->{id}); my $role=text($d->{role}); my $model=text($d->{model});
  my $task=title($d->{task}); my $status=text($d->{status}); my $outcome=text($d->{outcome});
  my $bridge=text($d->{bridge}); my $duration=num($d->{duration_s});
  $s->{has_native}=1 if $bridge eq "codex-native";
  $s->phase_consume($d,$pc,$px);
  if ($ty eq "usage") {
    my $i=text($d->{scope}) eq "lead" ? 0 : 3; my $u=$s->{usage};
    $u->[$i]+=$i==0 ? num($d->{messages}) : 1; $u->[$i+1]+=$cost; $u->[$i+2]+=$tk; $s->{has_usage}=1;
  }
  if ($ty eq "advisor") {my $a=$s->{advisor}; $a->[0]+=num($d->{calls}); $a->[1]+=$cost; $a->[2]+=$tk; $a->[3]=$model||"-"; $a->[4]=$ts; $a->[5]+=num($d->{tokens_in}); $s->{has_advisor}=1}
  if ($ty eq "delegation_start") {push @{$s->{starts}},$d; shift @{$s->{starts}} while @{$s->{starts}}>20}
  if ($ty eq "delegation") {
    $s->{done}{$id}=1; my $t=$s->{total}; ++$t->[0];
    ++$t->[8] if text($d->{review}) eq "incomplete";
    if ($bridge eq "codex-native") {++$t->[5]; ++$t->[2] if $status ne "ok"}
    else {
      my $m=$s->{models}{$model}//=[0,0,0,$plan]; ++$m->[0]; $m->[2]+=$tk;
      if ($plan) {$t->[4]+=$tk} else {$m->[1]+=$cost; $t->[1]+=$cost; ++$t->[3]}
      if ($status eq "paused") {++$t->[6]} elsif ($status eq "handed_over") {++$t->[7]} elsif ($status ne "ok") {++$t->[2]}
    }
    my $a=$s->{avg}{"$role|$model"}//=[0,0]; $a->[0]+=$duration; ++$a->[1];
    push @{$s->{last}},wire($ts,$status,$role,$model,$duration,$cost,(text($d->{failover_from}) ne "" ? "⇄ " : "").substr($task,0,40),$fam,$tk,$outcome,$bridge);
    shift @{$s->{last}} while @{$s->{last}}>5;
  }
  if ($ty =~ /^(delegation|usage)$/) {$s->{monthly}{substr($ts,0,7)."|$fam"}+=$cost}
  if ($ty =~ /^(delegation|usage|advisor)$/ && $bridge ne "subagent" && text($d->{cost_in}) ne "usage") {$s->{tokens}+=$tk}
  my ($who,$what,$extra)=("","","");
  if ($ty eq "delegation_start") {($who,$what,$extra)=($role,"start","$model · ".substr($task,0,52))}
  elsif ($ty eq "delegation") {($who,$what,$extra)=($role,$status eq "ok" ? ($outcome =~ /^(partial|blocked)$/ ? $outcome : "done") : "failed",($duration>=60 ? int($duration/60)." min ".($duration%60)." s" : "$duration s")." · $model".(text($d->{failover_from}) ne "" ? " · ⇄ ".$d->{failover_from} : ""))}
  elsif ($ty eq "advisor") {($who,$what,$extra)=("advisor","consulted",num($d->{calls})." × $model · ".int(num($d->{tokens_in})/1000)."k")}
  elsif ($ty =~ /^(phase|task_phase|audit_phase)$/) {my $mode=$ty; $mode =~ s/_?phase$//; ($who,$what,$extra)=("phase",text($d->{phase}),$mode)}
  elsif ($ty eq "session") {($who,$what,$extra)=("session",text($d->{event}),text($d->{tool}))}
  elsif ($ty eq "skill") {($who,$what,$extra)=("skills",text($d->{event}),text($d->{name})." · ".substr(text($d->{reason}),0,52))}
  elsif ($ty eq "usage" && text($d->{scope}) eq "lead") {($who,$what,$extra)=("lead","replied",num($d->{messages})." msg · $model")}
  if ($who ne "") {push @{$s->{sessionlog}},wire($ts,$who,$what,$extra); shift @{$s->{sessionlog}} while @{$s->{sessionlog}}>400}
  push @{$s->{log}},JSON::PP->new->canonical->encode($d); shift @{$s->{log}} while @{$s->{log}}>400; $s->{log_dirty}=1;
  # Legacy rows carry the same normalized fields as the one-shot Bash reducer.
  $s->{dirty}=1;
  return if $bridge eq "claude-native" && text($d->{source}) eq "hook";
  my $seq=++$s->{seq}; my $tool=text($d->{tool}//$d->{family}//($bridge eq "subagent" ? "claude" : ""));
  my $sid=text($d->{session}); my $context=$s->{context}//"";
  if ($ty eq "session") {
    my $key="$tool|".($sid || "pid".text($d->{pid}));
    if (text($d->{event}) eq "start") {my $old=$s->{sessions}{$key}; $s->{sessions}{$key}={%$d,seq=>($old && !$old->{ended} && $sid ne "" && text($old->{pid}) eq text($d->{pid}) ? $old->{seq} : $seq)}; $s->{context}=$context=$key; $s->{lead_context}{$tool}=$key; push @{$s->{status_order}},$key; shift @{$s->{status_order}} while @{$s->{status_order}}>10}
    else {$s->{sessions}{$key}{ended}=1 if $s->{sessions}{$key}; $s->{last_end}=[$ts,$tool]}
  }
  $context=$s->{lead_context}{$tool}//$context if $ty eq "usage" && text($d->{scope}) eq "lead";
  my %v=(%$d,tool=>$tool,task=>$task,excerpt=>title($d->{excerpt}),cost_usd=>int($cost*1000000+0.5));
  $v{pid}=$d->{owner_pid}//0 if $bridge eq "codex-native";
  $v{duration_s}="—" if $bridge eq "codex-native" && $ty eq "delegation" && !defined $d->{duration_s};
  $v{requested}=defined $d->{requested} ? ($d->{requested} ? "true" : "false") : "";
  my $row=wire($ty,Loomy::LiveState::epoch($ts),map {$v{$_}} qw(id event session pid tool role model effort task status duration_s cost_usd outcome excerpt requested off_routing bridge cost_in scope agent_id activity context_freshness resume_at));
  push @{$s->{rows}},[$seq,$context,$row]; $s->{dirty}=1;
}
sub snapshot {
  my ($s,$preferred,$native,$force_logs)=@_; my @out;
  if (delete $s->{dirty}) {
    push @out,"K|reset";
    for my $ph (sort keys %{$s->{phase}}) {my @v=@{$s->{phase}{$ph}}; $v[3]=sprintf "%.2f",$v[3]; push @out,wire("K","B",$ph,join(" ",@v))}
    push @out,wire("K","U",sprintf("%d %.4f %d %d %.4f %d",@{$s->{usage}}));
    my @a=@{$s->{advisor}}; $a[1]=sprintf "%.4f",$a[1]; push @out,wire("K","V",join(" ",@a));
    my @t=@{$s->{total}}; $t[1]=sprintf "%.4f",$t[1]; push @out,wire("K","S","TOTAL ".join(" ",@t));
    for my $m (sort keys %{$s->{models}}) {my @v=@{$s->{models}{$m}}; $v[1]=sprintf "%.4f",$v[1]; push @out,wire("K","M","MODEL $m ".join(" ",@v))}
    push @out,map {"K|F|$_"} @{$s->{last}};
    for my $d (@{$s->{starts}}) {next if $s->{done}{text($d->{id})} || text($d->{bridge}) eq "codex-native"; my $a=$s->{avg}{text($d->{role})."|".text($d->{model})}; push @out,wire("K","R",$d->{pid},$d->{ts},$d->{role},$d->{model},substr(title($d->{task}),0,60),$a && $a->[1] ? int($a->[0]/$a->[1]) : "")}
    push @out,wire("K","H",$s->{has_usage}//0,$s->{has_advisor}//0,$t[0],$s->{has_native}//0);
    push @out,wire("K","Q",$t[0],$s->{tokens}//0);
    push @out,map {wire("K","C",split(/\|/,$_),$s->{monthly}{$_})} sort keys %{$s->{monthly}};
    for my $key (reverse @{$s->{status_order}//[]}) {
      my $session=$s->{sessions}{$key}; next if !$session || $session->{ended};
      push @out,wire("K","O","open",$session->{pid},Loomy::LiveState::epoch($session->{ts}),$session->{tool});
    }
    push @out,wire("K","O","end","",Loomy::LiveState::epoch($s->{last_end}[0]),$s->{last_end}[1]) if $s->{last_end};
    push @out,"K|end";
    # Aggregates are re-sent only when a visible one changed (native activity alone changes none).
    my $digest=Digest::MD5::md5_hex(join("\n",@out));
    if (($s->{agg_digest}//"") eq $digest) { @out=() } else { $s->{agg_digest}=$digest }
  }
  # The bounded logs feed the status and log views only: coalesce bursts to one batch per second, at once on l/t.
  my $now=Time::HiRes::time();
  if ($s->{log_dirty} && ($force_logs || $now-($s->{log_sent}//0)>=1)) {
    push @out,"K|logreset",(map {"K|L|$_"} @{$s->{log}}),(map {"K|J|$_"} @{$s->{sessionlog}}),"K|logend";
    $s->{log_dirty}=0; $s->{log_sent}=$now;
  }
  return @out if $native;
  my @starts=sort {$b->{seq}<=>$a->{seq}} values %{$s->{sessions}};
  my @alive=grep {!$_->{ended} && alive($_->{pid})} @starts;
  my ($chosen)=grep {text($_->{tool}) eq $preferred} @alive; $chosen //= $alive[0] // $starts[0];
  my $seq=$chosen ? $chosen->{seq} : 0;
  my $reset=!defined $s->{selected} || $s->{selected}!=$seq;
  push @out,"E|RESET" if $reset; push @out,"E|SELECT|legacy:$seq|$seq" if $reset;
  my $sent=$reset ? 0 : $s->{sent}//0;
  for my $r (@{$s->{rows}}) {next if $r->[0]<=$sent; my $owner=$s->{sessions}{$r->[1]}; if ($r->[2]=~/^usage\|/ && $r->[0]>$seq && $owner && $owner->{seq}!=$seq && $r->[2]=~/\|lead\|/) {push @out,"E|IGNORE"; next} push @out,"E|".$r->[2]}
  $s->{sent}=$s->{seq}; $s->{selected}=$seq;
  return @out;
}
package main;
PERL

# One persistent sampler waits on the terminal and watches cheap local file signatures.
# Foreground stty avoids the SIGTTIN/stty race of a background Bash read -s.
loomy_watch_feed() {
  umask 077
  local errors=/dev/null
  ai_journal_enabled "$ROOT" && ai_journal_prepare "$ROOT" && errors="$ROOT/.loomy/logs/watch-errors.log" || true
  exec perl -MIO::Select -MTime::HiRes=time,stat -MFcntl=O_RDWR,O_APPEND,O_CREAT,O_NOFOLLOW -e "$LOOMY_WATCH_LEGACY_PERL"'
    binmode STDOUT, ":encoding(UTF-8)";
    my ($root,$cfg,$terminal,$native,$sessions,$reducer,$claude,$projects,$owner,$until,$errors,$pc,$px,$preferred)=@ARGV; $|=1;
    my %reported;
    my $diagnostics=$native; $diagnostics =~ s{/[^/]+$}{/watch-errors.pl};
    require $diagnostics;
    my $failed=0;
    my $attempt=sub {
      my ($stage,$action)=@_; my $result=eval {$action->()};
      if ($@) {Loomy::WatchErrors::record($errors,$stage,"exception"); $failed=1}
      return $result;
    };
    $SIG{__WARN__}=sub {
      my $kind=join("",@_) =~ /Native checkpoint invalid; reconstructing/ ? "checkpoint-recovering" : "warning";
      return if $reported{$kind}++;
      Loomy::WatchErrors::record($errors,"sampler",$kind); $failed=1;
    };
    my $live;
    $attempt->("initialize",sub {require $native; require $reducer; require $claude; $live=Loomy::LiveState->new});
    my $tty; open $tty,"<","/dev/tty" if $terminal;
    my $input=$tty; open $input,"<&",7 or die $! unless $input;
    my $select=IO::Select->new; $select->add($input) if $input;
    my @files=map { "$root/.loomy/$_" } qw(state audit.state task.state failover brief.md efforts session-only);
    push @files,$ENV{LOOMY_SESSION_ONLY} if ($ENV{LOOMY_SESSION_ONLY}//"") =~ /^\Q$root\E\/\.loomy\/session-only-\d+-[A-Za-z0-9]+$/;
    push @files,map { "$cfg/$_" } qw(config claude-limits codex-limits models.conf);
    my ($last,$buf,$last_tick,$maintained,$claude_maintained)=("","",0,0,0);
    my ($state,$claude_state,$discovering);
    my $legacy=Loomy::WatchLegacy->new;
    $attempt->("legacy-archives",sub {
      for my $file (sort glob "$root/.loomy/logs/archive/events-*.jsonl") {
        my $archive=Loomy::LiveState->new;
        do { $legacy->phase_consume($_,$pc,$px) for $archive->journal_records($file) }
          while (!$archive->{cursor}{at_eof} && $archive->{read_bytes});
      }
    });
    my $consume=\&Loomy::LiveState::consume;
    { no warnings "redefine";
      *Loomy::LiveState::consume=sub {
        my ($self,$d)=@_; $legacy->consume($d,$pc,$px) if $live && $self==$live;
        return $consume->(@_);
      };
    }
    while (1) {
      last unless kill 0,$owner;
      last if $until && !kill(0,$until);
      my $key="";
      if ($select->can_read(0.10)) { my $n=sysread($input,my $bytes,32); last unless defined($n) && $n; $buf.=$bytes }
      if ($buf =~ s/^\e\[A//) { $key="up" }
      elsif ($buf =~ s/^\e\[B//) { $key="down" }
      elsif ($buf ne "" && $buf !~ /^\e(?:\[)?$/) { $key=substr($buf,0,1,""); $key="" if $key =~ /[\x00-\x1f|]/ }
      my $wall=time; my $now=int($ENV{LOOMY_NATIVE_NOW}//$wall);
      $attempt->("initialize",sub {require $native; require $reducer; require $claude; $live=Loomy::LiveState->new}) unless $live;
      $attempt->("codex",sub {
        if (Loomy::CodexNative::watch_changed($root,$sessions,$now) || int($wall)!=$maintained) {
          $state=Loomy::CodexNative::poll($root,$sessions); $maintained=int($wall);
        }
      });
      $attempt->("claude",sub {
        if (Loomy::ClaudeNative::watch_changed($root,$projects) || int($wall)!=$claude_maintained) {
          $claude_state=Loomy::ClaudeNative::poll($root,$projects); $claude_maintained=int($wall);
        }
      });
      my $pending=$state ? ($state->{discovering}//0) : 0;
      if (!defined($discovering) || $pending!=$discovering) {print "D|$pending\n"; $discovering=$pending}
      my @deltas;
      $attempt->("reducer",sub {
        return unless $live;
        $live->read_journal("$root/.loomy/logs/events.jsonl"); $live->source_evidence($state);
        $live->claude_evidence($claude_state); @deltas=($legacy->snapshot($preferred,$live->{native},$key =~ /^[ltLT]$/),$live->projections($now));
      });
      if ($failed) {print "W|error\n"; $failed=0}
      my $sig="";
      for my $f (@files) { my @s=stat($f); $sig.=join(":",@s ? @s[0,1,7,9] : "-").";" }
      my ($rows,$cols)=(0,0);
      if ($tty) {
        my $size=""; ioctl($tty,$^O eq "darwin" ? 0x40087468 : 0x5413,$size);
        ($rows,$cols)=unpack("SS",$size) if length($size)>=4; $sig.=$size;
      }
      my @t=localtime($now); my $clock=sprintf "%02d:%02d:%02d",@t[2,1,0];
      my $dirty=$sig ne $last ? 1 : 0;
      # Send complete batches only on changes, input or a clock tick, never five idle frames/s.
      if (@deltas || $dirty || $key ne "" || $now!=$last_tick) {
        print join("",map { "$_\n" } @deltas),join("|",$now,$dirty,$key,$clock,$rows,$cols),"\n";
        $last_tick=$now;
      }
      $last=$sig;
    }
  ' "$ROOT" "${XDG_CONFIG_HOME:-$HOME/.config}/loomy" "$1" "$AI_CODEX_NATIVE_LIB" "${CODEX_HOME:-$HOME/.codex}/sessions" "$AI_LIVE_STATE_LIB" "$AI_CLAUDE_NATIVE_LIB" "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" "$$" "$UNTIL" "$errors" "$PLAN_C" "$PLAN_X" "${AI_LEAD:-}" 2>/dev/null
}

# A slow frame must not queue old clocks ahead of input. Read no further than the first key.
loomy_watch_coalesce() {
  if [[ "${LOOMY_WATCH_INLINE:-0}" == 1 ]]; then
    printf '%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "${watch_rows:-0}" "${watch_cols:-0}" >&9
    local feed_line
    while IFS= read -r feed_line <&10; do
      if [[ "$feed_line" == D\|* ]]; then watch_discovering="${feed_line#D|}"; force_frame=1; continue; fi
      if [[ "$feed_line" == W\|* ]]; then watch_error=1; force_frame=1; continue; fi
      if [[ "$feed_line" == E\|* ]]; then loomy_watch_legacy_accept "$feed_line"; native_dirty=1; continue; fi
      if [[ "$feed_line" == K\|* ]]; then LEGACY_VISIBLE=0; loomy_watch_legacy_accept "$feed_line"; (( ! LEGACY_VISIBLE )) || native_dirty=1; continue; fi
      if [[ "$feed_line" == N\|* ]]; then loomy_native_accept "$feed_line"; native_dirty=1; continue; fi
      loomy_native_read "$feed_line" now dirty key LV_CLOCK watch_rows watch_cols
      return 0
    done
    return 1
  fi
  # The server PID must be the Perl reader, so cleanup cannot wait on a blocked shell.
  local runner=(perl)
  [[ "${LOOMY_WATCH_SERVER:-0}" != 1 ]] || runner=(exec perl)
  "${runner[@]}" -MIO::Select -e '
    $|=1; my $server=$ENV{LOOMY_WATCH_SERVER};
    my ($owner,$dir)=splice @ARGV,-2;
    $SIG{PIPE}=sub {exit 0}; $SIG{TERM}=sub {exit 0};
    END {if ($server && $dir) {unlink "$dir/request"; rmdir $dir}}
    my $pending="";
    my $requests; open $requests,"<&",9 or die $! if $server;
    while (1) {
    my @args=@ARGV;
    if ($server) {
        my $ready=IO::Select->new($requests);
        while ($pending !~ /\n/) {
            exit 0 if getppid()==1 || !kill(0,$owner);
            next unless $ready->can_read(1);
            my $n=sysread($requests,my $bytes,4096); exit 0 unless defined($n) && $n;
            $pending.=$bytes;
        }
        $pending =~ s/^([^\n]*)\n//; @args=split /\|/,$1,-1;
    }
    my ($now,$dirty,$key,$clock,$rows,$cols)=@args; my @deltas;
    if ($key eq "") {
      open my $feed,"<&",8 or die "watch feed unavailable: $!";
      my $select=IO::Select->new($feed);
      while ($key eq "" && $select->can_read(0)) {
        my $line=""; my $n;
        while (($n=sysread($feed,my $char,1)) && $n==1) { $line.=$char; last if $char eq "\n" }
        last unless $line =~ /\n$/;
        chomp $line;
        if ($line =~ /^(?:N|W|D|E|K)\|/) { push @deltas,$line; next }
        my @row=split /\|/,$line,-1;
        next unless (@row==4 || @row==6) && $row[0]=~/^\d+$/ && $row[1]=~/^[01]$/;
        ($now,$key,$clock,$rows,$cols)=@row[0,2,3,4,5]; $dirty=($dirty || $row[1]) ? 1 : 0;
      }
    }
    print "$_\n" for @deltas;
    print join("|",$now,$dirty,$key,$clock,($server ? ($rows//0,$cols//0) : ())),"\n";
    last unless $server;
    }
  ' "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${watch_rows:-0}" "${watch_cols:-0}" "$$" "${WATCH_PIPE:-}"
}

# Keep navigation and its labels together: the tree's list is not the live-agent list.
watch_keys() {
  local word
  tv word orchestrator; WATCH_KEYS="[o] $word"
  if [[ "$view" == list ]]; then tv word status; else tv word 'live list'; fi
  WATCH_KEYS="$WATCH_KEYS · [a] $word"
  if [[ "$view" == tree ]]; then
    tv word status; WATCH_KEYS="$WATCH_KEYS · [t] $word"
    if [[ "$tree_layout" == list ]]; then tv word diagram; else tv word list; fi
    WATCH_KEYS="$WATCH_KEYS · [v] $word"
  else tv word tree; WATCH_KEYS="$WATCH_KEYS · [t] $word"; fi
  if [[ "$view" == list ]]; then
    if [[ "$LV_GROUP" == model ]]; then tv word 'group by request'; else tv word 'group by model'; fi
    WATCH_KEYS="$WATCH_KEYS · [v] $word"
  elif [[ "$view" == status ]]; then
    if [[ "$size" == --compact ]]; then tv word 'full view'; else tv word 'compact view'; fi
    WATCH_KEYS="$WATCH_KEYS · [c] $word"
  fi
  if [[ "$view" == log ]]; then tv word status; else tv word log; fi
  WATCH_KEYS="$WATCH_KEYS · [l] $word"
  if [[ -z "$UNTIL" ]] && (( ! IN_PANE )); then tv word session; WATCH_KEYS="$WATCH_KEYS · [s] $word"; fi
  tv word quit; WATCH_KEYS="$WATCH_KEYS · [q] $word"
}

loomy_watch_log_pretty() {
  local z sign=1 OFFSET PHASEMAP="" p i=0
  z="$(date +%z)"; [[ "${z:0:1}" != '-' ]] || sign=-1
  OFFSET=$(( sign * (10#${z:1:2} * 60 + 10#${z:3:2}) ))
  for p in $LOOMY_PHASES "done"; do i=$(( i + 1 )); PHASEMAP="$PHASEMAP$p=$i:$(loomy_phase_label "$p")|"; done
  # Subscription: tokens for each piece of work; API: its cost.
  local pc=0 px=0; loomy_on_plan claude && pc=1; loomy_on_plan codex && px=1
  awk -v pc="$pc" -v px="$px" -v off="$OFFSET" -v pm="$PHASEMAP" -v R="$C_RAIL" -v Z="$C_RESET" -v D="$C_DIM" -v B="$C_BOLD" \
      -v G="$C_GREEN" -v Y="$C_YELLOW" -v E="$C_RED" -v P="$C_BRAND" \
      -v T_START="$(t "starts")" -v T_IN="$(t "in ")" -v T_FAIL="$(t "failed after ")" -v T_DONE="$(t "Bootstrap done")" \
      -v T_PHASE="$(t "Phase")" -v T_REPLIES="$(t "reply(ies)")" -v T_SUB="$(t "sub-agent")" \
      -v T_REVIEW="$(t "review without TRIED")" \
      -v T_OPEN="$(t "Session opened")" -v T_CLOSED="$(t "Session closed")" '
    BEGIN { n = split(pm, a, "|"); for (i = 1; i <= n; i++) if (a[i] != "") { split(a[i], kv, "="); split(kv[2], il, ":"); idx[kv[1]] = il[1]; lab[kv[1]] = il[2] } }
    function field(k,   v) { if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/\\"/, "\"", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
    function hm(ts,   h, m, t) { h = substr(ts, 12, 2) + 0; m = substr(ts, 15, 2) + 0; t = (h * 60 + m + off + 1440) % 1440; return sprintf("%02d:%02d", int(t / 60), t % 60) }
    function dur(s) { s = int(s + 0.5); return s < 60 ? s " s" : int(s / 60) " min " sprintf("%02d", s % 60) " s" }
    function cut(s, w) { return length(s) > w ? substr(s, 1, w - 1) "…" : s }
    function tool(t) { return t == "codex" ? "Codex" : "Claude Code" }
    function tk(n) { return n >= 1e6 ? sprintf("%.1fM", n / 1e6) : (n >= 1e3 ? sprintf("%.1fk", n / 1e3) : sprintf("%d", n)) }
    function val() { return ((field("family") == "codex" ? px : pc) + 0) ? sprintf("%7s tk", tk(num("tokens_in") + num("tokens_out"))) : sprintf("%10s", sprintf("$%.4f", num("cost_usd"))) }
    {
      t = D hm(field("ts")) Z; ty = field("type"); if (ty == "agent_alias") next
      if (ty == "delegation_start" || ty == "delegation") {
        identity = field("session") "|" (field("turn_id") != "" ? field("turn_id") : field("id")) "|" ty
        if ((field("bridge") == "subagent" || field("bridge") == "claude-native") && seen[identity]++) next
      }
      if (ty == "delegation_start") printf "%s  %s◐%s %-10s %s%-16s%s %s%s%s  %s%s%s\n", t, Y, Z, field("role"), D, field("model"), Z, D, T_START, Z, D, cut(field("task"), 48), Z
      else if (ty == "delegation") {
        ok = field("status") == "ok"; oc = field("outcome")
        mk = ok ? G "✓" Z : E "✗" Z; if (ok && oc == "partial") mk = Y "◐" Z; if (ok && oc == "blocked") mk = Y "■" Z
        printf "%s  %s %-10s %s%-16s%s %s%s%s  %s%s%s  %s%s%s%s\n", t, mk, field("role"), D, field("model"), Z, (ok ? "" : E), (ok ? T_IN : T_FAIL) dur(num("duration_s")), Z, D, val(), Z, D, (field("failover_from") != "" ? "⇄ " : "") cut(field("task"), 36), Z, (field("review") == "incomplete" ? " · " Y T_REVIEW Z : "")
      }
      else if (ty == "phase") { ph = field("phase"); if (ph == "done") printf "%s  %s✦ %s%s\n", t, G B, T_DONE, Z; else printf "%s  %s▲ %s %s/10 · %s%s\n", t, P, T_PHASE, idx[ph], lab[ph], Z }
      else if (ty == "usage") {
        if (field("scope") == "lead") printf "%s  %s◆%s %-10s %s%-16s%s %s%d %s%s  %s%s%s\n", t, P, Z, "lead", D, field("model"), Z, D, num("messages"), T_REPLIES, Z, D, val(), Z
        else printf "%s  %s◇%s %-10s %s%-16s%s %s%s%s  %s%s%s\n", t, P, Z, cut(field("agent"), 10), D, field("model"), Z, D, T_SUB, Z, D, val(), Z
      }
      else if (ty == "session") printf "%s  %s %s\n", t, (field("event") == "start" ? G "●" Z " " T_OPEN : D "○ " T_CLOSED Z), D "(" tool(field("tool")) ")" Z
      else printf "%s  %s· %s%s\n", t, D, ty, Z
      fflush()
    }'
}


# Aggregates are snapshots from the feed; the bounded log is formatted once per batch.
loomy_watch_legacy_accept() {
  local kind item value tail
  if [[ "$1" == E\|* ]]; then
    loomy_live_accept "${1#E|}"; return 0
  fi
  # The bounded logs (hundreds of rows per batch) take a shortcut: no field splitting, no growing string per row;
  # the rows are joined once at logend.
  case "$1" in
    K\|L\|*) LEGACY_LOG_ARR[${#LEGACY_LOG_ARR[@]}]="${1#K|L|}"; return 0 ;;
    K\|J\|*) LEGACY_SESSION_ARR[${#LEGACY_SESSION_ARR[@]}]="${1#K|J|}"; return 0 ;;
  esac
  loomy_native_read "${1#K|}" item value tail
  case "$item" in
    reset) LEGACY_SEQ=$(( ${LEGACY_SEQ:-0} + 1 )); LEGACY_SUMMARY=""; LEGACY_LAST=""; LEGACY_RUNNING=""; LEGACY_MONTH=(); LEGACY_PHASE=(); LEGACY_SESSIONS=(); LEGACY_VISIBLE=1 ;;
    logreset) LEGACY_LOG_JSON=""; LEGACY_SESSION_ROWS=""; LEGACY_LOG_ARR=(); LEGACY_SESSION_ARR=() ;;
    B) LEGACY_PHASE+=("$value|$tail") ;;
    U) LEGACY_USAGE="$value" ;;
    V) LEGACY_ADVISOR="$value" ;;
    S|M) LEGACY_SUMMARY="$LEGACY_SUMMARY$value"$'\n' ;;
    F) LEGACY_LAST="$LEGACY_LAST$value|$tail"$'\n' ;;
    R) LEGACY_RUNNING="$LEGACY_RUNNING$value|$tail"$'\n' ;;
    H) loomy_native_read "$value|$tail" LEGACY_HAS_USAGE LEGACY_HAS_ADVISOR LEGACY_COUNT LEGACY_NATIVE ;;
    Q) LEGACY_TOTAL="$value $tail" ;;
    O) LEGACY_SESSIONS+=("$value|$tail") ;;
    C) LEGACY_MONTH+=("$value|$tail") ;;
    L) LEGACY_LOG_JSON="$LEGACY_LOG_JSON$value${tail:+|$tail}"$'\n' ;;
    J) LEGACY_SESSION_ROWS="$LEGACY_SESSION_ROWS$value|$tail"$'\n' ;;
    logend)
      (( ${#LEGACY_LOG_ARR[@]} == 0 )) || printf -v LEGACY_LOG_JSON '%s\n' "${LEGACY_LOG_ARR[@]}"
      (( ${#LEGACY_SESSION_ARR[@]} == 0 )) || printf -v LEGACY_SESSION_ROWS '%s\n' "${LEGACY_SESSION_ARR[@]}"
      LEGACY_LOG_ARR=(); LEGACY_SESSION_ARR=()
      LEGACY_LOG_SEQ=$(( ${LEGACY_LOG_SEQ:-0} + 1 )); [[ "${view:-}" != status && "${view:-}" != log ]] || LEGACY_VISIBLE=1 ;;
  esac
}
# The pretty log (awk) and session events (perl) cost a process each: build them only for a view that shows them,
# and only when the sampler's log changed since the last build.
loomy_watch_legacy_pretty() {
  [[ "${view:-}" == status || "${view:-}" == log ]] || return 0
  [[ "${LEGACY_PRETTY_SEQ:--1}" != "${LEGACY_LOG_SEQ:-0}" ]] || return 0
  LEGACY_PRETTY_SEQ="${LEGACY_LOG_SEQ:-0}"
  LEGACY_LOG_PRETTY="$(printf '%s' "$LEGACY_LOG_JSON" | loomy_watch_log_pretty)"
  LEGACY_SESSION_PRETTY="$(
    ai_journal_tail() { printf '%s' "$LEGACY_LOG_JSON"; }
    ai_journal_display_events "$J"
  )"
}
loomy_watch_legacy_render() (
  LOOMY_WATCH_REDUCED=1
  # The frame is captured as text: the screen paginator of the controller must never draw from here.
  UI_SCREEN=0; UI_PAGE_L=()
  now_s=$LV_NOW; TICK=$tick
  LOOMY_HL_DELEG=${hl_d:-0}; LOOMY_HL_PHASE=${hl_p:-0}
  LOOMY_WATCH_ID=$$; LOOMY_NO_CLEAR=1; LOOMY_NO_HEADER=1; LOOMY_TICK=$tick
  COMPACT=0; [[ "$size" != --compact ]] || COMPACT=1
  JOURNAL_VIEW=0; [[ "$view" != log ]] || JOURNAL_VIEW=1
  # The read-side formatters see only the sampler cache, never the journal or archives.
  _ai_session_events() {
    if [[ "$view" == status ]] && (( ! LEGACY_NATIVE )); then printf '%s' "$LEGACY_SESSION_ROWS";
    else printf '%s\n' "$LEGACY_SESSION_PRETTY"; fi
  }
  ai_session_state() {
    local row kind pid ts tool state=none hhmm="?" chosen_ts=0 chosen_tool=""
    for row in ${LEGACY_SESSIONS[@]+"${LEGACY_SESSIONS[@]}"}; do
      loomy_native_read "$row" kind pid ts tool
      if [[ "$kind" == open ]]; then
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then state=open; chosen_ts=$ts; chosen_tool=$tool; break; fi
      elif [[ "$state" == none ]]; then state=closed; chosen_ts=$ts; chosen_tool=$tool; fi
    done
    [[ "$state" != none ]] || { printf 'none\n'; return; }
    (( chosen_ts <= 0 )) || hhmm="$(date -r "$chosen_ts" +%H:%M 2>/dev/null || date -d "@$chosen_ts" +%H:%M)"
    printf '%s|%s|%s\n' "$state" "$hhmm" "$chosen_tool"
  }
  case "$view" in
    list) LOOMY_WATCH_BODY_HEIGHT=$watch_body_height LOOMY_WATCH_PIN=1 LOOMY_WATCH_VIEW=list loomy_live_render ;;
    tree) LOOMY_TREE=$tree_mode loomy_tree_classic_render ;;
    *) loomy_status_render ;;
  esac
)
loomy_status_has() {
  if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then
    case "$1" in usage) (( LEGACY_HAS_USAGE )) ;; advisor) (( LEGACY_HAS_ADVISOR )) ;; delegation) (( LEGACY_COUNT )) ;; native) (( LEGACY_NATIVE )) ;; esac
  else
    case "$1" in delegation) grep -q '"type":"delegation",' "$JOURNAL" ;; native) grep -q '"bridge":"codex-native"' "$JOURNAL" ;; *) grep -q "\"type\":\"$1\"" "$JOURNAL" ;; esac
  fi
}

loomy_status_render() {
# ---------------------------------------------------------------- header
# Direct command: the status prints normally (like git status), without full screen.
# In loomy watch, the header and footer are the app frame's (LOOMY_NO_HEADER).
if [[ -n "${LOOMY_NO_HEADER:-}" ]]; then :
elif [[ "$COMPACT" == "1" ]]; then
  # Compact view: the logo too (without blank lines around it), if the terminal is wide enough.
  if ui_logo_ok; then
    _ui_logo_lines "  "
    for l in "${UI_LINES[@]}"; do ui_print "$l"; done
    ui_print ""
    ui_print "${C_RAIL}┌${C_RESET}  ${C_TITLE}$(brief_get name 2>/dev/null || true)${C_RESET}  ${C_DIM}${ROOT/#$HOME/~}${C_RESET}"
  else
    ui_print "${C_RAIL}┌${C_RESET}  ${C_BRAND}loomy${C_RESET} ${C_TITLE}$(brief_get name 2>/dev/null || true)${C_RESET}  ${C_DIM}${ROOT/#$HOME/~}${C_RESET}"
  fi
else
  ui_banner "$(t "Project status")" "${C_RESET}${C_TITLE}$(n="$(brief_get name 2>/dev/null || true)"; echo "${n:-$(basename "$ROOT")}")${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"
fi
# Loomy version copied into the project, compared with the installed one (unless this script is itself the project copy).
proj_v="$(cat "$ROOT/.loomy/VERSION" 2>/dev/null || true)"; inst_v="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || true)"
# Since 0.3, the project only has relays to the installed Loomy: nothing to do on each version.
if [[ -d "$ROOT/.loomy/scripts/lib" ]]; then
  ui_warn "$(t "Loomy scripts copied into this project (before 0.3)")" "$(t "once and for all: loomy init --update")"
elif [[ -n "$proj_v" && -n "$inst_v" ]] && ! ai_version_ge "$inst_v" "$proj_v"; then
  ui_warn "$(t "Loomy %s installed, older than this project (%s)" "$inst_v" "$proj_v")" "loomy update"
fi

# ---------------------------------------------------------------- agent tree (key t of loomy watch)
if (( TREE_VIEW )); then exec bash "$SCRIPT_DIR/loomy-tree.sh" --root "$ROOT"; fi

# ---------------------------------------------------------------- vue journal (touche l de loomy watch)
if (( JOURNAL_VIEW )); then
  ui_section "$(t "LOG")" "$(t "latest events, local time")"
  _ui_term_size
  jn=$(( UI_ROWS - 9 )); (( jn < 5 )) && jn=5
  if [[ -s "$(ai_journal_file "$ROOT")" ]]; then
    if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then
      while IFS= read -r l; do ui_rail "$l"; done < <(printf '%s\n' "$LEGACY_LOG_PRETTY" | tail -n "$jn")
    else
      while IFS= read -r l; do ui_rail "$l"; done < <(bash "$SCRIPT_DIR/loomy-log.sh" --root "$ROOT" -n "$jn" 2>/dev/null || true)
    fi
  else
    ui_info "$(t "log empty for now")"
  fi
  [[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "${LOOMY_STATUS_FOOTER:-$(t "full log: loomy log")}"
  return 0
fi

# ---------------------------------------------------------------- phases du bootstrap
CURRENT=""
[[ -f "$STATE" ]] && CURRENT="$(sed -n 's/^phase=//p' "$STATE" | head -1)"
UPDATED=""
[[ -f "$STATE" ]] && UPDATED="$(sed -n 's/^updated=//p' "$STATE" | head -1)"

if [[ -z "$MISSION" && -z "$CURRENT" && ( -f "$ROOT/.loomy/docs/bootstrap/START.completed.md" || -f "$ROOT/.ai/bootstrap/START.completed.md" ) ]]; then CURRENT="done"; fi
if [[ -z "$MISSION" && -z "$CURRENT" && -f "$ROOT/START.md" && -f "$BRIEF" ]]; then CURRENT="brief"; fi
idx="$(loomy_phase_index "$CURRENT")"
note=""
if [[ "$CURRENT" == "done" ]]; then note="$(m_text note)"
elif (( idx > 0 )); then note="$(t "step %s of %s" "$idx" "$N_PH")${UPDATED:+ · $(t "since %s" "${UPDATED##* }")}"; fi
ui_section "$(m_text section)" "$note"
if [[ "$MISSION" == "task" ]]; then
  task_title="$(sed -n 's/^title=//p' "$TASK_STATE" | head -1)"
  [[ -n "$task_title" ]] && ui_rail "${C_BOLD}$task_title${C_RESET}"
fi
if [[ -z "$CURRENT" ]]; then
  if [[ -f "$ROOT/START.md" ]]; then ui_info "$(t "START.md present but brief empty: run loomy brief")"
  else ui_info "$(t "no Loomy project here: run loomy init")"; fi
else
  # Wide timeline: one box per phase (█ done, ▓ in progress, ░ upcoming), then ▲ and the name under the current box.
  _ui_term_size
  cw=$(( (UI_W - 3 - (N_PH - 1)) / N_PH )); (( cw > 7 )) && cw=7; (( cw < 2 )) && cw=2
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
  label="▲ $(loomy_phase_label "$CURRENT")"; [[ "$CURRENT" == "done" ]] && label="✓ $(m_text label)"
  total=$(( cw * N_PH + N_PH - 1 )); _ui_strlen "$label"
  off=$(( (idx > N_PH ? N_PH - 1 : idx - 1) * (cw + 1) )); (( off < 0 )) && off=0
  (( off + UI_LEN > total )) && off=$(( total - UI_LEN ))
  _ui_pad "" "$off"
  hl=""; [[ "${LOOMY_HL_PHASE:-0}" == "1" ]] && hl="  ${C_BOLD}${C_BRAND}✦ $(t "new phase")${C_RESET}"
  ui_rail "${UI_PADDED}${C_BRAND}${label}${C_RESET}${hl}"
  ui_print "${C_RAIL}│${C_RESET}"
  # Bootstrap finished: the summary (duration, delegations, cost), taken from the log.
  # Bootstrap summary (archives included): duration, delegations, cost of delegations and Claude Code until the end.
  J_DONE="$(ai_journal_file "$ROOT")"
  if [[ "$CURRENT" == "done" && -s "$J_DONE" ]]; then
if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then
    for cached in "${LEGACY_PHASE[@]}"; do [[ "$cached" != "$PH_TYPE|"* ]] || read -r b_start b_end b_n b_cost b_tok <<<"${cached#*|}"; done
else
    read -r b_start b_end b_n b_cost b_tok <<<"$(awk -v pc="$PLAN_C" -v px="$PLAN_X" -v pht="$PH_TYPE" -v first="${LOOMY_PHASES%% *}" '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
      function add() { if ((field("family") == "claude" ? pc : px) + 0) tk += num("tokens_in") + num("tokens_out"); else c += num("cost_usd") }
      # An audit or a task can be started again: its summary begins at the last start (first phase).
      index($0, "\"type\":\"" pht "\"") { if (pht != "phase" && index($0, "\"phase\":\"" first "\"")) { s = field("ts"); e = ""; n = 0; c = 0; tk = 0 }
        if (s == "") s = field("ts"); if (index($0, "\"phase\":\"done\"")) e = field("ts") }
      e == "" && index($0, "\"type\":\"delegation\",") { n++; add() }
      e == "" && (index($0, "\"type\":\"usage\"") || index($0, "\"type\":\"advisor\"")) { add() }
      END { printf "%s %s %d %.2f %d\n", (s == "" ? "-" : s), (e == "" ? "-" : e), n, c, tk }' < <(ai_journal_all "$ROOT" | ai_journal_canonical))"
fi
    s_ep="$(ai_ts_epoch "$b_start")"; e_ep="$(ai_ts_epoch "$b_end")"
    took=""
    if [[ -n "$s_ep" && -n "$e_ep" ]] && (( e_ep >= s_ep )); then
      d=$(( e_ep - s_ep )); if (( d >= 3600 )); then took="$(( d / 3600 )) h $(( d % 3600 / 60 )) min"; else took="$(( d / 60 )) min"; fi
    fi
    ui_rail "${C_GREEN}${C_BOLD}✦ $(m_text title)${C_RESET}${took:+ ${C_DIM}·${C_RESET} $(m_took "${C_BOLD}$took${C_RESET}")} ${C_DIM}·${C_RESET} $(t "%s delegation(s)" "$b_n")$( (( PLAN_C && PLAN_X )) || printf ' %s·%s $%s' "$C_DIM" "$C_RESET" "$b_cost")$( (( b_tok > 0 )) && printf ' %s·%s %s %s' "$C_DIM" "$C_RESET" "$(ai_tokens_label "$b_tok")" "$(t "tokens")")"
  fi
  [[ "$COMPACT" == "1" ]] || ui_rail "${C_DIM}$(loomy_phase_agent "$CURRENT")${C_RESET}"
  # Lead agent session: recorded by the Claude Code hooks and by loomy start (Codex).
  sess="$(ai_session_state "$ROOT")"; tool_name="Claude Code"; [[ "$sess" == *"|codex" ]] && tool_name="Codex"
  you="$(loomy_you_now "$CURRENT" "$sess")"
  ui_rail "${C_YELLOW}➜${C_RESET} ${C_BOLD}$(t "Your turn:")${C_RESET} $you"
  case "$sess" in
    open*) ui_rail "${C_GREEN}●${C_RESET} $(t "Lead agent session open since %s" "$(printf '%s' "$sess" | cut -d'|' -f2)") ${C_DIM}($tool_name)${C_RESET}" ;;
    closed*)
      if [[ -n "$MISSION" ]]; then ui_rail "${C_DIM}○ $(t "Session closed at %s (%s) → %s" "$(printf '%s' "$sess" | cut -d'|' -f2)" "$tool_name" "$(m_text resume)")${C_RESET}"
      else ui_rail "${C_DIM}○ $(t "Lead agent session closed at %s (%s) → loomy start to resume it" "$(printf '%s' "$sess" | cut -d'|' -f2)" "$tool_name")${C_RESET}"; fi ;;
    *) [[ "$CURRENT" != "done" ]] && ui_rail "${C_DIM}○ $( [[ -n "$MISSION" ]] && t "No session recorded → %s" "$(m_text resume)" || t "No lead agent session recorded → loomy start")${C_RESET}" ;;
  esac
  if (( idx >= 1 && idx < N_PH )) && [[ "$COMPACT" != "1" ]]; then
    next=""; i=0
    for p in $LOOMY_PHASES; do i=$(( i + 1 )); (( i > idx )) && next="${next:+$next → }$(loomy_phase_label "$p")"; done
    _ui_term_size; _ui_fit "$(t "next:") $next" $(( UI_W - 3 ))
    ui_rail "${C_DIM}${UI_FIT}${C_RESET}"
  fi
fi

# Temporary lead relay (quota or manual), compact and full views.
relay_txt="$(lf_status_text "$ROOT")"
[[ -z "$relay_txt" ]] || ui_rail "${C_YELLOW}⇄ ${relay_txt}${C_RESET}"

# ---------------------------------------------------------------- brief
if [[ -f "$BRIEF" && "$COMPACT" != "1" ]]; then
  ui_section "BRIEF"
  risk="$(brief_get risk)"
  risk_c="$C_GREEN"; [[ "$risk" == "MEDIUM" ]] && risk_c="$C_YELLOW"; [[ "$risk" == "HIGH" ]] && risk_c="$C_RED"
  ui_kv "$(t "Name")" "${C_TITLE}$(brief_get name)${C_RESET} · $(label_of "$(brief_get type)") · $(label_of "$(brief_get stage)")"
  ui_kv "$(t "Risk")" "${risk_c}${risk:-?}${C_RESET}"
  ui_kv "$(t "AI mode")" "${C_MAGENTA}$(brief_get ai_mode)${C_RESET} · lead $(label_of "$(brief_get ai_lead)")"
  ui_kv "Budget" "$(label_of "$(brief_get budget)")"
  ui_kv "Git" "$(t "auto commit: %s · auto push: %s" "$(label_of "$(brief_get commit_after_setup)")" "$(label_of "$(brief_get push_after_commit)")")"
fi

# ---------------------------------------------------------------- activity
JOURNAL="$(ai_journal_file "$ROOT")"
if [[ -s "$JOURNAL" ]]; then
  ui_section "$(t "ACTIVITY")"
  # Running delegations: a start without an end (a single read of the log), whose process is still running.
  now_s="$(date +%s)"
  if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then printf '%s' "$LEGACY_RUNNING"; else
  ai_journal_canonical <"$JOURNAL" | awk '
    function field(k,   v) { if (match($0, "\"" k "\":\"([^\"\\\\]|\\\\.)*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); gsub(/\\"/, "\"", v); return v } return "" }
    function num(k,   v) { if (match($0, "\"" k "\":[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "" }
    /"bridge":"codex-native"/ { next }
    /"type":"delegation_start"/ { id = field("id"); order[++n] = id
      line[id] = num("pid") "|" field("ts") "|" field("role") "|" field("model") "|" substr(field("task"), 1, 60); next }
    /"type":"delegation",/ { finished[field("id")] = 1; k = field("role") "|" field("model"); tot[k] += num("duration_s"); cnt[k]++ }
    END { for (i = (n > 20 ? n - 19 : 1); i <= n; i++) if (!(order[i] in finished)) { split(line[order[i]], f, "|"); k = f[3] "|" f[4]
            print line[order[i]] "|" (cnt[k] ? int(tot[k] / cnt[k]) : "") } }' ; fi |
  while IFS='|' read -r pid ts role m task est; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null || continue
    since="$(ai_ts_epoch "$ts")"
    # Spinner (one frame per loomy watch refresh), timer, and progress estimated from past delegations
    # of the same role on the same model.
    spin="${UI_SPIN[$(( ${LOOMY_TICK:-0} % 4 ))]}"
    el_s=0; [[ -n "$since" ]] && el_s=$(( now_s - since )); (( el_s < 0 )) && el_s=0
    _ui_dur $(( el_s * 1000 )); el="${UI_DUR/[.,]? s/ s}"
    prog=""
    if [[ -n "$est" ]] && (( est > 0 )); then
      fill=$(( el_s * 10 / est )); (( fill > 10 )) && fill=10
      bar=""; for (( k = 0; k < 10; k++ )); do if (( k < fill )); then bar="${bar}▰"; else bar="${bar}▱"; fi; done
      _ui_dur $(( est * 1000 )); est_txt="${UI_DUR/[.,]? s/ s}"
      if (( el_s > est * 3 / 2 )); then prog="${C_YELLOW}${bar}${C_RESET} ${el} ${C_DIM}· $(t "longer than usual (~%s)" "$est_txt")${C_RESET}"
      else prog="${C_BRAND}${bar}${C_RESET} ${el} ${C_DIM}/ ~${est_txt}${C_RESET}"; fi
    else
      prog="${el} ${C_DIM}· $(t "first time for this role")${C_RESET}"
    fi
    ui_rail "${C_YELLOW}${spin} $(t "running")${C_RESET} ${C_BOLD}$(printf '%-11s' "$role")${C_RESET}${C_DIM}$(printf '%-17s' "$m")${C_RESET} ${prog}"
    ui_rail "           ${C_DIM}${task}${C_RESET}"
  done
  # Native turns have no agent process or elapsed-time completion estimate.
  if loomy_status_has native; then
    # shellcheck source=loomy-tree.sh
    source "$SCRIPT_DIR/loomy-tree.sh" --library
    if [[ "${LOOMY_WATCH_REDUCED:-0}" != 1 ]]; then loomy_live_init; loomy_live_poll "$JOURNAL"; LV_NOW="$now_s"; loomy_live_states; fi
    if (( NS_ENABLED )); then
      LOOMY_NO_HEADER=1 loomy_native_render
    fi
    LV_WIDTH=$(( UI_COLS - 8 )); LV_ROLE_WIDTH=12
    native_seen="|"
    for (( ni=${#LV_ID[@]}-1; ni>=0; ni-- )); do
      [[ "${LV_BRIDGE[ni]:-}" == codex-native ]] || continue
      native_id="${LV_AGENT_ID[ni]:-${LV_ID[ni]}}"
      [[ "$native_seen" != *"|$native_id|"* ]] || continue
      native_seen="$native_seen$native_id|"
      loomy_tree_native_title "native:$ni"; loomy_tree_native_state "$ni"
      native_row="$(loomy_native_line '' "$LV_NATIVE_TITLE" " · ${LV_MODELSHORT[ni]} ${LV_WORD[ni]}" "$NS_TEXT${NS_DETAIL:+ · $NS_DETAIL}" "$LV_TIME")"
      while IFS= read -r native_line; do ui_rail "$NS_COLOR$native_line$C_RESET"; done <<<"$native_row"
    done
  fi
  # Claude Code direct work (lead agent, native subagents): cost measured by the Stop and SubagentStop hooks.
  if loomy_status_has usage; then
if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then
    read -r u_ln u_lc u_lt u_sn u_sc u_st <<<"$LEGACY_USAGE"
else
    read -r u_ln u_lc u_lt u_sn u_sc u_st <<<"$(awk '
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
      index($0, "\"type\":\"usage\"") {
        c = num("cost_usd"); m = num("messages"); tk = num("tokens_in") + num("tokens_out")
        if (index($0, "\"scope\":\"lead\"")) { ln += m; lc += c; lt += tk } else { sn++; sc += c; st += tk } }
      END { printf "%d %.4f %d %d %.4f %d\n", ln, lc, lt, sn, sc, st }' "$JOURNAL")"
fi
    # Subscription: tokens (the quota is shown below); API: the real cost.
    if (( PLAN_C )); then u_lv="$(ai_tokens_label "$u_lt") $(t "tokens")"; u_sv="$(ai_tokens_label "$u_st") $(t "tokens")"
    else u_lv="$(t "cost %s" "\$${u_lc}")"; u_sv="$(t "cost %s" "\$${u_sc}")"; fi
    ui_kv "$(t "Lead agent")" "$(t "%s reply(ies)" "${C_BOLD}${u_ln}${C_RESET}") · ${C_BOLD}${u_lv}${C_RESET} ${C_DIM}($(t "measured"))${C_RESET}"
    (( u_sn > 0 )) && ui_kv "$(t "Sub-agents")" "${C_BOLD}${u_sn}${C_RESET} · ${C_BOLD}${u_sv}${C_RESET} ${C_DIM}($(t "measured"))${C_RESET}"
    # Advisor (Claude Code's advisor tool): consultations of the stronger model by the lead agent.
    if loomy_status_has advisor; then
if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then
      read -r a_n a_c a_t a_m _ <<<"$LEGACY_ADVISOR"
else
      read -r a_n a_c a_t a_m <<<"$(awk '
        function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
        index($0, "\"type\":\"advisor\"") { n += num("calls"); c += num("cost_usd"); tk += num("tokens_in") + num("tokens_out")
          if (match($0, /"model":"[^"]*"/)) m = substr($0, RSTART + 9, RLENGTH - 10) }
        END { printf "%d %.4f %d %s\n", n, c, tk, (m == "" ? "-" : m) }' "$JOURNAL")"
fi
      if (( PLAN_C )); then a_v="$(ai_tokens_label "$a_t") $(t "tokens")"; else a_v="$(t "cost %s" "\$${a_c}")"; fi
      ui_kv "$(t "Advisor")" "$(t "%s consultation(s)" "${C_BOLD}${a_n}${C_RESET}") · $a_m · ${C_BOLD}${a_v}${C_RESET} ${C_DIM}($(t "measured"))${C_RESET}"
    fi
  fi
  if ! loomy_status_has delegation; then
    ui_info "$(t "no finished delegation yet")"
    ui_rail "${C_DIM}  $(t "they show up here as soon as the lead agent hands a task to Claude or Codex")${C_RESET}"
  else
if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then
    summary="$LEGACY_SUMMARY"
else
    summary="$(ai_journal_canonical <"$JOURNAL" | grep '"type":"delegation"' | awk -v pc="$PLAN_C" -v px="$PLAN_X" '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v + 0 } return 0 }
      { if (field("review") == "incomplete") ri++
        if (field("bridge") == "codex-native") { n++; native++; if (field("status") != "ok") err++; next }
        m = field("model"); f = field("family"); plan = (f == "claude" ? pc : px) + 0
        tk = num("tokens_in") + num("tokens_out"); calls[m]++; tok[m] += tk; mp[m] = plan
        if (plan) { ptok += tk } else { cost[m] += num("cost_usd"); total += num("cost_usd"); api++ }
        n++; st=field("status"); if (st == "paused") paused++; else if (st == "handed_over") handed++; else if (st != "ok") err++ }
      END { printf "TOTAL %d %.4f %d %d %d %d %d %d %d\n", n, total, err, api, ptok, native, paused, handed, ri
            for (m in calls) printf "MODEL %s %d %.4f %d %d\n", m, calls[m], cost[m], tok[m], mp[m] }')"
fi
    read -r _ n_calls total_cost n_err n_api plan_tok n_native n_paused n_handed n_review <<<"$(printf '%s\n' "$summary" | grep '^TOTAL')"
    # API part: its cost; subscription part: its tokens (the quota is in the plans lines).
    d_val=""
    (( n_api > 0 )) && d_val="${C_BOLD}\$${total_cost}${C_RESET}"
    (( n_api < n_calls - n_native )) && d_val="${d_val:+$d_val · }${C_BOLD}$(ai_tokens_label "$plan_tok")${C_RESET} $(t "tokens")"
    (( n_native == 0 )) || d_val="${d_val:+$d_val · }$(t 'native usage unknown')"
    ui_kv "$(t "Delegations")" "${C_BOLD}${n_calls}${C_RESET} · ${d_val}$( [[ "${n_err:-0}" != "0" ]] && printf ' · %s%s%s' "$C_RED" "$(t "%s failed" "$n_err")" "$C_RESET")$( (( n_review > 0 )) && printf ' · %s' "$(t "%s review(s) without TRIED" "$n_review")")"
    (( n_paused == 0 && n_handed == 0 )) || ui_kv "$(t 'Availability')" "$(t '%s paused' "$n_paused") · $(t '%s handed over' "$n_handed")"
    last_n=5
    if [[ "$COMPACT" == "1" ]]; then last_n=3; else
    all_tok="$(printf '%s\n' "$summary" | awk '/^MODEL/ { s += $5 } END { print s + 0 }')"
    printf '%s\n' "$summary" | awk '/^MODEL/' | sort -k5 -rn | while read -r _ m c cost tok onplan; do
      # Bar: share of the tokens (comparable across API and subscription).
      width=0
      (( all_tok > 0 )) && width=$(( tok * 24 / all_tok ))
      bar=""; rest=""; i=0
      while (( i < 24 )); do if (( i < width )); then bar="${bar}█"; else rest="${rest}░"; fi; i=$(( i + 1 )); done
      color="$C_CYAN"; case "$m" in *opus*|*astra*) color="$C_MAGENTA" ;; *luna*|*haiku*) color="$C_GREEN" ;; esac
      line="$(printf '%-17s %3s %-8s %7s %s' "$m" "$c" "$(t "call(s)")" "$(ai_tokens_label "$tok")" "$(t "tokens")")"
      (( onplan )) || line="$line  $(printf '$%.4f' "$cost")"
      ui_rail "${color}${bar}${C_RESET}${C_DIM}${rest}${C_RESET} ${line}"
    done
    ui_rail ""
    ui_rail "${C_DIM}$(t "Latest delegations")${C_RESET}"
    fi
    if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then n_shown=$LEGACY_COUNT; else n_shown="$(ai_journal_canonical <"$JOURNAL" | grep -c '"type":"delegation",' || true)"; fi
    (( n_shown > last_n )) && n_shown=$last_n
    row=0
    if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then printf '%s' "$LEGACY_LAST" | tail -n "$last_n"; else
    ai_journal_canonical <"$JOURNAL" | grep '"type":"delegation"' | tail -"$last_n" | awk '
      function field(k,   v) { if (match($0, "\"" k "\":\"[^\"]*\"")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":\"", "", v); sub("\"$", "", v); return v } return "" }
      function num(k,   v) { if (match($0, "\"" k "\":[0-9.]+")) { v = substr($0, RSTART, RLENGTH); sub("^\"" k "\":", "", v); return v } return "0" }
      { printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", field("ts"), field("status"), field("role"), field("model"), num("duration_s"), num("cost_usd"), (field("failover_from") != "" ? "⇄ " : "") substr(field("task"), 1, 40), field("family"), num("tokens_in") + num("tokens_out"), field("outcome"), field("bridge") }' ; fi |
    while IFS='|' read -r t st role m d cost task fam tk oc bridge; do
      row=$(( row + 1 ))
      # Log in UTC, shown in local time.
      ep="$(ai_ts_epoch "$t")"
      if [[ -n "$ep" ]]; then t="$(date -r "$ep" +%H:%M 2>/dev/null || date -d "@$ep" +%H:%M)"; else t="${t:11:5}"; fi
      mark="${C_GREEN}✓${C_RESET}"; [[ "$st" != "ok" ]] && mark="${C_RED}✗${C_RESET}"
      case "$st" in paused) mark="${C_YELLOW}Ⅱ${C_RESET}"; task="$(t 'paused') · $task" ;; handed_over) mark="${C_YELLOW}⇄${C_RESET}"; task="$(t 'handed over') · $task" ;; esac
      [[ "$oc" != unknown ]] || mark="${C_DIM}?${C_RESET}"
      # Structured result: partial or blocked means the task is not done, even when the call succeeded.
      if [[ "$st" == "ok" ]]; then case "$oc" in partial) mark="${C_YELLOW}◐${C_RESET}" ;; blocked) mark="${C_YELLOW}■${C_RESET}" ;; unknown) mark="${C_DIM}?${C_RESET}" ;; esac; fi
      # Delegation just finished (loomy watch): highlighted for a few seconds.
      if (( row > n_shown - ${LOOMY_HL_DELEG:-0} )); then mark="${mark}${C_BRAND}${C_BOLD}✦${C_RESET}"; t="${C_BOLD}${t}"; else mark="${mark} "; fi
      if [[ "$bridge" == codex-native ]]; then
        ai_native_end_label "$st"; val="$(t "$AI_NATIVE_END") · $(t 'native usage unknown')"
        case "$st" in ok) mark="${C_GREEN}✓${C_RESET}" ;; interrupted) mark="${C_DIM}${C_RED}⊘${C_RESET}" ;; error) mark="${C_RED}✗${C_RESET}" ;; esac
      elif { [[ "$fam" == "claude" ]] && (( PLAN_C )); } || { [[ "$fam" != "claude" ]] && (( PLAN_X )); }; then val="$(printf '%7s' "$(ai_tokens_label "$tk")") tk"
      else val="$(printf '%10s' "$(printf '$%.4f' "$cost")")"; fi
      ui_rail "$mark ${C_DIM}${t}${C_RESET} $(printf '%-11s %-17s %4ss  %s' "$role" "$m" "$d" "$val")  ${C_DIM}${task}${C_RESET}"
    done
  fi
else
  ui_section "$(t "ACTIVITY")"
  ui_info "$(t "no delegation yet")"
  ui_rail "${C_DIM}  $(t "they show up here as soon as the lead agent hands a task to Claude or Codex")${C_RESET}"
fi

# ---------------------------------------------------------------- plans
# Subscription: the share of the plan's quota in use, as Claude Code and Codex report it. API: the real cost this month.
plan_lines() {
  local fam plan name value q month
  month="$(date -u +%Y-%m)"
  for fam in claude codex; do
    plan="$(loomy_plan "$fam")"; name="Claude"; [[ "$fam" == "codex" ]] && name="Codex"
    if [[ "$plan" == "api" ]]; then
      [[ "$COMPACT" == "1" ]] && continue
if [[ "${LOOMY_WATCH_REDUCED:-0}" == 1 ]]; then
      value=0
      for cached in "${LEGACY_MONTH[@]}"; do
        [[ "$cached" != "$month|$fam|"* ]] || value="${cached##*|}"
      done
      value="$(awk -v c="$value" 'BEGIN {printf (c >= 1 ? "%.2f" : "%.4f"), c}')"
else
      value="$(awk -v fam="\"family\":\"$fam\"" -v ts="\"ts\":\"$month" '
        (index($0, "\"type\":\"delegation\",") || index($0, "\"type\":\"usage\"")) && index($0, fam) && index($0, ts) {
          if (match($0, /"cost_usd":[0-9.]+/)) c += substr($0, RSTART+11, RLENGTH-11) }
        END { printf (c >= 1 ? "%.2f" : "%.4f"), c }' "$JOURNAL" 2>/dev/null || true)"
fi
      ui_kv "$name" "API · $(t "cost this month:") ${C_BOLD}\$${value:-0}${C_RESET}"
    else
      q="$(ai_quota_line "$fam")"
      if [[ -n "$q" ]]; then ui_kv "$name" "$( [[ "$COMPACT" == "1" ]] || printf '%s · ' "$(ai_plan_label "$fam" "$plan")")$q"
      elif [[ "$COMPACT" != "1" ]]; then ui_kv "$name" "$(ai_plan_label "$fam" "$plan") · ${C_DIM}$(ai_quota_hint "$fam")${C_RESET}"; fi
      # Nearly exhausted: where the work goes now.
      if ai_quota_saturated "$fam"; then
        sw="$(ai_switch_family "$fam")"
        if [[ -n "$sw" ]]; then ui_rail "                 ${C_YELLOW}⇄ $(t "%s's roles go to %s until it resets" "$name" "$( [[ "$sw" == codex ]] && echo Codex || echo Claude)")${C_RESET}"
        else ui_rail "                 ${C_RED}! $(t "no other tool with room left: tasks may stop until it resets")${C_RESET}"; fi
      fi
    fi
  done
}
# Session log, scrolling in loomy watch (one new line per refresh, the newest highlighted).
if [[ -n "${LOOMY_WATCH_ID:-}" ]]; then
  sl_n=7; [[ "$COMPACT" == "1" ]] && sl_n=4
  if sl="$(ai_session_log "$ROOT" "$sl_n")"; then
    ui_section "$(t "SESSION LOG")" "$(t "live, newest at the bottom")"
    while IFS= read -r l; do ui_rail "$l"; done <<<"$sl"
  fi
fi
if [[ "$COMPACT" == "1" ]]; then
  [[ -n "$(ai_quota_line claude)$(ai_quota_line codex)" ]] && { ui_section "$(t "PLANS")"; plan_lines; }
else
  ui_section "$(t "PLANS")" "$(t "quota for subscriptions, cost for the API")"
  plan_lines
  if (( ! PLAN_C || ! PLAN_X )) && [[ -s "$JOURNAL" ]]; then ui_info "$(t "API costs at list price, from the logged work (delegations, lead agent, sub-agents)")"; fi
  ui_info "$(t "details: loomy stats")"
fi

# ---------------------------------------------------------------- AI files
# (not for a repository that only has an audit: no Loomy project files there)
if [[ "$COMPACT" != "1" && -f "$BRIEF" ]]; then
ui_section "$(t "AI FILES")" "$(privacy_label "$(privacy_mode "$ROOT")")"
if [[ "$(privacy_mode "$ROOT")" == "private" ]]; then
  if ! privacy_companion_ready "$ROOT"; then ui_warn "$(t "private repository missing on this machine")" "loomy privacy restore <$(t "account/repo")>"
  elif [[ "$(privacy_pending "$ROOT")" != "0" ]]; then ui_warn "$(t "%s unsaved change(s) in the private repository" "$(privacy_pending "$ROOT")")" "loomy privacy sync"; fi
elif [[ "$(privacy_mode "$ROOT")" == "local" ]] && [[ -n "$(privacy_git_root "$ROOT")" ]] && ! privacy_excluded "$ROOT"; then
  ui_warn "$(t "AI files not excluded on this machine yet")" "loomy privacy local"
fi
check_file() {
  if [[ -e "$ROOT/$1" ]]; then ui_ok "$1" "${2:-}"; else ui_rail "${C_DIM}○ $1${C_RESET}"; fi
}
if [[ ! -e "$ROOT/AGENTS.md" && ! -e "$ROOT/CLAUDE.md" ]]; then
  ui_rail "${C_DIM}$(t "created by the lead agent during Build: it's normal for them to be missing before")${C_RESET}"
fi
check_file AGENTS.md
check_file CLAUDE.md
check_file PROJECT.md
check_file ARCHITECTURE.md
check_file .loomy/docs/AI_WORKFLOW.md
check_file .loomy/docs/AI_ORCHESTRATION.md
check_file .loomy/docs/AI_MODEL_ROUTING.md
if [[ -d "$ROOT/.claude/agents" ]]; then
  agents="$(find "$ROOT/.claude/agents" -maxdepth 1 -name '*.md' -exec basename {} .md \; | sort | paste -sd ',' - | sed 's/,/, /g')"
  ui_ok ".claude/agents/" "${agents:-$(t "empty")}"
else
  ui_rail "${C_DIM}○ .claude/agents/${C_RESET}"
fi
if [[ -f "$ROOT/.loomy/docs/HANDOFF.md" ]]; then
  ui_warn ".loomy/docs/HANDOFF.md" "$(t "active handoff:") $(sed -nE 's/^(De|From) *: *//p' "$ROOT/.loomy/docs/HANDOFF.md" | head -1) → $(sed -nE 's/^(Vers|To) *: *//p' "$ROOT/.loomy/docs/HANDOFF.md" | head -1)"
fi

fi

# ---------------------------------------------------------------- git
ui_section "GIT"
if [[ "$COMPACT" == "1" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || t "detached")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  last="$(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null || true)"
  if [[ "$dirty" == "0" ]]; then ui_ok "$(t "%s clean" "$branch")" "${last:0:48}"; else ui_warn "$branch" "$(t "%s uncommitted file(s)" "$dirty")"; fi
elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || t "detached")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  last="$(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null || true)"
  if [[ "$dirty" == "0" ]]; then ui_ok "$(t "branch %s" "$branch")" "$(t "clean")"
  else ui_warn "$(t "branch %s" "$branch")" "$(t "%s modified file(s) not committed" "$dirty")"; fi
  if [[ -n "$last" ]]; then ui_info "$(t "last commit: %s" "$last")"; else ui_info "$(t "no commit")"; fi
  upstream="$(git -C "$ROOT" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    counts="$(git -C "$ROOT" rev-list --left-right --count "HEAD...$upstream" 2>/dev/null || echo "0 0")"
    ahead="${counts%%[[:space:]]*}"; behind="${counts##*[[:space:]]}"
    if [[ "$ahead" == "0" && "$behind" == "0" ]]; then ui_ok "$(t "in sync with %s" "$upstream")"
    else ui_warn "$upstream" "$(t "%s ahead · %s behind" "$ahead" "$behind")"; fi
  else
    remote="$(git -C "$ROOT" remote 2>/dev/null | head -1)"
    if [[ -n "$remote" ]]; then ui_info "$(t "remote %s set, no tracked branch" "$remote")"
    else ui_info "$(t "no remote set")"; fi
  fi
  wt="$(git -C "$ROOT" worktree list 2>/dev/null | wc -l | tr -d ' ')"
  if (( wt > 1 )); then ui_warn "$(t "%s parallel worktree(s)" "$(( wt - 1 ))")" "git worktree list"; fi
else
  ui_info "$(t "no Git repository")"
fi
[[ -n "${LOOMY_NO_HEADER:-}" ]] || ui_end "${LOOMY_STATUS_FOOTER:-$(t "start or resume: loomy start · live tracking: loomy watch")}"

}

# Tests and the watch worker load renderers without running a command.
if [[ "${LOOMY_STATUS_LIBRARY:-0}" == 1 ]]; then return 0; fi

if (( ! WATCH )) && [[ -z "${LOOMY_WATCH_ID:-}" ]]; then
  ai_codex_native_poll "$ROOT"
  ai_claude_native_poll "$ROOT"
fi
if (( WATCH )); then
  # Watch already redraws timers; the independent 16 Hz logo loop would dominate idle CPU.
  LOOMY_NO_ANIM=1 ui_screen_begin
  KEY_READER=""; COALESCER=""; WATCH_PIPE=""; WATCH_STTY=""
  watch_cleanup() {
    # Process substitutions inherit EXIT on Bash 3.2; only the watch owns the terminal.
    (( BASH_SUBSHELL == 0 )) || return 0
    [[ -z "$KEY_READER" ]] || { kill "$KEY_READER" 2>/dev/null || true; wait "$KEY_READER" 2>/dev/null || true; }
    [[ -z "$COALESCER" ]] || { kill "$COALESCER" 2>/dev/null || true; wait "$COALESCER" 2>/dev/null || true; }
    KEY_READER=""; COALESCER=""
    exec 7<&- 8<&- 9<&- 10<&-
    [[ -z "$WATCH_PIPE" ]] || { rm -f "$WATCH_PIPE/request"; rmdir "$WATCH_PIPE" 2>/dev/null || true; WATCH_PIPE=""; }
    UI_PAGE_L=(); _ui_restore
    [[ -z "$WATCH_STTY" ]] || stty "$WATCH_STTY" 2>/dev/null || true
  }
  trap 'exit 0' INT TERM HUP
  trap watch_cleanup EXIT
  printf '\033[?25l' >&2
  terminal=0
  if [[ -t 0 ]]; then
    terminal=1; WATCH_STTY="$(stty -g 2>/dev/null || true)"
    stty -echo -icanon min 1 time 0 2>/dev/null || true
  fi
  # Process substitutions replace stdin with /dev/null; preserve the controller input explicitly.
  exec 7<&0
  ai_detect_env "$ROOT"
  exec 8< <(loomy_watch_feed "$terminal")
  KEY_READER=$!
  WATCH_PIPE="$(mktemp -d "${TMPDIR:-/tmp}/loomy-watch-feed.XXXXXX")"
  mkfifo "$WATCH_PIPE/request"
  exec 9<>"$WATCH_PIPE/request"
  exec 10< <(LOOMY_WATCH_SERVER=1 loomy_watch_coalesce)
  COALESCER=$!
  NAME_W="$(brief_get name 2>/dev/null || true)"; NAME_W="${NAME_W:-$(basename "$ROOT")}"
  J="$(ai_journal_file "$ROOT")"
  # shellcheck source=loomy-tree.sh
  source "$SCRIPT_DIR/loomy-tree.sh" --library
  loomy_live_init
  LEGACY_SEQ=0; LEGACY_SESSIONS=(); LEGACY_PHASE=(); LEGACY_MONTH=(); LEGACY_SUMMARY=""; LEGACY_LAST=""; LEGACY_RUNNING=""; LEGACY_LOG_JSON=""; LEGACY_LOG_ARR=(); LEGACY_SESSION_ARR=(); LEGACY_SESSION_ROWS=""; LEGACY_SESSION_PRETTY=""; LEGACY_LOG_PRETTY=""; LEGACY_LOG_SEQ=0; LEGACY_PRETTY_SEQ=-1; LEGACY_VISIBLE=0
  LEGACY_USAGE="0 0 0 0 0 0"; LEGACY_ADVISOR="0 0 0 -"; LEGACY_TOTAL="0 0"; LEGACY_COUNT=0; LEGACY_NATIVE=0; LEGACY_HAS_USAGE=0; LEGACY_HAS_ADVISOR=0
  legacy_stamp=""; legacy_frame=""
  # Internal failures leave the terminal controller alive; no command/source text is logged.
  set +eu
  set -E
  watch_error=0; watch_discovering=0
  watch_internal_error() {
    watch_error=1; force_frame=1
    if ai_journal_enabled "$ROOT"; then
      perl "$SCRIPT_DIR/lib/watch-errors.pl" "$ROOT/.loomy/logs/watch-errors.log" controller error 2>/dev/null || true
    fi
    return 0
  }
  trap watch_internal_error ERR
  _ui_term_size
  # The sampler already owns TIOCGWINSZ; reuse it even inside the UI drawing helpers.
  watch_rows=$UI_ROWS; watch_cols=$UI_COLS
  _ui_term_size() {
    UI_ROWS=${watch_rows:-0}; UI_COLS=${watch_cols:-0}
    (( UI_ROWS > 0 )) || UI_ROWS=${LINES:-24}; (( UI_ROWS > 0 )) || UI_ROWS=24
    (( UI_COLS > 0 )) || UI_COLS=${COLUMNS:-80}; (( UI_COLS > 0 )) || UI_COLS=80
    [[ "$UI_ROWS" =~ ^[0-9]+$ ]] || UI_ROWS=24
    [[ "$UI_COLS" =~ ^[0-9]+$ ]] || UI_COLS=80
    UI_W=$(( UI_COLS - 2 )); (( UI_W > 78 )) && UI_W=78; (( UI_W < 40 )) && UI_W=40
    return 0
  }
  # Footer/logo layout is stable between key/size/note changes; only the title has a clock.
  _watch_chrome_def="$(declare -f _ui_chrome)"
  eval "${_watch_chrome_def/_ui_chrome/loomy_watch_chrome_build}"
  watch_chrome_sig=""; watch_chrome_alt=""; watch_footer_alt=()
  _ui_chrome() {
    local sig="$UI_ROWS|$UI_COLS|$UI_FTR_KEYS|$UI_FTR_NOTE"
    if [[ "$sig" != "$watch_chrome_sig" ]]; then
      local saved_footer=(${UI_FOOTER_LINES[@]+"${UI_FOOTER_LINES[@]}"}) saved_sig="$watch_chrome_sig"
      if [[ "$sig" == "$watch_chrome_alt" ]]; then
        UI_FOOTER_LINES=("${watch_footer_alt[@]}")
        UI_FOOTER="${UI_FOOTER_LINES[$(( ${#UI_FOOTER_LINES[@]} - 1 ))]}"
        UI_CHROME_H=$(( ${#UI_HDR_LINES[@]} + ${#UI_FOOTER_LINES[@]} ))
      else loomy_watch_chrome_build; fi
      watch_footer_alt=(${saved_footer[@]+"${saved_footer[@]}"}); watch_chrome_alt="$saved_sig"; watch_chrome_sig="$sig"
    fi
    UI_HDR_LINES[$(( ${#UI_HDR_LINES[@]} - 1 ))]="${C_RAIL}┌${C_RESET}  ${C_TITLE}${UI_HDR_TITLE:-loomy}${C_RESET}${UI_HDR_SUB:+  ${C_DIM}${UI_HDR_SUB}${C_RESET}}"
  }
  watch_pref="$(loomy_config_get watch_view tree)"
  native_dirty=0; state_tick=0; tick=0; wtop=0; view="tree"; tree_mode=auto; tree_layout=list; first=1; hl_phase=0; hl_deleg_until=0; hl_deleg_n=0; last_frame=""; force_frame=1
  tree_mode="${LOOMY_TREE:-$(loomy_config_get tree_view auto)}"
  if [[ "$watch_pref" == list || "$COMPACT" == 1 ]] || (( IN_PANE )); then view=list; fi
  watch_note=""; note_until=0
  p_relay=0; p_phase=""; p_done=0; p_err=0; p_sess=""; q_next=0; first_q=1
  scroll_word=""
  # shellcheck disable=SC2034  # read through ${!pv} below
  p_ql_claude=0 p_ql_codex=0
  while IFS= read -r feed_line <&8; do
    if [[ "$feed_line" == D\|* ]]; then watch_discovering="${feed_line#D|}"; force_frame=1; continue; fi
    if [[ "$feed_line" == W\|* ]]; then watch_error=1; force_frame=1; continue; fi
    if [[ "$feed_line" == E\|* ]]; then loomy_watch_legacy_accept "$feed_line"; native_dirty=1; continue; fi
    # The bounded log rows (hundreds per batch) are collected inline, without a function call per row.
    if [[ "$feed_line" == K\|L\|* ]]; then LEGACY_LOG_ARR[${#LEGACY_LOG_ARR[@]}]="${feed_line#K|L|}"; continue; fi
    if [[ "$feed_line" == K\|J\|* ]]; then LEGACY_SESSION_ARR[${#LEGACY_SESSION_ARR[@]}]="${feed_line#K|J|}"; continue; fi
    if [[ "$feed_line" == K\|* ]]; then LEGACY_VISIBLE=0; loomy_watch_legacy_accept "$feed_line"; (( ! LEGACY_VISIBLE )) || native_dirty=1; continue; fi
    if [[ "$feed_line" == N\|* ]]; then loomy_native_accept "$feed_line"; native_dirty=1; continue; fi
    loomy_native_read "$feed_line" now dirty key LV_CLOCK watch_rows watch_cols
    [[ -n "$UNTIL" ]] && ! kill -0 "$UNTIL" 2>/dev/null && break
    LOOMY_WATCH_INLINE=1 loomy_watch_coalesce "$now" "$dirty" "$key" "$LV_CLOCK" || break
    config_dirty=$dirty
    if (( native_dirty )); then dirty=1; native_dirty=0; fi
    case "$key" in q|Q) break ;; esac
    # ---- what changed since the previous frame
    LV_NOW="$now"
    if [[ -n "$watch_note" ]] && (( now >= note_until )); then watch_note=""; force_frame=1; fi
    if (( config_dirty || ! LV_META_READY )); then loomy_live_metadata; fi

    old_active=$LV_ACTIVE; old_finished=${#LV_FINISHED[@]}
    if (( dirty || now != state_tick )); then loomy_live_states; state_tick=$now; fi
    [[ "$old_active:${old_finished}" == "$LV_ACTIVE:${#LV_FINISHED[@]}" ]] || force_frame=1
    phase="$LV_PHASE"
    if (( dirty || now >= q_next )); then
      n_done=$LV_DONE; n_err=$LV_ERRORS
      sess=closed; (( LV_ACTIVE )) && sess=open
      relay=0; [[ -z "$LV_RELAY" ]] || relay=1
      if (( ! first )); then
        # Lead relay (quota): one notification when it starts, one when the master takes the lead back.
        if (( relay && ! p_relay )); then watch_notify "⇄ $(t "Temporary lead")" "$(lf_status_text "$ROOT")"
        elif (( ! relay && p_relay )); then watch_notify "⇄ $(t "Lead back")" "$(t "The lead agent set in the brief has quota again and leads.")"; fi
        if [[ "$phase" != "$p_phase" && -n "$phase" ]]; then
          hl_phase=$(( now + 8 ))
          if [[ "$phase" == "done" ]] && [[ "$MISSION" == "audit" ]]; then watch_notify "✦ $(t "Audit done")" "$(t "The report and the fix plan are ready in the audit folder.")"
          elif [[ "$phase" == "done" ]] && [[ "$MISSION" == "task" ]]; then watch_notify "✦ $(t "Task done")" "$(t "Duration, delegations and cost in loomy watch.")"
          elif [[ "$phase" == "done" ]]; then watch_notify "✦ $(t "Project ready")" "$(t "Bootstrap done: what comes next happens with the lead agent (loomy start).")"
          else watch_notify "Phase $(loomy_phase_index "$phase")/$N_PH · $(loomy_phase_label "$phase")" "$(loomy_you_now "$phase" "$(ai_session_state "$ROOT" 2>/dev/null || true)")"; fi
        fi
        if (( n_done > p_done )); then hl_deleg_n=$(( n_done - p_done )); hl_deleg_until=$(( now + 8 )); fi
        if (( n_err > p_err )); then watch_notify "$(t "Delegation failed")" "$(t "See the details in loomy watch (key l) or loomy log.")"; fi
        if [[ "$p_sess" == "open" && "$sess" == "closed" && "$phase" != "done" ]]; then
          if [[ -n "$MISSION" ]]; then watch_notify "$(t "Session closed")" "$(t "In progress: %s to resume it." "$(m_text resume)")"
          else watch_notify "$(t "Lead agent session closed")" "$(t "Bootstrap in progress: loomy start to resume it.")"; fi
        fi
      fi
      # Subscription quota: read every 15 s; a notification when it crosses 80 %, then 95 %.
      if (( now >= q_next )); then
        q_next=$(( now + 15 ))
        for fam in claude codex; do
          loomy_on_plan "$fam" || continue
          qm="$(ai_quota_max "$fam")"; ql=0; [[ -n "$qm" ]] && { (( qm >= 80 )) && ql=1; (( qm >= 95 )) && ql=2; }
          pv="p_ql_$fam"
          if (( ! first_q && ql > ${!pv} )); then
            watch_notify "$(t "%s quota at %s %%" "$( [[ "$fam" == codex ]] && echo Codex || echo Claude)" "$qm")" "$(sw="$(ai_switch_family "$fam")"; if [[ -n "$sw" ]]; then t "Its roles go to %s until it resets." "$( [[ "$sw" == codex ]] && echo Codex || echo Claude)"; elif (( ql == 2 )); then t "Almost exhausted: the next tasks may be cut off until it resets."; else t "Keep an eye on it: loomy stats shows what consumed it."; fi)"
          fi
          printf -v "$pv" '%s' "$ql"
        done
        first_q=0
      fi
      first=0; p_relay=$relay; p_phase="$phase"; p_done=$n_done; p_err=$n_err; p_sess="$sess"
    fi
    # ---- image
    timer=""; (( ${#LV_RUNNING[@]} == 0 && ! LV_ACTIVE )) || timer="$now"
    stamp="$timer:$LV_SEQ:$view:$phase:$COMPACT:$LV_GROUP:$tree_mode"
    if [[ "$stamp" != "$last_frame" ]] || (( force_frame || dirty )); then
      _ui_term_size; size="--full"
      if [[ "$COMPACT" == "1" ]] || { [[ -z "$COMPACT" ]] && (( UI_ROWS < 40 || UI_COLS < 90 )); }; then size="--compact"; fi
      tree_layout=list
      if [[ "$tree_mode" != list ]] && (( UI_COLS >= 124 )); then tree_layout=diagram; fi
      watch_keys; keys="$WATCH_KEYS"
      hl_d=0; (( now < hl_deleg_until )) && hl_d=$hl_deleg_n
      hl_p=0; (( now < hl_phase )) && hl_p=1
      # Reserve the actual banner/footer before deciding how much hierarchy fits.
      loomy_live_header; UI_HDR_TITLE="$LV_HEADER"
      tv scroll_word scroll; UI_FTR_KEYS="↑↓ $scroll_word · $keys"; UI_FTR_NOTE="$watch_note"; (( ! watch_discovering )) || tv UI_FTR_NOTE "Discovering source inventory (%s pending)." "$watch_discovering"; (( ! watch_error )) || tv UI_FTR_NOTE "Watch internal error; tracking continues (loomy doctor)."; _ui_chrome
      watch_body_height=$(( UI_ROWS - UI_CHROME_H )); (( watch_body_height >= 0 )) || watch_body_height=0
      # Redraw only changed state, user navigation, or running timers.
      last_frame="$stamp"; force_frame=0; tick="$now"
      native_frame=0
      if (( NS_ENABLED )) && [[ "$view" == list || "$view" == tree ]]; then
        LV_FRAME=""
        LOOMY_WATCH_CAPTURE=1 LOOMY_WATCH_BODY_HEIGHT=$watch_body_height LOOMY_WATCH_PIN=1 LOOMY_WATCH_VIEW=$view LOOMY_NO_HEADER=1 LOOMY_TICK=$tick loomy_native_render
        frame="${LV_FRAME%$'\n'}"; native_frame=1
      else
        legacy_key="$LEGACY_SEQ:$view:$size:$watch_body_height:$watch_cols:$tree_mode:$LV_GROUP"
        [[ "$view" != list && "$view" != tree ]] || legacy_key="$legacy_key:$timer"
        [[ "$view" != status && "$view" != log ]] || legacy_key="$legacy_key:$LEGACY_LOG_SEQ"
        if [[ "$legacy_stamp" != "$legacy_key" || "$dirty" == 1 ]]; then
          loomy_watch_legacy_pretty
          legacy_frame="$(loomy_watch_legacy_render 2>&1)" || true
          legacy_stamp="$legacy_key"
        fi
        frame="$legacy_frame"
      fi
      # Each line is cut to the terminal width ("…"), colour sequences included: no line wrap,
      # even in a terminal that ignores turning off automatic wrap.
      if (( ! native_frame )); then frame="$(printf '%s\n' "$frame" | ui_clip "$(( UI_COLS - 1 ))")"; fi
      loomy_live_viewport "$frame" "$watch_body_height" "$wtop"
      if [[ "$UI_SCREEN" == "1" ]]; then
        # Keep the banner/logo; redraw its clock only with a meaningful frame.
        loomy_live_header
        loomy_live_clip "$LV_HEADER" "$(( UI_COLS - 4 ))"; LV_HEADER="$LV_CLIPPED"
        ui_header "$LV_HEADER" ""
        UI_FTR_KEYS="$keys"; UI_FTR_NOTE="$watch_note"; (( ! watch_discovering )) || tv UI_FTR_NOTE "Discovering source inventory (%s pending)." "$watch_discovering"; (( ! watch_error )) || tv UI_FTR_NOTE "Watch internal error; tracking continues (loomy doctor)."
        _ui_term_size; _ui_chrome
        (( LV_PAGE_LINES > UI_ROWS - UI_CHROME_H )) && keys="↑↓ $scroll_word · $keys"
        UI_FTR_KEYS="$keys"; UI_BODY_TOP=$wtop
        if (( LV_PINNED )); then wtop=$LV_SCROLL_TOP; UI_BODY_TOP=0; fi
        ui_banner "$LV_HEADER" ""
        (( LV_PINNED )) || wtop=$UI_BODY_START
      else
        printf '%s\n' "${frame//$'\036loomy-recap'/}" >&2
      fi
    fi
    case "$key" in up) wtop=$(( wtop - 1 )) ;; down) wtop=$(( wtop + 1 )) ;; esac
    (( wtop >= 0 )) || wtop=0
    case "$key" in
      c|C) [[ "$view" == "status" ]] && { if [[ "$size" == "--compact" ]]; then COMPACT=0; else COMPACT=1; fi; } ;;
      l|L) if [[ "$view" == log ]]; then view=status; else view=log; fi; wtop=0 ;;
      t|T) if [[ "$view" == tree ]]; then view=status
        else view=tree; loomy_config_set watch_view tree; fi; wtop=0 ;;
      a|A) if [[ "$view" == list ]]; then view=status
        else view=list; loomy_config_set watch_view list; fi; wtop=0 ;;
      v|V)
        if [[ "$view" == tree ]]; then
          if [[ "$tree_layout" == list ]]; then
            tree_mode=diagram
            if (( UI_COLS < 124 )); then watch_note="$(t "Diagram needs at least %s columns." 124)"; note_until=$(( now + 5 )); fi
          else tree_mode=list; fi; wtop=0
        elif [[ "$view" == list ]]; then
          if [[ "$LV_GROUP" == model ]]; then LV_GROUP=request; else LV_GROUP=model; fi
          loomy_config_set watch_group "$LV_GROUP"
        fi ;;
      o|O)
        # The launcher has no ownership of the watch's screen, input or sampler.
        watch_note=""; open_rc=0
        watch_note="$(env -u LOOMY_SCREEN_OWNER -u LOOMY_PAGE_OUT LOOMY_NO_CLEAR=1 bash "$SCRIPT_DIR/loomy-start.sh" --root "$ROOT" --orchestrator </dev/null 2>&1 8<&-)" || open_rc=$?
        if (( open_rc )); then
          watch_note="$(loomy_cli_open_note "$open_rc" "$watch_note")"
          [[ -n "$watch_note" ]] || watch_note="$(t "Could not open the orchestrator; watch is still running.")"
          note_until=$(( now + 5 ))
        else
          watch_note="$(t "Orchestrator opened.")"; note_until=$(( now + 5 ))
        fi
        if (( terminal )); then stty -echo -icanon min 1 time 0 2>/dev/null || true; fi ;;

      s|S) [[ -z "$UNTIL" ]] && (( ! IN_PANE )) && { watch_cleanup; trap - EXIT INT TERM HUP; exec bash "$SCRIPT_DIR/loomy-start.sh" --root "$ROOT"; } ;;
    esac
    [[ -z "$key" ]] || force_frame=1
    # Tracking opened by loomy start --watch: it closes with the agent session.
    [[ -n "$UNTIL" ]] && ! kill -0 "$UNTIL" 2>/dev/null && break
  done
  UI_PAGE_L=()
  exit 0
fi

loomy_status_render
