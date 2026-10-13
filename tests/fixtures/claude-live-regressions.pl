# Deterministic structural cases; never open a real provider transcript or launch a provider CLI.
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
my ($repo,$work)=@ARGV;
require "$repo/scripts/lib/claude-native.pl";
require "$repo/scripts/lib/live-state.pl";
my $projects="$work/claude/projects";
sub row {
    my ($path,@rows)=@_; $path =~ m{^(.*)/[^/]+$}; make_path($1);
    open my $h,'>>',$path or die $!; print $h encode_json($_),"\n" for @rows; close $h or die $!;
}
sub collect {
    my ($root,$state)=@_; my $s=Loomy::ClaudeNative::poll($root,$projects);
    $state//=Loomy::LiveState->new; $state->read_journal("$root/.loomy/logs/events.jsonl"); $state->claude_evidence($s);
    return ($s,$state);
}
sub ts {'2026-10-13T01:00:'.sprintf('%02d',$_[0]).'.250Z'}
sub source {my ($root,$sid)=@_; return "$projects/".Loomy::ClaudeNative::slug($root)."/$sid.jsonl"}
my $root="$work/hook-only"; my $j="$root/.loomy/logs/events.jsonl";
for my $sid (qw(cli app)) {
    row($j,{type=>'session',tool=>'claude',session=>$sid,event=>'start',source=>'startup',ts=>ts(0)},
        {type=>'delegation_start',bridge=>'subagent',session=>$sid,id=>'same-call',role=>'developer',background=>JSON::PP::true,ts=>ts(1)});
}
my ($s,$v)=collect($root);
die 'hook-only lead groups/agents merged' unless keys(%{$v->{sessions}})==2 && keys(%{$v->{agents}})==2;
die 'startup was guessed to be a surface' if grep {$_->{surface} ne 'unknown'} values %{$v->{sessions}};
row($j,{type=>'subagent_stop',session=>'app',agent_id=>'same-agent',outcome=>'partial',ts=>ts(4)},
    {type=>'subagent_link',session=>'app',id=>'same-call',agent_id=>'same-agent',ts=>ts(3)},
    {type=>'subagent_link',session=>'cli',id=>'same-call',agent_id=>'same-agent',ts=>ts(3)});
($s,$v)=collect($root,$v);
die 'out-of-order stop crossed session aliases' unless $v->{agents}{'claude:app:same-call'}{state} eq 'done' && $v->{agents}{'claude:cli:same-call'}{state} eq 'running';
die 'outcome lost' unless $v->{turns}{'cl:app:same-call'}{outcome} eq 'partial';
row($j,{type=>'session_activity',tool=>'claude',session=>'app',state=>'idle',ts=>ts(5)});
($s,$v)=collect($root,$v); die 'Stop closed the lead' unless $v->{sessions}{'claude:app'}{state} eq 'idle' && !$v->{sessions}{'claude:app'}{closed};
row($j,{type=>'delegation',bridge=>'subagent',session=>'cli',id=>'same-call',status=>'error',outcome=>'failed',ts=>ts(6)});
($s,$v)=collect($root,$v); die 'failure missing' unless $v->{agents}{'claude:cli:same-call'}{state} eq 'failed';
print "hook-only sessions, scoped aliases, reverse stop, idle and failure passed\n";

$root="$work/alias"; make_path("$root/.loomy/logs");
my $path=source($root,'lead'); (my $child=$path)=~s{\.jsonl$}{/subagents/agent-child.jsonl};
my $base={sessionId=>'lead',cwd=>$root,entrypoint=>'claude-desktop'};
row($child,{%$base,type=>'user',agentId=>'child',timestamp=>ts(2),message=>{content=>'PRIVATE_CHILD'}});
($s,$v)=collect($root); $v->projections(1791853207);
die 'provisional child absent' unless $v->{agents}{'claude:lead:agent:child'};
row($path,{%$base,type=>'assistant',timestamp=>ts(1),message=>{content=>[{type=>'tool_use',name=>'Agent',id=>'call',input=>{subagent_type=>'developer',run_in_background=>JSON::PP::true,prompt=>'PRIVATE'}}]}},
    {%$base,type=>'user',timestamp=>ts(3),toolUseResult=>{agentId=>'child',isAsync=>JSON::PP::true},message=>{content=>[{type=>'tool_result',tool_use_id=>'call',content=>'PRIVATE'}]}});
