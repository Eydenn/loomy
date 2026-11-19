# Leak barrier for the journal directory (.loomy/logs). Runtime state tracked in the Git index (a clone can ship it)
# must never be written into: a later `git commit -a` would publish private events. Every journal write (the shared
# append in live-state.pl, the preparation in journal.sh, the small log writers) asks check() first.
# An "ok" verdict is answered from a private cache file (.loomy/logs/gate-v1: sha256 of a key made of the index stat,
# the .loomy and .loomy/logs identity and the resolved Git directory; no path or inode is stored in clear) so the common
# case costs three stats and a small read, no Git. Only "ok" is ever stored in the project: a tracked or refused verdict
# never writes into a tracked or refused logs directory. Not a repository: nothing to
# track. A Git that cannot answer is a refusal (fail closed); that refusal is remembered 30 s by an empty marker file
# outside the project (per-user cache directory, named by sha256 of the project root) so each hook does not rerun
# `git ls-files`; the marker is dropped by the next conclusive verdict. A tracked verdict is cached in the same
# per-user directory in one file per project root (t-<sha256 root>, the verdict key inside, so any index or identity
# change invalidates it), never in the project; the ok verdict of an aliased .loomy or logs (a linked worktree) is cached
# there too (o-<sha256 root>), never through the alias. Cache files are written by temp file and rename and read
# no-follow, non-blocking, regular, ours, one link. A group/world writable cache base is not used (memo only). A directory
# that is not exactly <root>/.loomy/logs is refused. Nothing is cached when logs does not exist yet,
# when the Git directory is not a valid repository, or when the index changed in the last 2 s (racily clean). An answer
# that needed Git is kept 2 s in the process (a long-lived writer does not spawn Git per write); a cache hit is never
# memoized, so an owner re-checks at every poll and sees a file that became tracked at once.
package Loomy::JournalGate;
use strict;
use warnings;
use Fcntl ();
use Time::HiRes ();
use Digest::SHA ();
use Cwd ();
my $REFUSAL_TTL=30; my %memo; my $SEQ=0;
my $LIB=__FILE__; $LIB =~ s{/[^/]+\z}{};
require "$LIB/private-group.pl";
# The project root of "<root>/.loomy/logs", or undef when the directory is not exactly that after normalising (trailing
# slashes dropped; ".loomy/logs" read against the cwd): the caller then refuses. An empty root or a case variant of the
# names is not recognised either (a case-folding filesystem would still reach the real directory), so it fails closed.
sub _norm {
    my $dir=shift; return unless defined $dir && !ref $dir; $dir =~ s{/+\z}{} if length($dir)>1;
    my $root;
    if ($dir eq ".loomy/logs") { require Cwd; $root=Cwd::getcwd() }
    elsif ($dir =~ m{\A(.+)/\.loomy/logs\z}s) {
        $root=$1; unless ($root =~ m{\A/}) { require Cwd; $root=Cwd::getcwd()."/$root"; $root =~ s{/\.(?=/|\z)}{}g }
    } else { return }
    return unless defined $root && length $root;
    return ($root,"$root/.loomy/logs");
}
sub _ident {
    my ($root,$dir,$idx,$alias)=@_;
    my @a=$alias ? stat("$root/.loomy") : lstat("$root/.loomy"); my @b=$alias ? stat($dir) : lstat($dir);
    return Digest::SHA::sha256_hex(join("|",$alias ? "v3a" : "v2",$idx,join(",",@a[0,1]),join(",",@b[0,1])));
}
# Per-user cache directory outside the project, the first usable of: $XDG_CACHE_HOME (absolute) or ~/.cache; then
# $XDG_RUNTIME_DIR (Linux, 0700); then $TMPDIR (macOS /var/folders/.../T). In each, "loomy/gate". Levels that are missing
# are created 0700 (create only); every existing level must be a real directory (never a symlink) owned by the user. The
# base must not be group or world writable (anyone who can write there can swap what is under it, as under a 0775
# ~/.cache with umask 002: that base is skipped, the next one is tried, and with none the in-process memo answers and Git
# is asked again). A loomy or gate level we own that was created group/world writable is tightened to 0700. For the
# cache base HOME must be ours to create it; the fallback bases must already exist. Returns the directory or undef.
sub _cdir {
    my $create=shift; my @bases;
    my $b=$ENV{XDG_CACHE_HOME}; $b=defined $ENV{HOME} && $ENV{HOME} =~ m{\A/} ? "$ENV{HOME}/.cache" : "" unless defined $b && $b =~ m{\A/};
    push @bases,[$b,1] if length $b;
    for my $v (qw(XDG_RUNTIME_DIR TMPDIR)) { my $x=$ENV{$v}; push @bases,[$x,0] if defined $x && $x =~ m{\A/} }
    for my $e (@bases) { my $d=_cdir_in($e->[0],$create,$e->[1]); return $d if defined $d }
    return;
}
sub _cdir_in {
    my ($base,$create,$home)=@_; $base =~ s{/+\z}{};
    return unless length $base;
    my $i=0;
    for my $x ($base,"$base/loomy","$base/loomy/gate") {
        my @s=lstat($x);
        if (!@s) {
            return unless $create;
            if ($i==0) { return unless $home; if (defined $ENV{HOME}) { my @h=stat($ENV{HOME}); return unless @h && -d _ && $h[4]==$< } }
            my $old=umask 0077; my $made=mkdir($x,0700); umask $old; return unless $made; @s=lstat($x);
        }
        return unless @s && -d _ && !-l _ && $s[4]==$<;
        if ($i==0) { return unless Loomy::PrivateGroup::mode_ok($s[2],$s[5]) }   # the base: not world writable, group writable only for the user's private group
        elsif ($s[2]&022) { chmod(0700,$x) or return; @s=lstat($x); return unless @s && -d _ && !($s[2]&022) }
        $i++;
    }
    return "$base/loomy/gate";
}
# Marker files in that directory, all small and path-free: "r-<sha256 of the root>" the 30 s refusal (empty),
# "t-<sha256 of the root>" the tracked verdict and "o-<sha256 of the root>" the ok verdict of an aliased logs directory
# (content "<verdict key>\n<value>\n"; the key changes with the index stat and the identity of .loomy and .loomy/logs,
# so any change invalidates it). One file per root and kind, replaced by rename: growth is bounded by the number of projects.
sub _marker {
    my ($name,$create)=@_; my $d=_cdir($create); return undef unless defined $d; return "$d/$name";
}
# Never opens an existing name for writing: a private temp file (O_EXCL, no symlink follow) renamed into place.
sub _mark {
    my ($path,$val)=@_; return unless defined $path && length $path; $val//="";
    (my $d=$path) =~ s{/[^/]*\z}{}; my $tmp="$d/.m$$.".(++$SEQ).".".int(Time::HiRes::time()*1000);
    my $old=umask 0077;
    if (sysopen(my $h,$tmp,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_NOFOLLOW(),0600)) {
        my $ok=length($val) ? syswrite($h,$val) : 1; close $h;
        if ($ok && rename($tmp,$path)) { umask $old; return 1 }
        unlink $tmp;
    }
    umask $old; return;
}
# (handle,stat) of a marker that is a regular file of ours with a single link, or (): O_NOFOLLOW|O_NONBLOCK (a planted
# FIFO or symlink never blocks or redirects), then fstat.
sub _open_marker {
    my $path=shift; return unless defined $path;
    sysopen(my $h,$path,Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK()) or return;
    my @s=stat($h); return unless @s && -f $h && $s[4]==$< && $s[3]==1 && !($s[2]&022);
    return ($h,\@s);
}
# ($key,$value) of a cache file (a marker or the project's gate-v1), or ().
sub _read {
    my $path=shift; my ($h,$s)=_open_marker($path) or return; return unless $s->[7]<=1024;
    sysread($h,my $raw,1025); close $h; my ($k,$v)=split /\n/,$raw; return unless defined $k && defined $v;
    return ($k,$v);
}
# Mtime of a refusal marker, or undef.
sub _marker_age {
    my $path=shift; my ($h,$s)=_open_marker($path) or return; close $h; return $s->[9];
}
# Old per-key t-<64 hex> files (7 bytes, "tracked"): dropped when a root's marker is written. Bounded scan.
sub _prune_legacy {
    my $d=shift; opendir(my $dh,$d) or return; my ($seen,$n)=(0,0);
    while (defined(my $f=readdir $dh)) {
        last if ++$seen>512 || $n>=64; next unless $f =~ /\At-[0-9a-f]{64}\z/;
        my @s=lstat("$d/$f"); next unless @s && -f _ && $s[4]==$< && $s[7]==7; $n++ if unlink("$d/$f");
    }
    closedir $dh;
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
# The physical root of a logs directory reached through a symlink (a linked worktree whose .loomy is the main checkout's),
# or undef when it cannot be established (the answer is then a refusal). Resolved, it must still be <root>/.loomy/logs.
sub _phys_root {
    my $dir=shift; require Cwd; my $p=Cwd::abs_path($dir);
    unless (defined $p) { (my $par=$dir) =~ s{/[^/]*\z}{}; my $q=Cwd::abs_path($par); $p="$q/logs" if defined $q && $dir =~ m{/logs\z} }
    return unless defined $p && $p =~ m{\A(.+)/\.loomy/logs\z}s;
    return $1;
}
# Returns (allowed, [file key, file value] to store or undef, cache-hit flag). Store is only for "ok". No memo.
# A dir that is not exactly <root>/.loomy/logs, or a missing root, is refused. Through an alias the physical root is
# judged too, on its own index (whose stat is part of the cached key); if that cannot be established, refused.
sub verdict {
    my ($dir,$fresh)=@_; my ($root,$nd)=_norm($dir); return (0,undef) unless defined $root; $dir=$nd;
    return (0,undef) if lstat("$root/.loomy/.git") || lstat("$dir/.git");   # a nested repository under the runtime directory (a submodule checkout shipped by a clone): never written, never trusted
    my $alias=(-l "$root/.loomy" || -l $dir) ? 1 : 0;   # the directory written is another project's: never stored in it, cached per user instead
    my @roots=($root);
    if ($alias) {
        my $p=_phys_root($dir); return (0,undef) unless defined $p;
        my $rr=Cwd::abs_path($root); $rr=$root unless defined $rr; push @roots,$p if $p ne $rr;
    }
    my ($allnorepo,@idx)=(1);
    for my $r (@roots) { my ($n,$i)=_index($r); $allnorepo=0 unless $n; push @idx,($n ? "norepo" : $i) }
    return (1,undef) if $allnorepo;
    my $existed=-d $dir; my $ix=(grep {!defined} @idx) ? undef : join("|",@idx);
    my $now=time; my $key=($existed && defined $ix) ? _ident($root,$dir,$ix,$alias) : undef;
    my $rh=Digest::SHA::sha256_hex($root);
    if ($existed && !$fresh && defined $key && !$alias) {
        my ($k,$v)=_read("$dir/gate-v1");
        return (1,undef,1) if defined $k && $k eq $key && $v eq "ok";   # third value: answered from the cache file, no memo needed
    }
    if (!$fresh && defined $key) {
        for my $kind ($alias ? ("t-","o-") : ("t-")) {
            my ($k,$v)=_read(_marker("$kind$rh"));   # verdict cached outside the project
            next unless defined $k && $k eq $key;
            return (0,undef,1) if $v eq "tracked"; return (1,undef,1) if $v eq "ok" && $kind eq "o-";
        }
    }
    my $mk=_marker("r-$rh");
    unless ($fresh || !defined $mk) {
        my $m=_marker_age($mk); return (0,undef) if defined $m && $m<=$now+1 && $now-$m<$REFUSAL_TTL;
    }
    my $why="";
    for my $r (@roots) {
        my ($path,$w)=eval { require "$LIB/runtime-paths.pl"; Loomy::RuntimePaths::tracked_runtime($r) };
        $w="index-error" unless defined $w;
        if ($w eq "timeout" || $w eq "index-error") { $why=$w; last }
        $why="tracked" if $w eq "tracked";
    }
    if ($why eq "timeout" || $why eq "index-error") {
        my $rm=_marker("r-$rh",1); _mark($rm,"");
        return (0,undef);
    }
    unlink $mk if defined $mk;
    my $allowed=$why eq "tracked" ? 0 : 1;
    if (!$allowed && defined $key) { my $tm=_marker("t-$rh",1); if (_mark($tm,"$key\ntracked\n")) { (my $d=$tm) =~ s{/[^/]*\z}{}; _prune_legacy($d) } }
    elsif ($allowed && $alias && defined $key) { my $om=_marker("o-$rh",1); _mark($om,"$key\nok\n") }
    return ($allowed,($allowed && defined $key && !$alias) ? [$key,"ok"] : undef);
}
sub store {
    my ($dir,$s)=@_; return unless $s && $s->[1] eq "ok" && -d $dir && !-l $dir;
    my $tmp="$dir/gate-v1.$$"; my $old=umask 0077;
    if (sysopen(my $h,$tmp,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_NOFOLLOW(),0600)) {
        my $ok=syswrite($h,"$s->[0]\n$s->[1]\n"); close $h;
        if ($ok) { rename($tmp,"$dir/gate-v1") or unlink $tmp } else { unlink $tmp }
    }
    umask $old;
}
# The question every journal writer asks: may this logs directory be written?
# With $nostore (an election, which may end as a follower that must leave the logs directory untouched) a positive
# answer is read from the cache but not stored in the project.
sub check {
    my ($dir,$nostore)=@_; my $k=$nostore ? "n:$dir" : $dir;   # a no-store answer never serves a storing caller (it would defer the store and keep a stale ok); any answer serves a no-store one
    my $m=$memo{$dir}; $m=$memo{$k} if $nostore && !($m && Time::HiRes::time()<$m->[0]);
    return $m->[1] if $m && Time::HiRes::time()<$m->[0];
    my ($allowed,$s,$hit)=verdict($dir); store($dir,$s) if $s && !$nostore;
    $memo{$k}=[Time::HiRes::time()+2,$allowed] unless ($s && !$nostore) || $hit;   # a cache hit costs stats only: never memoized, so a later poll sees a change at once
    return $allowed;
}
1;
