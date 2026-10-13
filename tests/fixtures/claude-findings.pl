# Regression oracles F1..F14: synthetic structural fields only, never real transcript content.
use strict;
use warnings;
no warnings 'once';
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use Fcntl qw(O_RDWR LOCK_EX LOCK_NB);
use POSIX qw(strftime);
my ($repo,$work,$finding)=@ARGV;
require "$repo/scripts/lib/claude-native.pl";
require "$repo/scripts/lib/live-state.pl";
my $root="$work/$finding"; my $projects="$work/projects";
make_path("$root/.loomy/logs");
my $path="$projects/".Loomy::ClaudeNative::slug($root).'/lead.jsonl';
my $journal="$root/.loomy/logs/events.jsonl";
my $idx="$root/.loomy/logs/claude-native.idx";
my $clock=1791853200;
$ENV{LOOMY_NATIVE_NOW}=$clock+7;
sub ts {strftime('%Y-%m-%dT%H:%M:%S',gmtime($clock+$_[0])).'.750Z'}
sub rows {
    my ($file,@records)=@_; $file =~ m{^(.*)/[^/]+$}; make_path($1);
    open my $f,'>>',$file or die $!; print $f encode_json($_),"\n" for @records; close $f or die $!;
}
sub base {return (sessionId=>'lead',cwd=>$root,timestamp=>ts($_[1]),type=>$_[0])}
sub launch {
    my ($cid,$at)=@_; rows($path,{base('assistant',$at),message=>{model=>'claude-sonnet-5-5',stop_reason=>undef,
        content=>[{type=>'tool_use',name=>'Agent',id=>$cid,input=>{subagent_type=>'developer'}}]}});
}
sub returned {
    my ($cid,$aid,$at)=@_; rows($path,{base('user',$at),toolUseResult=>{status=>'async_launched',agentId=>$aid},
        message=>{content=>[{type=>'tool_result',tool_use_id=>$cid,content=>[]}]}});
    (my $child=$path)=~s{\.jsonl$}{/subagents/agent-$aid.jsonl};
    rows($child,{base('user',$at),agentId=>$aid,isSidechain=>JSON::PP::true,message=>{content=>[]}},
        {base('assistant',$at),agentId=>$aid,message=>{model=>'claude-sonnet-5-5',stop_reason=>undef,content=>[]}});
}
sub notification {
    my ($cid,$status,$at)=@_; rows($path,{base('queue-operation',$at),operation=>'enqueue',
        content=>"<task-notification><task-id>child</task-id><tool-use-id>$cid</tool-use-id><status>$status</status></task-notification>"});
}
sub poll {return Loomy::ClaudeNative::poll($root,$projects)//die 'poll failed'}
sub events {open my $f,'<',$journal or die $!; return map {decode_json($_)} <$f>}
sub state {my $s=Loomy::LiveState->new; $s->read_journal($journal); return $s}
sub shell {
    my $rc=system('bash','-c',$_[0],'_', $repo,$root,@_[1..$#_]); die "shell failed ($rc)" if $rc;
}
if ($finding eq 'F1') {
    my $outside="$work/previous"; make_path($outside);
    rows($path,map {{type=>'user',sessionId=>'previous',cwd=>$outside,timestamp=>ts(-4000),uuid=>"old$_",message=>{content=>[]}}} 1..3000);
    launch('resumed',1); poll(); my $v=state();
    die 'resume used previous identity/cwd' unless keys(%{$v->{sessions}})==1 && $v->{agents}{'claude:lead:resumed'};
    die 'old session persisted' if (grep {($_->{session}//'') eq 'previous'} events());
} elsif ($finding eq 'F2') {
    launch('ok',1); returned('ok','a',2); launch('bad',2); returned('bad','b',3);
    my $s=poll(); die 'async_launched without background ended early' if grep {$_->{ended}} values %{$s->{sessions}{lead}{calls}};
    notification('ok','completed',4); notification('bad','failed',5); $s=poll();
    die 'notifications lost' unless $s->{sessions}{lead}{calls}{ok}{state} eq 'done' && $s->{sessions}{lead}{calls}{bad}{state} eq 'failed';
    die 'lead running forever' unless $s->{sessions}{lead}{state} eq 'idle';
    my ($end)=grep {$_->{type} eq 'delegation' && $_->{turn_id} eq 'ok'} events();
    die 'milliseconds lost' unless $end->{source_ts} eq ts(4) && $end->{duration_s}==3;
    launch('silent',6); returned('silent','c',6); poll(); $ENV{LOOMY_NATIVE_NOW}=$clock+200;
    rows($path,{base('assistant',200),message=>{stop_reason=>undef,content=>[]}}); $s=poll();
    die 'silent child still running' unless $s->{sessions}{lead}{calls}{silent}{state} eq 'interrupted';
} elsif ($finding eq 'F3') {
    launch('open',1); poll(); my $v=state();
    die 'fresh agent interrupted' unless grep {/\|A\|.*\|running\|/} $v->projections($clock+7);
    $v=state();
    die 'silent child lost own lease' unless grep {/\|A\|.*\|running\|/} $v->projections($clock+200);
    die 'stale agent running forever' unless grep {/\|A\|.*\|unknown\|/} $v->projections($clock+1000);
    $v=state(); $v->consume({type=>'session',tool=>'claude',session=>'lead',event=>'end',ts=>ts(3)});
    die 'closed agent running forever' unless grep {/\|A\|.*\|interrupted\|/} $v->projections($clock+7);
    my $w=state(); $w->{sessions}{'claude:lead'}{pid}=2147483647;
    die 'dead lead agent running forever' unless grep {/\|A\|.*\|interrupted\|/} $w->projections($clock+7);
} elsif ($finding eq 'F5') {
    my $lead={id=>'old',surface=>'unknown',seen=>ts(-700000),calls=>{},aliases=>{},stops=>{}};
    my $s={sessions=>{old=>$lead},sent=>{}};
    for (1..1600) {
        $lead->{calls}{"c$_"}={started=>ts(-700003),ended=>ts(-700000),state=>'done',status=>'ok',role=>'agent',task=>'x'x5500};
        $s->{sent}{"context:cl:old:c$_"}=encode_json({task=>'x'x5500});
    }
    open my $f,'>',$idx or die $!; print $f encode_json($s); close $f;
    die 'growth fixture not >16 MiB' unless -s $idx>16777216;
    $s=poll(); die 'old calls/sent not pruned' if keys %{$s->{sessions}} || keys %{$s->{sent}};
    die 'checkpoint not bounded' unless -s $idx<2097152;
    my $sig=Loomy::ClaudeNative::signature($idx);
    {no warnings 'redefine'; local *JSON::PP::encode=sub {die 'whole state encoded on idle'}; poll() for 1..10}
    die 'idle checkpoint changed' unless Loomy::ClaudeNative::signature($idx) eq $sig;
    rows($path,{type=>'assistant',sessionId=>'old',cwd=>$root,timestamp=>ts(-700000),message=>{content=>[]}});
    launch('new',1); poll();
    die 'new resumed turn lost after prune' unless state()->{agents}{'claude:lead:new'};
} elsif ($finding eq 'F6' || $finding eq 'F14') {
    launch('call',1); returned('call','a',2); notification('call','completed',4);
    rows($journal,{type=>'delegation_start',bridge=>'subagent',session=>'lead',id=>'call',role=>'developer',family=>'claude',model=>'claude-sonnet-5-5',ts=>ts(1)},
        {type=>'delegation',bridge=>'subagent',session=>'lead',id=>'call',role=>'developer',family=>'claude',model=>'claude-sonnet-5-5',status=>'ok',ts=>ts(4),cost_in=>'usage',cost_usd=>0,tokens_in=>0,tokens_cached=>0,tokens_out=>0});
    poll();
    shell(q{source "$1/scripts/lib/journal.sh"; ai_journal_canonical <"$2/.loomy/logs/events.jsonl" >"$2/canonical"});
    open my $f,'<',"$root/canonical" or die $!; my @e=map {decode_json($_)} <$f>;
    die 'canonical lifecycle duplicated' unless (grep {$_->{type} eq 'delegation_start'} @e)==1 && (grep {$_->{type} eq 'delegation'} @e)==1;
    shell(q{bash "$1/scripts/loomy-stats.sh" --root "$2" >"$2/stats" 2>&1; grep -q 'Delegations.*1' "$2/stats"});
    if ($finding eq 'F6') {
        shell(q{bash "$1/scripts/loomy-log.sh" --root "$2" -n 100 >"$2/log" 2>&1; test "$(grep -c 'developer.*starts' "$2/log")" = 1; test "$(grep -c 'developer.*in ' "$2/log")" = 1});
        shell(q{bash "$1/scripts/loomy-tree.sh" --root "$2" >"$2/tree" 2>&1; test "$(grep -c 'developer.*done' "$2/tree")" = 1});
        shell(q{bash "$1/scripts/loomy-status.sh" --root "$2" >"$2/status" 2>&1; grep -q 'Delegations.*1' "$2/status"});
    } else {
        shell(q{! grep -q 'division by 0' "$2/stats"; grep -q '0 %' "$2/stats"});
    }
} elsif ($finding eq 'F7') {
    launch('call',1); poll();
    Loomy::ClaudeNative::watch_changed($root,$projects);
    notification('call','completed',4);
    die 'change not detected' unless Loomy::ClaudeNative::watch_changed($root,$projects);
    sysopen my $lock,$idx,O_RDWR or die $!; flock($lock,LOCK_EX|LOCK_NB) or die $!;
    die 'contended poll unexpectedly succeeded' if defined Loomy::ClaudeNative::poll($root,$projects);
    close $lock;
    die 'failed poll consumed signature' unless Loomy::ClaudeNative::watch_changed($root,$projects);
    die 'retry lost completion' unless poll()->{sessions}{lead}{calls}{call}{state} eq 'done';
    launch('throw',5);
    {no warnings 'redefine';local *Loomy::ClaudeNative::read_transcript=sub {die 'injected failure'};eval {poll()};die 'exception not exercised' unless $@}
    die 'exception consumed signature' unless Loomy::ClaudeNative::watch_changed($root,$projects);
    poll();
} elsif ($finding eq 'F8') {
    launch('call',1); poll();
    (my $second=ts(1))=~s/\.750Z/Z/;
    rows($journal,{type=>'session_activity',tool=>'claude',session=>'lead',state=>'idle',ts=>$second});
    die 'whole-second Stop lost after ms activity' unless poll()->{sessions}{lead}{state} eq 'idle';
    shell(q{source "$1/scripts/lib/journal.sh"; ai_journal_claude_idle "$2" '{"session_id":"lead"}'});
    my @e=events(); die 'Stop timestamp lacks ms' unless $e[-1]{ts}=~/\.\d{3}Z$/;
} elsif ($finding eq 'F9') {
    make_path("$root-other");
    my $bad="$projects/".Loomy::ClaudeNative::slug($root).'-other/foreign.jsonl';
    rows($bad,{type=>'user',sessionId=>'foreign',cwd=>"$root-other",timestamp=>ts(1),message=>{content=>[]}});
    poll(); my $reads=0;
    {no warnings 'redefine';my $original=\&Loomy::ClaudeNative::metadata;
        local *Loomy::ClaudeNative::metadata=sub {$reads++;$original->(@_)};
        for (1..10) {rows($bad,{type=>'assistant',sessionId=>'foreign',cwd=>"$root-other",timestamp=>ts(2),message=>{stop_reason=>undef,content=>[]}}); poll()}
    }
    die 'invalid sibling metadata re-read' if $reads;
    die 'foreign source admitted' if keys %{poll()->{files}};
    my $unknown="$projects/".Loomy::ClaudeNative::slug($root).'/unknown.jsonl';
    rows($unknown,map {{type=>'progress',sessionId=>'unknown',timestamp=>ts(1),uuid=>"record$_"}} 1..5000);
    shell(q{ { sleep 1; printf 'q\n'; } | CLAUDE_CONFIG_DIR="${3%/projects}" bash "$1/scripts/loomy-status.sh" --root "$2" --watch >"$2/frame" 2>"$2/stderr";
      grep -q 'Claude transcript metadata unavailable' "$2/.loomy/logs/watch-errors.log";
      ! grep -q 'Claude transcript metadata unavailable' "$2/stderr"; },$projects);
    die 'watch diagnostics are not private' unless ((stat("$root/.loomy/logs/watch-errors.log"))[2]&0777)==0600;
} elsif ($finding eq 'F10') {
    launch('failed',1);
    rows($path,{base('user',2),message=>{content=>[{type=>'tool_result',tool_use_id=>'failed',is_error=>JSON::PP::true,content=>[]}]}});
    (my $child=$path)=~s{\.jsonl$}{/subagents/agent-orphan.jsonl};
    rows($child,{base('user',3),agentId=>'orphan',message=>{content=>[]}});
    poll(); die 'finished failed call hides provisional child' unless state()->{agents}{'claude:lead:agent:orphan'};
} elsif ($finding eq 'F11') {
    for (1..6) {rows($journal,{type=>'session',tool=>'claude',session=>"s$_",event=>'start',pid=>0,ts=>ts(0)})}
    launch('running',1); returned('running','a',2); poll();
    my $before=state();
    open my $f,'>',"$root/.loomy/logs/month" or die $!; print $f "2000-01\n"; close $f;
    shell(q{source "$1/scripts/lib/journal.sh"; _ai_journal_rotate "$2/.loomy/logs/events.jsonl"});
    my $after=state();
    die 'rotation lost session/agent projection' unless keys(%{$after->{sessions}})==keys(%{$before->{sessions}}) && $after->{agents}{'claude:lead:running'};
    poll();
    shell(q{source "$1/scripts/lib/journal.sh"; ai_journal_all "$2" | ai_journal_canonical >"$2/history"});
    open $f,'<',"$root/history" or die $!;my @e=map {decode_json($_)} <$f>;
    die 'rotation double-counted starts' unless (grep {$_->{type} eq 'delegation_start'} @e)==1;
} elsif ($finding eq 'F12') {
    launch('relative',1);
    shell(q{cd "$1"; perl scripts/lib/claude-native.pl "$2" "$3"},$projects);
    die 'relative CLI invocation lost agent' unless state()->{agents}{'claude:lead:relative'};
} else {die "unknown finding $finding"}
print "PASS $finding structural regression\n";
