#!/usr/bin/env perl
# Helpers for the private-history companion trust record (scripts/lib/privacy.sh). No git is spawned here.
#   id DIR                       "realpath<TAB>dev:ino" of DIR itself (never through a link)
#   nonce                        fresh random hex nonce
#   scan MODE < config -z list   allow-list audit of a companion config (MODE adopt|ready). Lines: P<TAB>problem,
#                                U<TAB>remote<TAB>key<TAB>value, L<TAB>1 (a local remote), D<TAB>digest of every url/pushurl
#   files DIR                    redirecting files, executable hooks, op-state files, attributes: one "P<TAB>problem" per line
#   write RECORDS DIR DIGEST     new nonce file inside DIR + record line (real, dev:ino, nonce, digest)
#   match RECORDS DIR            prints the recorded digest when real path, dev:ino and the nonce file all match; exit 1 otherwise
#   forget RECORDS REAL          removes the record of REAL (exact field compare)
#   key DIR RECORDDIGEST         sha256 over the stat of every file the audit reads
#   vhas|vadd CACHE KEY          verdict cache (bounded), written with a rename
# The record file is 0600 in a 0700 folder, written through a temp file in the same folder under an flock, and fields
# containing a tab, newline or NUL are refused.
use strict; use warnings;
use Digest::SHA qw(sha256_hex); use Fcntl qw(:flock); use File::Basename qw(dirname);
my ($cmd, @a) = @ARGV; $cmd //= '';
sub esc { my $v = shift; $v =~ s/([\x00-\x1f\x7f])/sprintf('\\x%02x', ord($1))/ge; $v }
sub bad { $_[0] =~ /[\t\n\r\0]/ }
sub dirid { my $d = shift; return unless -d $d && !-l $d; my @s = lstat($d) or return; my $r = Cwd::abs_path($d); return unless defined $r; return ($r, "$s[0]:$s[1]") }
require Cwd;
sub locked(&$) { my ($code, $file) = @_; my $dir = dirname($file); unless (-d $dir) { require File::Path; File::Path::make_path($dir, { mode => 0700 }) }
  open(my $lk, '>>', "$file.lock") or die "lock: $!"; flock($lk, LOCK_EX) or die "flock"; my $r = $code->(); close $lk; $r }
sub slurp_lines { my $f = shift; open(my $h, '<', $f) or return (); my @l = <$h>; close $h; chomp @l; @l }
sub rewrite { my ($file, @lines) = @_; my $tmp = sprintf("%s.tmp.%d.%d", $file, $$, int(rand(1e9)));
  my $old = umask(077); open(my $o, '>', $tmp) or die "write: $!"; print $o map { "$_\n" } @lines; close $o or die; umask($old); chmod(0600, $tmp); rename($tmp, $file) or die "rename: $!" }
if ($cmd eq 'id') { my ($r, $i) = dirid($a[0]) or exit 1; exit 1 if bad($r); print "$r\t$i\n"; exit 0 }
if ($cmd eq 'nonce') { open(my $r, '<', '/dev/urandom') or exit 1; binmode $r; read($r, my $b, 16) == 16 or exit 1; print unpack('H*', $b), "\n"; exit 0 }
if ($cmd eq 'forget') { my ($file, $real) = @a; exit 0 unless -f $file; locked { rewrite($file, grep { (split /\t/, $_, -1)[0] ne $real } slurp_lines($file)); 1 } $file; exit 0 }
if ($cmd eq 'write') {
  my ($file, $dir, $digest) = @a; my ($r, $i) = dirid($dir) or exit 1; exit 1 if bad($r) || bad($digest);
  open(my $n, '<', '/dev/urandom') or exit 1; binmode $n; read($n, my $b, 16) == 16 or exit 1; my $nonce = unpack('H*', $b);
  my $pf = "$dir/loomy-provenance"; unlink $pf; my $old = umask(077);
  sysopen(my $p, $pf, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600) or exit 1; print $p "$nonce\n"; close $p; umask($old);
  locked { rewrite($file, (grep { (split /\t/, $_, -1)[0] ne $r } slurp_lines($file)), join("\t", $r, $i, $nonce, $digest)); 1 } $file; exit 0 }