($s,$v)=collect($root,$v);
my @delta=$v->projections(1791853207);
die 'provisional alias not deleted from incremental frame' unless grep {$_ eq 'N|X|claude:lead:agent:child'} @delta;
die 'alias left duplicate agents/turns' unless keys(%{$v->{agents}})==1 && keys(%{$v->{turns}})==1;
row($child,{%$base,type=>'assistant',agentId=>'child',timestamp=>ts(4),message=>{content=>[{type=>'text',text=>'PRIVATE plain text is not a stop'}]}});
($s,$v)=collect($root,$v); die 'assistant text ended agent' unless $v->{agents}{'claude:lead:call'}{state} eq 'running';
row($child,{%$base,type=>'assistant',agentId=>'child',timestamp=>ts(5),message=>{stop_reason=>'end_turn',model=>'claude-sonnet-5-5'}});
($s,$v)=collect($root,$v); die 'explicit stop missing' unless $v->{agents}{'claude:lead:call'}{state} eq 'done';
my $size=-s "$root/.loomy/logs/events.jsonl";
# Inode replacement is a source revision, not another execution or billable turn.
open my $h,'<',$path or die; my $raw=do {local $/; <$h>}; close $h;
open $h,'>',"$path.replacement" or die; print $h $raw; close $h; rename "$path.replacement",$path or die;
($s,$v)=collect($root,$v); die 'replacement duplicated events' unless (-s "$root/.loomy/logs/events.jsonl")==$size;
die 'source lease did not expire' unless grep {/\|G\|claude:lead\|.*\|stale\|/} $v->projections(1791853500);
print "late provisional alias, content-only activity, explicit end, replacement and lease passed\n";

$root="$work/bounded"; make_path("$root/.loomy/logs"); $path=source($root,'large');
$base={sessionId=>'large',cwd=>$root,entrypoint=>'cli'};
row($path,{%$base,type=>'user',timestamp=>ts(0),message=>{content=>'PRIVATE'}});
open $h,'>>',$path or die; print $h encode_json({type=>'assistant',message=>{content=>'PRIVATE_' x 100000}}),"\n";
my $partial=encode_json({%$base,type=>'assistant',timestamp=>ts(1),message=>{content=>[{type=>'tool_use',name=>'Agent',id=>'bounded-call',input=>{subagent_type=>'developer'}}]}});
print $h substr($partial,0,-8); close $h;
($s,$v)=collect($root);
die 'partial JSON accepted' if keys %{$v->{agents}};
die 'per-file read exceeded bound' if grep {($_->{read_bytes}//0)>($_->{meta}{agent} ? 262144 : 2097152)} values %{$s->{files}};
open $h,'>>',$path or die; print $h substr($partial,-8),"\n"; close $h;
($s,$v)=collect($root,$v); die 'tail fast path lost lifecycle after large content' unless $v->{agents}{'claude:large:bounded-call'};
for (1..12) {($s,$v)=collect($root,$v)}
die 'catch-up duplicated child' unless keys(%{$v->{agents}})==1;
open $h,'<',"$root/.loomy/logs/claude-native.idx" or die; $raw=do {local $/; <$h>}; close $h;
die 'checkpoint copied private content' if $raw =~ /PRIVATE_/;
my $disabled="$work/disabled"; make_path("$disabled/.loomy/logs");
{local $ENV{LOOMY_JOURNAL}=0; collect($disabled)}
die 'disabled collector wrote checkpoint' if -e "$disabled/.loomy/logs/claude-native.idx";
print "bounded oversized/partial lines, tail fast path, replay and journal opt-out passed\n";

$root="$work/boundary"; make_path("$root/.loomy/logs","$root/src","$root-other");
for my $cwd ($root,"$root/src","$root-other") {
    my $sid=$cwd eq $root ? 'root' : $cwd eq "$root/src" ? 'descendant' : 'excluded';
    row(source($cwd,$sid),{type=>'user',cwd=>$cwd,sessionId=>$sid,entrypoint=>'cli',timestamp=>ts(0),message=>{content=>'PRIVATE'}});
}
($s,$v)=collect($root);
die 'descendant missing or sibling admitted by slug' unless keys(%{$v->{sessions}})==2 && $v->{sessions}{'claude:root'} && $v->{sessions}{'claude:descendant'};
print "canonical cwd boundary excludes slug-prefix siblings and includes descendants\n";
