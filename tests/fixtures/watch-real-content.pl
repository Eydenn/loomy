# Synthetic read-side display scenarios; grants are fixture bytes, never a TTY bypass.
use strict;
use warnings;
use utf8;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
use FindBin;
my ($root,$mode,$pid)=@ARGV;
require "$FindBin::Bin/../../scripts/lib/content-policy.pl";
umask 0077;
make_path("$root/.loomy/logs",{mode=>0700});
my $now=1791853200;
my $policy={%{Loomy::ContentPolicy::defaults()},policy_generation=>1,grant_prompt_version=>1,
    label_sources=>($mode eq 'off' ? 'none' : Loomy::ContentPolicy::recommended_sources())};
open my $c,'>',"$root/.loomy/logs/content-policy.conf" or die $!;
print $c "$_=$policy->{$_}\n" for sort keys %$policy; close $c or die $!;
my $project=Loomy::ContentPolicy::effective_policy($root)->{project_id};
sub label {
    my ($kind,$target,$attempt,$source,$text)=@_;
    return Loomy::ContentPolicy::save_label($root,{project_id=>$project,target_kind=>$kind,target_id=>$target,
        attempt_id=>$attempt,source=>$source,text=>$text});
}
open my $j,'>',"$root/.loomy/logs/events.jsonl" or die $!;
sub put {
    my ($at,$type,%f)=@_; my @t=gmtime($at);
    my $ts=sprintf '%04d-%02d-%02dT%02d:%02d:%02dZ',$t[5]+1900,$t[4]+1,@t[3,2,1,0];
    print $j encode_json({ts=>$ts,type=>$type,content_policy=>'structural-v1',policy_generation=>1,%f}),"\n";
}
my $classic=$mode eq 'bridge' || $mode eq 'hook';
my $tool=$mode =~ /\A(?:claude|unicode|wide|flags|halfwidth)\z/ || $classic ? 'claude' : 'codex';
open my $b,'>',"$root/.loomy/brief.md" or die $!;
print $b "---\nai_mode: SOLO\nai_lead: $tool\n---\n\n# Structural display fixture\n"; close $b;
open my $s,'>',"$root/.loomy/state" or die $!; print $s "phase=done\n"; close $s;
if ($classic) {
    put($now-500,'session',event=>'start',tool=>'claude',session=>'content-classic',pid=>0+$pid);
    put($now-490,'session_context',tool=>'claude',session=>'content-classic',pid=>0+$pid,
        model=>'claude-sonnet-5-5',effort=>'high',context_freshness=>'current');
    for my $n (1..3) {
        my $id="d1791853${n}0012345"; my $title=$mode eq 'hook' ? "Claude description $n" : "Bridge review $n";
        my %e=(id=>$id,attempt_id=>$id,session=>'content-classic',pid=>0+$pid,
            bridge=>($mode eq 'hook' ? 'subagent' : 'codex'),family=>($mode eq 'hook' ? 'claude' : 'codex'),
            role=>($mode eq 'hook' ? 'unknown' : $n==1 ? 'reviewer' : $n==2 ? 'developer' : 'explorer'),
            model=>($mode eq 'hook' ? 'claude-sonnet-5-5' : 'gpt-6-luna'),effort=>'max',
            task=>'UNGRANTED_TASK_CANARY',requested=>JSON::PP::true,
            label_ref=>label('delegation',$id,$id,$mode eq 'hook' ? 'claude-description' : 'explicit-lead',$title));
        $e{agent_type}=('Explore','Plan','custom.agent')[$n-1] if $mode eq 'hook';
        put($now-90+$n,'delegation_start',%e);
    }
    close $j or die $!; exit;
}
my $sid='content-session';
my %base=(schema=>2,tool=>$tool,family=>$tool,session_key=>"$tool:$sid",session=>$sid,
    surface=>'app',agent_id=>$sid,source=>($tool eq 'codex' ? 'rollout' : 'transcript'));
put($now-3,'session_observed',%base,state=>'running',source_active=>1);
put($now-2,'session_context',%base,model=>($tool eq 'codex' ? 'gpt-6.2-sol' : 'claude-sonnet-5-5'),effort=>'high',context_freshness=>'current');
my @slug=$mode eq 'codex-v1' ? qw(consolidation enrichment vocabulary) : qw(inventory verification vocabulary);
for my $n (1..3) {
    my $aid="00000000-0000-4000-8000-${n}00012345678";
    my $turn="cn:$aid:00000000-0000-4000-8000-${n}00087654321";
    my $parent=$n==3 ? "$tool:00000000-0000-4000-8000-100012345678" : "$tool:$sid";
    my %e=(%base,id=>$turn,turn_id=>"00000000-0000-4000-8000-${n}00087654321",agent_id=>$aid,parent_agent_id=>$parent,
        attempt_id=>$aid,bridge=>"$tool-native",role=>($n==3 || $tool eq 'claude' ? 'agent' : 'explorer'),
        model=>($tool eq 'codex' ? 'gpt-6-luna' : 'claude-sonnet-5-5'),effort=>'max',task=>'UNGRANTED_TASK_CANARY');
    $e{multi_agent_version}='v2' if $mode ne 'codex-v1' && $tool eq 'codex';
    if ($tool eq 'codex' && $mode ne 'off') {
        my %parts=(slug=>$slug[$n-1]);
        @parts{qw(nickname role)}=($n==3 ? 'Nova' : 'Lyra',$n==3 ? 'qa' : 'explorer') unless $mode eq 'codex-v1';
        $e{label_refs}={map {$_=>label('agent',$aid,$aid,$_ eq 'slug' ? 'codex-path-slug' : "codex-$_",$parts{$_})} keys %parts};
    } elsif ($tool eq 'claude') {
        $e{agent_type}=('Explore','Plan','custom.agent')[$n-1];
        my $title=$mode eq 'unicode' ? "かな語彙 ".("e\x{301} 👩🏽 語彙 "x8)."Claude description $n"
            : $mode eq 'wide' ? join(' ',('語彙')x30)
            : $mode eq 'flags' ? ("🇯🇵 "x25)."Claude description $n"
            : $mode eq 'halfwidth' ? ("ｶﾞ "x25)."Claude description $n" : "Claude description $n";
        $e{label_ref}=label('agent',$aid,$aid,'claude-description',$title);
    }
    put($now-($n==1 ? 2500 : 60-$n),'delegation_start',%e);
    put($now-2100,'delegation',%e,status=>'ok',outcome=>'partial',duration_s=>400) if $n==1;
}
close $j or die $!;
