#!/usr/bin/env perl
# Helpers for the private-history companion trust record (scripts/lib/privacy.sh). No git is spawned here.
#   id DIR                       "realpath<TAB>dev:ino" of DIR itself (never through a link)
#   nonce                        fresh random hex nonce
#   scan MODE [ROOT...] < config -z list   allow-list audit of a companion config (MODE adopt|ready). Lines: P<TAB>code<TAB>argument
#                                (a reason code the shell maps to a translated sentence), U<TAB>remote<TAB>key<TAB>value, L<TAB>1 (a local
#                                remote), D<TAB>digest of every url/pushurl. Adopt accepts a local remote only when it is an absolute path to
#                                an existing directory you own, outside every ROOT (the project work tree and its repository top level).
#   files DIR                    redirecting files, executable hooks, op-state files, attributes: one "P<TAB>code<TAB>argument" per line
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
# Escapes control bytes, C1 controls (U+0080-009F), bidi controls (U+200E/F, U+202A-E, U+2066-9) and invalid UTF-8 as \xNN
# (per byte); other valid UTF-8 stays readable. Strings here are raw bytes.
sub esc { my $v = shift; my $o = '';
  while ($v =~ /\G(?:([\x00-\x1f\x7f]|\xC2[\x80-\x9F]|\xE2\x80[\x8E\x8F\xAA-\xAE]|\xE2\x81[\xA6-\xA9])|([\x20-\x7e]|[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2})|(.))/gcs) {
    if (defined $2) { $o .= $2 } else { $o .= join('', map { sprintf('\\x%02x', ord) } split //, (defined $1 ? $1 : $3)) } }
  $o }
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
  my ($file, $dir, $digest, $rinfo) = @a; $rinfo = '-' unless defined $rinfo && length $rinfo; my ($r, $i) = dirid($dir) or exit 1; exit 1 if bad($r) || bad($digest) || bad($rinfo);
  open(my $n, '<', '/dev/urandom') or exit 1; binmode $n; read($n, my $b, 16) == 16 or exit 1; my $nonce = unpack('H*', $b);
  my $pf = "$dir/loomy-provenance"; unlink $pf; my $old = umask(077);
  sysopen(my $p, $pf, Fcntl::O_WRONLY() | Fcntl::O_CREAT() | Fcntl::O_EXCL(), 0600) or exit 1; print $p "$nonce\n"; close $p; umask($old);
  locked { rewrite($file, (grep { (split /\t/, $_, -1)[0] ne $r } slurp_lines($file)), join("\t", $r, $i, $nonce, $digest, $rinfo)); 1 } $file; exit 0 }
if ($cmd eq 'match') {
  my ($file, $dir) = @a; my ($r, $i) = dirid($dir) or exit 1; exit 1 if bad($r);
  my $pf = "$dir/loomy-provenance"; my @s = lstat($pf) or exit 1; exit 1 if -l $pf || !-f _ || $s[4] != $> || ($s[2] & 077);
  open(my $p, '<', $pf) or exit 1; my $nonce = <$p>; close $p; defined $nonce or exit 1; chomp $nonce; exit 1 unless $nonce =~ /\A[0-9a-f]{32}\z/;
  for my $l (slurp_lines($file)) { my @f = split /\t/, $l, -1; next unless @f == 5; if ($f[0] eq $r && $f[1] eq $i && $f[2] eq $nonce) { print "$f[3]\t$f[4]\n"; exit 0 } }
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
  for my $f (qw(commondir gitdir objects/info/alternates info/grafts)) { push @p, ["redirect", $f] if -e "$d/$f" || -l "$d/$f" }
  push @p, ["attributes", "info/attributes"] if -e "$d/info/attributes" && (-s _ || -l "$d/info/attributes");
  for my $legacy (qw(remotes branches)) {
    next unless -e "$d/$legacy" || -l "$d/$legacy";
    if (-d "$d/$legacy" && !-l "$d/$legacy") { if (opendir(my $lh, "$d/$legacy")) { my @e = grep { $_ ne '.' && $_ ne '..' } readdir $lh; closedir $lh; push @p, ["legacy", "$legacy/" . $e[0]] if @e } }
    else { push @p, ["legacy", $legacy] }
  }
  if (opendir(my $h, "$d/hooks")) { for my $e (sort grep { $_ ne '.' && $_ ne '..' && !/\.sample\z/ } readdir $h) { push @p, ["hook", "hooks/$e"] } closedir $h }
  for my $f (qw(rebase-merge rebase-apply sequencer MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG BISECT_START BISECT_TERMS BISECT_NAMES BISECT_EXPECTED_REV BISECT_ANCESTORS_OK)) { push @p, ["op", $f] if -e "$d/$f" || -l "$d/$f" }
  print "P\t$_->[0]\t", esc($_->[1]), "\n" for @p; exit 0 }
# git_roots PROJECT: every place the project's repository lives, without spawning git: the project, its repository top level, the .git
# directory, the common dir and every linked worktree (from <common>/worktrees/*/gitdir). A local remote may not sit in or above any of them.
sub rd1 { my $f = shift; open(my $h, '<', $f) or return; my $l = <$h>; close $h; return unless defined $l; chomp $l; $l }
sub git_roots { my $proj = shift; my @r = ($proj); my $d = Cwd::abs_path($proj); return @r unless defined $d; push @r, $d;
  my $t = $d; my $top; while (1) { if (-e "$t/.git" || -l "$t/.git") { $top = $t; last } last if $t eq '/'; $t = dirname($t) }
  return @r unless defined $top; push @r, $top; my $gd = "$top/.git";
  if (-f $gd) { my $l = rd1($gd); if (defined $l && $l =~ /\Agitdir:\s*(.+)\z/) { $gd = $1; $gd = "$top/$gd" unless $gd =~ m{\A/} } }
  my $common = $gd; my $c = rd1("$gd/commondir"); if (defined $c && length $c) { $common = $c =~ m{\A/} ? $c : "$gd/$c" }
  for my $x ($gd, $common) { push @r, $x; my $a = Cwd::abs_path($x); push @r, $a if defined $a }
  my $cr = Cwd::abs_path($common); if (defined $cr && $cr =~ m{/\.git\z}) { push @r, dirname($cr) }
  if (opendir(my $h, "$common/worktrees")) { for my $e (grep { $_ ne '.' && $_ ne '..' } readdir $h) { my $g = rd1("$common/worktrees/$e/gitdir"); next unless defined $g && length $g; push @r, $g; push @r, dirname($g) } closedir $h }
  @r }
# ancestor_ids PATH: "dev:ino" of PATH and each of its ancestors (compared by identity, so a case-insensitive file system cannot hide one).
sub ancestor_ids { my $q = shift; my %id; while (1) { my @s = stat($q); $id{"$s[0]:$s[1]"} = 1 if @s; last if $q eq '/' || $q eq ''; $q = dirname($q); $q = '/' if $q eq '' } \%id }
# local_problem URL PATH ROOTS: why a local remote is refused (empty when acceptable). Applies to every local remote (adopted, or recorded by
# Loomy itself): git resolves the path again at push time, so it must be exactly what it names. The path is absolute (after file:// is
# stripped), canonical (no symlink, `.`, `..`, trailing slash, no /proc or /dev), an existing directory you own that is a git dir itself
# (`<p>/.git` and `<p>.git` absent: git's local transport tries those suffixes), and neither inside nor above any root.
sub local_problem { my ($v, $p, $roots) = @_;
  return 'local_rel' unless $p =~ m{\A/};
  return 'local_pct' if $v =~ m{\Afile://}i && $p =~ /%/;
  return 'local_special' if $p =~ m{\A/(?:proc|dev)(?:/|\z)};
  return 'local_dir' unless -d $p;
  return 'local_own' unless -O $p;
  my $r = Cwd::abs_path($p); return 'local_dir' unless defined $r;
  return 'local_canon' unless $r eq $p;
  for my $e (qw(HEAD objects refs)) { return 'local_nogit' unless -e "$p/$e" }
  for my $x ("$p/.git", "$p.git") { return 'local_nogit' if lstat($x) }
  my $mine = ancestor_ids($p); my %rid;
  for my $root (grep { defined && length } @$roots) {
    my $rp = Cwd::abs_path($root) // $root; my @s = stat($rp) or next; $rid{"$s[0]:$s[1]"} = 1;
    return 'local_anc' if ancestor_ids($rp)->{ join(':', (stat($p))[0,1]) };
  }
  for my $k (keys %$mine) { return 'local_in' if $rid{$k} }
  '' }
# rentry PATH: record entry "uid:dev:ino:hexpath" for a local remote.
sub rentry { my $p = shift; my @s = stat($p); return unless @s; join(':', $s[4], $s[0], $s[1], unpack('H*', $p)) }
if ($cmd eq 'canon') { my $u = $a[0] // ''; my $lp = $u; my $isl = $lp =~ s{\Afile://}{}i || $lp =~ m{\A(?:/|\./|\.\./)};
  if ($isl && $lp !~ /%/ && -d $lp) { my $r = Cwd::abs_path($lp); if (defined $r) { print "$r\n"; exit 0 } } print "$u\n"; exit 0 }
if ($cmd eq 'rcheck') {  # rcheck PROJECT RINFO: every recorded local remote is still the same canonical, outside git dir (no cache)
  my ($proj, $info) = @a; exit 0 if !defined $info || $info eq '-' || $info eq ''; my @roots = git_roots($proj);
  for my $e (split /,/, $info) { my ($uid, $dev, $ino, $hex) = split /:/, $e; exit 1 unless defined $hex && $hex =~ /\A(?:[0-9a-f]{2})+\z/; my $p = pack('H*', $hex);
    my @s = lstat($p); exit 1 unless @s && !-l _ && $s[4] == $uid && $s[0] == $dev && $s[1] == $ino; exit 1 if local_problem($p, $p, \@roots) }
  exit 0 }
if ($cmd eq 'scan') {
  my ($mode, @roots) = @a; $mode //= 'adopt'; my $strict = $mode eq 'adopt'; my %rent;
  @roots = (@roots, git_roots($roots[0])) if @roots;
  my %core = map { $_ => 1 } qw(repositoryformatversion filemode bare logallrefupdates ignorecase precomposeunicode symlinks autocrlf eol safecrlf);
  my %remote = map { $_ => 1 } qw(url pushurl fetch push tagopt);
  my (%bad, %urls, %pushes, %names, @u, $local, $local_bad); local $/ = "\0";
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
      if ($sub !~ /\A[A-Za-z0-9._-]+\z/) { print "P\tremote_name\t", esc($sub), "\n"; next }
      $ok = $remote{$var} ? 1 : 0;
      if ($ok && ($var eq 'url' || $var eq 'pushurl')) {
        my $isl = $v =~ m{\A(?:/|\./|\.\./|file://)}i ? 1 : 0;
        my $lp = $v; $lp =~ s{\Afile://}{}i if $isl;
        # Local paths may hold spaces and valid UTF-8 (no controls, no bidi controls); network URLs are printable ASCII only.
        $ok = 0 if $v =~ /\A-/ || $v =~ /::/ || $v =~ /\A(?:ext|fd)\b/i || ($isl ? ($lp eq '' || esc($lp) ne $lp) : $v !~ /\A[\x21-\x7e]+\z/);
        $ok = 0 unless $v =~ m{\A(?:https://|ssh://|file://|/|\./|\.\./|[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*:|[A-Za-z0-9][A-Za-z0-9.-]*:[^/])}i;
        if ($ok && $isl) {
          $local = 1;
          my $why = local_problem($v, $lp, \@roots);
          if ($why) { $ok = 0; $skip = 1; $local_bad = 1; print "P\t$why\t", esc("remote.$sub.$var"), "\n" } else { my $en = rentry($lp); $rent{$lp} = $en if defined $en }
        }
        push @u, [$sub, $var, $v] if $ok || $isl;
        if ($var eq 'url') { push @{ $urls{$sub} }, $v } else { push @{ $pushes{$sub} }, $v }
      }
    }
    $bad{$k} = 1 unless $ok || $skip;
  }
  for my $r (sort keys %urls) { print "P\turl_several\t", esc($r), "\n" if @{ $urls{$r} } > 1 }
  if ($strict) {
    for my $r (sort keys %pushes) { for my $pv (@{ $pushes{$r} }) { my $u1 = $urls{$r} ? $urls{$r}[0] : undef; print "P\tpush_differs\t", esc($r), "\n" if !defined $u1 || $u1 ne $pv } }
    for my $r (sort keys %names) { print "P\tremote_other\t", esc($r), "\n" if $r ne 'origin' && $r =~ /\A[A-Za-z0-9._-]+\z/ }
  }
  for my $k (sort keys %bad) { print "P\tconfig_key\t", esc($k), "\n" }
  print "P\tlocal_remedy\t-\n" if $local_bad;
  print "U\t", join("\t", map { esc($_) } @$_), "\n" for grep { $_->[0] eq 'origin' } sort { join("\t", @$a) cmp join("\t", @$b) } @u;
  print "L\t1\n" if $local;
  print "R\t", (%rent ? join(',', map { $rent{$_} } sort keys %rent) : '-'), "\n";
  print "D\t", sha256_hex(join("\n", sort map { join("\t", @$_) } @u)), "\n"; exit 0 }
exit 2;
