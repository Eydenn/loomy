# Structural Claude CLI/Code-tab fixtures, with one immutable source clock.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
use POSIX qw(strftime);
my ($op,$root,$projects,$surface,$background,$n)=@ARGV;
$surface//='app'; $background//=0; $n//=1;
my $slug=$root; $slug =~ s/[^A-Za-z0-9]/-/g;
my $dir="$projects/$slug"; my $sid="$surface-lead"; my $call="call$n"; my $aid="child$n";
my $path="$dir/$sid.jsonl"; my $child="$dir/$sid/subagents/agent-$aid.jsonl";
my $base=1791853200;
sub ts {strftime('%Y-%m-%dT%H:%M:%S',gmtime($base+$_[0])).'.250Z'}
sub rows {my $path=shift; $path =~ m{^(.*)/[^/]+$}; make_path($1); open my $f,'>>',$path or die $!; print $f encode_json($_),"\n" for @_; close $f or die $!}
sub common {my ($type,$offset)=@_; return (type=>$type,cwd=>$root,sessionId=>$sid,timestamp=>ts($offset),entrypoint=>$surface eq 'app'?'claude-desktop':'cli',uuid=>"u$offset")}
sub hook {rows("$root/.loomy/logs/events.jsonl",@_)}
if ($op eq 'seed') {
    make_path("$root/.loomy/logs"); open my $b,'>',"$root/.loomy/brief.md" or die; print $b "name=Claude test\nai_mode=ORCHESTRATED\nai_lead=claude\nbudget=standard\n"; close $b;
    open my $state,'>',"$root/.loomy/state" or die; print $state "phase=done\n"; close $state;
    rows($path,{common('user',0),message=>{role=>'user',content=>'PRIVATE_PROMPT'}},
        {common('assistant',1),effort=>'high',message=>{id=>'msg1',model=>'claude-sonnet-5-5',content=>[{type=>'text',text=>'PRIVATE_CONTENT'},{type=>'tool_use',id=>$call,name=>'Agent',input=>{subagent_type=>'developer',description=>'PRIVATE_DESCRIPTION',prompt=>'PRIVATE_TASK',run_in_background=>$background?JSON::PP::true:JSON::PP::false}}],stop_reason=>undef}});
    rows($child,{common('user',2),agentId=>$aid,isSidechain=>JSON::PP::true,message=>{role=>'user',content=>'PRIVATE_CHILD'}});
} elsif ($op eq 'hooks') {
    hook({ts=>ts(0),type=>'session',event=>'start',tool=>'claude',session=>$sid,pid=>0},
        {ts=>ts(1),type=>'delegation_start',bridge=>'subagent',family=>'claude',session=>$sid,id=>$call,role=>'developer',model=>'claude-sonnet-5-5',background=>$background?JSON::PP::true:JSON::PP::false,task=>'Implement fixture'});
} elsif ($op eq 'return') {
    rows($path,{common('user',3),toolUseResult=>{status=>'async_launched',agentId=>$aid},message=>{content=>[{type=>'tool_result',tool_use_id=>$call,content=>'PRIVATE_RESULT'}]}});
} elsif ($op eq 'hook-return') {
    hook({ts=>ts(3),type=>'subagent_link',session=>$sid,id=>$call,agent_id=>$aid});
} elsif ($op eq 'stop') {
    rows($child,{common('assistant',4),agentId=>$aid,isSidechain=>JSON::PP::true,message=>{model=>'claude-sonnet-5-5',stop_reason=>undef,content=>[{type=>'text',text=>'PRIVATE_FINAL'}]}});
    rows($path,{common('queue-operation',4),operation=>'enqueue',content=>"<task-notification><task-id>$aid</task-id><tool-use-id>$call</tool-use-id><status>completed</status></task-notification>"});
} elsif ($op eq 'hook-stop') {
    hook({ts=>ts(4),type=>'subagent_stop',session=>$sid,agent_id=>$aid,outcome=>'done'},
        {ts=>ts(4),type=>'usage',tool=>'claude',family=>'claude',scope=>'subagent',model=>'claude-sonnet-5-5',cost_usd=>0.25});
} elsif ($op eq 'activity') {
    rows($path,{common('assistant',5),message=>{model=>'claude-sonnet-5-5',content=>[{type=>'text',text=>'PRIVATE_RUNNING'}],stop_reason=>undef}});
} elsif ($op eq 'live-child') {
    rows($path,{common('assistant',1),message=>{model=>'claude-sonnet-5-5',content=>[{type=>'tool_use',id=>$call,name=>'Agent',input=>{subagent_type=>"latency$n",run_in_background=>$background?JSON::PP::true:JSON::PP::false,prompt=>'PRIVATE_LATENCY'}}]}});
} elsif ($op eq 'live-hook') {
    hook({type=>'delegation_start',bridge=>'subagent',family=>'claude',session=>$sid,id=>$call,role=>"hook$n",model=>'claude-sonnet-5-5',background=>JSON::PP::true,ts=>ts(1)});
} elsif ($op eq 'live-finish') {
    hook({type=>'delegation',bridge=>'subagent',family=>'claude',session=>$sid,id=>$call,status=>'ok',outcome=>'done',ts=>ts(4)});
} elsif ($op eq 'idle') {rows($path,{common('system',6),subtype=>'turn_duration',durationMs=>1000})}
else {die "unknown fixture $op"}
