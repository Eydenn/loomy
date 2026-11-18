# `loomy doctor --fix`: take clone-shipped runtime state out of the Git index (files stay on disk).
# Only entries the gate itself reports (Loomy::RuntimePaths::tracked_runtime_paths: the exact raw index paths, byte for
# byte, including spellings the filesystem folds onto .loomy/logs) are touched, with raw paths as argv, never through
# a shell, and as literal pathspecs. Hardened Git (no fsmonitor, no hooks, GIT_* cleared, no lazy fetch).
# Output (tab separated, fixed codes): "none", "error<TAB>timeout|index-error|failed", or
# "removed<TAB>count<TAB>up to 3 displayable paths". Idempotent: a second run reports "none".
use strict;
use warnings;
use Cwd qw(abs_path);
use POSIX ();
my ($root)=@ARGV; $root=abs_path($root//".")//exit 1;
my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+\z}{};
require "$lib/runtime-paths.pl";
my $ctx=eval { Loomy::RuntimePaths::resolve($root) };
$root=$ctx->{root} if ref($ctx) eq "HASH" && defined $ctx->{root};
my ($hits,$why)=Loomy::RuntimePaths::tracked_runtime_paths($root,20);
if ($why eq "timeout" || $why eq "index-error") { print "error\t$why\n"; exit 1 }
unless (@$hits) { print "none\n"; exit 0 }
delete @ENV{grep {/\AGIT_/} keys %ENV}; $ENV{GIT_NO_LAZY_FETCH}=1;
my @paths=@$hits;
while (my @chunk=splice @paths,0,200) {
    my $pid=fork; unless (defined $pid) { print "error\tfailed\n"; exit 1 }
    if (!$pid) {
        open STDOUT,">","/dev/null" or POSIX::_exit(1); open STDERR,">","/dev/null" or POSIX::_exit(1);
        exec("git","-c","core.fsmonitor=false","-c","core.hooksPath=/dev/null","-C",$root,"--literal-pathspecs","rm","-r","--cached","--quiet","--",@chunk) or POSIX::_exit(1);
    }
    waitpid($pid,0); if ($? != 0) { print "error\tfailed\n"; exit 1 }
}
# What the gate still reports after the removal means it did not work: never claim success.
my ($left,$why2)=Loomy::RuntimePaths::tracked_runtime_paths($root,20);
if ($why2 ne "" || @$left) { print "error\tfailed\n"; exit 1 }
my @show=grep {/\A[A-Za-z0-9._\/-]{1,120}\z/} @$hits; @show=@show[0..2] if @show>3;
print "removed\t".scalar(@$hits)."\t".join(", ",@show)."\n";
