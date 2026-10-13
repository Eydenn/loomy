# Content-free, fixed-clock S4 fixtures; no provider or application processes.
use strict;
use warnings;
no warnings 'once';
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use POSIX qw(strftime);
use Time::HiRes qw(time clock_gettime CLOCK_PROCESS_CPUTIME_ID);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_RDWR O_CREAT O_NOFOLLOW LOCK_EX);
my ($repo,$work,$finding)=@ARGV;
require "$repo/scripts/lib/codex-native.pl";
require "$repo/scripts/lib/claude-native.pl";
my $root="$work/$finding"; my $dir="$root/.loomy/logs"; make_path($dir);
my $projects="$work/projects-$finding"; my $sessions="$work/sessions-$finding"; make_path($sessions);
my $path="$projects/".Loomy::ClaudeNative::slug($root).'/lead.jsonl';
(my $child=$path)=~s{\.jsonl$}{/subagents/agent-child.jsonl};
my $journal="$dir/events.jsonl"; my $clock=1791853200;
$ENV{LOOMY_NATIVE_NOW}=$clock+7;
sub ts {strftime('%Y-%m-%dT%H:%M:%S',gmtime($clock+($_[0]//0))).'.750Z'}
sub rows {
    my ($file,@e)=@_; (my $parent=$file)=~s{/[^/]+$}{}; make_path($parent);
    open my $f,'>>',$file or die $!; print $f encode_json($_),"\n" for @e; close $f or die $!;
    utime($ENV{LOOMY_NATIVE_NOW},$ENV{LOOMY_NATIVE_NOW},$file) or die $!;
}
sub base {return (sessionId=>'lead',cwd=>$root,entrypoint=>'claude-desktop',timestamp=>ts($_[1]),type=>$_[0])}
sub launch {rows($path,{base('assistant',1),message=>{content=>[{type=>'tool_use',name=>'Agent',id=>'call',input=>{run_in_background=>JSON::PP::true}}]}})}
sub returned {rows($path,{base('user',3),toolUseResult=>{status=>'async_launched',agentId=>'child',isAsync=>JSON::PP::true},message=>{content=>[{type=>'tool_result',tool_use_id=>'call',content=>[]}]}})}
sub child_record {rows($child,{base('assistant',$_[0]),message=>{model=>'claude-sonnet-5-5',content=>[],stop_reason=>undef}})}
sub notify {rows($path,{base('queue-operation',$_[0]),operation=>'enqueue',content=>'<task-notification><tool-use-id>call</tool-use-id><status>completed</status></task-notification>'})}
sub poll {Loomy::ClaudeNative::poll($root,$projects)//die 'Claude poll unavailable'}
sub events {return () unless -f $journal; open my $f,'<',$journal or die; return map {decode_json($_)} <$f>}
sub projected {
    my ($s,$now)=@_; my $v=Loomy::LiveState->new; $v->read_journal($journal); $v->claude_evidence($s); return $v->projections($now);
}
sub read_state {open my $f,'<',$_[0] or die; local $/; return decode_json(<$f>)}
sub write_state {open my $f,'>',$_[0] or die; print $f encode_json($_[1]); close $f or die}
if ($finding eq 'G2') {
    launch(); returned(); child_record(4); poll();
    for my $at (130,300) {
        $ENV{LOOMY_NATIVE_NOW}=$clock+$at;
        rows($path,{base('assistant',$at),message=>{content=>[],stop_reason=>undef}});
        my $s=poll(); die 'busy lead interrupted silent child' if $s->{sessions}{lead}{calls}{call}{ended};
        die 'silent child not running within own lease' unless grep {/^N\|A\|claude:lead:call\|.*\|running\|/} projected($s,$clock+$at);
    }
    die 'inferred terminal emitted' if grep {$_->{type} eq 'delegation'} events();
    die 'expired lease not unknown' unless grep {/^N\|A\|claude:lead:call\|.*\|unknown\|/} projected(poll(),$clock+1000);
} elsif ($finding eq 'G3') {
    launch(); returned();
    my $raw=encode_json({base('user',4),toolUseResult=>{stdout=>'x'x60000},message=>{content=>[{type=>'tool_result',tool_use_id=>'bash-ordinary',content=>'x'x60000}]}})."\n";
    open my $f,'>>',$path or die; print $f $raw for 1..570; close $f or die;
    rows($path,{base('system',5),subtype=>'turn_duration'});
    die 'benchmark too small' unless -s $path>=67108864;
    my ($cpu,$max,$polls,$decoded)=(clock_gettime(CLOCK_PROCESS_CPUTIME_ID),0,0,0);
    my $original=\&Loomy::ClaudeNative::decode_json;
    {
        no warnings 'redefine'; local *Loomy::ClaudeNative::decode_json=sub {$decoded++; $original->(@_)};
        while (1) {
            my $start=clock_gettime(CLOCK_PROCESS_CPUTIME_ID); my $s=poll(); $polls++;
            my $dt=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$start; $max=$dt if $dt>$max;
            last if $s->{files}{$path}{at_eof}; die 'catch-up stalled' if $polls>80;
        }
    }
    $cpu=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$cpu;
    die "tool result prefilter ineffective: $decoded decodes" if $decoded>200;
    die 'catch-up poll exceeds 100 ms CPU' if $max>=0.100;
    printf "64 MiB replay: %d polls, %d decoded envelopes, %.1f ms max, %.3f s CPU\n",$polls,$decoded,$max*1000,$cpu;
} elsif ($finding eq 'G4') {
    launch(); returned(); child_record(4); poll();
    my $before=grep {$_->{type} eq 'delegation_activity'} events();
    for my $at (10..30) {$ENV{LOOMY_NATIVE_NOW}=$clock+$at; child_record($at); poll()}
    my $after=grep {$_->{type} eq 'delegation_activity'} events();
    die "ordinary source evidence created $after activities (was $before)" if $after!=$before;
    die 'volatile evidence persisted in activity' if grep {$_->{type} eq 'delegation_activity' && (exists $_->{evidence_ts} || exists $_->{source_mtime})} events();
} elsif ($finding eq 'G6') {
    launch(); poll();
    my $idx="$dir/claude-native.idx"; sysopen my $lock,"$idx.lock",O_RDWR|O_CREAT|O_NOFOLLOW,0600 or die; flock($lock,LOCK_EX) or die;
    rows($path,{base('system',6),subtype=>'turn_duration'});
    die 'contended poll should defer' if defined Loomy::ClaudeNative::poll($root,$projects);
    close $lock; my $calls=0;
    {no warnings 'redefine'; local *Loomy::ClaudeNative::poll_locked=sub {$calls++; die 'unexpected retry'};
        Loomy::ClaudeNative::poll($root,$projects) for 1..20;
    }
    die 'failure retry did not back off' if $calls;
    # Advance the monotonic fixture without a real five-second sleep.
    {no warnings 'redefine'; my $future=time()+6; local *Time::HiRes::time=sub {$future}; die 'backoff did not resume' unless defined Loomy::ClaudeNative::poll($root,$projects)}
} elsif ($finding eq 'arrival-race') {
    launch(); returned(); poll();
    child_record(4);
    my $original=\&Loomy::ClaudeNative::read_transcript; my $injected=0;
    {no warnings 'redefine'; local *Loomy::ClaudeNative::read_transcript=sub {
        my $used=$original->(@_);
        if (!$injected++ && $_[1] eq $path) {
            rows($path,{base('assistant',6),message=>{content=>[{type=>'tool_use',name=>'Agent',id=>'late-source',input=>{subagent_type=>'late-source'}}]}});
            rows($journal,{type=>'delegation_start',bridge=>'subagent',family=>'claude',session=>'lead',id=>'late-hook',role=>'late-hook',background=>JSON::PP::true,ts=>ts(6)});
        }
        return $used;
    }; poll()}
    my $s=poll();
    die 'concurrent source was sealed as inspected' unless $s->{sessions}{lead}{calls}{'late-source'};
    die 'concurrent hook offset skipped' unless $s->{sessions}{lead}{calls}{'late-hook'};
} elsif ($finding eq 'growth') {
    open my $f,'>',$journal or die;
    for my $i (1..24900) {
        my $b={schema=>2,tool=>'codex',bridge=>'codex-native',session_key=>'codex:lead',agent_id=>'worker'.($i%100),id=>"turn$i",ts=>ts(1)};
        print $f encode_json({%$b,type=>'delegation_start'}),"\n",encode_json({%$b,type=>'delegation',status=>'ok',outcome=>'done'}),"\n";
    }
    for my $i (1..100) {
        my $b={schema=>2,tool=>'codex',bridge=>'codex-native',session_key=>'codex:lead',agent_id=>"active$i",id=>"active$i",ts=>ts(2)};
        print $f encode_json({%$b,type=>'delegation_start'}),"\n",encode_json({%$b,type=>'delegation_activity',state=>'running'}),"\n";
    }
    close $f or die;
    my $v=Loomy::LiveState->new;
    $v->read_journal($journal) until $v->{cursor}{at_eof}; $v->projections($clock+7);
    die 'reducer detail unbounded' if (grep {$_->{ended}} values %{$v->{turns}})>1000;
    die 'growth did not retain 100 active turns' unless (grep {!$_->{ended}} values %{$v->{turns}})==100;
    my $n=Loomy::CodexNative::poll($root,$sessions);
    $n=Loomy::CodexNative::poll($root,$sessions) until $n->{journal}{at_eof};
    Loomy::CodexNative::poll($root,$sessions);
    $v->read_journal($journal); $v->projections($clock+7);
    my $idx="$dir/codex-native.idx"; my $sig=Loomy::LiveState::file_signature($idx); my $max=0;
    for (1..100) {
        my $start=time(); Loomy::CodexNative::poll($root,$sessions); $v->read_journal($journal); $v->projections($clock+7);
        my $dt=time()-$start; $max=$dt if $dt>$max; die 'idle journal read' if $v->{read_bytes};
    }
    die 'idle checkpoint rewritten' if Loomy::LiveState::file_signature($idx) ne $sig;
    die 'warm idle frame >=100 ms' if $max>=0.100;
    printf "50,000 events: 100 warm idle frames, max %.3f ms; zero idle reads/writes\n",$max*1000;
} elsif ($finding eq 'prune') {
    my $s={version=>1,files=>{},seen=>{}};
    for my $i (1..2000) {
        my $id="retired$i"; $s->{files}{"/source/$i"}={meta=>{id=>"source$i",task=>'old'},key=>"1:$i",offset=>$i,finished=>1,id=>$id,last_observed_ts=>ts(-700000)};
        $s->{seen}{sha256_hex("$id:$_")}=1 for qw(start end);
    }
    $s->{files}{'/source/active'}={meta=>{id=>'active'},offset=>120,id=>'active-turn',finished=>0};
    my $key=sha256_hex('active-turn:start'); $s->{seen}{$key}=1;
    Loomy::CodexNative::prune_checkpoint($s,$clock+7);
    die 'retired event keys not pruned' unless keys(%{$s->{seen}})==1 && $s->{seen}{$key};
    die 'retired source cursor lost' unless $s->{files}{'/source/2000'}{offset}==2000 && $s->{files}{'/source/2000'}{replay_fence};
    die 'retired detail survived' if $s->{files}{'/source/2000'}{id};
    die 'unfinished identity dropped' unless $s->{files}{'/source/active'}{id} eq 'active-turn';
} elsif ($finding eq 'migration') {
    system($^X,"$repo/tests/fixtures/codex-native.pl",'seed',$root,$sessions,$$)==0 or die;
    my $s=Loomy::CodexNative::poll($root,$sessions); my $idx="$dir/codex-native.idx";
    die 'migration has no active source cursor' unless grep {$_->{id} && !$_->{finished}} values %{$s->{files}};
    $s->{version}=1; $s->{seen}{sha256_hex("old-$_")}=1 for 1..65000;
    my %offset=map {$_=>$s->{files}{$_}{offset}} keys %{$s->{files}};
    my $active=(grep {$_->{id}} values %{$s->{files}})[0]; my $key=sha256_hex("$active->{id}:start");
    $s->{seen}{$key}=1; write_state($idx,$s); die 'v1 fixture <=4 MiB' unless -s $idx>4194304;
    my $ends=grep {$_->{type} eq 'delegation'} events(); my $starts=grep {$_->{type} eq 'delegation_start'} events();
    $s=Loomy::CodexNative::poll($root,$sessions);
    die 'version not migrated' unless $s->{version}==2;
    die 'current dedup lost' unless $s->{seen}{$key};
    die 'cursor lost' if grep {$s->{files}{$_}{offset}!=$offset{$_}} keys %offset;
    die 'v2 too large' if -s $idx>2097152; die 'seen unbounded' if keys(%{$s->{seen}})>8100;
    die 'migration duplicated terminal' unless $ends==grep {$_->{type} eq 'delegation'} events();
    die 'migration duplicated active start' unless $starts==grep {$_->{type} eq 'delegation_start'} events();
    printf "v1 >4 MiB / 65,000 keys migrated: v2 %d bytes\n",-s $idx;
} elsif ($finding =~ /^(?:crash|reconstruct)-(?:codex|claude)$/) {
    my ($idx,$saved,$ends,$usage);
    if ($finding =~ /codex$/) {
        system($^X,"$repo/tests/fixtures/codex-native.pl",'seed',$root,$sessions,$$)==0 or die;
        Loomy::CodexNative::poll($root,$sessions); $idx="$dir/codex-native.idx"; $saved=read_state($idx);
        system($^X,"$repo/tests/fixtures/codex-native.pl",'finish',$root,$sessions,$$)==0 or die;
        Loomy::CodexNative::poll($root,$sessions);
    } else {
        launch(); returned(); child_record(4); poll(); $idx="$dir/claude-native.idx"; $saved=read_state($idx); notify(5); poll();
    }
    rows($journal,{type=>'usage',ts=>ts(5),tool=>'claude',cost_usd=>0.25});
    $ends=grep {$_->{type} eq 'delegation'} events(); $usage=grep {$_->{type} eq 'usage'} events(); die 'no terminal fixture' unless $ends;
    # Restore precisely the checkpoint preceding append, then restart in a fresh interpreter.
    if ($finding =~ /^reconstruct-/) {
        for my $p ($idx,"$idx.bak") {open my $broken,'>',$p or die; print $broken '{"version":'; close $broken}
    } else {write_state($idx,$saved)}
    my $module=$finding =~ /codex$/ ? 'codex-native.pl' : 'claude-native.pl';
    my $source=$finding =~ /codex$/ ? $sessions : $projects;
    system($^X,"$repo/scripts/lib/$module",$root,$source)==0 or die 'restart failed';
    die 'restart duplicated terminal' unless $ends==grep {$_->{type} eq 'delegation'} events();
    die 'restart duplicated usage' unless $usage==grep {$_->{type} eq 'usage'} events();
} elsif ($finding eq 'crash-batch' || $finding eq 'reconstruct-batch') {
    system($^X,"$repo/tests/fixtures/codex-native.pl",'seed',$root,$sessions,$$)==0 or die;
    my $s=Loomy::CodexNative::poll($root,$sessions); my $idx="$dir/codex-native.idx"; my $saved=read_state($idx);
    my ($source)=grep {$s->{files}{$_}{meta}{parent}} sort keys %{$s->{files}};
    open my $f,'>>',$source or die;
    for my $i (1..15000) {
        print $f encode_json({type=>'event_msg',timestamp=>ts($i+10),payload=>{type=>'task_started',turn_id=>"batch$i"}}),"\n";
        print $f encode_json({type=>'event_msg',timestamp=>ts($i+10),payload=>{type=>'task_complete',turn_id=>"batch$i",last_agent_message=>'STATUS: done'}}),"\n";
    }
    close $f; $ENV{LOOMY_NATIVE_NOW}=$clock+20000;
    for (1..100) {$s=Loomy::CodexNative::poll($root,$sessions); last if $s->{files}{$source}{at_eof}; die 'batch collector stalled' if $_==100}
    my @archives=glob "$dir/archive/events-*.jsonl"; die 'batch did not span rotations' unless @archives>=2;
    my $terminal_count=sub {
        my $count=0; for my $p (@archives,$journal) {open my $h,'<',$p or die; while (<$h>) {my $e=decode_json($_); $count++ if $e->{type} eq 'delegation'}} return $count;
    };
    my $ends=$terminal_count->(); die 'batch terminal fixture incomplete' if $ends<15000;
    if ($finding eq 'reconstruct-batch') {
        for my $p ($idx,"$idx.bak") {open my $broken,'>',$p or die; print $broken '{"version":'; close $broken}
    } else {write_state($idx,$saved)}
    system($^X,'-e',q{
        my ($module,$root,$sessions)=@ARGV; require $module;
        for (1..100) {
            my $s=Loomy::CodexNative::poll($root,$sessions) or die;
            my @st=stat("$root/.loomy/logs/events.jsonl");
            last if $s->{journal}{key} eq "$st[0]:$st[1]" && $s->{journal}{at_eof} && !grep {!$_->{at_eof}} values %{$s->{files}};
            die 'batch recovery stalled' if $_==100;
        }
    },"$repo/scripts/lib/codex-native.pl",$root,$sessions)==0 or die 'batch restart failed';
    @archives=glob "$dir/archive/events-*.jsonl";
    die 'bounded replay duplicated batch terminals' unless $ends==$terminal_count->();
    printf "15,000 terminal transitions / %d archive segments: restart preserved terminal count\n",scalar @archives;
} elsif ($finding eq 'rotation') {
    rows($journal,{type=>'session',tool=>'claude',session=>'lead',event=>'start',pid=>$$,ts=>ts(0)},
        {type=>'delegation_start',tool=>'claude',schema=>2,session_key=>'claude:lead',id=>'open',agent_id=>'child',ts=>ts(1)},
        {type=>'delegation_start',tool=>'claude',schema=>2,session_key=>'claude:lead',id=>'closed',agent_id=>'done',ts=>ts(1)},
        {type=>'delegation',tool=>'claude',schema=>2,session_key=>'claude:lead',id=>'closed',agent_id=>'done',status=>'ok',ts=>ts(2)},
        {type=>'usage',ts=>ts(3),cost_usd=>0.25});
    my $cursor={}; Loomy::CodexNative::lines($journal,$cursor,2097152); my %saved=%$cursor;
    rows($journal,{type=>'request',tool=>'claude',session=>'lead',ts=>ts(4)});
    Loomy::LiveState::atomic_file("$dir/month","2000-01\n");
    {my $lock=Loomy::LiveState::journal_lock($dir) or die; Loomy::LiveState::journal_rotate($journal)}
    my @e=events(); die 'rotation copied usage or closed work' if grep {$_->{type} eq 'usage' || ($_->{id}//'') eq 'closed'} @e;
    my $v=Loomy::LiveState->new; $v->read_journal($journal); my @r=$v->projections($clock+7);
    die 'rotation lost running child' unless grep {/^N\|A\|claude:child\|.*\|running\|/} @r;
    my $recover=Loomy::LiveState::recovery_path($journal,\%saved); die 'uncheckpointed archived suffix lost' if $recover eq $journal;
    my @delta=Loomy::CodexNative::lines($recover,\%saved,2097152); die 'wrong recovery suffix' unless @delta==1 && decode_json($delta[0][0])->{type} eq 'request';
    # Same-month size rotation with an oversized line (ignored by structural readers).
    open my $f,'>>',$journal or die; print $f 'x'x8388608,"\n"; close $f;
    {my $lock=Loomy::LiveState::journal_lock($dir) or die; Loomy::LiveState::journal_rotate($journal)}
    die 'size cap ineffective' if -s $journal>=8388608;
    # Recover the archive/snapshot rename gap left by a killed rotator.
    open my $copy,'<',$journal or die; local $/; my $snapshot=<$copy>; close $copy;
    my @st=stat($journal); my $name="events-2000-02-$st[0]-$st[1].jsonl";
    Loomy::LiveState::atomic_file("$dir/events.next",$snapshot);
    Loomy::LiveState::atomic_file("$dir/rotation",encode_json({archive=>$name,month=>'2026-10',key=>"$st[0]:$st[1]"}));
    rename $journal,"$dir/archive/$name" or die;
    {my $lock=Loomy::LiveState::journal_lock($dir) or die; Loomy::LiveState::journal_rotate($journal)}
    die 'rotation crash lost snapshots' unless -s $journal && !-e "$dir/rotation";
} elsif ($finding eq 'corruption') {
    open my $f,'>',$journal or die; print $f "bad-json\n",encode_json({type=>'delegation_start',id=>'missing'}),"\n",'x'x2200000,"\n";
    my $b={tool=>'claude',schema=>2,session_key=>'claude:lead',agent_id=>'child',id=>'good'};
    print $f encode_json({%$b,type=>'delegation_start',ts=>ts(1)}),"\n",encode_json({%$b,type=>'delegation',status=>'ok',ts=>ts(2)}),"\n";
    print $f encode_json({%$b,type=>'delegation_activity',state=>'running',ts=>ts(0)}),"\n",encode_json({%$b,type=>'delegation_start',ts=>ts(3)}),"\n";
    print $f encode_json({%$b,agent_id=>'duplicate-other-agent',type=>'delegation_start',ts=>ts(3)}),"\n";
    print $f encode_json({type=>'session',tool=>'claude',session=>'closed-lead',pid=>$$,event=>'end',ts=>ts(3)}),"\n",
        encode_json({type=>'session',tool=>'claude',session=>'closed-lead',pid=>$$,event=>'start',ts=>ts(1)}),"\n";
    print $f encode_json({%$b,id=>'future',type=>'delegation_start',ts=>ts(10000)}),"\n",encode_json({%$b,id=>'no-start',type=>'delegation_activity',state=>'running',ts=>ts(3)}),"\n",'{"type":'; close $f;
    my $v=Loomy::LiveState->new; $v->read_journal($journal) until $v->{cursor}{at_eof};
    my @r=$v->projections($clock+7); die 'corruption made phantom running row' if grep {/^N\|A\|.*\|running\|/} @r;
    die 'valid terminal lost' unless $v->{turns}{good}{state} eq 'done';
    die 'late old launcher start revived a closed session' unless $v->{sessions}{'claude:closed-lead'}{closed};
    open $f,'>>',$journal or die; print $f '"ignored"}',"\n"; close $f; $v->read_journal($journal);
    open $f,'>',$journal or die; print $f encode_json({%$b,type=>'delegation_activity',state=>'running',ts=>ts(4)}),"\n"; close $f; $v->read_journal($journal);
    die 'truncation reopened terminal' if grep {/^N\|A\|.*\|running\|/} $v->projections($clock+7);
} elsif ($finding eq 'backup') {
    my $idx="$dir/codex-native.idx"; Loomy::LiveState::checkpoint_save($idx,{version=>2,seen=>{retained=>1}});
    Loomy::LiveState::checkpoint_save($idx,{version=>2,seen=>{retained=>1,next=>1}});
    open my $f,'>',$idx or die; print $f '{"version":'; close $f;
    die 'valid backup not recovered' unless Loomy::LiveState::checkpoint_load($idx)->{seen}{retained};
    unlink "$idx.bak"; my $rebuilt=Loomy::LiveState::checkpoint_load($idx);
    die 'corrupt checkpoint silently reset' unless $rebuilt->{reconstructing};
    die 'damaged evidence not preserved' unless glob "$idx.invalid-*";
} elsif ($finding eq 'quarantine') {
    my $idx="$dir/codex-native.idx";
    for my $n (1..5) {
        my $p="$idx.invalid-1-$n";
        open my $f,'>',$p or die; print $f 'damaged'; close $f; utime $clock+$n,$clock+$n,$p;
    }
    symlink "$idx.invalid-1-5","$idx.invalid-1-99" or die;
    Loomy::LiveState::checkpoint_load($idx);
    my @kept=grep {!-l $_} glob "$idx.invalid-*";
    die 'quarantine retention lost newest evidence' unless @kept==2 && -f "$idx.invalid-1-4" && -f "$idx.invalid-1-5";
    die 'quarantine followed a symlink' unless -l "$idx.invalid-1-99";
    my $out=`perl "$repo/scripts/lib/watch-health.pl" "$root" "$work/codex" "$work/claude"`;
    die 'doctor quarantine measurement absent' unless $out =~ /quarantine\t.*codex-native.idx\t2 \/ 14/;
} elsif ($finding eq 'shards') {
    my $idx="$dir/codex-native.idx"; my %files=map {("/source/$_",{key=>"1:$_",offset=>$_,meta=>{id=>"source$_",cwd=>$root},padding=>'x'x350})} 1..6000;
    my $s={version=>2,files=>\%files,seen=>{safe=>1}}; Loomy::LiveState::checkpoint_save($idx,$s);
    my $snapshot=read_state($idx); die 'large inventory not sharded' unless @{$snapshot->{source_shards}//[]};
    die 'snapshot exceeds 2 MiB' if -s $idx>2097152;
    for my $name (@{$snapshot->{source_shards}}) {die 'shard exceeds 256 KiB' if -s "$idx.$name">262144}
    my $loaded=Loomy::LiveState::checkpoint_load($idx); die 'source cursors lost during shard load' unless keys(%{$loaded->{files}})==6000 && $loaded->{files}{'/source/6000'}{offset}==6000;
    $s->{files}{'/source/6000'}{offset}=6001; Loomy::LiveState::checkpoint_save($idx,$s);
    # The previous generation's shards remain usable when the primary is corrupted.
    open my $f,'>',$idx or die; print $f '{'; close $f;
    $loaded=Loomy::LiveState::checkpoint_load($idx); die 'backup inventory lost' unless $loaded->{files}{'/source/6000'}{offset}==6000;
} elsif ($finding eq 'repair') {
    my $idx="$dir/codex-native.idx"; my $s={version=>1,files=>{},seen=>{map {sha256_hex("old-$_")=>1} 1..65000}};
    write_state($idx,$s); my $before=-s $idx;
    system($^X,"$repo/scripts/lib/live-state.pl",'--migrate',$root)==0 or die 'repair migration failed';
    die 'repair migration reset state' unless read_state($idx)->{version}==2 && -f "$dir/checkpoint-v2" && $before>4194304;
    my $sig=Loomy::LiveState::file_signature($idx);
    system($^X,"$repo/scripts/lib/live-state.pl",'--migrate',$root)==0 or die;
    die 'repair not idempotent' if Loomy::LiveState::file_signature($idx) ne $sig;
} elsif ($finding eq 'privacy') {
    my $idx="$dir/codex-native.idx"; Loomy::LiveState::checkpoint_save($idx,{version=>2,seen=>{safe=>1}});
    die 'checkpoint not 0600' unless ((stat($idx))[2]&0777)==0600;
    my $target="$work/symlink-target"; write_state($target,{untouched=>1}); symlink $target,"$dir/link" or die;
    my $ok=eval {Loomy::LiveState::checkpoint_save("$dir/link",{version=>2}); 1}; die 'symlink destination accepted' if $ok;
    die 'symlink target modified' unless read_state($target)->{untouched};
} else {die 'unknown fixture'}
