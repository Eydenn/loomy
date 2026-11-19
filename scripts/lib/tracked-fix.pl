# `loomy doctor --fix`: take clone-shipped runtime state out of the Git index (files stay on disk).
# Only entries the gate itself reports (Loomy::RuntimePaths::tracked_runtime_paths: the exact raw index paths, byte for
# byte, including spellings the filesystem folds onto .loomy/logs) are touched, with raw paths on stdin (NUL separated), never
# through a shell, and as literal pathspecs. Hardened Git (no fsmonitor, no hooks, GIT_* cleared, no lazy fetch).
# Untracking alone would leave the shipped files in place, and the next gate would allow them and trust them (a
# content-policy.conf pre-granting consent, checkpoints, labels). So every reported regular file or symlink is first
# copied into a per-user quarantine, ${XDG_STATE_HOME:-$HOME/.local/state}/loomy/quarantine/<sha256 of the root>/<UTC time>/
# (every level 0700, files 0600, no symlink ever followed), then untracked, then removed from the project; a tracked
# symlink is removed, not followed (the journal, events.jsonl and archive/*.jsonl, is the user's own history: untracked, kept in place). A user who committed their own logs by mistake can copy them back from there.
# Output (tab separated, fixed codes): "none", "error<TAB>timeout|index-error|failed|quarantine", or
# "removed<TAB>count<TAB>up to 3 displayable paths<TAB>quarantine directory or -". Idempotent: a second run reports "none".
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA ();
use Fcntl ();
use POSIX ();
my ($root)=@ARGV; $root=abs_path($root//".")//exit 1;
my $lib=abs_path(__FILE__); $lib =~ s{/[^/]+\z}{};
require "$lib/runtime-paths.pl";
my $ctx=eval { Loomy::RuntimePaths::resolve($root) };
$root=$ctx->{root} if ref($ctx) eq "HASH" && defined $ctx->{root};
my ($hits,$why,$links)=Loomy::RuntimePaths::tracked_runtime_paths($root,20);
if ($why eq "timeout" || $why eq "index-error") { print "error\t$why\n"; exit 1 }
unless (@$hits) { print "none\n"; exit 0 }
# A submodule (gitlink) standing for .loomy or .loomy/logs, or anything under them, may have been checked out by a
# recursive clone with files of its own: it is never untracked automatically while it is on disk. The user deletes the
# directory, then runs the fix again (the index entry alone is then removed).
{ my @present=grep { lstat("$root/$_") } @{$links//[]};
  if (@present) { my ($n)=grep {/\A[A-Za-z0-9._\/-]{1,120}\z/} @present; print "error\tgitlink\t".($n//"-")."\n"; exit 1 } }
# Quarantine directory (created only when something is to be moved). Same rule as the gate's cache directory: the state
# base must not be group or world writable (refused), a level of ours below it is tightened to 0700, every level a real
# directory of ours; the files are then created relative to the final directory, pinned by chdir and re-checked by stat.
# Returns the path or undef (the caller prints the failure line).
sub _quarantine_dir {
    my $home=$ENV{HOME}; my $base=$ENV{XDG_STATE_HOME};
    $base=(defined $home && $home =~ m{\A/}) ? "$home/.local/state" : undef unless defined $base && $base =~ m{\A/};
    return unless defined $base; $base =~ s{/+\z}{};
    my $old=umask 0077; my $cur=""; my $res;
    $res=eval {
        my @parts=grep {length} split m{/},$base;
        for my $i (0..$#parts) {   # missing ancestors of the state directory are created 0700
            my $next="$cur/$parts[$i]"; my @s=lstat($next);
            if (!@s) { mkdir($next,0700) or die "mkdir\n"; @s=lstat($next) }
            if (-l _) { my @t=stat($next); die "link\n" unless @t && -d _ }
            elsif (!-d _) { die "notdir\n" }
            if ($i==$#parts) { my @t=stat($next); die "writable\n" unless @t && -d _ && $t[4]==$< && !($t[2]&022) }   # the state base itself: not group or world writable
            $cur=$next;
        }
        my @levels=("loomy","quarantine",Digest::SHA::sha256_hex($_[0]),POSIX::strftime("%Y%m%dT%H%M%SZ",gmtime));
        for my $i (0..$#levels) {
            my $next="$cur/$levels[$i]"; my @s=lstat($next);
            if (!@s) { mkdir($next,0700) or die "mkdir\n"; @s=lstat($next) }
            elsif ($i==$#levels) { $next.="-$$"; mkdir($next,0700) or die "mkdir\n"; @s=lstat($next) }
            die "level\n" unless @s && -d _ && !-l _ && $s[4]==$<;
            if ($s[2]&022) { chmod(0700,$next) or die "chmod\n"; @s=lstat($next); die "level\n" unless @s && !($s[2]&022) }
            $cur=$next;
        }
        my @pin=lstat($cur); chdir($cur) or die "chdir\n"; my @here=stat(".");
        die "pin\n" unless @pin && @here && $pin[0]==$here[0] && $pin[1]==$here[1] && $here[4]==$< && !($here[2]&022);
        $cur;
    };
    umask $old; return $res;
}
# The regular files and symlinks among the reported paths, safe to move: every parent a real directory (never a
# symlink), nothing outside the project. Directories (a gitlink standing for .loomy/logs) are left alone.
my @moves;
for my $h (@$hits) {
    next if $h =~ m{\A/} || $h =~ /\0/ || grep {$_ eq ".." || $_ eq "."} split m{/},$h;
    my @parts=split m{/},$h; my $leaf=pop @parts; my $d=$root; my $ok=1;
    for my $c (@parts) { $d.="/$c"; my @s=lstat($d); unless (@s && -d _ && !-l _) { $ok=0; last } }
    next unless $ok;
    my @s=lstat("$root/$h"); next unless @s;
    # The journal is the user's own history: untracked, kept in place (data, not state Loomy trusts), but only a real regular
    # file; a tracked link standing there is removed like any other hit (it would keep journaling off and be followed by readers).
    next if $h =~ m{\A\.loomy/logs/(?:events\.jsonl|archive/[^/]+\.jsonl)\z} && -f _ && !-l _;
    next unless -f _ || -l _;
    push @moves,[$h,"$root/$h",(-l _ ? "link" : "file"),$s[0],$s[1]];
}
my $qdir;
if (@moves) {
    $qdir=_quarantine_dir($root); unless (defined $qdir) { print "error\tquarantine\n"; exit 1 }
    my ($n,@index)=(0);
    for my $m (@moves) {
        $n++; (my $safe=$m->[0]) =~ s{.*/}{}; $safe =~ s/[^A-Za-z0-9._-]/_/g; $safe=substr($safe,0,80);
        (my $shown=$m->[0]) =~ s/[^\x20-\x7e]/?/g;
        if ($m->[2] eq "link") { my $t=readlink($m->[1]); $t="?" unless defined $t; $t =~ s/[^\x20-\x7e]/?/g; push @index,"$n\t$shown\t(symlink to $t, removed)"; next }
        my $dest=sprintf("%03d",$n)."-$safe";   # relative: the quarantine directory is the pinned cwd
        my $old=umask 0077;
        my $ok=sysopen(my $in,$m->[1],Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK());
        my @fs=$ok ? stat($in) : ();
        $ok=0 unless @fs && -f $in && $fs[0]==$m->[3] && $fs[1]==$m->[4];
        if ($ok) {
            $ok=sysopen(my $out,$dest,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_NOFOLLOW(),0600);
            if ($ok) {
                while (1) { my $r=sysread($in,my $buf,65536); unless (defined $r) {$ok=0; last} last unless $r;
                    my $off=0; while ($off<$r) { my $w=syswrite($out,$buf,$r-$off,$off); unless (defined $w) {$ok=0; last} $off+=$w } last unless $ok }
                $ok=0 unless close $out;
            }
        }
        umask $old;
        unless ($ok) { print "error\tquarantine\n"; exit 1 }
        push @index,"$n\t$shown";
    }
    my $old=umask 0077;
    if (sysopen(my $ix,"paths.txt",Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_NOFOLLOW(),0600)) { print $ix map {"$_\n"} @index; close $ix }
    umask $old;
}
delete @ENV{grep {/\AGIT_/} keys %ENV}; $ENV{GIT_NO_LAZY_FETCH}=1;
my @paths=@$hits;
# update-index --force-remove drops exactly the named index entries: no work-tree read, no clean filter, no descendant
# removal (a gitlink or symlink standing for .loomy never untracks the .loomy/memory entries), works on MM entries.
while (my @chunk=splice @paths,0,200) {
    my $pid=open(my $git,"|-"); unless (defined $pid) { print "error\tfailed\n"; exit 1 }
    if (!$pid) {
        open STDOUT,">","/dev/null" or POSIX::_exit(1); open STDERR,">","/dev/null" or POSIX::_exit(1);
        exec("git","-c","core.fsmonitor=false","-c","core.hooksPath=/dev/null","-C",$root,"--literal-pathspecs","update-index","--force-remove","-z","--stdin") or POSIX::_exit(1);
    }
    local $SIG{PIPE}="IGNORE";
    my $sent=print $git map {"$_\0"} @chunk; my $closed=close $git;
    if (!$sent || !$closed || $? != 0) { print "error\tfailed\n"; exit 1 }
}
# What the gate still reports after the removal means it did not work: never claim success.
my ($left,$why2)=Loomy::RuntimePaths::tracked_runtime_paths($root,20);
if ($why2 ne "" || @$left) { print "error\tfailed\n"; exit 1 }
# Only now that nothing tracked is left: the shipped files leave the project (a tracked symlink is unlinked, never followed).
for my $m (@moves) {
    my @s=lstat($m->[1]); next unless @s;
    unless ($s[0]==$m->[3] && $s[1]==$m->[4] && unlink($m->[1])) { print "error\tquarantine\n"; exit 1 }
}
my @show=grep {/\A[A-Za-z0-9._\/-]{1,120}\z/} @$hits; @show=@show[0..2] if @show>3;
my $qshow=defined $qdir && $qdir =~ m{\A[\x20-\x7e]+\z} ? $qdir : "-"; $qshow =~ s/\t/ /g;
print "removed\t".scalar(@$hits)."\t".join(", ",@show)."\t$qshow\n";
