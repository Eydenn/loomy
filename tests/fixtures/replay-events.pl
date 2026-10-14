# Provider-structure fixtures only: identifiers, clocks, Agent/Bash notification envelopes.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use Time::HiRes qw(time);
use File::Path qw(make_path);
my ($work,$action,$trial)=@ARGV; $trial//=0;
my $root="$work/project"; my $now=time;
# Claude stores a project's transcripts under its cwd with every non-alphanumeric character replaced by a dash.
(my $slug=$root)=~s/[^A-Za-z0-9]/-/g;
sub ts {my $t=$now+($_[0]//0); strftime('%Y-%m-%dT%H:%M:%S',gmtime($t)).sprintf('.%03dZ',int(($t-int $t)*1000))}
sub rows {
    my ($path,@rows)=@_; (my $dir=$path)=~s{/[^/]*$}{}; make_path($dir);
    open my $f,'>>',$path or die $!; print $f encode_json($_),"\n" for @rows; close $f or die $!;
}
sub codex_path {"$work/codex/sessions/2020/01/01/rollout-$_[0].jsonl"}
sub claude_path {"$work/claude/projects/$slug/$_[0].jsonl"}
sub meta {
    my ($id,$parent,$name,$surface)=@_;
    {type=>'session_meta',timestamp=>ts(),payload=>{id=>$id,cwd=>$root,timestamp=>ts(),
        source=>$parent ? {subagent=>{thread_spawn=>{parent_thread_id=>$parent,depth=>1,agent_role=>'worker',agent_nickname=>$name,agent_path=>"/root/$name"}}} : $surface,
        agent_nickname=>$name,agent_role=>'worker'}}
}
sub event {my ($kind,$turn)=@_; {type=>'event_msg',timestamp=>ts(),payload=>{type=>$kind,turn_id=>$turn}}}
sub base {my ($id,$type)=@_; (type=>$type,sessionId=>$id,cwd=>$root,entrypoint=>'claude-desktop',timestamp=>ts())}
my $journal="$root/.loomy/logs/events.jsonl";
if ($action eq 'seed') {
    make_path("$root/.loomy/logs");
    open my $f,'>',"$root/.loomy/brief.md" or die; print $f "---\nai_mode: SOLO\nai_lead: codex\n---\n"; close $f;
    for my $surface (qw(cli app)) {
        my $id="cx-$surface"; my $m=meta($id,'','',$surface eq 'app' ? 'vscode' : 'cli');
        $m->{payload}{originator}='Codex Desktop' if $surface eq 'app';
        rows(codex_path($id),$m,event('task_started',"lead-$surface"));
        rows(claude_path("cl-$surface"),{base("cl-$surface",'user'),entrypoint=>$surface eq 'app' ? 'claude-desktop' : 'cli',message=>{content=>[]}});
    }
} elsif ($action eq 'start' || $action eq 'end') {
    for my $surface (qw(cli app)) {
        my $name="cx${surface}$trial"; my $lead="cx-$surface";
        my $child="$name-child";
        if ($action eq 'start') {rows(codex_path($child),meta($child,$lead,$name,''),event('task_started',"turn-$trial"))}
        else {
            rows(codex_path($child),event('task_complete',"turn-$trial"));
            rows(codex_path($lead),
                {type=>'response_item',timestamp=>ts(),payload=>{type=>'function_call',name=>'close_agent',call_id=>"close-$trial",arguments=>encode_json({id=>$child})}},
                {type=>'response_item',timestamp=>ts(),payload=>{type=>'function_call_output',call_id=>"close-$trial",output=>encode_json({status=>{$child=>'completed'}})}});
        }
        my $cl="cl-$surface"; my $call="call-$trial"; my $agent="agent-$trial"; my $role="cl${surface}$trial";
        if ($action eq 'start') {
            rows(claude_path($cl),
                {base($cl,'assistant'),message=>{content=>[{type=>'tool_use',name=>'Agent',id=>$call,input=>{subagent_type=>$role,run_in_background=>JSON::PP::true}}]}},
                {base($cl,'user'),toolUseResult=>{status=>'async_launched',agentId=>$agent,isAsync=>JSON::PP::true},message=>{content=>[{type=>'tool_result',tool_use_id=>$call,content=>[]}]}});
            rows("$work/claude/projects/$slug/$cl/subagents/agent-$agent.jsonl",{base($cl,'assistant'),message=>{content=>[],model=>'claude-sonnet-5-5'}});
            # Bash background notifications must never create an agent row.
            rows(claude_path($cl),{base($cl,'queue-operation'),operation=>'enqueue',content=>'<task-notification><tool-use-id>bash-phantom</tool-use-id><status>completed</status></task-notification>'});
        } else {
            rows(claude_path($cl),{base($cl,'queue-operation'),operation=>'enqueue',content=>"<task-notification><tool-use-id>$call</tool-use-id><status>completed</status></task-notification>"});
        }
    }
    # Two bridge containers, with explicit nested native identities (no time/cwd guessing).
    for my $depth (1..2) {
        my $id="bridge-$trial-$depth"; my $parent=$depth==2 ? "bridge-$trial-1" : '';
        my $base={schema=>2,session_key=>'codex:cx-cli',tool=>'codex',bridge=>'codex',id=>$id,agent_id=>$id,
            parent_delegation=>$parent,parent_agent_id=>$parent,role=>"bridge$depth-$trial",ts=>ts()};
        rows($journal,{%$base,type=>$action eq 'start' ? 'delegation_start' : 'delegation',
            $action eq 'start' ? (state=>'running') : (status=>'ok',outcome=>'done',duration_s=>1)});
    }
} else {die 'unknown replay action'}
