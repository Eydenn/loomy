# Non-PTY integration bound; Mac PTY assertions remain a separate acceptance gate.
use strict;
use warnings;
use IO::Select;
use IPC::Open3;
use Symbol qw(gensym);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);
my ($repo,$root,$sessions)=@ARGV;
my ($in,$out,$err); $err=gensym;
local $ENV{COLUMNS}=170; local $ENV{LINES}=65;
my $pid=open3($in,$out,$err,$^X,"$repo/tests/fixtures/watchdog.pl",60,'bash',"$repo/scripts/loomy-status.sh",'--root',$root,'--watch','--full');
# Keep controller stdin open until q; EOF is now an explicit watch exit.
my $select=IO::Select->new($out,$err);
my ($buf,$max)=('',0);
sub await_row {
    my ($pattern,$deadline)=@_;
    while (clock_gettime(CLOCK_MONOTONIC)<$deadline) {
        for my $h ($select->can_read(0.02)) {
            my $n=sysread($h,my $chunk,65536);
            if (!$n) { $select->remove($h); next }
            $buf.=$chunk; die 'unexpected large frame backlog' if length($buf)>2097152;
            return if $buf =~ $pattern;
        }
    }
    die "visible row deadline exceeded\n";
}
my $ok=eval {
    await_row(qr/consolidation[^\n]*running/,clock_gettime(CLOCK_MONOTONIC)+10);
    for my $trial (30..49) {
        sleep(rand(0.24)); $buf='';
        my ($elapsed,$visible);
        for my $attempt (1..2) {
            $buf='';
            my $start=clock_gettime(CLOCK_MONOTONIC);
            system($^X,"$repo/tests/fixtures/codex-native.pl",'live-child',$root,$sessions,$trial)==0 or die 'fixture write failed';
            $visible=eval {await_row(qr/latency$trial[^\n]*running[^\n]*\n/,$start+5); 1};
            $elapsed=clock_gettime(CLOCK_MONOTONIC)-$start;
            last if $visible;
            warn "frame trial $trial retry after: $@" if $attempt==1;
        }
        die "frame trial $trial failed after retry\n" unless $visible;
        $max=$elapsed if $elapsed>$max;
    }
    1;
};
my $error=$@;
print {$in} "q\n" if $ok; close $in;
kill 'TERM',$pid unless $ok;
waitpid($pid,0);
die "watch controller failed: $?\n" if $ok && $?;
die $error unless $ok;
printf "20 watch frame trials: maximum %.3f s (<5 s, one retry); Mac PTY still required\n",$max;
