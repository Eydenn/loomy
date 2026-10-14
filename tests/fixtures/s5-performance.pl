# Declared envelope: 10,000 sources, four leads, 100 active agents, 50,000 events.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use File::Path qw(make_path);
use POSIX qw(strftime);
use Time::HiRes qw(time clock_gettime CLOCK_PROCESS_CPUTIME_ID);
my ($repo,$work)=@ARGV;
require "$repo/tests/fixtures/time-scale.pl";
require "$repo/scripts/lib/codex-native.pl";
require "$repo/scripts/lib/claude-native.pl";
my $root="$work/performance"; my $logs="$root/.loomy/logs";
my $sources="$work/perf-codex/sessions"; make_path($logs,"$sources/2020/01/01");
my $now=int time; $ENV{LOOMY_NATIVE_NOW}=$now;
my $ts=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime($now));
open my $f,'>',"$logs/events.jsonl" or die;
for my $i (1..24900) {
    my $b={schema=>2,tool=>'codex',bridge=>'codex-native',session_key=>'codex:lead1',agent_id=>'old'.($i%100),id=>"turn$i",ts=>$ts};
    print $f encode_json({%$b,type=>'delegation_start'}),"\n",encode_json({%$b,type=>'delegation',status=>'ok',outcome=>'done'}),"\n";
}
for my $i (1..100) {
    my $b={schema=>2,tool=>'codex',bridge=>'codex-native',session_key=>'codex:lead'.(1+$i%4),agent_id=>"active$i",id=>"active$i",ts=>$ts};
    print $f encode_json({%$b,type=>'delegation_start'}),"\n",encode_json({%$b,type=>'delegation_activity',state=>'running'}),"\n";
}
close $f;
for my $i (1..10000) {
    open my $source,'>',sprintf("$sources/2020/01/01/rollout-%05d.jsonl",$i) or die;
    my $id=$i<=4 ? "lead$i" : "unrelated$i";
    print $source encode_json({type=>'session_meta',timestamp=>$ts,payload=>{id=>$id,cwd=>$i<=4 ? $root : $work,source=>'cli',timestamp=>$ts}}),"\n";
    print $source encode_json({type=>'event_msg',timestamp=>$ts,payload=>{type=>'task_started',turn_id=>"root-$i"}}),"\n" if $i<=4;
    close $source;
}
my $cold=time; my $state;
do {$state=Loomy::CodexNative::poll($root,$sources)} while ($state->{discovering} || !$state->{journal}{at_eof});
printf "10,000-source inventory/cold journal: %.3f s (separate from warm budget)\n",time-$cold;
my $view=Loomy::LiveState->new;
$view->read_journal("$logs/events.jsonl") until $view->{cursor}{at_eof}; $view->source_evidence($state);
open my $rows,'>',"$work/perf.rows" or die; print $rows "$_\n" for $view->projections($now); close $rows;
my $max=0;
for (1..50) {
    my $start=clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
    Loomy::CodexNative::watch_changed($root,$sources,$now);
    $state=Loomy::CodexNative::poll($root,$sources);
    $view->read_journal("$logs/events.jsonl"); $view->source_evidence($state); $view->projections($now);
    my $elapsed=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$start; $max=$elapsed if $elapsed>$max;
    die 'historical read on warm frame' if $view->{read_bytes};
}
my $warm_budget=Loomy::TestTiming::budget(0.150);
die sprintf "warm reducer/frame %.3f ms CPU (budget <%.3f ms)\n",1000*$max,1000*$warm_budget if $max>=$warm_budget;
printf "50,000 events/10,000 sources: 50 warm reducer frames max %.3f ms CPU (budget <%.3f ms), zero history reads\n",1000*$max,1000*$warm_budget;
# Pending directory discovery must prioritize a new old-date file over a cold backlog.
open my $late,'>',"$sources/2020/01/01/rollout-00000-late.jsonl" or die;
print $late encode_json({type=>'session_meta',timestamp=>$ts,payload=>{id=>'late',cwd=>$root,source=>'cli',timestamp=>$ts}}),"\n",
    encode_json({type=>'event_msg',timestamp=>$ts,payload=>{type=>'task_started',turn_id=>'late-turn'}}),"\n"; close $late;
my $started=time; die 'old-date new source missed' unless Loomy::CodexNative::watch_changed($root,$sources,$now);
$state=Loomy::CodexNative::poll($root,$sources); $view->read_journal("$logs/events.jsonl"); $view->source_evidence($state);
die 'new source invisible in declared envelope' unless grep {/N\|G\|codex:late\|.*running/} $view->projections($now);
my $latency=time-$started; my $latency_budget=Loomy::TestTiming::budget(1);
die sprintf "new source latency %.3f ms (budget <%.3f ms)\n",1000*$latency,1000*$latency_budget if $latency>=$latency_budget;
printf "new old-date source in 10,000-file directory: %.3f ms (budget <%.3f ms)\n",1000*$latency,1000*$latency_budget;
