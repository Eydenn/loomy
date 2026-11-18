# Synthetic tree geometry only, never sourced from a personal rollout.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use File::Path qw(make_path);
use FindBin;
my ($root,$pid,$mode)=@ARGV;
my $structural=($ARGV[3]//'') eq 'structural';
umask 0077 if $structural;
make_path("$root/.loomy/logs");
my $ts=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime(time-20));
my $tool=$mode eq 'advisor' ? 'claude' : 'codex';
my @rows=({ts=>$ts,type=>'session',event=>'start',tool=>$tool,pid=>0+$pid,session=>'layout-owner'});
push @rows,{ts=>$ts,type=>'session_context',tool=>$tool,bridge=>'codex-native',scope=>'lead',owner_pid=>0+$pid,session=>'layout-owner',
    model=>($mode eq 'advisor' ? 'claude-sonnet-5-5' : 'gpt-6.2-sol'),effort=>'high',context_freshness=>($mode eq 'catchup' ? 'catching_up' : 'current')} unless $mode eq 'unknown';
my @labels=('vocab_enrichissement_reprise','vocab_integration_finale','vocab_label_extremement_long_sans_espace_et_sans_fin','vocab_consolidation_finale');
for my $n (0..3) {
    push @rows,{ts=>$ts,type=>'delegation_start',bridge=>'codex-native',tool=>'codex',session=>'layout-owner',owner_pid=>0+$pid,
        id=>"layout-$n",agent_id=>"layout-agent-$n",role=>('role_' . ('x'x45)),task=>$labels[$n],
        model=>($n==2 ? 'gpt-'.('longmodel'x8) : 'gpt-6-luna'),effort=>'max'};
}
push @rows,{ts=>$ts,type=>'delegation',bridge=>'codex-native',tool=>'codex',session=>'layout-owner',owner_pid=>0+$pid,
    id=>'layout-2',agent_id=>'layout-agent-2',status=>'unknown',outcome=>'unknown'};
if ($structural) {
    require "$FindBin::Bin/../../scripts/lib/content-policy.pl";
    my $p={%{Loomy::ContentPolicy::defaults()},label_sources=>'explicit-lead',policy_generation=>1,grant_prompt_version=>1};
    open my $c,'>',"$root/.loomy/logs/content-policy.conf" or die $!;
    print $c "$_=$p->{$_}\n" for sort keys %$p; close $c or die $!;
    my $project=Loomy::ContentPolicy::effective_policy($root)->{project_id}; my %refs;
    for my $e (@rows) {
        $e->{content_policy}='structural-v1'; $e->{policy_generation}=1;
        if (defined $e->{task}) {
            $refs{$e->{id}}=Loomy::ContentPolicy::save_label($root,{project_id=>$project,target_kind=>'agent',
                target_id=>$e->{agent_id},attempt_id=>$e->{agent_id},source=>'explicit-lead',text=>delete $e->{task}});
        }
        $e->{label_ref}=$refs{$e->{id}} if defined($e->{id}) && $refs{$e->{id}};
    }
}
open my $j,'>',"$root/.loomy/logs/events.jsonl" or die $!;
print $j encode_json($_),"\n" for @rows; close $j or die $!;
open my $b,'>',"$root/.loomy/brief.md" or die $!;
print $b "---\nai_mode: SOLO\nai_lead: $tool\n---\n\n# Layout fixture\n";
open my $s,'>',"$root/.loomy/state" or die $!; print $s "phase=done\n";
