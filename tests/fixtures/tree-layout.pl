# Synthetic tree geometry only, never sourced from a personal rollout.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use File::Path qw(make_path);
my ($root,$pid,$mode)=@ARGV;
make_path("$root/.loomy/logs");
my $ts=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime(time-20));
my $tool=$mode eq 'advisor' ? 'claude' : 'codex';
my @rows=({ts=>$ts,type=>'session',event=>'start',tool=>$tool,pid=>0+$pid,session=>'layout-owner'});
push @rows,{ts=>$ts,type=>'session_context',tool=>$tool,bridge=>'codex-native',scope=>'lead',owner_pid=>0+$pid,session=>'layout-owner',
    model=>($mode eq 'advisor' ? 'claude-sonnet-5-5' : 'gpt-6.1-sol'),effort=>'high',context_freshness=>($mode eq 'catchup' ? 'catching_up' : 'current')} unless $mode eq 'unknown';
my @labels=('vocab_enrichissement_reprise','vocab_integration_finale','vocab_label_extremement_long_sans_espace_et_sans_fin','vocab_consolidation_finale');
for my $n (0..3) {
    push @rows,{ts=>$ts,type=>'delegation_start',bridge=>'codex-native',tool=>'codex',session=>'layout-owner',owner_pid=>0+$pid,
        id=>"layout-$n",agent_id=>"layout-agent-$n",role=>('role_' . ('x'x45)),task=>$labels[$n],
        model=>($n==2 ? 'gpt-'.('longmodel'x8) : 'gpt-6-luna'),effort=>'max'};
}
push @rows,{ts=>$ts,type=>'delegation',bridge=>'codex-native',tool=>'codex',session=>'layout-owner',owner_pid=>0+$pid,
    id=>'layout-2',agent_id=>'layout-agent-2',status=>'unknown',outcome=>'unknown'};
open my $j,'>',"$root/.loomy/logs/events.jsonl" or die $!;
print $j encode_json($_),"\n" for @rows; close $j or die $!;
open my $b,'>',"$root/.loomy/brief.md" or die $!;
print $b "---\nai_mode: SOLO\nai_lead: $tool\n---\n\n# Layout fixture\n";
open my $s,'>',"$root/.loomy/state" or die $!; print $s "phase=done\n";
