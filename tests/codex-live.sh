#!/usr/bin/env bash
# S1: desktop/CLI discovery, parallel hierarchy, bounded deltas and state-preserving rows.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=fixtures/watchdog.sh
source "$REPO/tests/fixtures/watchdog.sh"
WORK="$(mktemp -d "/tmp/loomy-codex-live.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
trap 'exit 143' TERM HUP
trap 'exit 130' INT
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export LOOMY_HOME="$REPO" LOOMY_LANG=en NO_COLOR=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1
export LOOMY_FIXTURE_NOW=1791853200 LOOMY_NATIVE_NOW=1791853200
unset LOOMY_DELEGATION LOOMY_PROJECT_ROOT LOOMY_UI_LANG AI_ROUTE_ENV LOOMY_WATCH_TOOL LOOMY_JOURNAL LOOMY_JOURNAL_TASKS LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
ROOT="$WORK/project"; J="$ROOT/.loomy/logs/events.jsonl"; PASS=0
check() { local title="$1"; shift; if test_step "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
fixture() { perl "$REPO/tests/fixtures/codex-native.pl" "$1" "$ROOT" "$CODEX_HOME/sessions" "$$"; }
poll() { perl "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"; }
check 'completed agents close on ended/dead owners, never on an absent PID or while running' perl -e '
 require $ARGV[0];
 for my $case (qw(ended dead ownerless running)) {
   my $s=Loomy::LiveState->new;
   my $pid=$case eq "dead" ? 99999999 : $case eq "ownerless" ? 0 : $$;
   my $base={schema=>2,session_key=>"codex:lead",tool=>"codex",bridge=>"codex-native",agent_id=>"child",id=>"turn",owner_pid=>$pid};
   $s->consume({type=>"session",tool=>"codex",session=>"lead",pid=>$pid,event=>"start",ts=>"2026-10-13T01:00:00Z"});
   $s->consume({%$base,type=>"delegation_start",ts=>"2026-10-13T01:00:01Z"});
   $s->consume({%$base,type=>"delegation",status=>"ok",ts=>"2026-10-13T01:00:02Z"}) unless $case eq "running";
   $s->consume({type=>"session",tool=>"codex",session=>"lead",pid=>$pid,event=>"end",ts=>"2026-10-13T01:00:03Z"}) if $case eq "ended" || $case eq "running";
   # A turn still open when its lead session ends is interrupted, never left running (review finding F3).
   my $expected=$case eq "ownerless" ? "idle" : $case eq "running" ? "interrupted" : "done";
   die "$case: expected $expected" unless grep {/^N\|A\|codex:child\|codex:lead\|[^|]*\|\Q$expected\E\|/} $s->projections(1791853204);
 }
' "$REPO/scripts/lib/live-state.pl"
# macOS temp aliases are symlinks: rejection must not prepend an unfitted diagnostic to views.
mkdir -p "$WORK/rejected-source/sessions" "$ROOT/.loomy/logs"
printf '%s\n' '---' 'ai_mode: SOLO' 'ai_lead: codex' '---' >"$ROOT/.loomy/brief.md"
ln -s "$WORK/rejected-source" "$WORK/source-alias"
for lang in en fr; do
  for cols in 45 140 170; do
    args=(); [[ "$cols" != 45 ]] || args=(--once)
    COLUMNS=$cols LINES=60 CODEX_HOME="$WORK/source-alias" LOOMY_UI_LANG=$lang LOOMY_NO_HEADER=1 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" ${args[@]+"${args[@]}"} >"$WORK/rejected-frame" 2>&1
    check "$lang $cols-column rejected source keeps frame fitted and tree title scroll position" perl -MEncode=decode -e '
      my ($path,$width)=@ARGV; open my $f,"<",$path or die; my @lines=<$f>;
      die "unfitted adapter diagnostic" if grep {/Codex session path contains a symlink/} @lines;
      if ($width==45) {for (@lines) {chomp; die "wrapped line" if length(decode("UTF-8",$_))>$width-1}}
      else {die "tree title moved below two-line scroll" unless grep {/LOOMY AGENT TREE|ARBRE DES AGENTS LOOMY/} @lines[0,1]}
    ' "$WORK/rejected-frame" "$cols"
  done
done
fixture seed; fixture app; fixture second-lead; fixture boundary
check 'ownerless desktop and descendant CLI discovery' poll
check 'five starts, root groups and grandchild parent identities, no invented owner PID' perl -MJSON::PP -e '
 my @e=grep {ref($_) eq "HASH"} map {eval {decode_json($_)}} <>; my @starts=grep {$_->{type} eq "delegation_start"} @e;
 die unless @starts==5;
 die unless (grep {$_->{session_key} eq "codex:00000000-0000-4000-8000-000000000001"} @starts)==3;
 my ($g)=grep {($_->{task}//"") eq "grandchild"} @starts;
 die unless $g && $g->{session_key} eq "codex:00000000-0000-4000-8000-000000000008" && $g->{parent_agent_id} eq "codex:00000000-0000-4000-8000-000000000009";
 die if grep {exists $_->{owner_pid} || exists $_->{pid}} @starts;
 die if grep {($_->{session_key}//"")=~/000011$/} @e;
 die unless grep {$_->{type} eq "session_observed" && $_->{surface} eq "app"} @e;
 die if encode_json(\@e)=~/PRIVATE_|Unrelated|excluded/;
' "$J"
bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/journal.sh"; ai_journal_display_events "$2"' _ "$REPO" "$J" >"$WORK/journal-display"
check 'ownerless journal activity never guesses interruption from absent PID' perl -ne 'die if /\|interrupted\|/; ++$n if /\|running\|.*(?:consolidation|cli_worker|grandchild)/; END{die unless $n==3}' "$WORK/journal-display"
check 'metadata >64 KiB accepted using actual desktop source/originator format' perl -MJSON::PP -e '
 my ($f)=glob "$ARGV[0]/*/*/*/*000001.jsonl"; open my $h,"<",$f or die;
 my $line=<$h>; my $d=decode_json($line); die unless length($line)>65536 && $d->{payload}{source} eq "vscode" && $d->{payload}{originator} eq "Codex Desktop";
' "$CODEX_HOME/sessions"
for view in live list diagram; do
 args=(); [[ "$view" != live ]] || args=(--once)
 COLUMNS=170 LINES=65 LOOMY_TREE="$view" bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" ${args[@]+"${args[@]}"} >"$WORK/$view"
 check "$view has two live leads and nested persistent agents/turns" perl -0777 -e '
  my $s=<>; die unless $s=~/codex app 00000001.*live/ && $s=~/codex cli 00000008.*src.*live/;
  die unless $s=~/cli_worker/ && $s=~/grandchild/ && $s=~/turn 00000020/;
  die unless $s=~/5 running/;
  my @lines=split /\n/,$s; my ($c)=grep {/cli_worker/} @lines; my ($g)=grep {/grandchild/} @lines;
  die unless $c=~/^  ┣/ && $g=~/^    ┣/;
 ' "$WORK/$view"
done
fixture wait; poll; fixture wait-unrelated; poll
check 'unrelated output cannot clear unresolved wait; no ordinary-call journal heartbeat' perl -MJSON::PP -e '
 my @e=grep {ref($_) eq "HASH"} map {eval {decode_json($_)}} <>; my @a=grep {$_->{type} eq "delegation_activity" && ($_->{task}//"") eq "consolidation"} @e;
 die unless $a[-1]{state} eq "waiting";
 die if grep {($_->{task}//"") eq "consolidation" && $_->{ts} eq "2026-10-13T00:59:58Z"} @e;
' "$J"
fixture wait-result; poll
check 'matched wait result returns to running' perl -MJSON::PP -e 'my @e=grep {ref($_) eq "HASH"} map {eval {decode_json($_)}} <>; my @a=grep {$_->{type} eq "delegation_activity" && ($_->{task}//"") eq "consolidation"} @e; die unless $a[-1]{state} eq "running";' "$J"
fixture finish; poll
for width in 40 52 65 80 100 170; do
 COLUMNS="$width" LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/narrow-$width"
 check "$width columns preserve partial and interrupted with elapsed" perl -Mutf8 -CS -0777 -e '
  my ($w,$p)=@ARGV; open my $f,"<:encoding(UTF-8)",$p or die; my $s=do{local $/;<$f>};
  die unless $s=~/partial · [0-9]+:[0-9]{2}/ && $s=~/interrupted · [0-9]+:[0-9]{2}/;
  die if grep {length($_)>$w-1} split /\n/,$s;
 ' "$width" "$WORK/narrow-$width"
done
check 'legacy bridges without a proven parent remain visible in an unassigned recap bucket' perl -e '
 require $ARGV[0]; my $s=Loomy::LiveState->new;
 $s->consume({schema=>2,session_key=>"codex:lead",tool=>"codex",type=>"session_observed",source_active=>1,ts=>"2026-10-13T01:00:00Z",state=>"running"});
 $s->consume({type=>"delegation_start",tool=>"claude",id=>"unpaired-bridge",model=>"claude-sonnet-5-5",ts=>"2026-10-13T01:00:00Z"});
 my @r=$s->projections(1791853200); die unless grep {/^N\|G\|unassigned:claude\|claude\|.*\|stale\|/} @r;
 die unless grep {/^N\|A\|claude:unpaired-bridge\|unassigned:claude\|unassigned:claude\|running\|/} @r;
' "$REPO/scripts/lib/live-state.pl"
check 'same-second turns and late old activity cannot revive or replace the current turn' perl -e '
 require $ARGV[0]; my $s=Loomy::LiveState->new;
 my $base={schema=>2,session_key=>"codex:lead",tool=>"codex",bridge=>"codex-native",agent_id=>"child",ts=>"2026-10-13T01:00:00.500Z"};
 $s->consume({%$base,type=>"delegation_start",id=>"turn1",model=>"old"});
 $s->consume({%$base,type=>"delegation",id=>"turn1",status=>"ok",outcome=>"partial",duration_s=>0.5});
 $s->consume({%$base,type=>"delegation_start",id=>"turn2",model=>"current"});
 $s->consume({%$base,type=>"delegation_activity",id=>"turn1",state=>"running",model=>"late-old"});
 my $a=$s->{agents}{"codex:child"}; die unless $a->{latest} eq "turn2" && $a->{model} eq "current" && $a->{state} eq "running";
 die unless $s->{turns}{turn1}{state} eq "done" && $s->{turns}{turn1}{duration}==0.5 && $s->{turns}{turn1}{started}==1791853200.5;
' "$REPO/scripts/lib/live-state.pl"
check 'persistent reducer seeks before decoding and reads zero idle bytes' perl -MJSON::PP -e '
 my ($module,$journal)=@ARGV; require $module; my $s=Loomy::LiveState->new;
 $s->read_journal($journal); my $first=$s->{cursor}{offset}; die unless $first==(-s $journal);
 $s->read_journal($journal); die unless $s->{read_bytes}==0 && $s->{cursor}{offset}==$first;
 open my $h,">>",$journal or die; print $h "malformed but complete\n",q({"type":); close $h;
 $s->read_journal($journal); my $off=$s->{cursor}{offset}; die unless $off==(-s $journal)-8;
 open $h,">>",$journal or die; print $h qq("fixture"}\n); close $h;
 $s->read_journal($journal); die unless $s->{cursor}{offset}==(-s $journal) && $s->{read_bytes}<64;
' "$REPO/scripts/lib/live-state.pl" "$J"
check 'unchanged source/checkpoint has zero delta writes after warm-up' perl -MTime::HiRes=stat -MJSON::PP -e '
 my ($module,$root,$sessions)=@ARGV; require $module;
 Loomy::CodexNative::poll($root,$sessions); Loomy::CodexNative::poll($root,$sessions);
 my $idx="$root/.loomy/logs/codex-native.idx"; my $journal="$root/.loomy/logs/events.jsonl";
 my $stamp=(stat($idx))[9]; my $size=-s $journal;
 for (1..10) {my $s=Loomy::CodexNative::poll($root,$sessions); die if grep {($_->{read_bytes}//0)>0} values %{$s->{files}}}
 die unless (stat($idx))[9]==$stamp && (-s $journal)==$size;
' "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"
check 'lease expiry is stale without invented terminal; child evidence reactivates ancestors' perl -e '
 my ($module,$native,$root,$sessions)=@ARGV; require $module; require $native;
 my $s=Loomy::LiveState->new; $s->read_journal("$root/.loomy/logs/events.jsonl");
 my @r=$s->projections(1791853500); die unless grep {/\|G\|codex:.*00000001\|.*\|stale\|/} @r;
 die if grep {/\|T\|.*interrupted/ && /000000019/} @r;
 my $n=Loomy::CodexNative::poll($root,$sessions);
 for (values %{$n->{files}}) {$_->{last_observed_ts}="2026-10-13T01:05:00Z" if $_->{meta}{id}=~/000009$/}
 $s->source_evidence($n); @r=$s->projections(1791853500);
 die unless grep {/\|G\|codex:.*00000008\|.*\|live\|/} @r;
' "$REPO/scripts/lib/live-state.pl" "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"
LOOMY_WATCH_TOOL=claude COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/filter"
check 'view filter reports hidden groups and preserves collection' grep -q 'hidden groups' "$WORK/filter"
check 'private modes and allowlisted saved fields' perl -0777 -e 'for(@ARGV){open my $f,"<",$_ or die; die unless ((stat($f))[2]&0777)==0600; my $s=do{local $/;<$f>}; die if $s=~/PRIVATE_|developer_instructions|tool_arguments/}' "$J" "$ROOT/.loomy/logs/codex-native.idx"
fixture surface-leads; poll
check 'exec, vscode IDE and future surfaces are all discoverable' perl -MJSON::PP -e '
 my @e=grep {ref($_) eq "HASH"} map {eval {decode_json($_)}} <>;
 for my $id (7,12,13) {my $suffix=sprintf "%012d",$id; die unless grep {$_->{type} eq "session_observed" && ($_->{session}//"")=~/\Q$suffix\E$/ && $_->{state} eq "running" && $_->{surface} eq ($id==7 ? "exec" : "unknown")} @e}
' "$J"
fixture orphan; poll
check 'missing parent is visible as pending rather than dropped or attached by time' perl -MJSON::PP -e 'my @e=grep {ref($_) eq "HASH"} map {eval {decode_json($_)}} <>; my @s=grep {$_->{type} eq "delegation_start" && ($_->{agent_id}//"")=~/000006$/} @e; die unless @s==1 && $s[0]{session_key}=~/pending:.*000099$/;' "$J"
check 'warm reducer moves orphan atomically and removes the empty pending group' perl -e '
 my ($module,$native,$fixture,$root,$sessions,$pid)=@ARGV; require $module; require $native;
 my $s=Loomy::LiveState->new; $s->read_journal("$root/.loomy/logs/events.jsonl");
 my @r=$s->projections(1791853200); die unless grep {/\|G\|codex:pending:.*000099\|/} @r;
 system($^X,$fixture,"late-parent",$root,$sessions,$pid)==0 or die;
 Loomy::CodexNative::poll($root,$sessions); $s->read_journal("$root/.loomy/logs/events.jsonl");
 @r=$s->projections(1791853200); die unless grep {/^N\|D\|codex:pending:.*000099$/} @r;
 die unless (grep {/^N\|A\|codex:.*000006\|codex:.*000099\|/} @r)==1;
' "$REPO/scripts/lib/live-state.pl" "$REPO/scripts/lib/codex-native.pl" "$REPO/tests/fixtures/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions" "$$"
check 'parent arriving late resolves descendants by identity without replaying other starts' perl -MJSON::PP -e 'my @e=grep {ref($_) eq "HASH"} map {eval {decode_json($_)}} <>; my @s=grep {$_->{type} eq "agent_link" && ($_->{agent_id}//"")=~/000006$/} @e; die unless @s==1 && $s[0]{session_key} eq "codex:00000000-0000-4000-8000-000000000099";' "$J"
ROOT="$WORK/cli-only"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/cli-only-codex"
fixture seed; fixture ownerless-cli; LOOMY_JOURNAL_TASKS=0 poll
check 'ownerless CLI with privacy opt-out remains discoverable' perl -MJSON::PP -e 'my @e=grep {ref($_) eq "HASH"} map {eval {decode_json($_)}} <>; die unless (grep {$_->{type} eq "delegation_start"} @e)==3; die if encode_json(\@e)=~/consolidation|enrichment|review|Native[234]|\/root\//;' "$J"

# Fixed-clock oracle: the old owner ended at 01:00:00, the resumed turn starts at 01:00:10.
ROOT="$WORK/ended-owner-resume"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/ended-owner-codex"
fixture compact-seed; poll; fixture end-owner; poll
check 'old owner closes only the turns it owned' perl -MJSON::PP -e '
 my @e=map {decode_json($_)} <>;
 my @end=grep {$_->{type} eq "delegation"} @e;
 die unless @end==3 && !grep {$_->{status} ne "interrupted" || $_->{ts} ne "2026-10-13T01:00:00Z"} @end;
' "$J"
check 'resume reopens warm and cold projections using source lease, never the ended owner PID' perl -e '
 my ($module,$native,$fixture,$root,$sessions,$pid)=@ARGV; require $module; require $native;
 my $journal="$root/.loomy/logs/events.jsonl"; my $warm=Loomy::LiveState->new;
 $warm->read_journal($journal); my @before=$warm->projections(1791853200);
 die if grep {/^N\|G\|codex:.*000001\|.*\|live\|/} @before;
 system($^X,$fixture,"after-owner",$root,$sessions,$pid)==0 or die;
 local $ENV{LOOMY_NATIVE_NOW}=1791853220;
 my $n=Loomy::CodexNative::poll($root,$sessions);
 $warm->read_journal($journal); $warm->source_evidence($n);
 my $cold=Loomy::LiveState->new; $cold->read_journal($journal); $cold->source_evidence($n);
 for my $s ($warm,$cold) {
  my @r=$s->projections(1791853220);
  die unless grep {/^N\|G\|codex:.*000001\|.*\|live\|.*\|source lease\|/} @r;
  die unless grep {/^N\|A\|codex:.*000002\|.*\|running\|.*\|cn:.*000042\|/} @r;
  die if grep {/^N\|T\|cn:.*000042\|/} @r;
  @r=$s->projections(1791853332);
  die unless grep {/^N\|G\|codex:.*000001\|.*\|stale\|.*\|source lease\|/} @r;
 }
' "$REPO/scripts/lib/live-state.pl" "$REPO/scripts/lib/codex-native.pl" "$REPO/tests/fixtures/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions" "$$"
check 'resumed child has one start, no historical owner binding or premature terminal' perl -MJSON::PP -e '
 require shift; my @e=map {decode_json($_)} <>; my @new=grep {($_->{id}//"")=~/000042$/} @e;
 die unless (grep {$_->{type} eq "delegation_start" && $_->{ts} eq "2026-10-13T01:00:10Z"} @new)==1;
 die if grep {$_->{type} eq "delegation" || $_->{type} eq "agent_closed" || exists $_->{owner_pid}} @new;
 my %start=map {$_->{id}=>Loomy::LiveState::epoch($_->{ts})} grep {$_->{type} eq "delegation_start"} @e;
 for (grep {$_->{type} eq "delegation"} @e) {die if Loomy::LiveState::epoch($_->{ts})<$start{$_->{id}}}
' "$REPO/scripts/lib/live-state.pl" "$J"
cp "$J" "$WORK/resumed-journal"; LOOMY_NATIVE_NOW=1791853221 poll
check 'unchanged resumed source does not replay starts or historical close' cmp "$J" "$WORK/resumed-journal"
fixture after-owner-invalid-end; LOOMY_NATIVE_NOW=1791853222 poll
check 'source terminal before resumed start is rejected' perl -MJSON::PP -e 'die if grep {$_->{type} eq "delegation" && ($_->{id}//"")=~/000042$/} map {decode_json($_)} <>;' "$J"
fixture after-owner-complete; LOOMY_NATIVE_NOW=1791853223 poll
check 'resumed turn keeps its valid source completion and five-second duration' perl -MJSON::PP -e '
 my @end=grep {$_->{type} eq "delegation" && ($_->{id}//"")=~/000042$/} map {decode_json($_)} <>;
 die unless @end==1 && $end[0]{status} eq "ok" && $end[0]{ts} eq "2026-10-13T01:00:15Z" && $end[0]{duration_s}==5;
' "$J"
check 'reducer rejects an end before a known start, including fractional seconds' perl -e '
 require $ARGV[0]; my $s=Loomy::LiveState->new;
 my $base={schema=>2,session_key=>"codex:lead",tool=>"codex",bridge=>"codex-native",agent_id=>"child",id=>"turn"};
 $s->consume({%$base,type=>"delegation_start",ts=>"2026-10-13T01:00:10.500Z"});
 $s->consume({%$base,type=>"delegation",ts=>"2026-10-13T01:00:10.499Z",status=>"interrupted"});
 my @r=$s->projections(1791853220); die if grep {/^N\|T\|turn\|/} @r;
 die unless grep {/^N\|A\|codex:child\|.*\|running\|/} @r;
' "$REPO/scripts/lib/live-state.pl"
ROOT="$WORK/new-owner-resume"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/new-owner-codex"
fixture compact-seed; poll; fixture end-owner; poll
fixture after-owner-launcher; fixture after-owner; LOOMY_NATIVE_NOW=1791853220 poll
check 'new activation uses its current live launcher beyond the source lease' perl -e '
 my ($module,$journal)=@ARGV; require $module; my $s=Loomy::LiveState->new; $s->read_journal($journal);
 my @r=$s->projections(1791853400);
 die unless grep {/^N\|G\|codex:.*000001\|.*\|live\|.*\|launcher\|/} @r;
 die unless grep {/^N\|A\|codex:.*000002\|.*\|running\|.*\|cn:.*000042\|/} @r;
' "$REPO/scripts/lib/live-state.pl" "$J"
fixture after-owner-launcher-end; LOOMY_NATIVE_NOW=1791853240 poll
check 'only the current owner end closes resumed work, without extending the old ownership' perl -MJSON::PP -e '
 my ($journal,$index)=@ARGV; open my $j,"<",$journal or die; my @e=map {decode_json($_)} <$j>;
 my @end=grep {$_->{type} eq "delegation" && ($_->{id}//"")=~/000042$/} @e;
 die unless @end==1 && $end[0]{status} eq "interrupted" && $end[0]{ts} eq "2026-10-13T01:00:30Z";
 open my $i,"<",$index or die; my $n=decode_json(do{local $/;<$i>});
 my @o=sort {$a->{ts} cmp $b->{ts}} values %{$n->{owners}};
 die unless @o==2 && $o[0]{ended} eq "2026-10-13T01:00:00Z" && $o[1]{ended} eq "2026-10-13T01:00:30Z";
' "$J" "$ROOT/.loomy/logs/codex-native.idx"
ROOT="$WORK/dead-owner-resume"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/dead-owner-codex"
perl "$REPO/tests/fixtures/codex-native.pl" compact-seed "$ROOT" "$CODEX_HOME/sessions" 99999999; poll
fixture after-owner; LOOMY_NATIVE_NOW=1791853220 poll
check 'previously observed process death cannot interrupt a later activation without an end hook' perl -MJSON::PP -e '
 my @e=map {decode_json($_)} <>;
 die unless (grep {$_->{type} eq "delegation_start" && ($_->{id}//"")=~/000042$/ && !exists $_->{owner_pid}} @e)==1;
 die if grep {$_->{type} eq "delegation" && ($_->{id}//"")=~/000042$/} @e;
' "$J"
# Exercise the same body composition as watch, including its real banner/footer budget, without a PTY.
ROOT="$WORK/viewport"; export CODEX_HOME="$WORK/viewport-codex"
fixture seed; fixture app; fixture second-lead; fixture finish
for trial in {30..41}; do perl "$REPO/tests/fixtures/codex-native.pl" live-child "$ROOT" "$CODEX_HOME/sessions" "$trial"; done
render_frame() {
  COLUMNS=170 LINES=40 bash -c '
    repo=$1; ROOT=$2; view=$3; limit=$4; offset=$5
    for lib in ui models journal phases usage sessionlog; do source "$repo/scripts/lib/$lib.sh"; done
    source "$repo/scripts/loomy-tree.sh" --library
    loomy_live_init; loomy_live_poll "$ROOT/.loomy/logs/events.jsonl"; LV_NOW=$LOOMY_NATIVE_NOW
    loomy_live_states; loomy_live_metadata; loomy_live_header
    _ui_term_size; UI_HDR_TITLE="$LV_HEADER"
    UI_FTR_KEYS="↑↓ scroll · [o] orchestrator · [a] live list · [t] status · [v] list · [l] log · [s] session · [q] quit"
    _ui_chrome; height=$(( UI_ROWS - UI_CHROME_H )); [[ "$limit" == auto ]] || height=$limit
    if [[ "$view" == classic ]]; then
      NS_ENABLED=0; LV_RUNNING=(); LV_FINISHED=(); LV_GROUP=model; LV_ACTIVE=1
      for (( i=0; i<12; i++ )); do
        LV_RUNNING+=("$i"); LV_LABEL[i]="worker$i"; LV_ROLE[i]=developer; LV_TASK[i]="classic$i"
        LV_MODEL[i]=gpt-6-luna; LV_TOOL[i]=Codex; LV_MODELSHORT[i]=6-luna; LV_WORD[i]=low
        LV_BAR[i]=""; LV_FLAGS[i]=""; LV_OBSERVED[i]=running; LV_TS[i]=$(( LV_NOW - 12 + i )); LV_START_SEQ[i]=$i
      done
    fi
    frame=$(LOOMY_NO_HEADER=1 LOOMY_WATCH_VIEW=$view LOOMY_WATCH_BODY_HEIGHT=$height LOOMY_WATCH_PIN=1 loomy_live_render)
    loomy_live_viewport "$frame" "$height" "$offset"
    (( ${#UI_PAGE_L[@]} <= height )) || exit 1
    printf "HEIGHT=%s OFFSET=%s\n" "$height" "$LV_SCROLL_TOP"
    printf "%s\n" "${UI_PAGE_L[@]}"
  ' _ "$REPO" "$ROOT" "$1" "$2" "$3"
}
for view in tree list; do
  render_frame "$view" auto 0 >"$WORK/frame-$view"
  check "$view 170x40 frame keeps twelve running children and both leads above the footer" perl -0777 -e '
    my $s=<>; for my $n (30..41) {die "missing latency$n" unless $s=~/latency$n[^\n]*running/}
    die unless $s=~/cli_worker[^\n]*running/ && $s=~/grandchild[^\n]*running/;
    die unless $s=~/codex app 00000001/ && $s=~/codex cli 00000008/ && $s=~/\+3 finished/;
  ' "$WORK/frame-$view"
  render_frame "$view" auto 9999 >"$WORK/frame-$view-scroll"
  check "$view recap scroll preserves every active row and lead" perl -0777 -e '
    my $s=<>; for my $n (30..41) {die unless $s=~/latency$n[^\n]*running/}
    die unless $s=~/codex app 00000001/ && $s=~/codex cli 00000008/ ;
    die if $s=~/OFFSET=0\n/;
  ' "$WORK/frame-$view-scroll"
  render_frame "$view" auto 1 >"$WORK/frame-$view-detail"
  check "$view finished turn outcomes remain available in the scrolling recap" grep -q partial "$WORK/frame-$view-detail"
  render_frame "$view" 10 0 >"$WORK/frame-$view-small"
  check "$view saturation keeps newest active children and both leads in ten body rows" perl -0777 -e '
    my $s=<>; die unless $s=~/codex app 00000001/ && $s=~/codex cli 00000008/;
    for my $n (39..41) {die "missing latency$n:\n$s" unless $s=~/latency$n[^\n]*running/}
    die unless $s=~/\+11 running/;
  ' "$WORK/frame-$view-small"
done
render_frame classic auto 0 >"$WORK/frame-classic"
check 'classic live list 170x40 keeps twelve active rows and orchestrator without scrolling' perl -0777 -e '
  my $s=<>; die unless $s=~/Orchestrator/; for my $n (0..11) {die unless $s=~/classic$n[^\n]*running/}
' "$WORK/frame-classic"
render_frame classic 10 0 >"$WORK/frame-classic-small"
check 'classic saturation keeps the six newest rows beside the orchestrator' perl -0777 -e '
  my $s=<>; die unless $s=~/Orchestrator/; for my $n (6..11) {die unless $s=~/classic$n[^\n]*running/}
' "$WORK/frame-classic-small"
ROOT="$WORK/latency"; export CODEX_HOME="$WORK/latency-codex"
fixture seed; fixture app; fixture second-lead
check 'stat-only idle detection and twenty changed-file projections stay under 80 ms CPU with one retry' perl -MTime::HiRes=clock_gettime,CLOCK_PROCESS_CPUTIME_ID -MJSON::PP -e '
 my ($repo,$root,$sessions,$pid)=@ARGV;
 require "$repo/scripts/lib/codex-native.pl"; require "$repo/scripts/lib/live-state.pl";
 my $live=Loomy::LiveState->new; my $journal="$root/.loomy/logs/events.jsonl";
 my $warm=sub { my $s=Loomy::CodexNative::poll($root,$sessions); $live->read_journal($journal); $live->source_evidence($s); $live->projections($ENV{LOOMY_NATIVE_NOW}); return $s };
 $warm->() for 1..3;
 Loomy::CodexNative::watch_changed($root,$sessions,$ENV{LOOMY_NATIVE_NOW});
 my $max=0;
 for (1..100) {
   my $t=clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
   die "idle detector reports change" if Loomy::CodexNative::watch_changed($root,$sessions,$ENV{LOOMY_NATIVE_NOW});
   my $elapsed=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$t; $max=$elapsed if $elapsed>$max;
   die "idle detector exceeds 25 ms" if $elapsed>=0.025;
 }
 { no warnings "redefine"; local *Loomy::CodexNative::open_read=sub { die "idle source read" };
   $warm->(); die "idle journal bytes" if $live->{read_bytes}; }
 printf "100 idle probes: maximum %.3f ms; no source/journal reads\n",$max*1000;
 $max=0;
 for my $trial (70..89) {
   my $passed;
   for my $attempt (0..1) {
     my $id=$trial+$attempt*100;
     system($^X,"$repo/tests/fixtures/codex-native.pl","live-child",$root,$sessions,$id)==0 or die "fixture";
     my $t=clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
     die "new file undetected" unless Loomy::CodexNative::watch_changed($root,$sessions,$ENV{LOOMY_NATIVE_NOW});
     my $s=Loomy::CodexNative::poll($root,$sessions);
     $live->read_journal($journal); $live->source_evidence($s);
     my @d=$live->projections($ENV{LOOMY_NATIVE_NOW});
     die "new child projection absent" unless grep {/\|latency$id\|/} @d;
     my $elapsed=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$t;
     if ($elapsed<0.080) {$passed=1; $max=$elapsed if $elapsed>$max; last}
     warn "changed-file detector retry after ${elapsed}s CPU\n" unless $attempt;
   }
   die "changed-file detector exceeds 80 ms CPU after retry" unless $passed;
   $warm->() for 1..2;
   Loomy::CodexNative::watch_changed($root,$sessions,$ENV{LOOMY_NATIVE_NOW});
 }
 printf "20 detection/read/reducer trials: maximum %.3f ms (<80 ms CPU, one retry)\n",$max*1000;
' "$REPO" "$ROOT" "$CODEX_HOME/sessions" "$$"
# Keep screen timing independent of the detection-cost fixture above.
ROOT="$WORK/frame-latency"; export CODEX_HOME="$WORK/frame-latency-codex"
fixture seed; fixture app; fixture second-lead
check 'twenty sampler/render frames complete within five seconds with one retry' perl "$REPO/tests/fixtures/codex-live-latency.pl" "$REPO" "$ROOT" "$CODEX_HOME/sessions"
if [[ "${LOOMY_TEST_NATIVE_PTY:-1}" == 0 ]]; then
 printf 'SKIP S1 screen latency: explicitly disabled; run tests/fixtures/codex-live-watch.exp on Mac PTY\n'
else
 check 'twenty screen trials see new app children within 600 ms' expect "$REPO/tests/fixtures/codex-live-watch.exp"
fi
printf '%s S1 Codex live checks passed\n' "$PASS"
