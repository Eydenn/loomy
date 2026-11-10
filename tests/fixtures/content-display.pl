# Synthetic display matrix, never copied from a provider transcript.
use strict;
use warnings;
use utf8;
use JSON::PP;
use POSIX qw(strftime);
use Encode qw(decode);
use File::Path qw(make_path);
my ($repo,$root,$setup,$grant,$pid)=@ARGV;
require "$repo/scripts/lib/content-policy.pl";
my $json=JSON::PP->new->canonical->utf8;
umask 0077;
make_path("$root/.loomy/logs","$root/.loomy/tasks");
my $lead=$setup =~ /codex(?:-solo)?$/ ? 'codex' : 'claude';
my $hybrid=$setup =~ /^hybrid/;
my $native=$hybrid ? ($lead eq 'codex' ? 'claude' : 'codex') : $lead;
my $model=$native eq 'codex' ? 'gpt-6-luna' : 'claude-sonnet-5-5';
my $policy=Loomy::ContentPolicy::defaults();
$policy->{label_sources}=$grant ? Loomy::ContentPolicy::recommended_sources() : 'none';
$policy->{grant_prompt_version}=1;
open my $p,'>',"$root/.loomy/logs/content-policy.conf" or die $!;
print $p "$_=$policy->{$_}\n" for sort keys %$policy;
close $p or die $!;
my $project=Loomy::ContentPolicy::effective_policy($root)->{project_id};
my $now=time;
sub ts { strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now+$_[0])) }
sub label {
    my ($kind,$id,$attempt,$source,$text)=@_;
    return unless $grant;
    # Optional wide-label matrix (tests/content-display.sh): the label keeps its distinct tail.
    $text=decode('UTF-8',$ENV{LOOMY_FIXTURE_LABEL_PREFIX}).' '.$text if length($ENV{LOOMY_FIXTURE_LABEL_PREFIX}//'');
    return Loomy::ContentPolicy::save_label($root,{project_id=>$project,target_kind=>$kind,
        target_id=>$id,attempt_id=>$attempt,source=>$source,text=>$text});
}
my @rows;
sub emit {
    my ($type,$offset,%rest)=@_;
    push @rows,{ts=>ts($offset),type=>$type,content_policy=>'structural-v1',policy_generation=>0,%rest};
}
my $owner='matrix-owner';
emit('session',-50,event=>'start',tool=>$native,session=>$owner,pid=>0+$pid);
emit('session_observed',-49,tool=>$native,session=>$owner,session_key=>"$native:$owner",owner_pid=>0+$pid,
    schema=>2,surface=>($hybrid ? 'app' : 'cli'),state=>'running',source_active=>1,model=>$model,effort=>'high');
emit('session_context',-49,tool=>$native,session=>$owner,session_key=>"$native:$owner",owner_pid=>0+$pid,scope=>'lead',schema=>2,
    model=>$model,effort=>'high',context_freshness=>'current',bridge=>"$native-native");
emit('request',-48,session=>$owner,id=>'request-matrix',excerpt=>'PRIVATE_REQUEST_MUST_NOT_DISPLAY');
for my $spec (['first','agent-one00000001','alpha','Atlas','explorer'],
              ['second','agent-two00000001','beta','Vega','explorer'],
              ['custom','agent-custom003','gamma','Nova','unknown'],
              ['parent','agent-parent004','parent','Orion','explorer'],
              ['nested','agent-nested005','nested','Iris','explorer'],
              ['failed','agent-failed006','failed','Cygnus','explorer']) {
    my ($id,$agent,$slug,$nickname,$role)=@$spec;
    my %base=(bridge=>"$native-native",tool=>$native,family=>$native,session=>$owner,
        parent_session=>($id eq 'nested' ? 'agent-parent004' : $owner),owner_pid=>0+$pid,session_key=>"$native:$owner",
        parent_agent_id=>"$native:".($id eq 'nested' ? 'agent-parent004' : $owner),
        id=>$id,agent_id=>$agent,schema=>2,role=>$role,model=>$model,effort=>'max',
        task=>'PRIVATE_TASK_MUST_NOT_DISPLAY',nickname=>'PRIVATE_NICKNAME_MUST_NOT_DISPLAY');
    if ($native eq 'codex') {
        my %refs;
        for my $part (['slug','codex-path-slug',$slug],['nickname','codex-nickname',$nickname],['role','codex-role',($role eq 'unknown' ? 'custom-scout' : $role)]) {
            my $ref=label('agent',$agent,$agent,$part->[1],$part->[2]); $refs{$part->[0]}=$ref if $ref;
        }
        $base{label_refs}=\%refs if keys %refs;
        $base{label_ref}=$refs{slug} if $refs{slug};
        $base{multi_agent_version}='v2';
    } else {
        $base{turn_id}=$id;
        $base{agent_type}=$role eq 'unknown' ? 'custom-scout' : 'loomy-explorer';
        my $ref=label('delegation',$id,$owner,'claude-description',"Inspect $slug");
        $base{label_ref}=$ref if $ref;
    }
    emit('delegation_start',-40,%base);
    if ($id eq 'parent' || $id eq 'failed') {
        emit('delegation',-25,%base,status=>($id eq 'failed' ? 'error' : 'ok'),
            outcome=>($id eq 'failed' ? 'failed' : 'done'),duration_s=>15,cost_usd=>0);
    } else {
        emit('delegation_activity',-2,%base,activity=>'running');
    }
}
my $bridge_ref=label('delegation','bridge-paused','bridge-paused','explicit-lead','Recover paused task');
emit('delegation',-1,id=>'bridge-paused',bridge=>$lead,family=>$lead,role=>'reviewer',model=>($lead eq 'codex' ? 'gpt-6-luna' : 'claude-sonnet-5-5'),
    effort=>'max',status=>'paused',outcome=>'partial',duration_s=>83,resume_at=>$now+300,
    cost_usd=>0.125,tokens_in=>1200,tokens_out=>300,cost_in=>'direct',task=>'PRIVATE_PAUSED_MUST_NOT_DISPLAY',
    ($bridge_ref ? (label_ref=>$bridge_ref) : ()));
emit('skill',-1,name=>'pdf',event=>'added',reason_code=>'installed',reason=>'PRIVATE_SKILL_MUST_NOT_DISPLAY');
emit('lead_failover',-1,master=>'claude',acting=>'codex',reason_code=>'quota',quota_window=>'5h',used_percent=>92,
    reason=>'PRIVATE_REASON_MUST_NOT_DISPLAY');
emit('usage',-1,tool=>$native,family=>$native,scope=>'lead',model=>$model,messages=>2,
    tokens_in=>5000,tokens_out=>500,tokens_cached=>1000,cost_usd=>0.25,cost_source=>'estimate');
open my $j,'>',"$root/.loomy/logs/events.jsonl" or die $!;
for my $row (@rows) {
    my %body=%$row; my $ts=delete $body{ts}; my $type=delete $body{type};
    my $encoded=$json->encode(\%body); $encoded=substr($encoded,1,-1);
    print $j '{"ts":',$json->encode($ts),',"type":',$json->encode($type),',',$encoded,"}\n";
}
# A partial final write must never create a phantom task or revive private data.
print $j '{"type":"delegation_start","task":"PRIVATE_PARTIAL';
close $j or die $!;
open my $b,'>',"$root/.loomy/brief.md" or die $!;
print $b "---\nname: Display fixture\nai_mode: ",($hybrid ? 'HYBRID' : 'SOLO'),"\nai_lead: $lead\nbudget: equilibre\n---\n";
close $b;
open my $s,'>',"$root/.loomy/state" or die $!; print $s "phase=build\n"; close $s;
open my $t,'>',"$root/.loomy/task.state" or die $!;
print $t "id=1\ntitle=Authored task title\nfile=.loomy/tasks/001-display.md\nphase=build\n"; close $t;
open my $d,'>',"$root/.loomy/tasks/001-display.md" or die $!;
print $d "# Task #1 - Authored task title\n"; close $d;
open my $e,'>',"$root/expected.json" or die $!;
print $e $json->encode({native=>$native,first=>($native eq 'codex' ? 'Atlas explorer alpha' : 'Inspect alpha'),
    second=>($native eq 'codex' ? 'Vega explorer beta' : 'Inspect beta'),project=>$project});
close $e;
