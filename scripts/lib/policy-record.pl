# User-owned consent record (ADR-0012). A content-policy.conf is a consent: only a policy that this machine's Loomy wrote
# is trusted. Every write of the file records, outside the project, ${XDG_CONFIG_HOME:-~/.config}/loomy/policies/<sha256
# of the project root realpath>: the device:inode of the policy file and the sha256 of its content. A reader trusts a
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
my $SEQ=0;
# The records directory, or undef. Missing levels are created 0700; the loomy and policies levels must be real
# directories of ours (a group/world writable one that is ours is tightened to 0700, never trusted as it was).
sub _dir {
    my $create=shift; my $base=$ENV{XDG_CONFIG_HOME};
    $base=(defined $ENV{HOME} && $ENV{HOME} =~ m{\A/}) ? "$ENV{HOME}/.config" : undef unless defined $base && $base =~ m{\A/};
    return unless defined $base; $base =~ s{/+\z}{};
    my @s=lstat($base);
    if (!@s) { return unless $create; my $o=umask 0077; my $m=mkdir($base,0700); umask $o; return unless $m; @s=lstat($base) }
    unless (-d _ && !-l _) { my @t=stat($base); return unless @t && -d _ }   # the base may be a link to a directory (dotfile managers); the levels below may not
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
# Writes (replaces) the entry of $root. Dies on failure so a policy write is never left unrecorded.
sub record {
    my ($root,$dev,$ino,$sha)=@_; my $n=_name($root); die "content policy record unavailable\n" unless defined $n && $dev =~ /\A\d+\z/ && $ino =~ /\A\d+\z/ && $sha =~ /\A[0-9a-f]{64}\z/;
    my $d=_dir(1); die "content policy record unavailable\n" unless defined $d;
    sysopen(my $dh,$d,Fcntl::O_RDONLY()) or die "content policy record unavailable\n";
    flock($dh,Fcntl::LOCK_EX()) or die "content policy record unavailable\n";
    my $tmp="$d/.$n.$$.".(++$SEQ); my $o=umask 0077;
    my $ok=sysopen(my $h,$tmp,Fcntl::O_WRONLY()|Fcntl::O_CREAT()|Fcntl::O_EXCL()|Fcntl::O_NOFOLLOW(),0600);
    if ($ok) {
        my $line="v1\n$dev:$ino\n$sha\n"; $ok=defined(syswrite($h,$line)) && close($h);
        $ok=rename($tmp,"$d/$n") if $ok; unlink $tmp unless $ok;
    }
    umask $o; close $dh; die "content policy record unavailable\n" unless $ok;
    return 1;
}
# True when the entry of $root names exactly this inode and content.
sub trusted {
    my ($root,$dev,$ino,$sha)=@_; my $n=_name($root); return 0 unless defined $n && defined $dev && defined $ino && defined $sha;
    my $d=_dir(0); return 0 unless defined $d;
    sysopen(my $h,"$d/$n",Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK()) or return 0;
    my @s=stat($h); return 0 unless @s && -f $h && $s[4]==$< && $s[3]==1 && !($s[2]&022) && $s[7]<=128;
    sysread($h,my $raw,129); close $h; return 0 unless defined $raw;
    my ($v,$id,$hash)=split /\n/,$raw; return 0 unless defined $v && defined $id && defined $hash && $v eq "v1";
    return ($id eq "$dev:$ino" && $hash eq $sha) ? 1 : 0;
}
# Trust of a policy already read: ($root, stat array, raw bytes).
sub trusted_read { my ($root,$st,$raw)=@_; return 0 unless ref($st) eq 'ARRAY' && @$st>1 && defined $raw; return trusted($root,$st->[0],$st->[1],Digest::SHA::sha256_hex($raw)) }
# Trust of the policy file of $root as it is now (shell fast paths, tests): opens it without following a link, requires a
# regular private file of ours.
sub verify_file {
    my $root=shift; return 0 unless defined $root && length $root;
    my $p="$root/.loomy/logs/content-policy.conf";
    sysopen(my $h,$p,Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK()) or return 0;
    my @s=stat($h); return 0 unless @s && -f $h && $s[4]==$< && $s[3]==1 && $s[7]<=16384;
    sysread($h,my $raw,16385); close $h; return 0 unless defined $raw && length($raw)<=16384;
    return trusted($root,$s[0],$s[1],Digest::SHA::sha256_hex($raw));
}
# Records the policy file of $root (or the file at $path, to be renamed over it) as it is now (tests and tools that create a policy file themselves).
sub record_file {
    my ($root,$path)=@_; my $p=$path // "$root/.loomy/logs/content-policy.conf";
    sysopen(my $h,$p,Fcntl::O_RDONLY()|Fcntl::O_NOFOLLOW()|Fcntl::O_NONBLOCK()) or die "content policy unavailable\n";
    my @s=stat($h); die "content policy unavailable\n" unless @s && -f $h;
    sysread($h,my $raw,16385); close $h; $raw//='';
    return record($root,$s[0],$s[1],Digest::SHA::sha256_hex($raw));
}
unless (caller) {
    my ($cmd,$root)=@ARGV;
    if (defined $cmd && $cmd eq 'check') { exit(verify_file($root) ? 0 : 1) }
    if (defined $cmd && $cmd eq 'record') { exit(eval { record_file($root); 1 } ? 0 : 1) }
    exit 2;
}
1;
