# Round 2 oracles: real Claude record envelopes with empty messages/arguments.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use POSIX qw(strftime);
my ($repo,$work,$finding)=@ARGV;
require "$repo/scripts/lib/claude-native.pl";
require "$repo/scripts/lib/live-state.pl";
my $root="$work/$finding"; my $projects="$work/projects";
make_path("$root/.loomy/logs");
my $path="$projects/".Loomy::ClaudeNative::slug($root).'/lead.jsonl';
my $journal="$root/.loomy/logs/events.jsonl";
my $clock=1791853200;
$ENV{LOOMY_NATIVE_NOW}=$clock+7;
sub ts {strftime('%Y-%m-%dT%H:%M:%S',gmtime($clock+$_[0])).'.750Z'}
sub rows {
    my ($file,@records)=@_; $file =~ m{^(.*)/[^/]+$}; make_path($1);
    open my $f,'>>',$file or die $!; print $f encode_json($_),"\n" for @records; close $f or die $!;
}
sub base {return (sessionId=>'lead',cwd=>$root,timestamp=>ts($_[1]),type=>$_[0])}
sub launch {
    my ($cid,$at,$tool)=@_; rows($path,{base('assistant',$at),message=>{model=>'claude-sonnet-5-5',stop_reason=>undef,
        content=>[{type=>'tool_use',name=>$tool//'Agent',id=>$cid,input=>{subagent_type=>'developer'}}]}});
}
sub returned {
    my ($cid,$aid,$at)=@_; rows($path,{base('user',$at),toolUseResult=>{status=>'async_launched',agentId=>$aid},
        message=>{content=>[{type=>'tool_result',tool_use_id=>$cid,content=>[]}]}});
    (my $child=$path)=~s{\.jsonl$}{/subagents/agent-$aid.jsonl};
    rows($child,{base('user',$at),agentId=>$aid,isSidechain=>JSON::PP::true,message=>{content=>[]}},
        {base('assistant',$at),agentId=>$aid,message=>{stop_reason=>undef,content=>[]}});
}
sub notification {
    my ($cid,$status,$at)=@_; rows($path,{base('queue-operation',$at),operation=>'enqueue',
        content=>"<task-notification><task-id>child</task-id><tool-use-id>$cid</tool-use-id><status>$status</status></task-notification>"});
}
sub poll {return Loomy::ClaudeNative::poll($root,$projects)//die 'poll failed'}
sub state {my $s=Loomy::LiveState->new; $s->read_journal($journal); return $s}
sub events {open my $f,'<',$journal or die $!; return map {decode_json($_)} <$f>}
sub shell {
    my $rc=system('bash','-e','-o','pipefail','-c',$_[0],'_', $repo,$root,@_[1..$#_]); die "shell failed ($rc)" if $rc;
}
if ($finding eq 'R1') {
    for my $i (1..20) {
        my $sid=sprintf('s%02d',$i); (my $file=$path)=~s{/lead.jsonl$}{/$sid.jsonl};
        rows($file,{sessionId=>$sid,cwd=>$root,type=>'assistant',timestamp=>ts(1),message=>{stop_reason=>undef,
            content=>[{type=>'tool_use',name=>'Agent',id=>'call',input=>{}}]}});
    }
    for (1..4) {system('perl',"$repo/scripts/lib/claude-native.pl",$root,$projects)==0 or die 'one-shot failed'}
    die 'twenty small one-shot transcripts starved' unless keys(%{state()->{agents}})==20;
    my $size=-s $journal;
    system('perl',"$repo/scripts/lib/claude-native.pl",$root,$projects)==0 or die;
    die 'one-shot replay duplicated events' unless (-s $journal)==$size;
} elsif ($finding eq 'R2') {
    launch('bash',1,'Bash'); notification('bash','completed',2);
    notification('pending','completed',4); launch('pending',3);
    launch('agent',5); returned('agent','child',6); notification('agent','completed',7);
    my $s=poll();
    die 'Bash notification fabricated an agent' if $s->{sessions}{lead}{calls}{bash};
    die 'known or out-of-order Agent notification lost' unless $s->{sessions}{lead}{calls}{pending}{state} eq 'done' && $s->{sessions}{lead}{calls}{agent}{state} eq 'done';
    die 'phantom Bash journal event' if grep {($_->{turn_id}//'') eq 'bash'} events();
} elsif ($finding eq 'R3') {
    launch('silent',1); returned('silent','child',2); poll();
    $ENV{LOOMY_NATIVE_NOW}=$clock+500;
    die 'wall clock interrupted a long tool call' if poll()->{sessions}{lead}{calls}{silent}{ended};
    notification('silent','completed',314);
    die 'late completion lost' unless poll()->{sessions}{lead}{calls}{silent}{state} eq 'done';
    launch('inferred',315); returned('inferred','other',316);
    rows($path,{base('assistant',500),message=>{stop_reason=>undef,content=>[]}});
    die 'G2: lead evidence interrupted child within its own lease' unless poll()->{sessions}{lead}{calls}{inferred}{state} eq 'running';
    notification('inferred','completed',510);
    die 'completion could not override interruption' unless poll()->{sessions}{lead}{calls}{inferred}{state} eq 'done';
    die 'correction not projected' unless state()->{agents}{'claude:lead:inferred'}{state} eq 'done';
    shell(q{source "$1/scripts/lib/journal.sh"; ai_journal_canonical <"$2/.loomy/logs/events.jsonl" >"$2/canonical";});
    open my $corrected,'<',"$root/canonical" or die;
    my @ends=grep {$_->{type} eq 'delegation' && ($_->{turn_id}//'') eq 'inferred'} map {decode_json($_)} <$corrected>;
    die 'interrupted correction double-counted' unless @ends==1 && $ends[0]{status} eq 'ok';
    launch('killed',511); notification('killed','killed',512);
    die 'killed notification not interrupted' unless poll()->{sessions}{lead}{calls}{killed}{state} eq 'interrupted';
    # A long resumed head shares its filename identity; real time must not close it mid-replay.
    my $replay="$work/R3-replay"; make_path("$replay/.loomy/logs");
    my $file="$projects/".Loomy::ClaudeNative::slug($replay).'/lead.jsonl';
    rows($file,{sessionId=>'lead',cwd=>$replay,type=>'assistant',timestamp=>ts(1),message=>{stop_reason=>undef,
        content=>[{type=>'tool_use',name=>'Agent',id=>'replay',input=>{}}]}},
        {sessionId=>'lead',cwd=>$replay,type=>'user',timestamp=>ts(2),toolUseResult=>{status=>'async_launched',agentId=>'child'},message=>{content=>[{type=>'tool_result',tool_use_id=>'replay',content=>[]}]}});
    rows($file,map {{sessionId=>'lead',cwd=>$replay,type=>'progress',timestamp=>ts(400),uuid=>"record$_"}} 1..5000);
    delete $ENV{LOOMY_NATIVE_NOW};
    my $s=Loomy::ClaudeNative::poll($replay,$projects);
    die 'head catch-up inferred interruption before EOF' if !$s->{files}{$file}{at_eof} && $s->{sessions}{lead}{calls}{replay}{ended};
    for (1..12) {$s=Loomy::ClaudeNative::poll($replay,$projects)}
    die 'G2: EOF fabricated a terminal without child evidence' if $s->{sessions}{lead}{calls}{replay}{ended};
    rows($file,{sessionId=>'lead',cwd=>$replay,type=>'queue-operation',timestamp=>ts(510),operation=>'enqueue',content=>'<task-notification><tool-use-id>replay</tool-use-id><status>completed</status></task-notification>'});
    $s=Loomy::ClaudeNative::poll($replay,$projects);
    die 'real-clock head replay completion lost' unless $s->{sessions}{lead}{calls}{replay}{state} eq 'done';
} elsif ($finding eq 'R4') {
    my $fresh="$work/R4-fresh"; make_path("$fresh/.loomy");
    shell(q{ { sleep 2; printf 'q\n'; } | LOOMY_JOURNAL=0 bash "$1/scripts/loomy-status.sh" --root "$3" --watch >"$2/frame" 2>"$2/stderr";
      grep -q 'AGENT TREE' "$2/stderr"; ! grep -q 'No such file' "$2/stderr";
      test ! -e "$3/.loomy/logs"; },$fresh);
} elsif ($finding eq 'R6') {
    rows($journal,{type=>'phase',phase=>'brief',ts=>ts(0)},
        {type=>'delegation_start',bridge=>'subagent',session=>'lead',id=>'call',role=>'developer',family=>'claude',model=>'claude-sonnet-5-5',ts=>ts(1)},
        {type=>'delegation',bridge=>'subagent',session=>'lead',id=>'call',role=>'developer',family=>'claude',model=>'claude-sonnet-5-5',status=>'ok',ts=>ts(4)});
    launch('call',1); returned('call','a',2); notification('call','completed',4); poll();
    rows($journal,{type=>'phase',phase=>'done',ts=>ts(8)});
    shell(q{printf 'name=Round2\nai_mode=MANUAL\nai_lead=claude\n' >"$2/.loomy/brief.md"; printf 'phase=done\n' >"$2/.loomy/state";
      bash "$1/scripts/loomy-status.sh" --root "$2" >"$2/status" 2>&1;
      grep -q 'Project ready.*1 delegation(s)' "$2/status";
      bash "$1/scripts/loomy-report.sh" --root "$2" >"$2/report" 2>&1;
      grep -q 'Total.*1 .*0 failed' "$2/report";
      source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/sessionlog.sh";
      _ai_session_events "$2/.loomy/logs/events.jsonl" >"$2/sessionlog";
      test "$(grep -c '|developer|start|' "$2/sessionlog")" = 1;
      test "$(grep -c '|developer|done|' "$2/sessionlog")" = 1;
      bash "$1/scripts/loomy-context.sh" --root "$2" >"$2/context" 2>&1;
      grep -q 'Latest delegations: developer (claude-sonnet-5-5, ok).' "$2/context";
      test "$(grep 'Latest delegations:' "$2/context" | grep -o 'developer' | wc -l | tr -d ' ')" = 1;});
} elsif ($finding eq 'R7') {
    rows($journal,map {{type=>'usage',ts=>ts(0),scope=>'lead',model=>'history',messages=>1}} 1..10000);
    launch('call',1); returned('call','a',2); notification('call','completed',4); poll();
    shell(q{source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/journal.sh";
      eval "$(declare -f ai_journal_canonical | sed '1s/ai_journal_canonical/round2_original_canonical/')";
      ai_journal_canonical() { local input; input="$(cat)"; test "$(printf '%s\n' "$input" | wc -l)" -le 4000 || return 1;
        printf '%s\n' "$input" | round2_original_canonical; }
      ai_journal_display_events "$2/.loomy/logs/events.jsonl" >"$2/display";
      grep -q '|developer|done|' "$2/display"; });
} elsif ($finding eq 'R5') {
    for (1..8) {rows($journal,{type=>'session',session=>"s$_",tool=>'claude',event=>'start',ts=>ts(0)},
        {type=>'session',session=>"s$_",tool=>'claude',event=>'start',id=>"request$_",agent_id=>"noise$_",ts=>ts(1)})}
    launch('closed',1); returned('closed','a',2); notification('closed','completed',4);
    launch('open',5); returned('open','b',6); poll();
    my $before=state();
    shell(q{source "$1/scripts/lib/journal.sh";
      printf '2000-01\n' >"$2/.loomy/logs/month"; _ai_journal_rotate "$2/.loomy/logs/events.jsonl";
      cp "$2/.loomy/logs/events.jsonl" "$2/rotation1";
      printf '2000-02\n' >"$2/.loomy/logs/month"; _ai_journal_rotate "$2/.loomy/logs/events.jsonl";
      cmp "$2/rotation1" "$2/.loomy/logs/events.jsonl";
      ai_journal_all "$2" | ai_journal_canonical >"$2/history"; });
    my $after=state();
    die 'monthly rotation lost active session/agent' unless keys(%{$after->{sessions}})==keys(%{$before->{sessions}}) && $after->{agents}{'claude:lead:open'}{state} eq 'running';
    die 'closed delegation survived monthly rotation' if grep {($_->{id}//'') eq 'cl:lead:closed' || $_->{type} eq 'delegation'} events();
    die 'rotation did not collapse sessions with differing ids' unless (grep {$_->{type} eq 'session'} events())==8;
    open my $f,'<',"$root/history" or die; my @history=map {decode_json($_)} <$f>;
    die 'archives double-counted closed execution' unless (grep {$_->{type} eq 'delegation' && ($_->{turn_id}//'') eq 'closed'} @history)==1;
} elsif ($finding eq 'R8') {
    for (1..2) {rows($journal,{type=>'usage',ts=>ts(1),scope=>'lead',cost_usd=>0.5,tokens_in=>12},
        {type=>'delegation_start',ts=>ts(1),id=>'call',session=>'lead'},
        {type=>'session',ts=>ts(1),event=>'start',tool=>'claude',session=>'lead'})}
    shell(q{source "$1/scripts/lib/journal.sh"; ai_journal_canonical <"$2/.loomy/logs/events.jsonl" >"$2/canonical";});
    open my $f,'<',"$root/canonical" or die; my @e=map {decode_json($_)} <$f>;
    die 'identical usage records dropped' unless (grep {$_->{type} eq 'usage'} @e)==2;
    die 'rotation snapshots no longer deduplicated' unless (grep {$_->{type} eq 'session'} @e)==1 && (grep {$_->{type} eq 'delegation_start'} @e)==1;
} elsif ($finding eq 'R9') {
    launch('relative',1);
    shell(q{cd "$1"; CLAUDE_CONFIG_DIR="${3%/projects}" perl scripts/lib/live-state.pl "$2" "$2/no-codex" >"$2/live";
      grep -q '^N|A|claude:lead:relative|' "$2/live"; },$projects);
} elsif ($finding eq 'R10') {
    # Reconstruction now repairs malformed checkpoints at startup. Inject during sampling to test diagnostics.
    my $errors="$root/.loomy/logs/watch-errors.log";
    shell(q{ { sleep 1; rm -f "$2/.loomy/logs/claude-native.idx.bak";
      printf '{}broken' >"$2/.loomy/logs/claude-native.idx"; sleep 3; printf 'q\n'; } |
      bash "$1/scripts/loomy-status.sh" --root "$2" --watch >"$2/frame" 2>"$2/stderr";
      test "$(grep -c 'watch sampler checkpoint-recovering' "$2/.loomy/logs/watch-errors.log")" = 1;
      ! grep -q 'Native checkpoint invalid' "$2/stderr"; });
    open my $f,'>',$errors or die; print $f 'x'x70000; close $f;
    shell(q{ { sleep 1; rm -f "$2/.loomy/logs/claude-native.idx.bak";
      printf '{}broken' >"$2/.loomy/logs/claude-native.idx"; sleep 2; printf 'q\n'; } |
      bash "$1/scripts/loomy-status.sh" --root "$2" --watch >"$2/frame" 2>"$2/stderr";
      grep -q 'watch sampler checkpoint-recovering' "$2/.loomy/logs/watch-errors.log"; });
    die 'watch diagnostics not bounded/private' unless -s $errors<=65536 && ((stat($errors))[2]&0777)==0600;
} else {die "unknown finding $finding"}
print "PASS $finding Round 2 structural regression\n";
