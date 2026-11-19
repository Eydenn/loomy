# One rule for the user-level folders Loomy keeps outside a project (the barrier cache, the consent records, the
# quarantine): a folder is acceptable when it is not world writable and, if it is group writable, the group is the user's
# own private group. That is the Debian/Ubuntu default (umask 002, user-private groups), where ~/.config, ~/.cache and
# ~/.local/state are often 0775 and the group holds only the user. A group is private when all of these hold: it is the
# user's primary group; no other member is listed for it; no other passwd entry has it as primary group (one scan of the
# passwd database, cached for the process). A shared group (macOS staff, a project group) is never accepted.
package Loomy::PrivateGroup;
use strict;
use warnings;
my (%answer,$scanned,%primary);
# Test seams: the group member list and the passwd scan.
sub _members { my @g=getgrgid($_[0]); return unless @g; return [grep {length} split ' ',$g[3]//''] }
sub _primary_uids {
    unless ($scanned) { setpwent(); while (my @p=getpwent()) { push @{$primary{$p[3]}},$p[2] } endpwent(); $scanned=1 }
    return $primary{$_[0]} // [];
}
sub private_group {
    my $gid=shift; return 0 unless defined $gid; return $answer{$gid} if exists $answer{$gid};
    my @me=getpwuid($<); my $r=0;
    if (@me && $gid==$me[3]) {
        my $m=_members($gid);
        $r=1 if $m && !grep({$_ ne $me[0]} @$m) && !grep({$_ != $<} @{_primary_uids($gid)});
    }
    return $answer{$gid}=$r;
}
# $mode and $gid of a directory (from stat): true when the mode is acceptable under the rule above. Ownership is the caller's check.
sub mode_ok {
    my ($mode,$gid)=@_; return 0 if $mode&002; return 1 unless $mode&020; return private_group($gid);
}
sub _reset { %answer=(); }   # tests
1;
