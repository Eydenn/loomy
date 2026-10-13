# Portable deadline for a test command and its process group (no timeout(1) on macOS).
use strict;
use warnings;
use POSIX qw(setpgid WNOHANG _exit);
use Time::HiRes qw(time sleep);
use File::Path qw(remove_tree);
my $cleanup=delete($ENV{LOOMY_WATCHDOG_CLEANUP})//'';
END {remove_tree($cleanup) if $cleanup =~ m{^/[^\n]*?/loomy-expect\.[A-Za-z0-9]+$} && -d $cleanup && !-l $cleanup}

my $limit=shift @ARGV;
die "usage: watchdog.pl seconds command [args...]\n" unless $limit && $limit=~/^\d+(?:\.\d+)?$/ && @ARGV;

my $pty=($ENV{LOOMY_WATCHDOG_PTY}//'0') eq '1' && -t STDIN && getpgrp(0)==$$;
$SIG{TTOU}='IGNORE';
pipe my $ready,my $go or die $!;
my $pid=fork; die $! unless defined $pid;
if (!$pid) {
    close $go;
    my $group=$pty ? 0 : setpgid(0,0);
    die "watchdog setpgid: $!" unless defined($group) || getpgrp(0)==$$;
    # Parent releases the child after installing its signal handlers.
    scalar <$ready>;
    close $ready;
    # The suite retains foreground ownership so Ctrl-C reaches its signal traps.
    $SIG{TTOU}='IGNORE';
    $SIG{$_}='DEFAULT' for qw(INT TERM HUP);
    exec @ARGV or die "watchdog exec $ARGV[0]: $!";
}
close $ready;
eval {setpgid($pid,$pid)} unless $pty;
my $group=$pty ? getpgrp(0) : $pid;

print {$go} "go\n"; close $go;
my ($expired,$signal)=(0,'');
$SIG{ALRM}=sub {$expired=1};
$SIG{$_}=sub {$signal=$_[0]} for qw(TERM HUP INT);
alarm int($limit+0.999);
my $status;
while (1) {
    my $done=waitpid($pid,WNOHANG);
    if ($done==$pid) {$status=$?; last}
    last if $expired || $signal;
    sleep 0.02;
}
alarm 0;
if ($expired || $signal) {
    warn "WATCHDOG: $ARGV[0] exceeded ${limit}s; terminating process group $pid\n" if $expired;
    # A requested signal belongs to the controller; give its own child-reaping trap time to run.
    # On deadline the whole group is stopped immediately, including a wedged controller.
    kill($signal || 'TERM',$expired && !$pty ? -$group : $pid);
    my $end=time+($expired ? 2 : 8);
    while (time<$end && !defined($status)) {
        if (waitpid($pid,WNOHANG)==$pid) {$status=$?; last}
        sleep 0.02;
    }
}
# A dedicated Expect PTY keeps supervisor and command in its foreground group.
# Reap that group after the supervisor exits, preserving its status and cleanup END block.
if ($pty) {
    pipe my $death,my $life or die $!;
    my $reaper=fork; die $! unless defined $reaper;
    if (!$reaper) {
        close $life; setpgid(0,0); close STDIN; close STDOUT; close STDERR;
        $SIG{$_}='DEFAULT' for qw(INT TERM HUP);
        scalar <$death>; close $death;
        kill 'TERM',-$group; sleep 0.5; kill 'KILL',-$group; _exit(0);
    }
    close $death;
    # Keep the pipe alive until interpreter exit, including lexical scope cleanup.
    $SIG{$_}='IGNORE' for qw(INT TERM HUP);
    kill 'TERM',-$group;
    waitpid($pid,0) unless defined $status;
    exit 124 if $expired;
    exit($signal eq 'INT' ? 130 : $signal eq 'HUP' ? 129 : 143) if $signal;
    exit($status & 127 ? 128+($status & 127) : $status>>8);
}
kill 'TERM',-$group;
my $end=time+0.5;
while (kill(0,-$group) && time<$end) {sleep 0.02}
kill 'KILL',-$group;
waitpid($pid,0) unless defined $status;

exit 124 if $expired;
exit($signal eq 'INT' ? 130 : $signal eq 'HUP' ? 129 : 143) if $signal;
exit($status & 127 ? 128+($status & 127) : $status>>8);
