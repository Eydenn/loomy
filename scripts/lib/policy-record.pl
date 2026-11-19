# User-owned consent record (ADR-0012). A content-policy.conf is a consent: only a policy that this machine's Loomy wrote
# is trusted. Every write of the file records, outside the project, ${XDG_CONFIG_HOME:-~/.config}/loomy/policies/<sha256
# of the project root realpath>: the device:inode and the change time (ctime, taken after the final rename: a byte-identical
# file that lands on a reused inode cannot match it) of the policy file and the sha256 of its content. A reader trusts a
# policy only when the entry matches that root, inode and content; any other file (shipped by a clone, tracked or not,
# left after `doctor --fix`, hand edited, replaced) reads as absent: defaults, no grant, first-use consent pending.
# The directory is 0700 and each entry 0600; an entry is written through a temp file renamed into place under an flock
# on the directory. Nothing here reads the project except the policy file it is asked about.
package Loomy::PolicyRecord;
use strict;
use warnings;
use Cwd ();
use Digest::SHA ();
use Fcntl ();
use Time::HiRes ();
my $SEQ=0;
# The records directory, or undef. Missing levels are created 0700. Every level must be a real directory of ours (never a
# symlink; the base alone may be one, to a directory of ours, for dotfile managers); the base must not be group or world
# writable (anyone who can write there can swap what is under it: no fallback, the policy is then never trusted and
# unsafe_base() says which folder to fix); a loomy or policies level of ours that is group/world writable is tightened to 0700.
sub _base {
    my $base=$ENV{XDG_CONFIG_HOME};
    $base=(defined $ENV{HOME} && $ENV{HOME} =~ m{\A/}) ? "$ENV{HOME}/.config" : undef unless defined $base && $base =~ m{\A/};
    return unless defined $base; $base =~ s{/+\z}{}; return length($base) ? $base : undef;
}
# The base folder when it exists and breaks the rule above, else undef (doctor says so in one line).
sub unsafe_base {
    my $base=_base(); return unless defined $base; my @s=stat($base); return unless @s && -d _;
    return ($s[4]!=$< || ($s[2]&022)) ? $base : undef;
}
sub _dir {
    my $create=shift; my $base=_base(); return unless defined $base;
    my @s=lstat($base);
    if (!@s) { return unless $create; my $o=umask 0077; my $m=mkdir($base,0700); umask $o; return unless $m; @s=lstat($base) }
    @s=stat($base) if -l _; return unless @s && -d _ && $s[4]==$< && !($s[2]&022);
    my $cur=$base;
    for my $l ("loomy","policies") {
        my $n="$cur/$l"; @s=lstat($n);
        if (!@s) { return unless $create; my $o=umask 0077; my $m=mkdir($n,0700); umask $o; return unless $m; @s=lstat($n) }
        return unless @s && -d _ && !-l _ && $s[4]==$<;
        if ($s[2]&022) { chmod(0700,$n) or return; @s=lstat($n); return unless @s && !($s[2]&022) }
        $cur=$n;
    }
    return $cur;
}
sub _name {
    my $root=shift; return unless defined $root && !ref $root && length $root; my $r=Cwd::abs_path($root); return unless defined $r;
    return Digest::SHA::sha256_hex($r);
}
# "$dev:$ino:$ctime" of a stat array (Time::HiRes: fractional ctime, microsecond text).
sub _id { my @s=@_; return unless @s>10; return "$s[0]:$s[1]:".sprintf("%.6f",$s[10]) }
# Writes (replaces) the entry of $root for the file with this id (see _id) and content hash. Dies on failure.
sub record {
    my ($root,$id,$sha)=@_; my $n=_name($root); die "content policy record unavailable\n" unless defined $n && defined $id && $id =~ /\A\d+:\d+:\d+\.\d+\z/ && $sha =~ /\A[0-9a-f]{64}\z/;
    my $d=_dir(1); die "content policy record unavailable\n" unless defined $d;
    sysopen(my $dh,$d,Fcntl::O_RDONLY()) or die "content policy record unavailable\n";
    flock($dh,Fcntl::LOCK_EX()) or die "content policy record unavailable\n";
    my $tmp="$d/.$n.$$.".(++$SEQ); my $o=umask 0077;
    my $ok=sysopen(my $h,$tmp,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_NOFOLLOW(),0600);
    if ($ok) {
        my $line="v2\n$id\n$sha\n"; $ok=defined(syswrite($h,$line)) && close($h);
        $ok=rename($tmp,"$d/$n") if $ok; unlink $tmp unless $ok;
    }
    umask $o; close $dh; die "content policy record unavailable\n" unless $ok;
    return 1;
}
# The entry text of $root, or undef.
sub _entry {
    my ($root,$d)=@_; my $n=_name($root); return unless defined $n; $d//=_dir(0); return unless defined $d;
    sysopen(my $h,"$d/$n",Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK()) or return;
    my @s=stat($h); return unless @s && -f $h && $s[4]==$< && $s[3]==1 && !($s[2]&022) && $s[7]<=160;
    sysread($h,my $raw,161); close $h; return $raw;
}
# True when the entry of $root names exactly this file (device, inode, ctime) and content.
sub trusted {
    my ($root,$id,$sha)=@_; return 0 unless defined $id && defined $sha;
    my $raw=_entry($root); return 0 unless defined $raw;
    my ($v,$eid,$hash)=split /\n/,$raw; return 0 unless defined $v && defined $eid && defined $hash && $v eq "v2";
    return ($eid eq $id && $hash eq $sha) ? 1 : 0;
}
# Trust of a policy already read: ($root, stat array from Time::HiRes, raw bytes).
sub trusted_read { my ($root,$st,$raw)=@_; return 0 unless ref($st) eq 'ARRAY' && defined $raw; return trusted($root,_id(@$st),Digest::SHA::sha256_hex($raw)) }
# The policy file of $root as it is now: (stat array, raw) of a regular private file of ours opened without following a link, or ().
sub _file {
    my $path=shift; sysopen(my $h,$path,Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK()) or return;
    my @s=Time::HiRes::stat($h); return unless @s && -f $h && $s[4]==$< && $s[3]==1 && $s[7]<=16384;
    sysread($h,my $raw,16385); close $h; return unless defined $raw && length($raw)<=16384;
    return (\@s,$raw);
}
# Trust of the policy file of $root as it is now (shell fast paths, tests).
sub verify_file {
    my $root=shift; return 0 unless defined $root && length $root;
    my ($s,$raw)=_file("$root/.loomy/logs/content-policy.conf"); return 0 unless $s;
    return trusted_read($root,$s,$raw);
}
# Drops the entry of $root (the policy file is gone: `doctor --fix` moved it aside, or it was deleted).
sub forget {
    my $root=shift; my $n=_name($root); return 0 unless defined $n; my $d=_dir(0); return 0 unless defined $d;
    sysopen(my $dh,$d,Fcntl::O_RDONLY()) or return 0; flock($dh,Fcntl::LOCK_EX()) or return 0;
    my $r=unlink("$d/$n"); close $dh; return $r ? 1 : 0;
}
# Drops the entry of $root when it no longer matches the file now (re-checked under the lock, so a writer that just
# recorded a new file keeps its entry). Returns 1 when an entry was dropped.
sub forget_if_stale {
    my $root=shift; my $n=_name($root); return 0 unless defined $n; my $d=_dir(0); return 0 unless defined $d;
    sysopen(my $dh,$d,Fcntl::O_RDONLY()) or return 0; flock($dh,Fcntl::LOCK_EX()) or return 0;
    my $r=0; my $raw=_entry($root,$d);
    if (defined $raw) { my ($s,$c)=_file("$root/.loomy/logs/content-policy.conf"); $r=unlink("$d/$n") ? 1 : 0 unless $s && trusted_read($root,$s,$c) }
    close $dh; return $r;
}
# Records the policy file of $root (or the file at $path) as it is now (tests and tools that create a policy file themselves).
sub record_file {
    my ($root,$path)=@_; my ($s,$raw)=_file($path // "$root/.loomy/logs/content-policy.conf"); die "content policy unavailable\n" unless $s;
    return record($root,_id(@$s),Digest::SHA::sha256_hex($raw));
}
unless (caller) {
    my ($cmd,$root)=@ARGV;
    if (defined $cmd && $cmd eq 'check') { exit(verify_file($root) ? 0 : 1) }
    if (defined $cmd && $cmd eq 'record') { exit(eval { record_file($root); 1 } ? 0 : 1) }
    if (defined $cmd && $cmd eq 'forget') { exit(forget($root) ? 0 : 1) }
    exit 2;
}
1;