if ($cmd eq 'match') {
  my ($file, $dir) = @a; my ($r, $i) = dirid($dir) or exit 1; exit 1 if bad($r);
  my $pf = "$dir/loomy-provenance"; my @s = lstat($pf) or exit 1; exit 1 if -l $pf || !-f _ || $s[4] != $> || ($s[2] & 077);
  open(my $p, '<', $pf) or exit 1; my $nonce = <$p>; close $p; defined $nonce or exit 1; chomp $nonce; exit 1 unless $nonce =~ /\A[0-9a-f]{32}\z/;
  for my $l (slurp_lines($file)) { my @f = split /\t/, $l, -1; next unless @f == 4; if ($f[0] eq $r && $f[1] eq $i && $f[2] eq $nonce) { print "$f[3]\n"; exit 0 } }
  exit 1 }
if ($cmd eq 'key') {
  my ($dir, $rec) = @a; my @p = map { "$dir/$_" } qw(config HEAD packed-refs hooks remotes branches info info/attributes info/grafts commondir gitdir objects/info/alternates loomy-provenance
    rebase-merge rebase-apply sequencer MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG BISECT_START BISECT_TERMS BISECT_NAMES BISECT_EXPECTED_REV BISECT_ANCESTORS_OK);
  my $s = ''; for my $f (@p) { my @t = lstat($f); $s .= @t ? join(',', $f, @t[0,1,2,4,7,9, 10]) : "$f,absent"; $s .= "\n" }
  my ($r, $i) = dirid($dir); print sha256_hex("$s\n$rec\n" . ($r // '') . "\n" . ($i // '')), "\n"; exit 0 }
if ($cmd eq 'vhas' || $cmd eq 'vadd') {
  my ($file, $key) = @a; exit 1 unless defined $key && $key =~ /\A[0-9a-f]{64}\z/;
  if ($cmd eq 'vhas') { exit((grep { $_ eq $key } slurp_lines($file)) ? 0 : 1) }
  locked { my @l = grep { $_ ne $key } slurp_lines($file); push @l, $key; @l = @l[-200..-1] if @l > 200; rewrite($file, @l); 1 } $file; exit 0 }
if ($cmd eq 'files') {
  my $d = $a[0]; my @p;
  for my $f (qw(commondir gitdir objects/info/alternates info/grafts)) { push @p, "redirecting file present: $f" if -e "$d/$f" || -l "$d/$f" }
  push @p, "attributes present: info/attributes" if -e "$d/info/attributes" && (-s _ || -l "$d/info/attributes");
  for my $legacy (qw(remotes branches)) {
    next unless -e "$d/$legacy" || -l "$d/$legacy";
    if (-d "$d/$legacy" && !-l "$d/$legacy") { if (opendir(my $lh, "$d/$legacy")) { my @e = grep { $_ ne '.' && $_ ne '..' } readdir $lh; closedir $lh; push @p, "legacy remote file present: $legacy/" . esc($e[0]) if @e } }
    else { push @p, "legacy remote file present: $legacy" }
  }
  if (opendir(my $h, "$d/hooks")) { for my $e (sort grep { $_ ne '.' && $_ ne '..' && !/\.sample\z/ } readdir $h) { push @p, "hook present: hooks/$e" } closedir $h }
  for my $f (qw(rebase-merge rebase-apply sequencer MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG BISECT_START BISECT_TERMS BISECT_NAMES BISECT_EXPECTED_REV BISECT_ANCESTORS_OK)) { push @p, "operation in progress: $f" if -e "$d/$f" || -l "$d/$f" }
  print "P\t$_\n" for map { esc($_) } @p; exit 0 }
if ($cmd eq 'scan') {
  my $mode = $a[0] // 'adopt'; my $strict = $mode eq 'adopt';
  my %core = map { $_ => 1 } qw(repositoryformatversion filemode bare logallrefupdates ignorecase precomposeunicode symlinks autocrlf eol safecrlf);
  my %remote = map { $_ => 1 } qw(url pushurl fetch push tagopt);
  my (%bad, %urls, %pushes, %names, @u, $local); local $/ = "\0";
  while (my $rec = <STDIN>) {
    chomp $rec; my ($k, $v) = split /\n/, $rec, 2; $v = '' unless defined $v;
    my ($sec, $rest) = $k =~ /\A([^.]+)\.(.+)\z/s or do { $bad{$k} = 1; next }; $sec = lc $sec;
    my ($sub, $var) = $rest =~ /\A(.*)\.([^.]+)\z/s; ($sub, $var) = (undef, $rest) unless defined $var; $var = lc $var;
    my ($ok, $skip) = (0, 0);
    if ($sec eq 'core' && !defined $sub) { $ok = $core{$var} ? 1 : 0 }
    elsif ($sec eq 'status' && !defined $sub) { $ok = $var eq 'showuntrackedfiles' }
    elsif ($sec eq 'user' && !defined $sub) { $ok = $var eq 'name' || $var eq 'email' }
    elsif ($sec eq 'branch' && defined $sub) { $ok = $var eq 'remote' || $var eq 'merge' || $var eq 'rebase' }
    elsif ($sec eq 'remote' && defined $sub) {
      $names{$sub} = 1;
      if ($sub !~ /\A[A-Za-z0-9._-]+\z/) { print "P\t", esc("remote name not allowed: $sub"), "\n"; next }
      $ok = $remote{$var} ? 1 : 0;
      if ($ok && ($var eq 'url' || $var eq 'pushurl')) {
        my $isl = $v =~ m{\A(?:/|\./|\.\./|file://)}i ? 1 : 0;
        $ok = 0 if $v =~ /\A-/ || $v =~ /::/ || $v =~ /[\x00-\x1f\s]/ || $v =~ /\A(?:ext|fd)\b/i;
        $ok = 0 unless $v =~ m{\A(?:https://|ssh://|file://|/|\./|\.\./|[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*:|[A-Za-z0-9][A-Za-z0-9.-]*:[^/])}i;
        if ($ok && $isl) { $local = 1; if ($strict) { $ok = 0; print "P\t", esc("local remote refused by adopt: remote.$sub.$var"), "\n"; $skip = 1 } }
        push @u, [$sub, $var, $v] if $ok || $isl;
        if ($var eq 'url') { push @{ $urls{$sub} }, $v } else { push @{ $pushes{$sub} }, $v }
      }
    }
    $bad{$k} = 1 unless $ok || $skip;
  }
  for my $r (sort keys %urls) { print "P\t", esc("remote.$r.url has several values"), "\n" if @{ $urls{$r} } > 1 }
  if ($strict) {
    for my $r (sort keys %pushes) { for my $pv (@{ $pushes{$r} }) { my $u1 = $urls{$r} ? $urls{$r}[0] : undef; print "P\t", esc("pushurl differs from url: remote.$r"), "\n" if !defined $u1 || $u1 ne $pv } }
    for my $r (sort keys %names) { print "P\t", esc("remote other than origin: $r"), "\n" if $r ne 'origin' && $r =~ /\A[A-Za-z0-9._-]+\z/ }
  }
  for my $k (sort keys %bad) { print "P\t", esc("config key not allowed: $k"), "\n" }
  print "U\t", join("\t", map { esc($_) } @$_), "\n" for grep { $_->[0] eq 'origin' } sort { join("\t", @$a) cmp join("\t", @$b) } @u;
  print "L\t1\n" if $local;
  print "D\t", sha256_hex(join("\n", sort map { join("\t", @$_) } @u)), "\n"; exit 0 }
exit 2;
