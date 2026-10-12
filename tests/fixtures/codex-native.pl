# Synthetic protocol evidence only. No copied sessions, prompts, or personal identities.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use POSIX qw(strftime);
use File::Path qw(make_path);
my ($action,$root,$sessions,$pid)=@ARGV;
my $now=time;
sub ts { strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now+($_[0]//0))) }
sub id { sprintf '00000000-0000-4000-8000-%012d',$_[0] }
my $dir="$sessions/".strftime('%Y/%m/%d',gmtime($now));
sub path { "$dir/rollout-fixture-".id($_[0]).'.jsonl' }
sub write_json {
    my ($p,$append,@rows)=@_; open my $f,($append ? '>>' : '>'),$p or die $!;
    for my $d (@rows) { print $f encode_json($d),"\n" } close $f or die $!;
}
sub event { {timestamp=>ts($_[2]//-30),type=>'event_msg',payload=>{type=>$_[0],turn_id=>id($_[1]),@_[3..$#_]}} }
sub start { event('task_started',$_[0],$_[1]) }
sub context { {timestamp=>ts($_[1]//-29),type=>'turn_context',payload=>{turn_id=>id($_[0]),model=>'gpt-6-luna',effort=>'max'}} }
sub meta {
    my ($n,$parent,$cwd,$name,$task)=@_;
    return {timestamp=>ts(-59),type=>'session_meta',payload=>{id=>id($n),cwd=>$cwd,timestamp=>ts(-59),
        source=>($parent ? {subagent=>{thread_spawn=>{parent_thread_id=>id($parent),depth=>1,agent_role=>($n==4 ? 'default' : 'worker'),agent_nickname=>$name,agent_path=>"/root/$task"}}} : 'cli'),
        agent_role=>($n==4 ? 'default' : 'worker'),agent_nickname=>$name}};
}
if ($action eq 'seed' || $action eq 'compact-seed') {
    make_path($dir,"$root/.loomy/logs");
    my $owner={ts=>ts(-60),type=>'session',event=>'start',tool=>'codex',pid=>0+$pid};
    $owner->{session}=id(1) if $action eq 'compact-seed';
    write_json("$root/.loomy/logs/events.jsonl",0,$owner);
    write_json(path(1),0,meta(1,0,$root,'',''),start(10,-50));
    for my $n (2..4) {
        my $task=(qw(unused unused consolidation enrichment review))[$n];
        write_json(path($n),0,meta($n,1,$root,"Native$n",$task),start(10+$n),context(10+$n),
            {timestamp=>ts(-28),type=>'response_item',payload=>{type=>'function_call',name=>'exec_command',arguments=>'PRIVATE_TOOL_ARGUMENT'}});
    }
    # Both kinds of isolation failures: wrong project, and wrong lead at the same project.
    write_json(path(5),0,meta(5,1,'/nonexistent-fixture-project','Excluded','excluded'),start(15),context(15));
    write_json(path(6),0,meta(6,99,$root,'Unrelated','unrelated'),start(16),context(16));
    # Root exec/bridge metadata is never a native lead candidate.
    my $bridge=meta(7,0,$root,'',''); $bridge->{payload}{source}='exec'; write_json(path(7),0,$bridge);
    open my $state,'>',"$root/.loomy/state" or die $!; print $state "phase=done\n";
    my $brief_text="# Brief\n\n## AI tools\n\n- Lead: Codex\n";
    $brief_text="---\nai_mode: SOLO\nai_lead: codex\n---\n\n$brief_text" if $action eq 'compact-seed';
    open my $brief,'>',"$root/.loomy/brief.md" or die $!; print $brief $brief_text;
} elsif ($action eq 'compact') {
    write_json("$root/.loomy/logs/events.jsonl",1,{ts=>ts(),type=>'session',event=>'start',tool=>'codex',pid=>0+$pid,session=>id(1)});
} elsif ($action eq 'root-context' || $action eq 'root-update' || $action eq 'root-no-effort') {
    my $c=context(10,-40);
    $c->{payload}{model}=$action eq 'root-update' ? 'gpt-6-sol' : 'gpt-6.1-sol';
    $c->{payload}{effort}=$action eq 'root-update' ? 'max' : 'high';
    delete $c->{payload}{effort} if $action eq 'root-no-effort';
    $c->{payload}{developer_instructions}='PRIVATE_ROOT_INSTRUCTIONS';
    write_json(path(1),1,$c);
} elsif ($action eq 'root-large') {
    write_json(path(1),1,{timestamp=>ts(-25),type=>'response_item',payload=>{type=>'message',content=>'PRIVATE_ROOT_HISTORY'.('x'x6000000)}});
} elsif ($action eq 'root-incomplete') {
    my $c=context(10,-1); $c->{payload}{model}='gpt-incomplete';
    open my $f,'>>',path(1) or die $!; print $f encode_json($c);
} elsif ($action eq 'root-complete-line') {
    open my $f,'>>',path(1) or die $!; print $f "\n";
} elsif ($action eq 'root-truncate' || $action eq 'root-truncate-empty') {
    my $c=context(10,-1); $c->{payload}{model}='gpt-truncated'; $c->{payload}{effort}='low';
    write_json(path(1),0,meta(1,0,$root,'',''),($action eq 'root-truncate' ? $c : ()));
} elsif ($action eq 'root-reopen') {
    write_json("$root/.loomy/logs/events.jsonl",1,{ts=>ts(),type=>'session',event=>'end',tool=>'codex',pid=>0+$pid},
        {ts=>ts(),type=>'session',event=>'start',tool=>'codex',pid=>0+$pid,session=>id(1)});
} elsif ($action eq 'root-resumed-context') {
    my $c=context(10,1); $c->{payload}{model}='gpt-resumed'; $c->{payload}{effort}='high';
    write_json(path(1),1,$c);
} elsif ($action eq 'root-restore-identical') {
    my $p=path(1); open my $f,'<',"$root/root-snapshot.jsonl" or die $!;
    my @rows=map {decode_json($_)} <$f>; close $f;
    write_json($p,0,@rows);
} elsif ($action eq 'root-stale-sessionless') {
    write_json("$root/.loomy/logs/events.jsonl",1,{ts=>ts(),type=>'session_context',bridge=>'codex-native',tool=>'codex',owner_pid=>0+$pid,
        scope=>'lead',session=>'',model=>'gpt-stale-owner',effort=>'low'});
} elsif ($action eq 'root-corrupt-index') {
    open my $f,'>',"$root/.loomy/logs/codex-native.idx" or die $!; print $f '{"version":';
} elsif ($action eq 'root-legacy-freshness-index') {
    my $index="$root/.loomy/logs/codex-native.idx"; open my $f,'<',$index or die $!;
    my $s=decode_json(do {local $/;<$f>}); close $f;
    for my $snapshot (values %{$s->{root_snapshots}}) { delete $snapshot->{context_freshness}; delete $snapshot->{context_revision} }
    open my $h,'>',$index or die $!; print $h encode_json($s); close $h or die $!;
} elsif ($action eq 'root-legacy-journal') {
    my $journal="$root/.loomy/logs/events.jsonl"; open my $f,'<',$journal or die $!;
    my @rows=map {decode_json($_)} <$f>; close $f;
    for my $d (@rows) {
        next unless ($d->{type}//'') eq 'session_context';
        delete $d->{context_revision}; delete $d->{parent_session} unless $d->{model};
    }
    write_json($journal,0,@rows);
} elsif ($action eq 'claude-later') {
    write_json("$root/.loomy/logs/events.jsonl",1,{ts=>ts(),type=>'session',event=>'start',tool=>'claude',pid=>0+$pid,session=>id(8)});
} elsif ($action eq 'finish') {
    write_json(path(2),1,event('task_complete',12,-20,last_agent_message=>"STATUS: done\nPRIVATE_FINAL"));
    write_json(path(3),1,event('turn_aborted',13,-20,reason=>'interrupted'));
    write_json(path(4),1,event('task_complete',14,-20,last_agent_message=>"STATUS: partial\nPRIVATE_FINAL"));
} elsif ($action eq 'later') {
    write_json(path(2),1,start(22,-10),context(22,-9),{timestamp=>ts(-8),type=>'response_item',payload=>{type=>'function_call',name=>'wait_agent',arguments=>'PRIVATE_TOOL_ARGUMENT'}});
} elsif ($action eq 'supersede') {
    write_json(path(2),1,start(32,-5),context(32,-4));
} elsif ($action eq 'unknown') {
    write_json(path(2),1,event('task_complete',32,-1,last_agent_message=>'PRIVATE_FINAL without machine status'));
} elsif ($action eq 'blocked') {
    write_json(path(4),1,start(24,-10),context(24,-9),event('task_complete',24,-1,last_agent_message=>'STATUS: blocked'));
} elsif ($action eq 'incomplete') {
    open my $f,'>>',path(2) or die $!; print $f '{"timestamp":"'.ts().'","type":"event_msg","payload":{"type":"task_complete","turn_id":"'.id(12).'","last_agent_message":"STATUS: done"}';
} elsif ($action eq 'complete-line') {
    open my $f,'>>',path(2) or die $!; print $f "}\n";
} elsif ($action eq 'malformed') {
    open my $f,'>>',path(2) or die $!; print $f "not-json\n[]\n{\"type\":\"event_msg\",\"payload\":[]}\n";
} elsif ($action eq 'huge-child' || $action eq 'huge-terminal') {
    open my $f,'>>',path(2) or die $!;
    print $f encode_json({timestamp=>ts(-25),type=>'response_item',payload=>{type=>'function_call',name=>'exec_command',arguments=>'PRIVATE_TOOL_ARGUMENT'.('x'x680000)}}),"\n";
    if ($action eq 'huge-terminal') { print $f encode_json(event('task_complete',12,-20,last_agent_message=>'STATUS: done')),"\n" }
} elsif ($action eq 'large-journal' || $action eq 'root-large-journal') {
    my $journal="$root/.loomy/logs/events.jsonl";
    my $first=do {open my $f,'<',$journal or die $!; local $/=$action eq 'root-large-journal' ? undef : "\n"; <$f>};
    open my $f,'>',$journal or die $!;
    for (1..16000) { print $f encode_json({ts=>ts(-70),type=>'fixture',padding=>'x'x160}),"\n" }
    print $f $first;
} elsif ($action eq 'end-owner') {
    write_json("$root/.loomy/logs/events.jsonl",1,{ts=>ts(),type=>'session',event=>'end',tool=>'codex',pid=>0+$pid});
} elsif ($action eq 'tomorrow') {
    my $next="$sessions/".strftime('%Y/%m/%d',gmtime($now+86400)); make_path($next);
    rename path(4),"$next/rollout-fixture-".id(4).'.jsonl' or die $!;
} elsif ($action eq 'resume') {
    my $f=path(1); open my $h,'<',$f or die $!; my @rows=map {decode_json($_)} <$h>; close $h;
    $rows[0]{timestamp}=ts(-86400); $rows[0]{payload}{timestamp}=ts(-86400); write_json($f,0,@rows);
} elsif ($action eq 'ambiguous') {
    write_json(path(8),0,meta(8,0,$root,'',''),start(18,-50));
} elsif ($action eq 'truncate') {
    write_json(path(2),0,meta(2,1,$root,'Native2','consolidation'),start(12),context(12));
} elsif ($action eq 'nine') {
    for my $n (2..10) { write_json(path($n),0,meta($n,1,$root,"Native$n","nine$n"),start(10+$n),context(10+$n)) }
} elsif ($action eq 'nine-grow') {
    for my $n (2..9) {
        write_json(path($n),1,{timestamp=>ts(-25),type=>'response_item',payload=>{type=>'function_call',name=>'exec_command',arguments=>'x'x300000}});
    }
    write_json(path(10),1,event('task_complete',20,-20,last_agent_message=>'STATUS: done'));
} elsif ($action eq 'bridge-stats') {
    write_json("$root/.loomy/logs/events.jsonl",1,{ts=>ts(),type=>'delegation',id=>'fixture-bridge',bridge=>'codex',family=>'codex',role=>'developer',model=>'fixture-model',status=>'ok',duration_s=>10,tokens_in=>100,tokens_out=>50,cost_usd=>1.25});
} elsif ($action eq 'rotate' || $action eq 'truncate-journal') {
    my $journal="$root/.loomy/logs/events.jsonl";
    open my $f,'<',$journal or die $!;
    my @rows=map {decode_json($_)} <$f>; close $f;
    my ($owner)=grep {($_->{type}//'') eq 'session' && ($_->{event}//'') eq 'start'} @rows;
    die 'no fixture owner' unless $owner;
    if ($action eq 'rotate') {
        make_path("$root/.loomy/logs/archive");
        rename $journal,"$root/.loomy/logs/archive/events-fixture.jsonl" or die $!;
    }
    write_json($journal,0,$owner);
} elsif ($action eq 'legacy-index') {
    my $index="$root/.loomy/logs/codex-native.idx";
    open my $f,'<',$index or die $!;
    my $s=decode_json(do {local $/;<$f>}); close $f;
    for my $v (values %{$s->{files}}) { delete $v->{last_observed_ts}; delete $v->{journal_generation} }
    delete $s->{journal}{generation};
    open my $h,'>',$index or die $!; print $h encode_json($s); close $h or die $!;
} else { die "unknown fixture action\n" }
