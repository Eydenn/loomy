# Measure detection/read/projection CPU independently of scheduling and shell startup.
use strict;
use warnings;
use Time::HiRes qw(clock_gettime CLOCK_PROCESS_CPUTIME_ID);
my ($repo,$root,$projects)=@ARGV;
require "$repo/scripts/lib/claude-native.pl";
require "$repo/scripts/lib/live-state.pl";
my $live=Loomy::LiveState->new;
sub detect {
    my $changed=Loomy::ClaudeNative::watch_changed($root,$projects);
    my $state=Loomy::ClaudeNative::poll($root,$projects);
    $live->read_journal("$root/.loomy/logs/events.jsonl");
    $live->claude_evidence($state);
    return ($changed,$live->projections($ENV{LOOMY_NATIVE_NOW}));
}
detect() for 1..3;
my $max=0;
for my $trial (30..69) {
    my $hook=$trial>=50; my $passed;
    for my $attempt (0..1) {
        my $id=$trial+$attempt*100;
        my $role=($hook ? 'hook' : 'latency').$id;
        system($^X,"$repo/tests/fixtures/claude-native.pl",$hook ? 'live-hook' : 'live-child',
            $root,$projects,'app',1,$id)==0 or die 'fixture write failed';
        my $begin=clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
        my ($changed,@rows)=detect();
        my $elapsed=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$begin;
        die "new $role projection absent\n" unless $changed && grep {/\|\Q$role\E\|/} @rows;
        if ($elapsed<0.08) {$passed=1; $max=$elapsed if $elapsed>$max; last}
        warn "$role: detection CPU ${elapsed}s, retrying fresh trial\n" unless $attempt;
    }
    die "trial $trial detection/read/projection exceeds 80 ms CPU after retry\n" unless $passed;
    detect() for 1..2;
}
printf "40 detection/read/projection trials: max %.3f ms CPU (<80 ms, one retry)\n",$max*1000;
