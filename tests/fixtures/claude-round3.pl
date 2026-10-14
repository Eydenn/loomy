# Round 3: Claude transcript envelopes only; no prompts, responses or tool output.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use POSIX qw(strftime);
use Time::HiRes qw(clock_gettime CLOCK_PROCESS_CPUTIME_ID);
my ($repo,$work,$finding)=@ARGV;
require "$repo/tests/fixtures/time-scale.pl";
require($ENV{LOOMY_CLAUDE_BENCH_MODULE}//"$repo/scripts/lib/claude-native.pl");
require($ENV{LOOMY_CLAUDE_BENCH_STATE_MODULE}//"$repo/scripts/lib/live-state.pl");
my $root="$work/$finding"; my $projects="$work/projects";
make_path("$root/.loomy/logs");
my $path="$projects/".Loomy::ClaudeNative::slug($root).'/lead.jsonl';
(my $child=$path)=~s{\.jsonl$}{/subagents/agent-child.jsonl};
my $journal="$root/.loomy/logs/events.jsonl";
my $clock=1791853200;
$ENV{LOOMY_NATIVE_NOW}=$clock+7;
sub ts {strftime('%Y-%m-%dT%H:%M:%S',gmtime($clock+$_[0])).'.750Z'}
sub rows {
    my ($file,@records)=@_; $file =~ m{^(.*)/[^/]+$}; make_path($1);
    open my $f,'>>',$file or die $!; print $f encode_json($_),"\n" for @records; close $f or die $!;
    my $at=$ENV{LOOMY_NATIVE_NOW}; utime($at,$at,$file) or die $!;
}
sub base {return (sessionId=>'lead',cwd=>$root,entrypoint=>'claude-desktop',timestamp=>ts($_[1]),type=>$_[0])}
sub launch {
    my ($cid,$at)=@_; rows($path,{base('assistant',$at),message=>{model=>'claude-sonnet-5-5',stop_reason=>undef,
        content=>[{type=>'tool_use',name=>'Agent',id=>$cid,input=>{subagent_type=>'developer',run_in_background=>JSON::PP::true}}]}});
}
sub returned {
    my ($cid,$at,$aid)=@_; $aid//='child'; rows($path,{base('user',$at),toolUseResult=>{status=>'async_launched',agentId=>$aid,isAsync=>JSON::PP::true},
        message=>{content=>[{type=>'tool_result',tool_use_id=>$cid,content=>[]}]}});
}
sub child_record {
    my ($type,$at)=@_; rows($child,{base($type,$at),agentId=>'child',isSidechain=>JSON::PP::true,
        message=>{model=>'claude-sonnet-5-5',stop_reason=>undef,content=>[]}});
}
sub notification {
    my ($cid,$at)=@_; rows($path,{base('queue-operation',$at),operation=>'enqueue',
        content=>"<task-notification><task-id>child</task-id><tool-use-id>$cid</tool-use-id><status>completed</status></task-notification>"});
}
sub poll {return Loomy::ClaudeNative::poll($root,$projects)//die 'poll failed'}
sub cpu {clock_gettime(CLOCK_PROCESS_CPUTIME_ID)}
sub projection {
    my ($native,$now,$v)=@_; $v//=Loomy::LiveState->new; $v->read_journal($journal); $v->claude_evidence($native);
    return $v->projections($now);
}
if ($finding eq 'N1') {
    launch('call',1); child_record('user',2); child_record('assistant',220);
    my $s=poll(); die 'child was not read before alias' unless $s->{sessions}{lead}{calls}{'agent:child'}{seen} eq ts(220);
    die 'unresolved launch interrupted while child writes' if $s->{sessions}{lead}{calls}{call}{ended};
    returned('call',3); rows($path,{base('assistant',230),message=>{content=>[],stop_reason=>undef}});
    $s=poll(); my $c=$s->{sessions}{lead}{calls}{call};
    die 'alias lost own child evidence' unless $c->{seen} eq ts(220) && $c->{started} eq ts(1);
    die 'active child interrupted after alias' if $c->{ended};
    for my $at (250,310) {
        $ENV{LOOMY_NATIVE_NOW}=$clock+$at; child_record('assistant',$at);
        rows($path,{base('assistant',$at+2),message=>{content=>[],stop_reason=>undef}});
        $s=poll(); die 'writing child interrupted' if $s->{sessions}{lead}{calls}{call}{ended};
        die 'writing child not projected running' unless grep {/^N\|A\|claude:lead:call\|.*\|running\|/} projection($s,$clock+$at);
    }
    open my $history,'<',$journal or die $!;
    die 'writing child emitted an interruption' if grep {($_->{type}//'') eq 'delegation' && ($_->{status}//'') eq 'interrupted'} map {decode_json($_)} <$history>;
    # An old checkpoint may contain the pre-fix premature terminal event.
    Loomy::ClaudeNative::finish($s->{sessions}{lead},'call',ts(310),'interrupted','unknown');
    open my $idx,'>',"$root/.loomy/logs/claude-native.idx" or die $!; print $idx encode_json($s); close $idx or die $!;
    rows($journal,{type=>'delegation',schema=>2,bridge=>'claude-native',tool=>'claude',family=>'claude',session_key=>'claude:lead',
        session=>'lead',id=>'cl:lead:call',agent_id=>'lead:call',turn_id=>'call',ts=>ts(310),status=>'interrupted'});
    child_record('assistant',320); $s=poll();
    die 'new child evidence did not reopen interruption' if $s->{sessions}{lead}{calls}{call}{ended};
    die 'reopened terminal remained projected' unless grep {/^N\|A\|claude:lead:call\|.*\|running\|/} projection($s,$clock+320);
    notification('call',340); die 'completion lost after reopen' unless poll()->{sessions}{lead}{calls}{call}{state} eq 'done';
} elsif ($finding eq 'N2') {
    launch('call',1); returned('call',3); child_record('user',2); child_record('assistant',4);
    rows($path,{base('system',5),subtype=>'turn_duration'}); my $s=poll();
    for my $at (130,300) {
        $ENV{LOOMY_NATIVE_NOW}=$clock+$at; $s=poll();
        die 'idle lead interrupted silent child' if $s->{sessions}{lead}{calls}{call}{ended};
        die "silent child not running at +$at" unless grep {/^N\|A\|claude:lead:call\|.*\|running\|/} projection($s,$clock+$at);
    }
    die 'expired own lease still running' unless grep {/^N\|A\|claude:lead:call\|.*\|unknown\|/} projection($s,$clock+1000);
    # File activity itself renews the child's lease even with no complete new record.
    utime($clock+990,$clock+990,$child) or die $!; $s=poll();
    die 'own file mtime did not renew lease' unless grep {/^N\|A\|claude:lead:call\|.*\|running\|/} projection($s,$clock+1000);
} elsif ($finding =~ /^N3(?:-shot)?(?:-bench)?$/) {
    my $benchmark=$finding=~/-bench$/; my $oneshot=$finding=~/-shot/;
    $ENV{LOOMY_NATIVE_NOW}=$clock+4000;
    launch('early',1); returned('early',3); child_record('user',2); child_record('assistant',4);
    for my $i (2..18) {
        launch("early$i",1); returned("early$i",3,"child$i");
        (my $file=$child)=~s/agent-child\.jsonl$/agent-child$i.jsonl/;
        rows($file,{base('user',2),agentId=>"child$i",isSidechain=>JSON::PP::true,message=>{content=>[]}},
            {base('assistant',4),agentId=>"child$i",message=>{content=>[],stop_reason=>undef}});
    }
    # 48 MiB of real progress envelopes, repeated in blocks to avoid fixture generation cost.
    my $padding=encode_json({base('progress',3900),data=>{type=>'agent_progress',agentId=>'other',message=>{type=>'assistant',message=>{content=>[]}}}})."\n";
    my $block=$padding x 512; open my $f,'>>',$path or die $!;
    print $f $block for 1..int(49283072/length($block)); close $f or die $!;
    notification('early',3901);
    notification("early$_",3901) for 2..18;
    open $f,'>>',$path or die $!; print $f $block for 1..int(1048576/length($block)); close $f or die $!;
    launch('late',3902); returned('late',3903); notification('late',3904);
    die 'fixture too small' unless -s $path>40000000;
    my ($polls,$total,$max)=(0,0,0); my $s; my $live=Loomy::LiveState->new;
    my (%stage_total,%stage_max);
    while (++$polls<=700) {
        my $begin=cpu(); my $child_cpu=0; my %stages;
        if ($oneshot) {
            # times() rounds reaped children to scheduler ticks: use the fresh child's
            # process clock, including interpreter/module startup and the full poll.
            open my $shot,'-|',$^X,'-e',
                'use Time::HiRes qw(clock_gettime CLOCK_PROCESS_CPUTIME_ID);
                 my ($startup,$load,$save)=(0,0,0);
                 END {printf "%.9f %.9f %.9f %.9f\n",clock_gettime(CLOCK_PROCESS_CPUTIME_ID),$startup,$load,$save}
                 require shift @ARGV;
                 $startup=clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
                 my $loader=\&Loomy::LiveState::checkpoint_load; my $saver=\&Loomy::LiveState::checkpoint_save;
                 {no warnings "redefine";
                  *Loomy::LiveState::checkpoint_load=sub {my $t=clock_gettime(CLOCK_PROCESS_CPUTIME_ID); my $s=$loader->(@_); $load+=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$t; return $s};
                  *Loomy::LiveState::checkpoint_save=sub {my $t=clock_gettime(CLOCK_PROCESS_CPUTIME_ID); $saver->(@_); $save+=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$t};
                 }
                 Loomy::ClaudeNative::poll(@ARGV)',
                $ENV{LOOMY_CLAUDE_BENCH_MODULE}//"$repo/scripts/lib/claude-native.pl",$root,$projects or die 'one-shot launch failed';
            my $timing=<$shot>;
            close $shot or die 'one-shot failed';
            die 'invalid one-shot CPU measurement' unless defined $timing && $timing =~ /^(?:\d+[.]\d+\s+){3}\d+[.]\d+\s*$/;
            ($child_cpu,@stages{qw(startup load save)})=split /\s+/,$timing;
            $stages{child}=$child_cpu;
            $stages{collect}=$child_cpu-$stages{startup}-$stages{load}-$stages{save};
            open my $idx,'<',"$root/.loomy/logs/claude-native.idx" or die; $s=decode_json(do {local $/; <$idx>});
        } else {
            die 'watch stopped before catch-up reached EOF' unless Loomy::ClaudeNative::watch_changed($root,$projects);
            $s=poll();
        }
        my @rows=projection($s,$clock+4000,$oneshot ? undef : $live);
        unless ($benchmark) {
            die 'phantom running row during replay' if grep {/^N\|A\|.*\|running\|/} @rows;
            die 'old unfinished call still marked running' if grep {!$_->{ended} && ($_->{state}//'') eq 'running'
                && Loomy::ClaudeNative::epoch($s->{sessions}{lead}{seen})-Loomy::ClaudeNative::epoch($_->{seen}//$_->{started})>900}
                values %{$s->{sessions}{lead}{calls}};
        }
        my $elapsed=cpu()-$begin+$child_cpu;
        if ($oneshot) {
            $stages{projection}=$elapsed-$child_cpu;
            for my $stage (keys %stages) {$stage_total{$stage}+=$stages{$stage}; $stage_max{$stage}=$stages{$stage} if $stages{$stage}>($stage_max{$stage}//0)}
        }
        $total+=$elapsed; $max=$elapsed if $elapsed>$max;
        last if $s->{files}{$path}{at_eof};
    }
    printf "%s %.1f MiB: %d polls, %.3f ms CPU/poll mean, %.3f ms max, %.3f s total CPU\n",
        $finding,(-s $path)/1048576,$polls,1000*$total/$polls,1000*$max,$total;
    printf "N3 stages (CPU ms mean/max): %s\n",join(', ',map {sprintf '%s %.3f/%.3f',$_,1000*$stage_total{$_}/$polls,1000*$stage_max{$_}} qw(startup load save collect projection)) if $oneshot;
    printf "N3 one-shot child CPU (startup + full poll): %.3f ms mean, %.3f ms max\n",1000*$stage_total{child}/$polls,1000*$stage_max{child} if $oneshot;
    die 'catch-up too many polls' if !$benchmark && $polls>40;
    my $budget=Loomy::TestTiming::budget(0.08);
    die sprintf "catch-up CPU %.3f ms/poll (budget <=%.3f ms)\n",1000*$max,1000*$budget if !$benchmark && $max>$budget;
    die 'late notifications did not settle every call' unless keys(%{$s->{sessions}{lead}{calls}})==19
        && !grep {$_->{state} ne 'done'} values %{$s->{sessions}{lead}{calls}};
    die 'replay duplicated terminal evidence' unless scalar(grep {/^N\|A\|/} projection($s,$clock+4000))==19;
} elsif ($finding eq 'N4') {
    notification('old',-604801); notification('boundary',-604800); notification('recent',-10);
    $ENV{LOOMY_NATIVE_NOW}=$clock; my $s=poll();
    die 'old pending notification retained' if $s->{sessions}{lead}{pending_notify}{old};
    die 'recent pending notification pruned' unless $s->{sessions}{lead}{pending_notify}{recent} && $s->{sessions}{lead}{pending_notify}{boundary};
} else {die "unknown finding $finding"}
print "PASS $finding Round 3 structural regression\n";
