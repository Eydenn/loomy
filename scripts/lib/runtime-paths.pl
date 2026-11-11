# Pure validation of the physical runtime store and its registered source roots.
package Loomy::RuntimePaths;
use strict;
use warnings;
use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :mode O_NOFOLLOW O_NONBLOCK F_GETFD F_SETFD FD_CLOEXEC);
use POSIX ();
use Time::HiRes qw(stat lstat);

my $GIT_BYTES = 1048576;
my $WORKTREES = 256;

sub _group_info { my @g=getgrgid($_[0]); return @g ? ($g[0],$g[3]) : () }
sub private_group {
    my ($gid,$group_info)=@_; $group_info//=\&_group_info;
    my @pw=getpwuid($<); my ($name,$members)=$group_info->($gid);
    # gr_mem omits primary-only members, so both the name and primary gid matter.
    return 0 unless @pw && defined($name) && $name eq $pw[0] && $gid==$pw[3];
    for my $m (split ' ',$members//'') { return 0 unless $m eq $pw[0] }
    return 1;
}
sub dir_unsafe {
    my ($mode,$gid,$lenient,$private_group)=@_; $private_group//=\&private_group;
    return 1 if $mode&002;
    return 0 unless $mode&020;
    return $lenient && $private_group->($gid) ? 0 : 1;
}
sub _cloexec {
    my ($h)=@_; my $flags=fcntl($h,F_GETFD,0);
    die "content directory unavailable\n" unless defined($flags) && fcntl($h,F_SETFD,$flags|FD_CLOEXEC);
    return $h;
}
sub dir {
    my ($p,$display,$private_group)=@_; $display//=$p;
    my $lenient=$p =~ m{(?:\A|/)(?:\.loomy|memory)\z} ? 1 : 0;
    my @s=lstat($p);
    die "unsafe content directory\n" unless @s && S_ISDIR($s[2]) && $s[4]==$<;
    die "unsafe directory: $display (group/world writable)\n" if dir_unsafe($s[2],$s[5],$lenient,$private_group);
    sysopen my $h,$p,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or die "unsafe content directory\n";
    _cloexec($h);
    my @f=stat($h);
    die "unsafe content directory\n" unless @f && $s[0]==$f[0] && $s[1]==$f[1] && $f[4]==$<;
    die "unsafe directory: $display (group/world writable)\n" if dir_unsafe($f[2],$f[5],$lenient,$private_group);
    return ($h,\@f);
}
sub _canonical {
    my ($root,$private_group)=@_; $root//='';
    my $input=$root;
    # A terminal /. must not conceal a symlink from the no-follow check.
    while ($input =~ s{/+\z}{} || $input =~ s{/\.\z}{}) {}
    $input='/' if !length($input) && $root =~ m{\A/};
    die "unsafe content directory\n" if -l $input;
    $root=abs_path($root) // die "content project unavailable\n";
    die "unsafe content project\n" if $root =~ /[\x00-\x1f\x7f]/;
    my @s=lstat($root);
    die "unsafe content directory\n" unless @s && S_ISDIR($s[2]);
    # Check the caller's project-relative spelling before canonicalization can
    # hide a symlink. OS ancestors such as /tmp are outside this boundary.
    $input=getcwd()."/$input" unless $input =~ m{\A/};
    $input =~ s{/\.(?=/|\z)}{}g;
    my $probe=$input;
    while (length $probe) {
        if (lstat("$probe/.git")) {
            die "unsafe content directory\n" if -l $probe;
            my $top=abs_path($probe) // die "unsafe content directory\n";
            _source_spelling($top.substr($input,length($probe)),$top); last;
        }
        last unless $probe =~ s{/[^/]*\z}{};
    }
    return $root;
}
sub _git {
    my ($root,@args)=@_;
    my $pid=open my $g,'-|'; die "content project unavailable\n" unless defined $pid;
    if (!$pid) {
        Loomy::CollectorOwner::after_fork_child() if defined(&Loomy::CollectorOwner::after_fork_child);
        delete @ENV{grep {/\AGIT_/} keys %ENV};
        open STDERR,'>','/dev/null' or POSIX::_exit(1);
        exec('git','-C',$root,@args) or POSIX::_exit(1);
    }
    my ($raw,$ok)=('',1);
    while (length($raw)<=$GIT_BYTES) {
        my $n=sysread($g,my $b,8192);
        if (!defined($n)) {$ok=0; last}
        last unless $n; $raw.=$b;
    }
    $ok=0 if length($raw)>$GIT_BYTES;
    my $closed=close $g;
    return $ok && $closed ? $raw : undef;
}
sub _relation {
    my ($root)=@_;
    my $raw=_git($root,'rev-parse','--path-format=absolute','--git-common-dir','--show-toplevel');
    return unless defined $raw;
    my @lines=split /\n/,$raw,-1;
    return unless @lines==3 && $lines[2] eq '' && !grep {/[\x00-\x1f\x7f]/} @lines[0,1];
    my $common=abs_path($lines[0]); my $top=abs_path($lines[1]);
    return unless defined($common) && defined($top) && ($root eq $top || index($root,"$top/")==0);
    return {common=>$common,top=>$top,relative=>substr($root,length($top))};
}
sub _registered {
    my ($root)=@_; my $raw=_git($root,'worktree','list','--porcelain','-z');
    die "unsafe content directory\n" unless defined $raw;
    my (@roots,%seen);
    for my $field (split /\0/,$raw,-1) {
        next unless $field =~ /\Aworktree (.*)\z/s;
        my $path=$1;
        die "unsafe content directory\n" if $path =~ /[\x00-\x1f\x7f]/ || @roots>=$WORKTREES;
        push @roots,$path unless $seen{$path}++;
    }
    die "unsafe content directory\n" unless @roots;
    return \@roots;
}
sub _source_spelling {
    my ($root,$top)=@_;
    # R1 applies its private-group rule to runtime directories, not the source
    # project's mode. Retain no-follow spelling checks for ordinary projects
    # created under umask 002 without imposing a new source admission rule.
    my $part=$top; my @parts=($part);
    for my $name (split m{/},substr($root,length($top))) {
        next unless length $name; $part.="/$name"; push @parts,$part;
    }
    for my $path (@parts) {
        my @s=lstat($path);
        die "unsafe content directory\n" unless @s && S_ISDIR($s[2]);
    }
    die "unsafe content directory\n" unless (abs_path($root)//'') eq $root;
    return 1;
}
sub _source_dir {
    my ($path)=@_; my @s=lstat($path);
    die "unsafe content directory\n" unless @s && S_ISDIR($s[2]) && $s[4]==$<;
    sysopen my $h,$path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or die "unsafe content directory\n";
    _cloexec($h);
    my @f=stat($h);
    die "unsafe content directory\n" unless @f && S_ISDIR($f[2]) && $f[4]==$<
        && $s[0]==$f[0] && $s[1]==$f[1];
    return $h;
}
sub _source {
    my ($root,$top,$private_group)=@_;
    # Git's registered pathname and each project-relative component must be real
    # directories. A source symlink is not an additional admitted workspace.
    # R1's group/world-write restrictions protect the runtime store, not source
    # roots. Keep their same-UID/no-follow checks separate from dir's mode rules.
    die "unsafe content directory\n" if -l $top;
    my $h=_source_dir($top);
    my $part=$top;
    for my $name (split m{/},substr($root,length($top))) {
        next unless length $name; $part.="/$name";
        $h=_source_dir($part);
    }
    die "unsafe content directory\n" unless (abs_path($root)//'') eq $root;
    return 1;
}
sub shared_owner {
    my ($root,$suffix,$private_group)=@_;
    my @link=lstat("$root/$suffix");
    die "unsafe content directory\n" unless @link && S_ISLNK($link[2]) && $link[4]==$<;
    my $target=abs_path("$root/$suffix") // die "unsafe content directory\n";
    die "unsafe content directory\n" unless $target =~ m{\A(.+)/\Q$suffix\E\z};
    my $owner=$1; my $a=_relation($root); my $b=_relation($owner);
    die "unsafe content directory\n" unless $a && $b && $a->{common} eq $b->{common}
        && $a->{relative} eq $b->{relative};
    my %registered=map {$_=>1} @{_registered($root)};
    die "unsafe content directory\n" unless $registered{$a->{top}} && $registered{$b->{top}};
    _source($root,$a->{top},$private_group); _source($owner,$b->{top},$private_group);
    return $owner;
}
sub _entry_same {
    my ($a,$b)=@_; return @$a && @$b && !grep {$a->[$_]!=$b->[$_]} (0,1,2,3,4,5,7,9,10);
}
sub resolve {
    my ($root,$private_group)=@_; $root=_canonical($root,$private_group); my $requested=$root;
    my @entry=lstat("$root/.loomy");
    return {root=>$root,requested_root=>$requested} unless @entry;
    my ($alias,$parent,$ps);
    if (S_ISLNK($entry[2])) {
        $alias={path=>"$root/.loomy",stat=>\@entry};
        $root=shared_owner($root,'.loomy',$private_group);
    } elsif (-l "$root/.loomy/logs") {
        ($parent,$ps)=dir("$root/.loomy",undef,$private_group);
        my @link=lstat("$root/.loomy/logs");
        $alias={path=>"$root/.loomy/logs",stat=>\@link};
        $root=shared_owner($root,'.loomy/logs',$private_group);
    }
    die "unsafe content project\n" if $root =~ /[\x00-\x1f\x7f]/;
    my ($loomy,$ls)=dir("$root/.loomy",undef,$private_group);
    my ($logs,$ds);
    ($logs,$ds)=dir("$root/.loomy/logs",undef,$private_group) if lstat("$root/.loomy/logs");
    my $c={root=>$root,requested_root=>$requested,loomy=>$loomy,ls=>$ls,
        ($logs ? (logs=>$logs,ds=>$ds) : ()),
        ($alias ? (_alias=>$alias) : ()),
        ($parent ? (_alias_parent=>$parent,_alias_parent_stat=>$ps) : ()),
        ($private_group ? (_private_group=>$private_group) : ())};
    assert_current($c); return $c;
}
sub _assert_dir {
    my ($path,$h,$pin,$private_group)=@_;
    my @s=lstat($path); my @f=stat($h);
    die "content directory changed\n" unless @s && @f && S_ISDIR($s[2]) && S_ISDIR($f[2])
        && $s[4]==$< && $f[4]==$< && $s[0]==$pin->[0] && $s[1]==$pin->[1]
        && $f[0]==$pin->[0] && $f[1]==$pin->[1];
    my $lenient=$path =~ m{(?:\A|/)(?:\.loomy|memory)\z} ? 1 : 0;
    die "unsafe directory: $path (group/world writable)\n" if dir_unsafe($s[2],$s[5],$lenient,$private_group)
        || dir_unsafe($f[2],$f[5],$lenient,$private_group);
}
sub assert_current {
    my ($c)=@_;
    die "content directory changed\n" unless ref($c) eq 'HASH' && defined($c->{root}) && defined($c->{requested_root});
    die "content directory changed\n" unless (abs_path($c->{requested_root})//'') eq $c->{requested_root}
        && (abs_path($c->{root})//'') eq $c->{root};
    my $private_group=$c->{_private_group};
    if (!$c->{loomy}) {die "content directory changed\n" if lstat("$c->{requested_root}/.loomy"); return 1}
    _assert_dir("$c->{root}/.loomy",$c->{loomy},$c->{ls},$private_group);
    if ($c->{logs}) {_assert_dir("$c->{root}/.loomy/logs",$c->{logs},$c->{ds},$private_group)}
    else {die "content directory changed\n" if lstat("$c->{root}/.loomy/logs")}
    if (my $alias=$c->{_alias}) {
        my @now=lstat($alias->{path});
        die "content directory changed\n" unless _entry_same($alias->{stat},\@now)
            && S_ISLNK($now[2]) && (abs_path($alias->{path})//'') eq
                "$c->{root}/".($c->{_alias_parent} ? '.loomy/logs' : '.loomy');
        _assert_dir("$c->{requested_root}/.loomy",$c->{_alias_parent},$c->{_alias_parent_stat},$private_group)
            if $c->{_alias_parent};
    } else {die "content directory changed\n" unless $c->{root} eq $c->{requested_root}}
    return 1;
}
sub scope_set {
    my ($c)=@_; assert_current($c);
    my @roots;
    if ($c->{loomy}) {
        my $relation=_relation($c->{root});
        if (!$relation) {push @roots,$c->{root}}
        else {
            for my $top (@{_registered($c->{root})}) {
                next if -l $top;
                my $canonical=abs_path($top); next unless defined($canonical) && $canonical eq $top;
                my $root="$top$relation->{relative}";
                my $candidate=eval {
                    _source($root,$top,$c->{_private_group});
                    my $r=_relation($root);
                    die "unsafe content directory\n" unless $r && $r->{common} eq $relation->{common}
                        && $r->{relative} eq $relation->{relative};
                    resolve($root,$c->{_private_group});
                };
                next unless $candidate && $candidate->{loomy};
                my ($a,$b)=$c->{logs} ? ($c->{ds},$candidate->{ds}) : ($c->{ls},$candidate->{ls});
                next unless $a && $b && $a->[0]==$b->[0] && $a->[1]==$b->[1];
                next if !$c->{logs} && $candidate->{logs};
                push @roots,$root;
            }
        }
    }
    assert_current($c);
    my %seen; @roots=sort grep {!$seen{$_}++} @roots;
    # Length framing is unambiguous even when a valid path contains punctuation.
    my $revision=sha256_hex(join('',map {length($_).":$_"} @roots));
    return {roots=>\@roots,revision=>$revision};
}
1;
