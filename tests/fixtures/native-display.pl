# Synthetic display evidence: no copied prompts, agents, projects or transcript data.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
my ($action,$root,$pid,$count)=@ARGV; $count//=2;
sub ts { sprintf '2026-01-02T10:00:%02dZ',$_[0] }
sub base { my ($id,$task)=@_; return {bridge=>'codex-native',tool=>'codex',family=>'codex',session=>'display-owner',parent_session=>'display-owner',owner_pid=>0+$pid,pid_role=>'owner',id=>$id,agent_id=>"agent-$id",role=>'worker',model=>'gpt-6-luna',effort=>'max',task=>$task} }
sub row { my ($type,$sec,$id,$task,%extra)=@_; return {%{base($id,$task)},type=>$type,ts=>ts($sec),%extra} }
sub write_rows { my ($append,@rows)=@_; open my $j,($append ? '>>' : '>'),"$root/.loomy/logs/events.jsonl" or die $!; print $j encode_json($_),"\n" for @rows; close $j or die $! }
if ($action eq 'seed') {
    make_path("$root/.loomy/logs");
    my @rows=({type=>'session',event=>'start',tool=>'codex',session=>'display-owner',pid=>0+$pid,ts=>ts(0),model=>'gpt-6.1-sol',effort=>'high'});
    for my $pair (['abort','aborted_task'],['superseded','superseded_task'],['response','response_task']) {
        push @rows,row('delegation_start',1,@$pair);
        my ($status,$outcome)=$pair->[0] eq 'abort' ? ('interrupted','interrupted') : $pair->[0] eq 'superseded' ? ('unknown','unknown') : ('ok','unknown');
        push @rows,row('delegation',5,@$pair,status=>$status,outcome=>$outcome,duration_s=>4);
    }
    for my $n (1..$count) {
        my $task=$n==1 ? 'vocab "quoted" \\path | safe' : "active_task_$n";
        push @rows,row('delegation_start',10,"active$n",$task);
        push @rows,row('delegation_activity',11,"active$n",$task,activity=>'running',prompt=>'PRIVATE_PROMPT',arguments=>'PRIVATE_TOOL_ARGUMENT');
        push @rows,row('delegation_activity',20,"active$n",$task,activity=>'running');
        push @rows,row('delegation_activity',30,"active$n",$task,activity=>($n==1 ? 'waiting' : 'running'));
        push @rows,row('delegation_activity',19,"active$n",$task,activity=>'running');
    }
    write_rows(0,@rows);
    open my $b,'>',"$root/.loomy/brief.md" or die $!; print $b "---\nai_mode: SOLO\nai_lead: codex\n---\n\n# Display fixture\n";
    open my $s,'>',"$root/.loomy/state" or die $!; print $s "phase=done\n";
} elsif ($action eq 'finish') {
    write_rows(1,row('delegation',40,'active1',undef,status=>'ok',outcome=>'unknown',duration_s=>30),
        row('delegation_activity',41,'active1',undef,activity=>'running'));
} elsif ($action eq 'typed') {
    write_rows(1,row('delegation_activity',35,'active2',{private=>'PRIVATE_HASH'},activity=>'waiting',role=>['PRIVATE_ROLE'],model=>{private=>'PRIVATE_MODEL'},arguments=>['PRIVATE_ARGUMENT']),
        row('delegation',39,'response',undef,status=>'ok',outcome=>'unknown',duration_s=>undef,role=>['PRIVATE_END_ROLE'],model=>{private=>'PRIVATE_END_MODEL'}));
} elsif ($action eq 'unknown-activity') {
    write_rows(1,row('delegation_activity',36,'active1','',activity=>'unknown'));
} elsif ($action eq 'later-turn') {
    write_rows(1,row('delegation',35,'active1',undef,status=>'ok',outcome=>'unknown',duration_s=>25),
        row('delegation_start',40,'active1-new','resumed_task',agent_id=>'agent-active1'),
        row('delegation_activity',45,'active1-new','resumed_task',agent_id=>'agent-active1',activity=>'waiting'),
        row('delegation_activity',50,'active1',undef,activity=>'running'));
} elsif ($action eq 'closed') {
    write_rows(1,{type=>'session',event=>'end',tool=>'codex',session=>'display-owner',pid=>0+$pid,ts=>ts(50)});
} elsif ($action eq 'sessionless-closed' || $action eq 'wrong-tool-closed' || $action eq 'wrong-pid-closed' || $action eq 'other-session-closed') {
    my $end={type=>'session',event=>'end',tool=>($action eq 'wrong-tool-closed' ? 'claude' : 'codex'),
        pid=>($action eq 'wrong-pid-closed' ? 99999999 : 0+$pid),ts=>ts(50)};
    $end->{session}='display-owner' if $action eq 'wrong-pid-closed';
    $end->{session}='other-owner' if $action eq 'other-session-closed';
    write_rows(1,$end);
} elsif ($action eq 'reopen') {
    write_rows(1,{type=>'session',event=>'start',tool=>'codex',session=>'display-owner',pid=>0+$pid,ts=>ts(51)},
        row('delegation_activity',55,'active1','vocab "quoted" \\path | safe',activity=>'waiting'));
} elsif ($action eq 'reopen-other') {
    write_rows(1,{type=>'session',event=>'start',tool=>'codex',session=>'other-owner',pid=>0+$pid,ts=>ts(51)},
        row('delegation_activity',55,'other-active','other_owner_task',session=>'other-owner',parent_session=>'other-owner',activity=>'running'),
        row('delegation_activity',56,'active1','vocab "quoted" \\path | safe',activity=>'waiting'));
} elsif ($action eq 'reopen-same-second') {
    write_rows(1,{type=>'session',event=>'end',tool=>'codex',pid=>0+$pid,ts=>ts(30)},
        {type=>'session',event=>'start',tool=>'codex',session=>'display-owner',pid=>0+$pid,ts=>ts(30)},
        row('delegation_activity',30,'active1','vocab "quoted" \\path | safe',activity=>'waiting'));
} elsif ($action eq 'compact-owner') {
    write_rows(1,{type=>'session',event=>'start',tool=>'codex',session=>'display-owner',pid=>0+$pid,ts=>ts(51)});
} elsif ($action eq 'sparse-activity') {
    write_rows(1,{type=>'delegation_activity',bridge=>'codex-native',id=>'active1',ts=>ts(45),activity=>'waiting'});
} elsif ($action eq 'tail-budget') {
    write_rows(0,row('delegation_start',1,'outside','OUTSIDE_TAIL'));
    my @rows=map {{type=>'fixture',ts=>ts(0),value=>$_}} 1..400;
    write_rows(1,@rows,row('delegation_activity',30,'tail-only','tail_task',activity=>'running'));
} else { die "unknown display fixture action\n" }
