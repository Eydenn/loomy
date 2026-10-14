# Synthetic paginated v2 protocol. No session messages, prompts, or tool/file content.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use File::Path qw(make_path);
my ($action,$root,$sessions)=@ARGV;
my $now=$ENV{LOOMY_FIXTURE_NOW}//time;
sub ts { strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now+($_[0]//0))) }
sub id { sprintf '00000000-0000-4000-8000-%012d',100000+$_[0] }
sub path {
    my ($n)=@_;
    my $dir="$sessions/".strftime('%Y/%m/%d',gmtime($now-($n==1 || $n>7 ? 172800 : 0)));
    make_path($dir); return "$dir/rollout-fixture-".id($n).'.jsonl';
}
sub row { {timestamp=>ts($_[2]),type=>$_[0],payload=>$_[1]} }
sub event { row('event_msg',{type=>$_[0],turn_id=>id(10+$_[1]),@_[3..$#_]},$_[2]) }
sub append {
    my ($n,@rows)=@_; open my $f,'>>',path($n) or die $!;
    print $f encode_json($_),"\n" for @rows; close $f or die $!;
    utime $now,$now,path($n) or die $!;
}
sub item { event('item_completed',$_[0],$_[1],thread_id=>id($_[0]),item=>{type=>'Reasoning',id=>'synthetic-item',summary_text=>[],raw_content=>[]},started_at_ms=>($now+$_[1]-1)*1000,completed_at_ms=>($now+$_[1])*1000) }
sub usage { row('token_usage_record',{thread_id=>id($_[0]),turn_id=>id(10+$_[0]),session_id=>id(1),root_turn_id=>id(11),response_id=>'synthetic-response',usage=>{input_tokens=>1,output_tokens=>1},turn_token_usage=>{},thread_token_usage=>{}},$_[1]) }
sub padding {
    my ($n,$bytes)=@_; open my $f,'>>',path($n) or die $!;
    my $line=encode_json(row('world_state',{full=>JSON::PP::false,state=>{fixture_padding=>'x'x8192}},-172790))."\n";
    print $f $line for 1..int($bytes/length($line)); close $f or die $!;
}
if ($action eq 'seed') {
    make_path("$root/.loomy/logs","$root/src");
    open my $brief,'>',"$root/.loomy/brief.md" or die $!;
    print $brief "---\nai_mode: SOLO\nai_lead: codex\n---\n"; close $brief;
    my @names=('','',qw(Lyra Orion Vega Iris Nova Excluded));
    my @roles=('','',qw(explorer qa developpement linguistique explorer explorer));
    my @slugs=('','',qw(inventory verification implementation vocabulary nested excluded));
    for my $n (1..7) {
        my $parent=$n==6 ? 2 : 1;
        my $agent_path='/root/'.($n==6 ? 'inventory/' : '').$slugs[$n];
        my $spawn={parent_thread_id=>id($parent),depth=>($n==6 ? 2 : 1),agent_path=>$agent_path,agent_nickname=>$names[$n],agent_role=>$roles[$n]};
        delete $spawn->{parent_thread_id} if $n==4 || $n==5;
        my $m={id=>id($n),timestamp=>ts($n==1 ? -172800 : -60),cwd=>($n==3 || $n==7 ? '/nonexistent-v2-workspace' : $root),
            runtime_workspace_roots=>[$n==7 ? "$root-unrelated" : "$root/src"],originator=>'codex-tui',source=>($n==1 ? 'cli' : {subagent=>{thread_spawn=>$spawn}}),
            thread_source=>($n==1 ? 'user' : 'subagent'),session_id=>id(1),history_mode=>'paginated',context_window=>{window_id=>id(100+$n)}};
        if ($n>1) {
            @$m{qw(multi_agent_version parent_thread_id agent_nickname agent_role agent_path)}=('v2',id($parent),$names[$n],$roles[$n],$agent_path);
            delete $m->{parent_thread_id} if $n==5;
        }
        open my $f,'>',path($n) or die $!; print $f encode_json(row('session_meta',$m,$n==1 ? -172800 : -60)),"\n"; close $f;
        append($n,event('task_started',$n,$n==1 ? -172795 : -50),
            row('turn_context',{turn_id=>id(10+$n),model=>'gpt-6.1-sol',effort=>'max'},$n==1 ? -172794 : -49));
        padding($n,$n==1 ? 36*1024*1024 : 2*1024*1024) if $n<7;
        append($n,item($n,-3),usage($n,-2),row('inter_agent_communication_metadata',{trigger_turn=>JSON::PP::true},-1));
    }
} elsif ($action eq 'finish') {
    append(2,event('task_complete',2,1,started_at=>($now-50)*1000,completed_at=>($now+1)*1000,duration_ms=>51000));
    append(3,event('turn_aborted',3,2));
} elsif ($action eq 'post-finish') {
    append(2,usage(2,3),row('inter_agent_communication_metadata',{trigger_turn=>JSON::PP::false},3));
} elsif ($action eq 'heartbeat') {
    append(1,item(1,5)); append(4,usage(4,5));
} elsif ($action eq 'mtime-only') {
    # A valid new record too large for a tail slice still proves the source is live.
    open my $f,'>>',path(1) or die $!;
    print $f encode_json(row('world_state',{full=>JSON::PP::false,state=>{fixture_padding=>'x'x300000}},5)),"\n";
    close $f; utime $now+5,$now+5,path(1) or die $!;
} elsif ($action eq 'final-item') {
    append(4,event('item_completed',4,4,thread_id=>id(4),item=>{type=>'AgentMessage',id=>'synthetic-final',phase=>'final_answer',content=>[]}));
} elsif ($action eq 'evidence-turn') {
    my $u=usage(5,5); $u->{payload}{turn_id}=id(45); append(5,$u);
} elsif ($action eq 'terminal-turn') {
    my $e=event('task_complete',5,6,started_at=>($now-5)*1000,completed_at=>($now+6)*1000);
    $e->{payload}{turn_id}=id(55); append(5,$e);
} elsif ($action eq 'oversized-child') {
    open my $f,'>>',path(4) or die $!;
    print $f encode_json(row('world_state',{full=>JSON::PP::false,state=>{fixture_padding=>'x'x300000}},5)),"\n"; close $f;
    append(4,item(4,6));
} elsif ($action eq 'legacy-index') {
    my $idx="$root/.loomy/logs/codex-native.idx";
    open my $f,'<',$idx or die $!; my $s=decode_json(do{local $/;<$f>}); close $f;
    for my $cursor (values %{$s->{files}}) {
        delete @{$cursor->{meta}}{qw(v2 metadata_protocol)};
        delete @$cursor{qw(projected_metadata v2_position v2_tail_sig source_mtime)};
        $cursor->{turn}='' if $cursor->{meta}{parent};
    }
    open $f,'>',$idx or die $!; print $f encode_json($s); close $f;
} elsif ($action eq 'midflight') {
    # Real v2 sequence: turn 1 completes inside the history gap, turn 2 starts there and is mid tool call in the tail.
    make_path("$root/.loomy/logs","$root/src");
    open my $brief,'>',"$root/.loomy/brief.md" or die $!;
    print $brief "---\nai_mode: SOLO\nai_lead: codex\n---\n"; close $brief;
    my $lead={id=>id(1),timestamp=>ts(-3600),cwd=>$root,originator=>'codex-tui',source=>'cli',thread_source=>'user',session_id=>id(1),history_mode=>'paginated'};
    open my $f,'>',path(1) or die $!; print $f encode_json(row('session_meta',$lead,-3600)),"\n"; close $f;
    append(1,event('task_started',1,-3590),row('turn_context',{turn_id=>id(11),model=>'gpt-6.1-sol',effort=>'high'},-3589));
    padding(1,3*1024*1024);
    # A newer lead turn sits far behind the tail: only a backward scan finds its model.
    append(1,event('task_started',1,-1200),row('turn_context',{turn_id=>id(111),model=>'gpt-6-luna',effort=>'max'},-1199));
    padding(1,1024*1024);
    append(1,item(1,-3),usage(1,-2));
    my $m={id=>id(8),timestamp=>ts(-3000),cwd=>$root,runtime_workspace_roots=>["$root/src"],originator=>'codex-tui',
        source=>{subagent=>{thread_spawn=>{parent_thread_id=>id(1),depth=>1,agent_path=>'/root/midflight',agent_nickname=>'Hegel',agent_role=>'qa'}}},
        thread_source=>'subagent',session_id=>id(1),history_mode=>'paginated',multi_agent_version=>'v2',parent_thread_id=>id(1),
        agent_nickname=>'Hegel',agent_role=>'qa',agent_path=>'/root/midflight'};
    open $f,'>',path(8) or die $!; print $f encode_json(row('session_meta',$m,-3000)),"\n"; close $f;
    append(8,event('task_started',8,-2990),row('turn_context',{turn_id=>id(18),model=>'gpt-6-luna',effort=>'high'},-2989),item(8,-2980));
    padding(8,512*1024);
    append(8,event('task_complete',8,-1300,started_at=>($now-2990)*1000,completed_at=>($now-1300)*1000));
    my $second=event('task_started',8,-1290); $second->{payload}{turn_id}=id(28); append(8,$second);
    append(8,row('turn_context',{turn_id=>id(28),model=>'gpt-6-luna',effort=>'high'},-1289));
    padding(8,512*1024);
    my $call=row('response_item',{type=>'custom_tool_call',name=>'exec',call_id=>'synthetic-call',input=>''},-2);
    my $i=item(8,-3); $i->{payload}{turn_id}=id(28); my $u=usage(8,-1); $u->{payload}{turn_id}=id(28);
    append(8,$i,$call,$u);
} elsif ($action eq 'gap-seed' || $action eq 'gap-finish') {
    # Watch seen turn 1 running, then not running for hours: turn 1 completes and turn 2 starts far behind the tail.
    if ($action eq 'gap-seed') {
        make_path("$root/.loomy/logs","$root/src");
        open my $brief,'>',"$root/.loomy/brief.md" or die $!;
        print $brief "---\nai_mode: SOLO\nai_lead: codex\n---\n"; close $brief;
        my $lead={id=>id(1),timestamp=>ts(-3600),cwd=>$root,originator=>'codex-tui',source=>'cli',thread_source=>'user',session_id=>id(1),history_mode=>'paginated'};
        open my $f,'>',path(1) or die $!; print $f encode_json(row('session_meta',$lead,-3600)),"\n"; close $f;
        append(1,event('task_started',1,-3590),row('turn_context',{turn_id=>id(11),model=>'gpt-6.1-sol',effort=>'high'},-3589));
        my $m={id=>id(9),timestamp=>ts(-3000),cwd=>$root,runtime_workspace_roots=>["$root/src"],originator=>'codex-tui',
            source=>{subagent=>{thread_spawn=>{parent_thread_id=>id(1),depth=>1,agent_path=>'/root/gap',agent_nickname=>'Aristotle',agent_role=>'worker'}}},
            thread_source=>'subagent',session_id=>id(1),history_mode=>'paginated',multi_agent_version=>'v2',parent_thread_id=>id(1),
            agent_nickname=>'Aristotle',agent_role=>'worker',agent_path=>'/root/gap'};
        open $f,'>',path(9) or die $!; print $f encode_json(row('session_meta',$m,-3000)),"\n"; close $f;
        append(9,event('task_started',9,-2990),row('turn_context',{turn_id=>id(19),model=>'gpt-6-luna',effort=>'max'},-2989),item(9,-2980));
    } else {
        padding(9,1024*1024);
        append(9,event('task_complete',9,-1300,started_at=>($now-2990)*1000,completed_at=>($now-1300)*1000));
        my $second=event('task_started',9,-1290); $second->{payload}{turn_id}=id(29); append(9,$second);
        append(9,row('turn_context',{turn_id=>id(29),model=>'gpt-6-luna',effort=>'max'},-1289));
        # Compaction records and a long run of work after the new turn started.
        append(9,row('compacted',{message=>'',replacement_history=>[]},-1280));
        padding(9,3*1024*1024);
        my $i=item(9,-3); $i->{payload}{turn_id}=id(29); my $u=usage(9,-1); $u->{payload}{turn_id}=id(29);
        append(9,$i,$u);
    }
} elsif ($action eq 'backlog') {
    for my $n (8..47) {
        my $m={id=>id($n),timestamp=>ts(-172800),cwd=>$root,multi_agent_version=>'v2',thread_source=>'subagent',parent_thread_id=>id(1),session_id=>id(1),history_mode=>'paginated',agent_nickname=>"Backlog$n",agent_role=>'explorer',agent_path=>"/root/old_$n"};
        open my $f,'>',path($n) or die $!; print $f encode_json(row('session_meta',$m,-172800)),"\n"; close $f;
        append($n,event('task_started',$n,-172799)); padding($n,512*1024);
        append($n,item($n,-172790)); utime $now-172790,$now-172790,path($n) or die $!;
    }
} else { die "unknown v2 fixture action\n" }
