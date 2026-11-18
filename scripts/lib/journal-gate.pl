# Leak barrier for the journal directory (.loomy/logs). Runtime state tracked in the Git index (a clone can ship it)
# must never be written into: a later `git commit -a` would publish private events. Every journal write (the shared
# append in live-state.pl, the preparation in journal.sh, the small log writers) asks check() first.
# The verdict is answered from a private cache file (.loomy/logs/gate-v1: verdict keyed on the index stat, the
# .loomy and .loomy/logs identity, the resolved Git directory) so the common case costs three stats and a small read,
# no Git. Not a repository: nothing to track. A Git that cannot answer is a refusal (fail closed); that refusal is
# cached for 30 s so each hook does not rerun `git ls-files`. Nothing is cached when logs does not exist yet, when the
# Git directory is not a valid repository, or when the index changed in the last 2 s (racily clean). An uncached
# answer is kept 2 s in the process, so a long-lived writer does not spawn Git per write.
package Loomy::JournalGate;
use strict;
use warnings;
use Fcntl ();
use Time::HiRes ();
my $REFUSAL_TTL=30; my %memo;
my $LIB=__FILE__; $LIB =~ s{/[^/]+\z}{};
sub _root {
    my $dir=shift; my $root=$dir; $root =~ s{/\.loomy/logs\z}{} or return;
    unless ($root =~ m{\A/}) { require Cwd; $root=Cwd::getcwd()."/$root"; $root =~ s{/\.(?=/|\z)}{}g }
    return $root;
}
sub _ident {
    my ($root,$dir,$idx)=@_; my @a=lstat("$root/.loomy"); my @b=lstat($dir);
    return join("|","v1",$idx,join(",",@a[0,1]),join(",",@b[0,1]));
}
# ($key,$value) of the cache file, or ().
sub _read {
    my $path=shift; sysopen(my $h,$path,Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()) or return;
    my @s=stat($h); return unless @s && -f $h && $s[4]==$< && $s[7]<=1024;
    sysread($h,my $raw,1025); my ($k,$v)=split /\n/,$raw; return unless defined $k && defined $v;
    return ($k,$v);
}
# A directory Git itself would accept: HEAD, objects and refs, here or in the common directory of a worktree.
sub _valid_gitdir {
    my $gd=shift; return 0 unless -f "$gd/HEAD";
    return 1 if -d "$gd/objects" && -d "$gd/refs";
    sysopen(my $h,"$gd/commondir",Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()) or return 0;
    sysread($h,my $raw,4097); return 0 unless defined $raw && $raw =~ /\A([^\n]+?)\r?\n?\z/ && length($raw)<=4096;
    my $c=$1; $c="$gd/$c" unless $c =~ m{\A/}; return 0 if $c =~ /[\x00-\x1f\x7f]/;
    return -f "$c/HEAD" && -d "$c/objects" && -d "$c/refs" ? 1 : 0;
}
sub _index {
    my $root=shift; my $d=$root; my $top;
    while (1) { if (lstat("$d/.git")) {$top=$d; last} last if $d eq "" || $d eq "/"; $d =~ s{/[^/]*\z}{}; }
    return (1,undef) unless defined $top;   # not a repository
    my @g=lstat("$top/.git"); my $gd;
    if (-d _ && !-l _) { $gd="$top/.git" }
    elsif (-f _ && sysopen(my $h,"$top/.git",Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW())) {
        sysread($h,my $raw,4097); $gd=$1 if $raw =~ /\Agitdir: ([^\n]+?)\r?\n?\z/ && length($raw)<=4096;
        $gd="$top/$gd" if defined $gd && $gd !~ m{\A/}; undef $gd unless defined $gd && $gd !~ /[\x00-\x1f\x7f]/ && -d $gd;
    }
    return (0,undef) unless defined $gd && _valid_gitdir($gd);   # unusual or invalid layout: ask Git every time
    my @i=stat("$gd/index"); return (0,undef) if @i && time-$i[9]<2;
    return (0,"$top|$gd|".(@i ? join(",",@i[0,1,7,9,10]) : "none"));
}
# Returns (allowed, [file key, file value] to store or undef). No memo, no side effect.
sub verdict {
    my ($dir,$fresh)=@_; my $root=_root($dir) or return (1,undef);
    my ($norepo,$idx)=_index($root); return (1,undef) if $norepo;
    my $existed=-d $dir && !-l $dir;   # a verdict taken while logs is absent is never stored
    my $now=time; my $key=($existed && defined $idx) ? _ident($root,$dir,$idx) : undef;
    my $refkey=$existed ? _ident($root,$dir,"-") : undef;
    if ($existed && !$fresh) {
        my ($k,$v)=_read("$dir/gate-v1");
        if (defined $k) {
            if (defined $refkey && $k eq $refkey && $v =~ /\Arefused (\d+)\z/ && $1>=$now && $1<=$now+$REFUSAL_TTL) { return (0,undef) }
            if (defined $key && $k eq $key) { return (1,undef) if $v eq "ok"; return (0,undef) if $v eq "tracked" }
        }
    }
    my ($path,$why)=eval { require "$LIB/runtime-paths.pl"; Loomy::RuntimePaths::tracked_runtime($root) };
    $why="index-error" unless defined $why;
    if ($why eq "timeout" || $why eq "index-error") { return (0,$existed ? [$refkey,"refused ".($now+$REFUSAL_TTL)] : undef) }
    my $allowed=$why eq "tracked" ? 0 : 1;
    return ($allowed,defined $key ? [$key,$allowed ? "ok" : "tracked"] : undef);
}
sub store {
    my ($dir,$s)=@_; return unless $s && -d $dir && !-l $dir;
    my $tmp="$dir/gate-v1.$$"; my $old=umask 0077;
    if (sysopen(my $h,$tmp,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_NOFOLLOW(),0600)) {
        my $ok=syswrite($h,"$s->[0]\n$s->[1]\n"); close $h;
        if ($ok) { rename($tmp,"$dir/gate-v1") or unlink $tmp } else { unlink $tmp }
    }
    umask $old;
}
# The question every journal writer asks: may this logs directory be written?
sub check {
    my $dir=shift; my $m=$memo{$dir}; return $m->[1] if $m && Time::HiRes::time()<$m->[0];
    my ($allowed,$s)=verdict($dir); store($dir,$s) if $s;
    $memo{$dir}=[Time::HiRes::time()+2,$allowed] unless $s;
    return $allowed;
}
1;
