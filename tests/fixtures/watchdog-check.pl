# A stalled process and a TERM-resistant descendant cannot outlive the watchdog.
use strict;
use warnings;
use Time::HiRes qw(time sleep);
my ($repo,$work)=@ARGV;
my $begin=time;
my $rc=system($^X,"$repo/tests/fixtures/watchdog.pl",1,$^X,'-e',q{
    my $f=shift; $SIG{TERM}='IGNORE';
    my $child=fork; die $! unless defined $child;
    if (!$child) {sleep 60; exit}
    open my $h,'>',$f or die $!; print {$h} "$$ $child\n"; close $h;
    sleep 60;
},"$work/watchdog-pids");
die "watchdog did not report timeout: $rc\n" unless $rc>>8==124 && time-$begin<6;
open my $f,'<',"$work/watchdog-pids" or die $!; my @pids=split /\s+/,<$f>; close $f;
# An orphan may briefly be a zombie until init reaps it; it cannot execute anymore.
if (($ENV{LOOMY_TEST_WATCH_PS}//1) ne '0' && system('ps -p $$ >/dev/null 2>&1')==0) {
open my $ps,'-|','ps','-axo','pid=,stat=' or die $!; my %state=map {/^\s*(\d+)\s+(\S+)/; $1=>$2} <$ps>; close $ps;
die "watchdog left a running descendant\n" if grep {exists($state{$_}) && $state{$_}!~/^Z/} @pids;
} else {print "SKIP watchdog ps check (explicit sandbox opt-out)\n"}
print "ok watchdog: deadline reported (124); process group sent TERM/KILL\n";
system($^X,"$repo/tests/fixtures/watchdog.pl",5,$^X,'-e','exit 7');
die "watchdog changed failure status\n" unless $?>>8==7;
print "ok watchdog: command failure status preserved\n";
system($^X,"$repo/tests/fixtures/watchdog.pl",1,'bash','-c',q{
    set -eu
    scratch=$(mktemp -d "$1/tmp/loomy-watchdog-trap.XXXXXX")
    trap 'rm -rf "$scratch"' EXIT
    trap 'exit 143' TERM HUP
    sleep 60
},'_',$work);
die "watchdog did not bound trapped shell\n" unless $?>>8==124;
die "watchdog timeout left a temporary directory\n" if glob "$work/tmp/loomy-watchdog-trap.*";
print "ok watchdog: timed-out shell EXIT trap removes temporary directory\n";

# SIGINT reaches the watchdog controller and preserves interrupt status.
my $controller=fork; die $! unless defined $controller;
if (!$controller) {exec $^X,"$repo/tests/fixtures/watchdog.pl",30,$^X,'-e','sleep 60'; die $!}
sleep 0.3; kill 'INT',$controller; waitpid($controller,0);
die "F13: interrupt was swallowed" unless $?>>8==130;
# A killed Tcl wrapper cannot own the cleanup; its Perl supervisor does.
my $cleanup="$work/tmp/loomy-expect.F13"; mkdir $cleanup or die $!;
{local $ENV{LOOMY_WATCHDOG_CLEANUP}=$cleanup;
 system($^X,"$repo/tests/fixtures/watchdog.pl",1,$^X,'-e','sleep 60');
 die "F13: nested temporary directory leaked" if -d $cleanup;
}
print "PASS F13 watchdog: interrupt status, per-step/suite deadlines, nested cleanup\n";
# The suite keeps its terminal; only an Expect-owned PTY shares the supervisor's group.
{
    local $ENV{LOOMY_HOME}=$repo;
    my $script=q{
        log_user 0
        set timeout 6
        set watchdog [file join $env(LOOMY_HOME) tests fixtures watchdog.pl]
        spawn env LOOMY_WATCHDOG_PTY=1 perl $watchdog 5 bash -c {echo READY; read -r reply; echo GOT:$reply; read -r again}
        expect READY
        send "q\r"
        expect {
            -re {GOT:q} {}
            eof {exit 1}
            timeout {exit 2}
        }
        send "\003"
        expect {
            eof {}
            timeout {exit 3}
        }
        set result [wait]
        if {[lindex $result 3] != 130} {exit 4}
    };
    system('expect','-c',$script);
    die "F13: dedicated PTY read/interrupt failed: $?" if $?;
}
print "PASS F13 dedicated PTY: keyboard read and Ctrl-C reach supervisor (130)\n";
