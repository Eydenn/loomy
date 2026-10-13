# Assert controller exits and reap the exact persistent children observed with ps.
use strict;
use warnings;
use IPC::Open3;
use IO::Select;
use Symbol qw(gensym);
use POSIX qw(WNOHANG);
use Time::HiRes qw(time sleep);
my ($repo,$root)=@ARGV;
my ($watch,$owner,$in,$out,$err);
my @children;
my $use_ps=($ENV{LOOMY_TEST_WATCH_PS}//1) ne "0";
sub processes {
    open my $ps,'-|','ps','-axo','pid=,ppid=,command=' or die $!;
    my @rows=<$ps>; close $ps;
    return @rows;
}
END {
    my $saved=$?;
    close $in if $in;
    kill 'KILL',grep {$_} ($watch,$owner,@children);
    waitpid($watch,0) if $watch;
    waitpid($owner,0) if $owner;
    $?=$saved;
}
$SIG{ALRM}=sub {die "watch exit regression exceeded 60 s\n"}; alarm 60;
if ($use_ps && !eval {processes(); 1}) {$use_ps=0; print "SKIP ps inventory (sandbox); require child-pipe EOF and feed cleanup\n"}
for my $mode (qw(until-exit TERM HUP EOF q KILL)) {
    $owner=fork; die $! unless defined $owner;
    if (!$owner) {sleep 60; POSIX::_exit(0)}
    $err=gensym;
    $watch=open3($in,$out,$err,'bash',"$repo/scripts/loomy-status.sh",'--root',$root,'--watch',
        ($mode eq 'until-exit' ? ('--until-exit',$owner) : ()));
    my $select=IO::Select->new($out,$err);
    my $buf="";
    my $drain=sub {
        for my $h ($select->can_read(0.02)) {
            my $n=sysread($h,my $bytes,65536); $select->remove($h) unless $n; $buf.=$bytes if $n;
        }
    };
    @children=(); my $end=time+10;
    while (time<$end) {
        @children=map {/^\s*(\d+)/; $1} grep {/^\s*\d+\s+$watch\s+.*perl -MIO::Select/} processes() if $use_ps;
        last if $use_ps ? @children==2 : $buf=~/AGENT TREE/;
        $drain->();
    }
    die "$mode: two persistent Perl children not observed\n" unless $use_ps ? @children==2 : $buf=~/AGENT TREE/;
    if ($mode eq 'until-exit') {kill 'TERM',$owner; waitpid($owner,0); $owner=undef}
    elsif ($mode eq 'EOF') {close $in; $in=undef}
    elsif ($mode eq 'q') {print {$in} "q\n"}
    else {kill $mode,$watch}
    $end=time+5; my $done=0;
    while (time<$end) {
        if (waitpid($watch,WNOHANG)==$watch) {$done=1; last}
        $drain->();
    }
    die "$mode: watch did not exit within five seconds\n" unless $done;
    die "$mode: watch failed ($?)\n" if $mode eq "KILL" ? ($? & 127)!=9 : $?;
    $watch=undef;
    $end=time+4;
    while ($select->count && time<$end) {$drain->()}
    die "$mode: child output descriptors survived controller exit\n" if $select->count;
    die "$mode: feed directory survived\n" if glob "$ENV{TMPDIR}/loomy-watch-feed.*";
    my %left=$use_ps ? map {/^\s*(\d+)/; $1=>1} processes() : ();
    die "$mode: persistent child survived: @children\n" if grep {$left{$_}} @children;
    @children=(); close $in if $in; $in=undef; close $out; close $err;
    kill 'TERM',$owner if $owner; waitpid($owner,0) if $owner; $owner=undef;
    print +($mode eq "KILL" ? "PASS F4 " : "ok "),"watch $mode: exit <=5 s",($use_ps ? "; sampler/coalescer absent from ps" : "; SKIP ps (explicit sandbox opt-out)"),"\n";
}
alarm 0;
