# Content-free, bounded watch diagnostics, shared by the sampler and Bash ERR trap.
package Loomy::WatchErrors;
use strict;
use warnings;
use Fcntl qw(O_RDWR O_APPEND O_CREAT O_NOFOLLOW LOCK_EX);
use POSIX qw(strftime);
use Cwd qw(abs_path);
sub record {
    my ($path,$stage,$kind)=@_;
    return if !$path || $path eq '/dev/null' || ($ENV{LOOMY_JOURNAL}//1) eq '0';
    # A project may be reached through a symlink; links inside its private tree remain refused.
    return unless $path =~ m{\A(.*?)(/\.loomy/.*)\z};
    my ($root,$suffix)=(abs_path($1),$2); return unless defined $root;
    $path="$root$suffix";
    my $parent=$path;
    while ($parent ne '') { return if -l $parent; $parent =~ s{/[^/]*$}{} }
    $stage='internal' unless ($stage//'') =~ /\A[a-z-]{1,40}\z/;
    $kind='error' unless ($kind//'') =~ /\A[a-z-]{1,40}\z/;
    my $line=strftime('%Y-%m-%dT%H:%M:%SZ',gmtime)." watch $stage $kind\n";
    sysopen my $f,$path,O_RDWR|O_APPEND|O_CREAT|O_NOFOLLOW,0600 or return;
    flock $f,LOCK_EX or return; chmod 0600,$f or return;
    truncate $f,0 if -s $f>65536-length($line);
    print $f $line;
}
record(@ARGV) unless caller;
1;
