# Project-local content grants, scoped labels and structural projections.
package Loomy::ContentPolicy;
use strict;
use warnings;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :flock :mode O_NOFOLLOW O_NONBLOCK);
use IO::Handle;
use JSON::PP ();
use POSIX qw(strftime tcflush TCIFLUSH);
use Time::Local qw(timegm);
use Time::HiRes qw(stat lstat sleep);

my $LIB = abs_path(__FILE__); $LIB =~ s{/[^/]+$}{};
require "$LIB/runtime-paths.pl";
require "$LIB/policy-record.pl";
my $JSON = JSON::PP->new->utf8->canonical;
my @SOURCES = qw(explicit-user explicit-lead claude-description codex-path-slug codex-nickname codex-role);
my @KEYS = qw(version journal_content policy_generation label_sources label_max_graphemes label_max_bytes
    codex_component_max_chars label_store_max_bytes private_results results_max_records
    results_max_record_bytes results_max_total_bytes results_max_age_days grant_prompt_version);
my %MAX = (label_max_graphemes=>96, label_max_bytes=>384, codex_component_max_chars=>40,
    label_store_max_bytes=>1048576, results_max_records=>200, results_max_record_bytes=>1048576,
    results_max_total_bytes=>16777216, results_max_age_days=>30);
my %KEY = map {$_=>1} @KEYS;
my %SOURCE = map {$_=>1} @SOURCES;
my $POLICY = 'content-policy.conf';
my $LABELS = 'display-context-v1.jsonl';
my $FULL = 'display-context-full';
my $MAX_GENERATION = 9007199254740991;

# Structural hooks usually handle ASCII identities and no display text. Load the
# Unicode codec only for labels, legacy excerpts, UI or Unicode project names.
sub _encode_utf8 { require Encode; return Encode::encode('UTF-8',$_[0]) }
sub _decode_utf8 {
    my ($bytes,$strict)=@_; require Encode;
    return Encode::decode('UTF-8',$bytes,$strict ? Encode::FB_CROAK() : 0);
}
sub defaults {
    return {version=>1, journal_content=>'structural', policy_generation=>0, label_sources=>'none',
        %MAX, private_results=>'off', grant_prompt_version=>0};
}
sub recommended_sources { return join ',', @SOURCES }
sub _scalar { return defined($_[0]) && !ref($_[0]) }
sub _id { return _scalar($_[0]) && $_[0] =~ /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,99}\z/ }
sub _sources {
    my ($v)=@_; return [] if defined($v) && $v eq 'none';
    die "invalid content policy\n" unless _scalar($v) && length($v);
    my %seen; my @s=split /,/, $v, -1;
    die "invalid content policy\n" if grep {!$SOURCE{$_} || $seen{$_}++} @s;
    return \@s;
}
sub _validate_policy {
    my ($p)=@_;
    die "invalid content policy\n" unless ref($p) eq 'HASH' && keys(%$p)==@KEYS && !grep {!$KEY{$_}} keys %$p;
    for (@KEYS) { die "invalid content policy\n" unless _scalar($p->{$_}) }
    die "invalid content policy\n" unless $p->{version} eq '1'
        && $p->{journal_content} =~ /\A(?:structural|legacy-excerpts)\z/
        && $p->{private_results} =~ /\A(?:on|off)\z/ && $p->{grant_prompt_version} =~ /\A[01]\z/
        && $p->{policy_generation} =~ /\A(?:0|[1-9][0-9]{0,15})\z/ && $p->{policy_generation}<=$MAX_GENERATION;
    for (keys %MAX) {
        die "invalid content policy\n" unless $p->{$_} =~ /\A[1-9][0-9]{0,8}\z/ && $p->{$_}<=$MAX{$_};
    }
    my %s=map {$_=>1} @{_sources($p->{label_sources})};
    $p->{label_sources}=join(',',grep {$s{$_}} @SOURCES) || 'none';
    return $p;
}
sub parse_policy {
    my ($raw)=@_; die "invalid content policy\n" if !defined($raw) || length($raw)>16384;
    my %p;
    for (split /\n/, $raw, -1) {
        next if $_ eq '';
        # record_nonce: random bytes Loomy writes so the consent record's hash covers content nobody can predict (ADR-0012); no meaning here.
        if (/\Arecord_nonce=([0-9a-f]{32})\z/) { die "invalid content policy\n" if exists $p{record_nonce}; $p{record_nonce}=$1; next }
        die "invalid content policy\n" unless /\A([a-z_]+)=(\S+)\z/ && $KEY{$1} && !exists($p{$1});
        $p{$1}=$2;
    }
    delete $p{record_nonce};
    return _validate_policy(\%p);
}

# Work relative to pinned directory descriptors. Renaming an ancestor cannot redirect
# a write; check the registered locations again before committing. Existing modes stay intact.
# Group write is tolerated on .loomy and .loomy/memory only when the directory
# group is the user's private group (group name == user name, nobody else a
# member). Shared groups such as macOS staff, and any world write, are refused.
sub _group_info { my @g=getgrgid($_[0]); return @g ? ($g[0],$g[3]) : () }
sub _private_group {
    my ($gid)=@_; my @pw=getpwuid($<); my ($name,$members)=_group_info($gid);
    # getgrgid lists only secondary members: also require the group to be the user's own primary group.
    return 0 unless @pw && defined($name) && $name eq $pw[0] && $gid==$pw[3];
    for my $m (split ' ',$members//'') { return 0 unless $m eq $pw[0] }
    return 1;
}
sub _dir_unsafe {
    return Loomy::RuntimePaths::dir_unsafe(@_,\&_private_group);
}
sub _dir {
    my ($p,$display)=@_; return Loomy::RuntimePaths::dir($p,$display,\&_private_group);
}
sub _same {
    my ($a,$b)=@_; return @$a && @$b && $a->[0]==$b->[0] && $a->[1]==$b->[1]
        && $a->[2]==$b->[2] && $a->[3]==$b->[3] && $a->[4]==$b->[4] && $a->[7]==$b->[7]
        && $a->[9]==$b->[9] && $a->[10]==$b->[10];
}
sub _shared_owner {
    my ($root,$suffix)=@_; return Loomy::RuntimePaths::shared_owner($root,$suffix,\&_private_group);
}
sub _context {
    my ($root,$create)=@_;
    my $c=Loomy::RuntimePaths::resolve($root,\&_private_group);
    die "unsafe content directory\n" unless $c->{loomy}; $root=$c->{root};
    # Leak barrier: creating (or later renaming into) a tracked or unverifiable .loomy/logs is refused before anything
    # is made there (the lock files, content-policy.conf), whatever the writer.
    die "content policy not saved: .loomy/logs is tracked by Git or Git cannot say; run loomy doctor --fix\n" if $create && !_label_gate($root);
    my $cwd; sysopen $cwd,'.',O_RDONLY or die "content directory unavailable\n";
    chdir $c->{loomy} or die "content directory unavailable\n";
    my ($logs,$ds,$project_id); my $ok=eval {
        $project_id=_project_id($root,$create);
        if (!lstat('logs') && $create) {
            my $mask=umask 0077; my $made=mkdir 'logs',0700; umask $mask;
            die "content directory unavailable\n" unless $made || -d 'logs';
        }
        ($logs,$ds)=_dir('logs',"$root/.loomy/logs") if lstat('logs');
        @$c{qw(logs ds)}=($logs,$ds); Loomy::RuntimePaths::assert_current($c); 1;
    }; my $err=$@;
    chdir $cwd or die "content directory unavailable\n"; die $err unless $ok;
    $c->{project_id}=$project_id; return $c;
}
# Pin the old namespace once, before any new references are made. Keeping that
# namespace is the migration: historical journal/label/memory references need no
# rewrite. The file lives in the shared .loomy, independently of its current path.
# The identity file may only be stored where it cannot appear as an untracked file: outside any Git work tree, or
# where a .gitignore / info/exclude of the owning repository already ignores it. Read directly: no process on the
# writer path. Only trailing spaces are ignored (Git strips nothing else); a `!` line naming .loomy or project-id,
# or a .loomy/.gitignore, means the outcome cannot be judged from the text: not pinned.
sub _ignore_text {
    my ($f)=@_; return '' unless -f $f && !-l $f && -s _ <= 1048576; open my $h,'<',$f or return '';
    local $/; my $t=<$h>//''; close $h; return $t;
}
sub _git_exclude_file {
    my ($dotgit)=@_; return "$dotgit/info/exclude" if -d $dotgit;
    # Worktree or submodule: ".git" is a file naming the real directory; info/exclude lives in the common one.
    my $line=_ignore_text($dotgit); return undef unless $line =~ /\Agitdir: (.+?)\r?\n?\z/;
    my $gd=$1; $gd="$1/$gd" if $gd !~ m{\A/} && $dotgit =~ m{\A(.*)/\.git\z};
    my $common=_ignore_text("$gd/commondir"); $common =~ s/\s+\z//;
    $gd=$common =~ m{\A/} ? $common : "$gd/$common" if length $common;
    return "$gd/info/exclude";
}
sub _identity_ignorable {
    my ($root)=@_;
    return 0 if -e "$root/.loomy/.gitignore" || -l "$root/.loomy/.gitignore";
    my $top=$root; $top =~ s{/[^/]*\z}{} until $top eq '' || -e "$top/.git";
    return 1 if $top eq ''; # No owning Git work tree (the filesystem root itself is not one).
    my $rel=substr($root,length $top); $rel =~ s{\A/}{};
    my $q=quotemeta($rel); my $ignore=qr{\.loomy(?:/(?:project-id)?)?};
    # Conservative on purpose: an unpinned (path-derived) identity is the safe fallback. A nested .gitignore between the
    # repository top and the project may re-include anything, and a parent rule matches a path only when that path
    # carries no pattern metacharacter or comment marker.
    if ($top ne $root) {
        my $d=$root; while (($d =~ s{/[^/]*\z}{}) && length($d) > length($top)) {
            return 0 if -e "$d/.gitignore" || -l "$d/.gitignore";
        }
    }
    my $anchored=length($rel) ? qr{\A(?:/?$q/$ignore|\.loomy/?)\z} : qr{\A/?$ignore\z};
    my @sources=(["$root/.gitignore",qr{\A/?$ignore\z},0]);
    push @sources,["$top/.gitignore",$anchored,1] if $top ne $root;
    my $ex=_git_exclude_file("$top/.git"); push @sources,[$ex,$anchored,$top ne $root ? 1 : 0] if defined $ex;
    my ($found,$parent_found)=(0,0);
    for my $src (@sources) {
        my ($f,$re,$parent)=@$src; my $t=_ignore_text($f); next unless length $t;
        for my $line (split /\n/,$t) {
            return 0 if $line =~ /\A!/; # Any negation, whatever it names (globs such as !* included).
            my $l=$line; $l =~ s/ +\z//;
            if ($l =~ $re) {$found=1; $parent_found=1 if $parent}
        }
    }
    return 0 unless $found;
    return 0 if $parent_found && ($rel !~ m{\A[A-Za-z0-9._/-]+\z} || grep {/\A#/} split m{/},$rel);
    return 1;
}
# The identity a reader or writer would derive while no project-id file exists.
sub _derived_id {
    my ($root)=@_;
    my $id='p'.sha256_hex(utf8::is_utf8($root) ? _encode_utf8($root) : $root);
    # A project may already have moved since the path-based writer ran.
    # Only a private, schema-valid local label record can supply its old ID.
    my $old=eval {(sub {
        my ($raw)=_read('logs/display-context-v1.jsonl',1048576);
        for (split /\n/,$raw//'') {
            my $r=eval {$JSON->decode($_)};
            return $r->{project_id} if ref($r) eq 'HASH'
                && ($r->{project_id}//'') =~ /\Ap[0-9a-f]{64}\z/ && _valid_label($r,$r->{project_id});
        }
        return;
    })->()};
    $id=$old if defined $old;
    return $id;
}
sub _project_id {
    my ($root,$create)=@_; my $name='project-id';
    unless (lstat($name)) {
        my $id=_derived_id($root);
        # Readers derive the identity without storing it. A writer pins it only where it cannot show up as an
        # untracked file (projects whose managed .gitignore block predates it are repaired first).
        return $id unless $create && _identity_ignorable($root);
        my $mask=umask 0077;
        if (sysopen my $h,$name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) {
            my $ok=eval {print {$h} "$id\n" or die; $h->flush && $h->sync or die; close $h or die; 1};
            umask $mask; die "content identity unavailable\n" unless $ok;
        } else {umask $mask; die "content identity unavailable\n" unless $!{EEXIST}}
    }
    # Another process can be between O_EXCL and its small, durable write.
    for (1..10) {
        my $raw; my $ok=eval {($raw)=_read($name,128); 1};
        die $@ unless $ok || $@ eq "content file changed\n";
        return $1 if defined($raw) && $raw =~ /\A(p[0-9a-f]{64})\n\z/;
        die "content identity unavailable\n" if defined($raw) && length($raw);
        sleep 0.01;
    }
    die "content identity unavailable\n";
}
sub _in_context {
    my ($ctx,$code)=@_; die "content directory unavailable\n" unless $ctx->{logs};
    my $cwd; sysopen $cwd,'.',O_RDONLY or die "content directory unavailable\n";
    chdir $ctx->{logs} or die "content directory unavailable\n";
    my $mask=umask 0077;
    my ($result,$ok); $ok=eval {$result=$code->(); 1}; my $err=$@; umask $mask;
    chdir $cwd or die "content directory unavailable\n"; die $err unless $ok;
    return $result;
}
sub _assert_context {
    my ($c)=@_;
    # Doctor's existing read-only caller carries stat pins rather than handles.
    if (!exists($c->{requested_root})) {
        my $current=Loomy::RuntimePaths::resolve($c->{root},\&_private_group);
        die "content directory changed\n" unless $current->{logs} && $c->{ls} && $c->{ds}
            && $current->{ls}[0]==$c->{ls}[0] && $current->{ls}[1]==$c->{ls}[1]
            && $current->{ds}[0]==$c->{ds}[0] && $current->{ds}[1]==$c->{ds}[1];
        return Loomy::RuntimePaths::assert_current($current);
    }
    die "content directory changed\n" unless $c->{logs};
    return Loomy::RuntimePaths::assert_current($c);
}
sub _private_stat {
    my ($name)=@_; my @s=lstat($name); return \@s unless @s;
    die "unsafe content file\n" unless S_ISREG($s[2]) && $s[3]==1 && $s[4]==$< && ($s[2]&0777)==0600;
    return \@s;
}
sub _read {
    my ($name,$limit)=@_; my $s=_private_stat($name); return (undef,$s) unless @$s;
    die "content file too large\n" if $s->[7]>$limit;
    sysopen my $h,$name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or die "content file unavailable\n";
    die "content file changed\n" unless _same($s,[stat($h)]);
    my $raw=''; while (length($raw)<=$limit) {
        my $n=sysread($h,my $b,$limit+1-length($raw)); die "content read failed\n" unless defined $n;
        last unless $n; $raw.=$b;
    }
    die "content file changed\n" if length($raw)>$limit || !_same($s,[lstat($name)]) || !_same($s,[stat($h)]);
    return ($raw,$s);
}
sub _atomic {
    my ($ctx,$name,$bytes,$before)=@_; _assert_context($ctx);
    die "content file changed\n" unless _same_or_absent($before,_private_stat($name));
    my $tmp=".$name.$$-".unpack('H*',_random(8));
    sysopen my $h,$tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600 or die "content write failed\n";
    my $ok=eval {
        print {$h} $bytes or die "content write failed\n";
        $h->flush && $h->sync or die "content write failed\n";
        my $written=[stat($h)];
        close $h or die "content write failed\n";
        _assert_context($ctx);
        die "content file changed\n" unless _same($written,_private_stat($tmp));
        die "content file changed\n" unless _same_or_absent($before,_private_stat($name));
        rename $tmp,$name or die "content write failed\n";
        # The consent record after the rename, keyed on the final file (inode and change time, taken now) and its content: a
        # byte-identical file landing on a reused inode cannot match. Before the record exists, or if this fails, the policy is
        # absent (consent asked again): fail closed.
        if ($name eq $POLICY) {
            my @f=stat($name); die "content write failed\n" unless @f;
            Loomy::PolicyRecord::record($ctx->{root},Loomy::PolicyRecord::_id(@f),sha256_hex($bytes));
        }
        1;    }; my $err=$@; close $h if defined(fileno($h)); unlink $tmp unless $ok; die $err unless $ok;
}
sub _same_or_absent { return !@{$_[0]} && !@{$_[1]} || _same(@_) }
sub _random {
    my ($n)=@_; sysopen my $h,'/dev/urandom',O_RDONLY or die "content identity unavailable\n";
    my $v=''; while (length($v)<$n) {my $r=sysread($h,my $b,$n-length($v)); die "content identity unavailable\n" unless $r; $v.=$b} return $v;
}
sub _lock {
    my ($ctx,$name,$retries)=@_; $name//='content-policy.lock'; $retries//=100;
    _assert_context($ctx); my $s=_private_stat($name); my $h;
    if (@$s) {sysopen $h,$name,O_RDWR|O_NOFOLLOW|O_NONBLOCK or die "content lock unavailable\n"}
    else {
        unless (sysopen $h,$name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0600) {
            $s=_private_stat($name); die "content lock unavailable\n" unless @$s;
            sysopen $h,$name,O_RDWR|O_NOFOLLOW|O_NONBLOCK or die "content lock unavailable\n";
        }
    }
    # Hooks/writers must degrade after at most one second, never wait for a
    # terminal or another process indefinitely. T2 shares this bounded helper.
    while (!flock($h,LOCK_EX|LOCK_NB)) {
        die "content lock unavailable\n" unless $!{EWOULDBLOCK} || $!{EAGAIN};
        die "content lock busy\n" unless $retries-- > 0;
        sleep 0.01;
    }
    die "content lock changed\n" unless _same(_private_stat($name),[stat($h)]);
    _assert_context($ctx); return $h;
}
sub _stored {
    my ($ctx)=@_; return {policy=>defaults(),source=>'default',valid=>1,stat=>[]} unless $ctx->{logs};
    # A policy file in a logs directory the barrier refuses (tracked by Git, or Git cannot say) may have been shipped by
    # a clone, checked out private and so passing the permission checks: it is absent, never trusted, never a consent.
    return {policy=>defaults(),source=>'default',valid=>1,stat=>[],gated=>1} unless _label_gate($ctx->{root},1);   # gated: the callers say why the grants are ignored
    my ($raw,$stat,$p);
    for (1..3) {
        my $unverified=0;
        my $ok=eval {
            ($raw,$stat)=_read($POLICY,16384);
            # ADR-0012: a policy is a consent, trusted only when this machine's Loomy wrote it (user-owned record: same
            # root, inode and content). Any other file, whatever its layout, reads as absent; its stat is kept so that
            # a writer replaces it atomically.
            if (defined($raw) && !Loomy::PolicyRecord::trusted_read($ctx->{root},$stat,$raw)) {$unverified=1; $p=defaults(); eval {Loomy::PolicyRecord::forget_if_stale($ctx->{root})}}
            else {$p=defined($raw) ? parse_policy($raw) : defaults()}
            1};
        return {policy=>$p,source=>(defined($raw) && !$unverified) ? 'project' : 'default',valid=>1,stat=>$stat,($unverified ? (unverified=>1) : ())} if $ok;
        # An atomic writer may replace the inode during an unlocked preflight.
        # Retry that race only; malformed/unsafe files remain closed immediately.
        last unless $@ eq "content file changed\n";
    }
    return {policy=>defaults(),source=>'invalid',valid=>0,stat=>$stat//[]};
}
sub load_policy {
    my ($root)=@_;
    # Stored-policy inspection is also the first-use writer's preflight. Its
    # validity describes parsing, not an effective grant or attested identity.
    return _snapshot_read($root,'effective',sub {
        my ($c,$stored)=@_; return $c->{loomy} ? $stored : undef;
    })->{value} // {policy=>defaults(),source=>'invalid',valid=>0};
}

# Supported managed paths retain parent/attempt markers even when launch.sh removes
# CLI-specific markers. Native CLI children also have provider markers. No env token
# or generated assertion is a substitute for reading a human answer on stdin.
my ($ANCESTOR_PID,$AGENT_ANCESTOR,$AGENT_ANCESTOR_NAME);
sub _agent_ancestor {
    return $AGENT_ANCESTOR if defined($ANCESTOR_PID) && $ANCESTOR_PID==$$;
    $ANCESTOR_PID=$$; $AGENT_ANCESTOR=0; $AGENT_ANCESTOR_NAME='';
    my $parent=getppid(); my %seen;
    for (1..32) {
        last if $parent<=1 || $seen{$parent}++;
        my $pid=open my $ps,'-|'; return $AGENT_ANCESTOR=1 unless defined $pid;
        if (!$pid) {
            open STDERR,'>','/dev/null' or POSIX::_exit(1);
            exec('ps','-p',"$parent",'-o','ppid=','-o','comm=') or POSIX::_exit(1);
        }
        my $line=<$ps>//''; my $ok=close $ps;
        # Process inspection unavailable is not evidence of a human origin.
        return $AGENT_ANCESTOR=1 unless $ok && $line =~ /\A\s*([0-9]+)\s+(.+?)\s*\z/;
        $parent=0+$1; my $comm=$2; $comm =~ s{.*/}{};
        if ($comm =~ /\A(?:codex|claude)(?:[-.].*)?\z/i || $comm =~ /\A(?:node|nodejs)\z/i) {
            $AGENT_ANCESTOR_NAME=$comm =~ /\Acodex/i ? 'codex'
                : $comm =~ /\Aclaude/i ? 'claude' : lc($comm);
            return $AGENT_ANCESTOR=1;
        }
    }
    return $AGENT_ANCESTOR=1 if $parent>1; # Incomplete/cyclic ancestry is not a human attestation.
    return $AGENT_ANCESTOR;
}
sub managed_origin {
    for (qw(LOOMY_DELEGATION LOOMY_CLI_MANAGED LOOMY_PARENT_ID LOOMY_ATTEMPT LOOMY_ATTEMPT_ID
        LOOMY_EVENT_PARENT_ID LOOMY_CLI_ID LOOMY_CLI_SESSION_ID LOOMY_CLI_BRIDGE_CHECKED LOOMY_CLI_PROBE
        LOOMY_HOOK LOOMY_HOOK_CONTEXT LOOMY_BRIDGE LOOMY_BRIDGE_OK LOOMY_MANAGED
        CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION
        CODEX_THREAD_ID CODEX_SESSION_ID CODEX_TOOL_CALL_ID CODEX_SANDBOX CODEX_SANDBOX_NETWORK_DISABLED
        CODEX_MANAGED_BY_NPM CODEX_MANAGED_BY_BUN BUN)) {
        return 1 if length($ENV{$_}//'');
    }
    return _agent_ancestor();
}
sub agent_ancestor_name { return $AGENT_ANCESTOR_NAME // ''; }
sub human_tty { return -t STDIN && -t STDOUT && !managed_origin() }
sub _effective {
    my ($ctx,$stored)=@_; my %p=%{$stored->{policy}};
    $p{source}=$stored->{source}; $p{valid}=$stored->{valid}; $p{project_id}=$ctx->{project_id};
    $p{project}=display_path($ctx->{root}); $p{journal_enabled}=($ENV{LOOMY_JOURNAL}//'1') ne '0' ? 1 : 0;
    if (exists $ENV{LOOMY_JOURNAL_CONTENT}) {
        my $v=$ENV{LOOMY_JOURNAL_CONTENT}; my $bound=$ENV{LOOMY_CONTENT_PROJECT}//'';
        my $resolved=$bound =~ m{\A/} ? abs_path($bound) : undef;
        if ($v eq 'structural') {$p{journal_content}='structural'; $p{source}='environment'}
        elsif ($v eq 'legacy-excerpts' && !managed_origin() && defined($resolved)
            && ($resolved eq $ctx->{root} || $resolved eq "$ctx->{root}/.loomy/logs")
            && $p{journal_content} eq 'legacy-excerpts' && $stored->{valid}) {$p{source}='environment'}
        else {$p{journal_content}='structural'; $p{source}='environment-denied'}
    }
    if (($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0') {
        @p{qw(journal_content label_sources private_results source)}=('structural','none','off','tasks-veto');
    }
    return \%p;
}
sub effective_policy {
    return policy_snapshot($_[0],'effective');
}

# Both modes share pinned paths and never store identity. R1 readers retain the
# unstored namespace; strict R2 exports require an existing project-id file.
sub _snapshot_context {
    my ($root,$mode)=@_; my $c=Loomy::RuntimePaths::resolve($root,\&_private_group);
    $c->{identity_mode}=$mode;
    return $c unless $c->{loomy};
    my $cwd; sysopen $cwd,'.',O_RDONLY or die "content directory unavailable\n";
    chdir $c->{loomy} or die "content directory unavailable\n";
    my ($raw,$identity_stat); my $ok=eval {
        my $present=lstat('project-id') ? 1 : 0;
        # Retain R1's bounded wait for a writer between O_EXCL and its first
        # durable identity write. create=0 never pins the fallback namespace.
        $c->{project_id}=_project_id($c->{root},0) if $mode eq 'effective';
        # The file may have appeared between the sample above and the derivation, which
        # then returned its bytes. An identity absent at the start is accepted only
        # through _concurrent_pin: equal to the id derived without the file.
        $c->{project_id}=_derived_id($c->{root}) if $mode eq 'effective' && !$present && lstat('project-id');
        ($raw,$identity_stat)=_read_identity($c,$present);
        die "content identity changed\n" if $mode eq 'effective'
            && ($present && !defined($raw) || defined($raw) && $raw ne "$c->{project_id}\n");
        1;
    }; my $err=$@;
    chdir $cwd or die "content directory unavailable\n"; die $err unless $ok;
    @$c{qw(identity_raw identity_stat)}=($raw,$identity_stat);
    $c->{project_id}=$1 if defined($raw) && $raw =~ /\A(p[0-9a-f]{64})\n\z/;
    return $c;
}
# A concurrent writer may pin an absent identity while an effective reader runs: the file
# can appear, still empty or mid-write, between the derivation and the pin. Accept only
# the same namespace the reader derived; a present identity that changes stays closed.
sub _concurrent_pin {
    my ($c,$present)=@_;
    return 0 unless ($c->{identity_mode}//'') eq 'effective' && !$present && defined($c->{project_id});
    return 0 unless lstat('project-id') && _project_id($c->{root},0) eq $c->{project_id};
    return 1;
}
sub _read_identity {
    my ($c,$present)=@_; my ($raw,$s);
    my $ok=eval {($raw,$s)=_read('project-id',128); 1}; my $err=$@;
    return ($raw,$s) if $ok && (!defined($raw) || ($c->{identity_mode}//'') ne 'effective'
        || $raw eq "$c->{project_id}\n");
    die $err unless $ok || $err eq "content file changed\n";
    return _read('project-id',128) if _concurrent_pin($c,$present);
    die $err unless $ok; return ($raw,$s);
}
sub _assert_snapshot_context {
    my ($c)=@_; Loomy::RuntimePaths::assert_current($c); return unless $c->{loomy};
    my $cwd; sysopen $cwd,'.',O_RDONLY or die "content directory unavailable\n";
    chdir $c->{loomy} or die "content directory unavailable\n";
    my $ok=eval {
        my $now=_private_stat('project-id');
        unless (_same_or_absent($c->{identity_stat},$now)) {
            die "content identity changed\n" unless $c->{identity_stat} && !@{$c->{identity_stat}} && _concurrent_pin($c,0);
            (undef,$c->{identity_stat})=_read('project-id',128);
        }
        1;
    }; my $err=$@;
    chdir $cwd or die "content directory unavailable\n"; die $err unless $ok;
}
# The optional callback is private reader plumbing; it sees the same pinned
# policy/identity snapshot, and its result is released only after revalidation.
sub _snapshot_read {
    my ($root,$mode,$reader)=@_;
    die "invalid content identity mode\n" unless _scalar($mode) && $mode =~ /\A(?:effective|strict)\z/;
    my $c=eval {_snapshot_context($root,$mode)};
    my $invalid=sub {return {policy=>{%{defaults()},source=>'invalid',valid=>0,journal_enabled=>0,
        identity_state=>'invalid',policy_state=>'invalid'}}};
    return $invalid->() unless $c;
    my $identity=!defined($c->{identity_raw}) ? 'missing' : defined($c->{project_id}) ? 'present' : 'invalid';
    my ($p,$stored,$value); my $ok=eval {
        $stored=$c->{logs} ? _in_context($c,sub {_stored($c)}) : _stored($c);
        _assert_snapshot_context($c);
        $p=_effective($c,$stored);
        $p->{identity_state}=$identity; $p->{policy_state}=$stored->{source};
        $p->{gated}=1 if $stored->{gated};
        $p->{unverified}=1 if $stored->{unverified};
        if (!$c->{loomy} || $identity eq 'invalid' || ($mode eq 'strict' && ($identity ne 'present' || !$stored->{valid}))) {
            # Keep origin diagnostics, not a usable grant or invented identity.
            $p={%{defaults()},project=>$p->{project},source=>'invalid',valid=>0,journal_enabled=>0,
                identity_state=>$identity,policy_state=>$stored->{source},
                ($identity eq 'present' ? (project_id=>$c->{project_id}) : ())};
            $p->{source}='tasks-veto' if ($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0';
        }
        $value=$reader->($c,$stored,$p) if $reader;
        _assert_snapshot_context($c); 1;
    };
    return $invalid->() unless $ok;
    return {policy=>$p,stored=>$stored,value=>$value};
}
sub policy_snapshot {return _snapshot_read($_[0],$_[1]//'strict')->{policy}}

# Explicit output selection is narrower than journal compatibility. Consume an
# existing same-project grant only; a flag/environment never persists consent.
# Exporters pass this result to project_with_policy, never project_event.
sub export_policy_snapshot {
    my ($root,$mode)=@_; $mode//='structural';
    die "invalid content export mode\n" unless _scalar($mode) && $mode =~ /\A(?:structural|legacy-excerpts)\z/;
    my $p=policy_snapshot($root);
    die "content export grant unavailable\n" unless $p->{identity_state} eq 'present';
    if ($mode eq 'legacy-excerpts' && ($ENV{LOOMY_JOURNAL_TASKS}//'1') ne '0') {
        die "content export grant unavailable\n" unless $p->{valid} && $p->{identity_state} eq 'present'
            && $p->{policy_state} eq 'project' && $p->{journal_content} eq 'legacy-excerpts';
    } else {$p->{journal_content}='structural'}
    return $p;
}
# Writers can hold this same lock across resolution and their protected commit (T2/T3).
sub with_policy {
    my ($root,$code)=@_; my $c=_context($root,1);
    return _in_context($c,sub {my $lock=_lock($c); return $code->(_effective($c,_stored($c)))});
}
sub _widening {
    my ($a,$b)=@_; return 1 if $a->{journal_content} ne $b->{journal_content} && $b->{journal_content} eq 'legacy-excerpts';
    return 1 if $a->{private_results} ne $b->{private_results} && $b->{private_results} eq 'on';
    my %old=map {$_=>1} @{_sources($a->{label_sources})};
    return 1 if grep {!$old{$_}} @{_sources($b->{label_sources})};
    return 1 if grep {$b->{$_}>$a->{$_}} keys %MAX; return 0;
}
sub _save_policy {
    my ($c,$stored,$p)=@_;
    die "invalid stored content policy\n" unless $stored->{valid}; _validate_policy($p);
    return $p if join('\n',map {$p->{$_}} @KEYS) eq join('\n',map {$stored->{policy}{$_}} @KEYS);
    die "content generation exhausted\n" if $stored->{policy}{policy_generation}>=$MAX_GENERATION;
    $p->{policy_generation}=$stored->{policy}{policy_generation}+1;
    _atomic($c,$POLICY,join('',map {"$_=$p->{$_}\n"} @KEYS).'record_nonce='.unpack('H*',_random(16))."\n",$stored->{stat}); return $p;
}

# All translations are supplied by content-policy.sh from the public i18n dictionary.
sub _message {
    my ($key,@args)=@_; my $fmt=$ENV{"LOOMY_CONTENT_UI_$key"}//die "content translation unavailable\n";
    $fmt=_decode_utf8($fmt,1) unless utf8::is_utf8($fmt);
    @args=map {utf8::is_utf8($_) ? $_ : _decode_utf8($_,1)} @args;
    return _encode_utf8(sprintf($fmt,@args)."\n");
}
sub _say { print STDOUT _message(@_) }
sub _shell_quote {my ($s)=@_; $s =~ s/'/'\\''/g; return "'$s'"}
sub display_path {
    my ($path)=@_;
    $path=_decode_utf8($path) if !utf8::is_utf8($path) && $path =~ /[^\x00-\x7f]/;
    $path =~ s/([\p{Cc}\p{Cf}\x{e0000}-\x{e007f}])/sprintf('\\u{%04X}',ord($1))/ge;
    return $path;
}
sub _answer {
    my ($default,$question)=@_; die "human content confirmation required\n" unless human_tty();
    # Flush BEFORE displaying each question: buffered Enter/answers must never
    # answer this or a later question. sysread avoids Perl read-ahead as well.
    defined(tcflush(fileno(STDIN),TCIFLUSH)) or die "content confirmation aborted\n";
    _say($question);
    local $SIG{ALRM}=sub {die "content confirmation aborted\n"}; alarm 120;
    my $line=''; while (1) {
        my $n=sysread(STDIN,my $ch,1); if (!defined($n) || !$n) {alarm 0; die "content confirmation aborted\n"}
        last if $ch eq "\n"; $line.=$ch if length($line)<=16;
    }
    alarm 0; $line =~ s/\r\z//;
    return $default if $line eq '';
    return 1 if $line =~ /\A(?:y|o|yes|oui)\z/i;
    return 0 if $line =~ /\A(?:n|no|non)\z/i;
    die "content confirmation aborted\n";
}
sub _describe {
    my ($c,$p)=@_; _say('TITLE',display_path($c->{root}));
    _say('PRIVACY', $ENV{'LOOMY_CONTENT_UI_'.($p->{journal_content} eq 'structural' ? 'STRUCTURE' : 'LEGACY')},
        $ENV{'LOOMY_CONTENT_UI_'.($p->{label_sources} eq 'none' ? 'OFF' : 'ON')},
        $ENV{'LOOMY_CONTENT_UI_'.($p->{private_results} eq 'off' ? 'OFF' : 'ON')});
    if ($p->{label_sources} eq 'none') {_say('SELECTED_NONE')} else {_say('SELECTED_SOURCES',$p->{label_sources})}
    _say('LOWER_LABEL_CAPS',@$p{qw(label_max_graphemes label_max_bytes codex_component_max_chars label_store_max_bytes)});
    _say('LOWER_RESULT_CAPS',@$p{qw(results_max_records results_max_record_bytes results_max_total_bytes results_max_age_days)});
}
sub _current {
    my ($before,$current)=@_; die "invalid stored content policy\n" unless $current->{valid};
    die "content policy changed; retry command\n" unless $before->{source} eq $current->{source}
        && $before->{policy}{policy_generation}==$current->{policy}{policy_generation}
        && _same_or_absent($before->{stat},$current->{stat});
}
sub change_policy {
    my ($root,$changes,$ack_labels)=@_; die "invalid content policy change\n" unless ref($changes) eq 'HASH';
    die "invalid content policy change\n" if grep {!$KEY{$_} || /\A(?:version|policy_generation|grant_prompt_version)\z/} keys %$changes;
    # Refuse widening before even creating a lock or logs directory in managed/non-TTY contexts.
    my $prectx=_context($root,0);
    my $pre=$prectx->{logs} ? _in_context($prectx,sub {_stored($prectx)}) : _stored($prectx);
    die "invalid stored content policy\n" unless $pre->{valid};
    my $next=_validate_policy({%{$pre->{policy}},%$changes});
    return $next if $pre->{source} eq 'default' && !_widening($pre->{policy},$next)
        && join('\n',map {$next->{$_}} @KEYS) eq join('\n',map {$pre->{policy}{$_}} @KEYS);
    my $widening=_widening($pre->{policy},$next);
    die "human content confirmation required\n" if $widening && !human_tty();
    my $confirmed=1;
    if ($widening) {
        _describe(_context($root,0),$next); $confirmed=_answer(0,'CONFIRM');
        die "content confirmation declined\n" unless $confirmed || $ack_labels;
    }
    my $ack=$ack_labels && human_tty();
    my $c=_context($root,1);
    return _in_context($c,sub {
        my $lock=_lock($c); my $stored=_stored($c);
        # Restrictive writers merge with the current generation. Human grants
        # must still match the exact snapshot whose fields were displayed.
        _current($pre,$stored) if $widening;
        my $p=_validate_policy({%{$stored->{policy}},%$changes});
        if (!$widening && _widening($stored->{policy},$p)) {
            die "content policy changed; retry command\n";
        }
        $p={%{$stored->{policy}}} unless $confirmed;
        $p->{grant_prompt_version}=1 if $ack;
        return _save_policy($c,$stored,$p);
    });
}
sub first_use {
    my ($root)=@_; return 0 unless human_tty();
    my $pre=load_policy($root); return 0 unless $pre->{valid} && !$pre->{policy}{grant_prompt_version};
    return 0 unless _label_gate(eval {Loomy::RuntimePaths::resolve($root)->{root}} // $root,1);   # no consent screen that could not be saved
    my $c=_context($root,1);
    return _in_context($c,sub {
        # A distinct, non-blocking screen lock suppresses duplicate screens;
        # automatic writers only need content-policy.lock and remain free.
        my $screen=eval {_lock($c,'content-prompt.lock',0)};
        return 0 if !$screen && $@ eq "content lock busy\n"; die $@ unless $screen;
        my $stored=_stored($c);
        return 0 unless $stored->{valid} && !$stored->{policy}{grant_prompt_version};
        my $p={%{$stored->{policy}}};
        _say('TITLE',display_path($c->{root})); _say($p->{journal_content} eq 'structural' ? 'CLARITY' : 'CLARITY_LEGACY');
        _say($_) for qw(SOURCES SOURCES_CODEX LABEL_CAPS);
        _say('LOWER_LABEL_CAPS',@$p{qw(label_max_graphemes label_max_bytes codex_component_max_chars label_store_max_bytes)})
            if grep {$p->{$_} != $MAX{$_}} qw(label_max_graphemes label_max_bytes codex_component_max_chars label_store_max_bytes);
        my $labels=_answer(1,'KEEP_LABELS');
        _say($_) for qw(RESULT_CAPS RESULT_RETENTION);
        _say('LOWER_RESULT_CAPS',@$p{qw(results_max_records results_max_record_bytes results_max_total_bytes results_max_age_days)})
            if grep {$p->{$_} != $MAX{$_}} qw(results_max_records results_max_record_bytes results_max_total_bytes results_max_age_days);
        my $results=_answer(1,'KEEP_RESULTS');
        _say($p->{journal_content} eq 'structural' ? 'EXCLUDED' : 'EXCLUDED_LEGACY');
        $p->{label_sources}=$labels ? recommended_sources() : 'none';
        $p->{private_results}=$results ? 'on' : 'off'; $p->{grant_prompt_version}=1;
        my $lock=_lock($c); my $current=_stored($c); _current($stored,$current);
        _save_policy($c,$current,$p); return 1;
    });
}

sub sanitize_label {
    my ($text,$graphemes,$bytes)=@_; die "label unavailable\n" unless _scalar($text);
    $text=_decode_utf8($text,1) unless utf8::is_utf8($text);
    # Remove complete terminal sequences before stripping the remaining controls.
    $text =~ s/(?:\e\]|\x{9d}).*?(?:\a|\e\\|\x{9c})//gs;
    $text =~ s/(?:\e[P^_X]|[\x{90}\x{98}\x{9e}\x{9f}]).*?(?:\e\\|\x{9c})//gs;
    $text =~ s/(?:\e\[|\x{9b})[0-?]*[ -\/]*[\@-~]//g;
    $text =~ s/\e[ -\/]*[\@-Z\\-_]//g;
    $text =~ s/[\r\n\t\x{2028}\x{2029}]+/ /g;
    $text =~ s/[\p{Cc}\p{Cf}\x{e0000}-\x{e007f}]//g;
    $text =~ s/\A\s+|\s+\z//g;
    my ($out,$n)=('',0); for my $cluster ($text =~ /\X/g) {
        last if ++$n>$graphemes || length(_encode_utf8($out.$cluster))>$bytes; $out.=$cluster;
    }
    $out =~ s/\s+\z//;
    die "label unavailable\n" unless length($out); return $out;
}
sub _scope {
    my ($s,$project)=@_; return _scalar($project) && $project =~ /\Ap[0-9a-f]{64}\z/
        && ref($s) eq 'HASH' && ($s->{project_id}//'') eq $project
        && _scalar($s->{target_kind}) && $s->{target_kind} =~ /\A(?:task|session|agent|delegation)\z/
        && _id($s->{target_id}) && _id($s->{attempt_id});
}
sub label_ref {
    my ($r)=@_; return {map {$_=>$r->{$_}} qw(version project_id target_kind target_id attempt_id label_id)};
}
sub _valid_label {
    my ($r,$project)=@_; return 0 unless _scope($r,$project) && keys(%$r)==10;
    my %allowed=map {$_=>1} qw(version project_id target_kind target_id attempt_id label_id text source created_at supersedes);
    return 0 if grep {!$allowed{$_}} keys %$r;
    return 0 unless ($r->{version}//'') eq '1' && _id($r->{label_id}) && $SOURCE{$r->{source}//''}
        && _timestamp($r->{created_at}) && _scalar($r->{supersedes}) && ($r->{supersedes} eq '' || _id($r->{supersedes}));
    return 0 if $r->{source} =~ /\Acodex-/ && (!_scalar($r->{text}) || length($r->{text})>40
        || $r->{text} !~ /\A[A-Za-z0-9_.-](?:[A-Za-z0-9_. -]*[A-Za-z0-9_.-])?\z/ || $r->{text} !~ /[A-Za-z0-9]/);
    my $clean=eval {sanitize_label($r->{text},96,384)};
    return defined($clean) && $clean eq $r->{text};
}
sub _rows {
    my ($raw,$project)=@_; my (@rows,%seen);
    for (split /\n/,$raw//'') {
        next if length($_)>4096;
        my $r=eval {$JSON->decode($_)}; next unless _valid_label($r,$project) && !$seen{$r->{label_id}}++;
        push @rows,$r;
    }
    return \@rows;
}
# Search from the tail and validate only matching candidates. Hooks normally
# need one scoped record, not a decode/sanitize pass over the entire history.
sub _find_label {
    my ($c,$match)=@_; my $before=_private_stat($LABELS); return unless @$before;
    die "content file too large\n" if $before->[7]>1048576;
    sysopen my $h,$LABELS,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or die "content file unavailable\n";
    die "content file changed\n" unless _same($before,[stat($h)]);
    my $offset=$before->[7]; my $carry=''; my $found;
    while ($offset>0 && !$found) {
        my $size=$offset>8192 ? 8192 : $offset; $offset-=$size;
        seek $h,$offset,0 or die "content read failed\n";
        my $n=sysread($h,my $chunk,$size); die "content read failed\n" unless defined($n) && $n==$size;
        my @lines=split /\n/,$chunk.$carry,-1;
        $carry=$offset ? shift @lines : '';
        for my $line (reverse @lines) {
            next if !length($line) || length($line)>4096;
            # Canonical local records allow a cheap exact-string prefilter.
            # Whitespace in older/manual JSON still goes through the decoder.
            next if index($line,$match->{needle})<0 && $line !~ /:\s+/;
            my $r=eval {$JSON->decode($line)};
            next unless _valid_label($r,$c->{project_id});
            next if grep {($r->{$_}//'') ne $match->{$_}} grep {$_ ne 'needle'} keys %$match;
            $found=$r; last;
        }
        # A corrupt huge line cannot grow an unbounded carry buffer.
        $carry=substr($carry,0,4097) if length($carry)>4097;
    }
    die "content file changed\n" unless _same($before,[stat($h)]) && _same($before,_private_stat($LABELS));
    return $found;
}
sub latest_label {
    my ($c,$kind,$target,$attempt,$source)=@_;
    return _find_label($c,{target_kind=>$kind,target_id=>$target,attempt_id=>$attempt,source=>$source,
        needle=>'"target_id":'.substr($JSON->encode([$target]),1,-1)});
}
# Leak barrier (journal-gate.pl): display-context-v1.jsonl lives in .loomy/logs, so it is never written (nor its lock
# created) when the project tracks runtime state in its Git index or Git cannot say.
sub _label_gate {
    my ($root,$readonly)=@_; return 0 unless defined $root; my $r=abs_path($root); return 1 unless defined $r;   # an unusable root fails later, as before
    require "$LIB/journal-gate.pl"; return Loomy::JournalGate::check("$r/.loomy/logs",$readonly);   # a reader never stores the verdict in the project
}
sub _save_label {
    my ($c,$p,$input,$last)=@_; die "invalid label scope\n" unless _scope($input,$c->{project_id});
    die "label not saved: .loomy/logs is tracked by Git or Git cannot say; run loomy doctor --fix\n" unless _label_gate($c->{root});
    my %granted=map {$_=>1} @{_sources($p->{label_sources})};
    my $source=$input->{source}//''; die "label source not granted\n" unless $SOURCE{$source} && $granted{$source};
    die "human content confirmation required\n" if $source eq 'explicit-user' && !human_tty();
    my $text=$input->{text};
    if ($source =~ /\Acodex-/) {
        die "invalid Codex label\n" unless _scalar($text) && $text =~ /\A[A-Za-z0-9_.-](?:[A-Za-z0-9_. -]*[A-Za-z0-9_.-])?\z/
            && $text =~ /[A-Za-z0-9]/ && length($text)<=$p->{codex_component_max_chars}
            && length($text)<=$p->{label_max_graphemes} && length($text)<=$p->{label_max_bytes};
    } else {$text=sanitize_label($text,$p->{label_max_graphemes},$p->{label_max_bytes})}
    $last=latest_label($c,@$input{qw(target_kind target_id attempt_id source)}) if @_<4;
    my $previous=$last ? $last->{label_id} : '';
    my $r={version=>1,project_id=>$c->{project_id},(map {$_=>$input->{$_}} qw(target_kind target_id attempt_id)),
        label_id=>'l'.unpack('H*',_random(16)),text=>$text,source=>$source,
        created_at=>strftime('%Y-%m-%dT%H:%M:%SZ',gmtime),supersedes=>$previous};
    my $line=$JSON->encode($r)."\n"; my $before=_private_stat($LABELS);
    my $size=@$before ? $before->[7] : 0;
    die "content file too large\n" if $size>1048576;
    my $h;
    if (@$before) {
        sysopen $h,$LABELS,O_RDWR|O_APPEND|O_NOFOLLOW|O_NONBLOCK or die "content file unavailable\n";
        die "content file changed\n" unless _same($before,[stat($h)]);
        if ($size) {seek $h,-1,2 or die "content read failed\n"; sysread($h,my $tail,1)==1 or die "content read failed\n"; $line="\n$line" if $tail ne "\n"}
    }
    if ($size+length($line)>$p->{label_store_max_bytes}) {
        my ($fact,$s)=_read($FULL,128); _atomic($c,$FULL,"display context full; label not saved\n",$s) unless defined $fact;
        die "display context full; label not saved\n";
    }
    _assert_context($c);
    unless ($h) {sysopen $h,$LABELS,O_WRONLY|O_APPEND|O_CREAT|O_EXCL|O_NOFOLLOW,0600 or die "content write failed\n"}
    die "content file changed\n" unless _same(_private_stat($LABELS),[stat($h)]);
    print {$h} $line or die "content write failed\n";
    $h->flush && $h->sync or die "content write failed\n";
    close $h or die "content write failed\n"; return label_ref($r);
}
sub save_label {
    my ($root,$input)=@_;
    # Capture is a consumer of a grant. Even a forged source name never creates consent.
    # The barrier first: over a tracked logs directory the grants read as absent, and "not granted" would name the wrong cause.
    die "label not saved: .loomy/logs is tracked by Git or Git cannot say; run loomy doctor --fix\n" unless _label_gate($root);
    my $pre=effective_policy($root); my %granted=map {$_=>1} @{_sources($pre->{label_sources})};
    die "label source not granted\n" unless $granted{$input->{source}//''};
    die "human content confirmation required\n" if ($input->{source}//'') eq 'explicit-user' && !human_tty();
    my $c=_context($root,1); return _in_context($c,sub {
        my $labels=_lock($c,'display-context.lock');
        my $lock=_lock($c); my $p=_effective($c,_stored($c));
        undef $lock;
        return _save_label($c,$p,$input);
    });
}
sub resolve_label {
    my ($root,$ref)=@_; return _snapshot_read($root,'effective',sub {
        my ($c)=@_; return unless $c->{logs};
        return _in_context($c,sub {
            my $project=$c->{project_id};
            return unless _scope($ref,$project) && keys(%$ref)==6 && ($ref->{version}//'') eq '1' && _id($ref->{label_id});
            return _find_label($c,{(map {$_=>$ref->{$_}} qw(label_id target_kind target_id attempt_id)),
                needle=>'"label_id":'.substr($JSON->encode([$ref->{label_id}]),1,-1)});
        });
    })->{value};
}
sub label_health {
    my ($root)=@_; return _snapshot_read($root,'effective',sub {
        my ($c)=@_; return unless $c->{loomy}; return 'ok' unless $c->{logs};
        return _in_context($c,sub {my ($raw)=_read($FULL,128); return defined($raw) ? 'full' : 'ok'});
    })->{value} // 'unavailable';
}

# Public manifest integrity is shared by the real loader and mutation canaries.
sub check_allowlist {
    my ($path)=@_; my $raw; open my $h,'<',$path or die "content allowlist unavailable\n";
    {local $/; $raw=<$h>} die "invalid content allowlist\n" if length($raw)>131072;
    my @lines=grep {length && !/^#/} split /\n/,$raw;
    die "content allowlist drift\n" unless sha256_hex(join("\n",@lines)."\n") eq
        '03f1430fd6a0ba60748a6d12b861c86a005ab5a9a6e3979dfcadf6b875a07e50';
    shift @lines; my %types;
    for (@lines) {my ($t,$k,$d)=split /\t/; $types{$t}{$k}=$d} return \%types;
}
my $ALLOW;
sub _allow { return $ALLOW//=check_allowlist("$LIB/content-allowlist.tsv") }
my %ENUM = (
    tool=>[qw(claude codex local unknown)], family=>[qw(claude codex local unknown)],
    acting=>[qw(claude codex local unknown)], master=>[qw(claude codex local unknown)],
    failover_from=>[qw(claude codex local unknown)],
    # CONTENT-CENSUS fixtures: bridge CLIs, both collectors and Claude tool hooks.
    bridge=>[qw(claude codex local claude-native codex-native subagent unknown)],
    effort=>[qw(none minimal low medium high xhigh max unknown)],
    status=>[qw(ok error interrupted unknown done paused handed_over running cancelled)],
    # usage.sh pause and models.sh ai_result_json emit these outcome codes.
    outcome=>[qw(done partial blocked failed error interrupted unknown ok paused handed_over cancelled waiting_for_reset unformatted credits)],
    state=>[qw(running busy idle done failed closed unknown interrupted paused handed_over waiting catching_up)],
    surface=>[qw(cli app exec unknown)], context_freshness=>[qw(current fresh catching_up unknown)],
    cost_in=>[qw(usage unknown)], cost_source=>[qw(usage actual reported estimated estimate provider local unknown)],
    multi_agent_version=>[qw(v2)], pid_role=>[qw(owner launcher lead unknown)],
    scope=>[qw(lead agent subagent session project unknown)],
    sandbox=>[qw(read-only workspace-write danger-full-access text-only unknown)],
    format=>[qw(structured free unknown)], review=>[qw(complete incomplete unknown)],
    profile=>[qw(econome equilibre qualite unknown),'-'], launcher=>[qw(terminal app desktop unknown)],
    activity=>[qw(start running busy idle waiting tool thinking output unknown)],
    # skills.sh uses the two catalog/skills.conf repository IDs as sources.
    source=>[qw(transcript hook cli app prompt startup resume clear compact native catalog official project user anthropic openai unknown)],
    evidence=>['source lease','parent pending',qw(launcher launch-session-id exec-json transcript hook native journal rollout unknown)],
    event=>[qw(start stop end open close add remove install update added restored removed unknown)],
    reason_code=>[qw(manual quota saturated reset available catalog selected installed removed updated unavailable unknown)],
    quota_window=>[qw(5h 7d daily weekly session unknown)],
    phase=>[qw(brief discover interview propose approve build verify document commit retire done plan review audit report scope analyze validate fix unknown)],
);
my %ROLE=map {$_=>1} qw(lead architect debugger developer executor reviewer security explorer documenter advisor agent worker default unknown);
# Native identity() accepts 100 ASCII characters. The collectors then assemble
# session keys, call/turn IDs and aliases from those parts; the composed value
# must not be rejected by the single-component limit (claude-native/codex-native).
my $ID_PART=qr/[A-Za-z0-9_.:-]{1,100}/;
sub _journal_id {
    my ($k,$v)=@_; return 0 unless _scalar($v);
    return 1 if $v =~ /\A$ID_PART\z/ || $v =~ /\A(?:cl|cn):$ID_PART:$ID_PART\z/;
    return 1 if $v =~ /\A(?:claude|codex):(?:pending:)?$ID_PART\z/;
    return 1 if $k =~ /\A(?:session|parent_session)\z/ && $v =~ /\Apending:$ID_PART\z/;
    return $k =~ /\A(?:agent_id|alias_from)\z/ && $v =~ /\A$ID_PART:$ID_PART\z/;
}
my (%TS_MEMO,$TS_MEMO_SIZE); # pure in the text
sub _timestamp {
    my ($v)=@_; return 0 unless _scalar($v);
    my $hit=$TS_MEMO{$v}; return $hit if defined $hit;
    my $ok=$v =~ /\A(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d{1,9})?Z\z/ && defined(eval {timegm($6,$5,$4,$3,$2-1,$1)}) ? 1 : 0;
    if ($TS_MEMO_SIZE++>=4096) {%TS_MEMO=(); $TS_MEMO_SIZE=1}
    return $TS_MEMO{$v}=$ok;
}
sub _number {
    my ($v)=@_; return _scalar($v) && length($v)<=32 && $v =~ /\A(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?\z/
        && $v<1e308;
}
# Key -> check, in the order the checks have always run (the first listing wins:
# acting, master and failover_from are enums before they are identities).
my %VKIND;
{
    my $kind=0;
    for my $keys (
        [qw(requested background manual snapshot)], ['source_active'], [qw(task_ref label_ref)], ['label_refs'],
        ['analysis_codes'], ['role'], ['agent_type'], ['agent'], [keys %ENUM], ['off_routing'], [qw(ts source_ts)],
        [qw(resume_at ended_at observed_at)],
        [qw(tokens_in tokens_out tokens_cached cost_usd duration_s calls messages pid owner_pid files_changed exit_code signal
            source_offset source_revision context_revision used_percent)],
        ['schema'], ['source_inode'], [qw(model requested_model)], ['name'], [qw(native_key event_key checkpoint_key)],
        [qw(id agent_id alias_from alias_id attempt_id session session_key turn_id parent_agent_id parent_id parent_session
            parent_delegation acting master failover_from)],
    ) {++$kind; $VKIND{$_}//=$kind for @$keys}
}
my %ENUM_OK=map {my $k=$_; ($k=>{map {$_=>1} @{$ENUM{$k}}})} keys %ENUM;
sub _value {
    my ($k,$v,$project)=@_; return undef unless defined $v; # Preserve null as unknown.
    my $kind=$VKIND{$k}//0;
    if ($kind==1) {
        die "invalid structural value\n" unless JSON::PP::is_bool($v); return $v;
    }
    # source_active is a numeric 0/1 in the existing native protocol.
    if ($kind==2) {die "invalid structural value\n" unless _scalar($v) && $v =~ /\A[01]\z/; return 0+$v}
    if ($kind==3) {
        die "invalid structural reference\n" unless _scope($v,$project) && ($v->{version}//'') eq '1'
            && keys(%$v)==($k eq 'label_ref' ? 6 : 5) && ($k ne 'label_ref' || _id($v->{label_id}));
        return {%$v};
    }
    if ($kind==4) {
        die "invalid structural reference\n" unless ref($v) eq 'HASH' && keys(%$v)<=3
            && !grep {!/\A(?:slug|nickname|role)\z/} keys %$v;
        return {map {$_=>_value('label_ref',$v->{$_},$project)} keys %$v};
    }
    if ($kind==5) {
        die "invalid structural value\n" unless ref($v) eq 'ARRAY' && @$v<=16;
        return [map {_value('reason_code',$_,$project)} @$v];
    }
    die "invalid structural value\n" unless _scalar($v);
    if ($kind==19) {
        die "invalid structural value\n" unless _journal_id($k,$v); return $v;
    }
    if ($kind==9) {
        return $v if $ENUM_OK{$k}{$v};
        die "invalid structural value\n" if $k eq 'multi_agent_version';
        return 'unknown';
    }
    if ($kind==11) {die "invalid structural value\n" unless _timestamp($v); return $v}
    if ($kind==6) {return $ROLE{$v} ? $v : 'unknown'}
    if ($kind==7) {return $v =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,39}\z/ ? $v : 'unknown'}
    if ($kind==8) {
        # Native agent_type is an identity, not a Loomy role enum. Keep validated
        # tokens (including Explore) and opaque IDs stable on a second projection.
        # Unvalidated custom names get a project-scoped identity, never prose.
        return $v if _id($v) || $v =~ /\Asha256:[0-9a-f]{64}\z/;
        return 'sha256:'.sha256_hex($project."\0".(utf8::is_utf8($v) ? _encode_utf8($v) : $v));
    }
    if ($kind==10) {
        die "invalid structural value\n" unless $v eq '' || $v =~ /\A(?:model|effort|sandbox|family|tool|profile)(?:,(?:model|effort|sandbox|family|tool|profile))*\z/;
        return $v;
    }
    if ($kind==12) {
        die "invalid structural value\n" unless _timestamp($v) || _number($v); return _number($v) ? 0+$v : $v;
    }
    if ($kind==13) {
        die "invalid structural value\n" unless _number($v) && ($k ne 'used_percent' || $v<=100); return 0+$v;
    }
    if ($kind==14) {die "invalid structural value\n" unless $v =~ /\A[12]\z/; return 0+$v}
    if ($kind==15) {die "invalid structural value\n" unless $v =~ /\A[0-9]+:[0-9]+\z/ && length($v)<=64; return $v}
    if ($kind==16) {
        # Same token alphabet as loomy-local-writer.sh, with the design's 128
        # character bound. Provider prefixes/local model IDs contain slashes.
        die "invalid structural value\n" unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9_.\/:-]{0,127}\z/; return $v;
    }
    if ($kind==17) {
        die "invalid structural value\n" unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/; return $v;
    }
    if ($kind==18) {
        die "invalid structural value\n" unless $v =~ /\A[A-Za-z0-9_.:-]{1,512}\z/; return $v;
    }
    die "unclassified structural field\n";
}
sub _signature {
    my ($type,$v,$project)=@_;
    return $v if _scalar($v) && ($v eq '1' || $v =~ /\Asha256:[0-9a-f]{64}\z/);
    if (_scalar($v) && $v =~ /\A(.+Z):([^:]*)\z/ && _timestamp($1)) {
        return $v if grep {$_ eq $2} @{$ENUM{status}};
    }
    my $body=ref($v) eq 'HASH' ? $v : eval {$JSON->decode($v)};
    unless (ref($body) eq 'HASH' && _allow()->{"$type/checkpoint_value"}) {
        my $bytes=eval {$JSON->encode([$v])} // '[null]';
        return 'sha256:'.sha256_hex(($project//'')."\0".$bytes);
    }
    my %out; for my $key (keys %$body) {
        next unless (_allow()->{"$type/checkpoint_value"}{$key}//'') eq 'keep';
        $out{$key}=eval {_value($key,$body->{$key},$project)};
    }
    return 'sha256:'.sha256_hex($JSON->encode(\%out));
}
sub project_with_policy {
    my ($p,$e)=@_; die "invalid structural event\n" unless ref($e) eq 'HASH' && _scalar($e->{type});
    $p={%$p,journal_content=>'structural'} if ($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0';
    my $type=$e->{type}; my $fields=_allow()->{$type};
    die "unknown structural event\n" unless $fields && $type !~ m{/};
    my %out=(type=>$type); my %extra=map {$_=>1} qw(content_policy policy_generation);
    if ($type =~ /\A(?:request|session_observed|delegation_start|delegation_activity|delegation|agent_link|agent_alias|agent_closed)\z/) {@extra{qw(task_ref label_ref)}=(1,1)}
    if ($type eq 'skill') {@extra{qw(reason_code analysis_codes)}=(1,1)}
    if ($type =~ /\Alead_(?:failover|return)\z/) {@extra{qw(reason_code quota_window used_percent)}=(1,1,1)}
    for my $k (keys %$e) {
        next if $k eq 'type' || $k eq 'content_policy' || $k eq 'policy_generation';
        my $d=$fields->{$k}//'';
        if ($d eq 'project') {$out{$k}=_signature($type,$e->{$k},$p->{project_id}); next}
        next unless $d eq 'keep' || $extra{$k};
        # A malformed old/provider value must never poison this event, rotation,
        # or the following write. Null retains the existing unknown semantics.
        $out{$k}=eval {_value($k,$e->{$k},$p->{project_id})};
    }
    if ($p->{journal_content} eq 'legacy-excerpts' && ($ENV{LOOMY_JOURNAL_TASKS}//'1') ne '0') {
        my %caps=(task=>200,excerpt=>60,why=>200,nickname=>40,cwd_relative=>256);
        for my $k (keys %caps) {
            next unless exists($e->{$k}) && ($fields->{$k}//'') eq 'omit' && _scalar($e->{$k});
            my $s=$e->{$k}; $s=_decode_utf8($s) unless utf8::is_utf8($s);
            if ($k eq 'cwd_relative') {next if $s =~ m{\A/|\\|(?:\A|/)\.\.(?:/|\z)|[\p{Cc}]}}
            $out{$k}=substr($s,0,$caps{$k});
        }
    }
    $out{content_policy}=$p->{journal_content} eq 'legacy-excerpts' ? 'legacy-excerpts-v1' : 'structural-v1';
    $out{policy_generation}=0+$p->{policy_generation}; return \%out;
}
sub project_event {my ($root,$event)=@_; return project_with_policy(effective_policy($root),$event)}

# R2 contracts only. Native writers do not call these APIs until T1 adopts the
# new store/transaction boundary. The descriptor is also the validator's closed
# field registry, rather than a second permissive checkpoint allowlist.
my $CHECKPOINT;
sub _checkpoint_contract {
    return $CHECKPOINT if $CHECKPOINT;
    my %objects=(
        checkpoint=>{fields=>{
            version=>'container_version',content_policy=>'content_marker',policy_generation=>'uint',
            files=>'source_map',source_shards=>'shard_names',journal=>'journal_cursor',seen=>'seen_map',sent=>'sent_map',
            sessions=>'session_map',owners=>'owner_map',owner_leads=>'owner_lead_map',root_revisions=>'counter_map',
            root_snapshots=>'root_snapshot_map',fences=>'epoch_map',rotation=>'uint',read_rotation=>'uint',
            reconstructing=>'flag',discovering=>'uint',recovery_sources=>'recovery_map',repair=>'repair_map',unknown_repair_v1=>'flag'},
            required=>[qw(version content_policy policy_generation)]},
        source_state=>{fields=>{
            meta=>'source_meta',key=>'inode',offset=>'uint',skipping=>'flag',read_sig=>'stat_signature',at_eof=>'flag',
            replay_fence=>'epoch',source_mtime=>'epoch',last_observed_ts=>'timestamp',last_evidence_ts=>'timestamp',
            last_model=>'model',last_effort=>'effort',id=>'journal_id',turn=>'native_id',started=>'timestamp',finished=>'flag',
            model=>'model',effort=>'effort',activity=>'activity',activity_ts=>'timestamp',activity_position=>'uint',event_position=>'uint',
            lead_state=>'state',lead_turn=>'native_id',lead_position=>'uint',lead_waits=>'flag_map',wait_calls=>'flag_map',
            close_calls=>'identity_map',closed_agents=>'timestamp_map',context=>'source_context',context_invalidated=>'flag',
            context_revision=>'uint',emitted_activity=>'activity_signature',projected_lead=>'lead_id',projected_metadata=>'protocol_two',
            journal_generation=>'uint',complete_sig=>'stat_signature',tail_sig=>'stat_signature',tail_start=>'uint',tail_end=>'uint',
            tail_at=>'epoch',back_chunk=>'uint',gap_start=>'uint',gap_end=>'uint',v2_position=>'uint',v2_tail_sig=>'stat_signature',
            v2_window=>'uint',model_probe=>'codex_turn_id',probe_sig=>'stat_signature',starts=>'start_epochs',oversized=>'flag',oversized_at=>'uint'},
            required=>['meta'],omit=>[qw(buffer read_bytes read_start)]},
        source_meta=>{fields=>{
            id=>'native_id',parent=>'native_id',agent=>'native_id',role=>'role',surface=>'surface',ts=>'timestamp',
            v2=>'flag',metadata_protocol=>'protocol_two',workspace_id=>'native_id',cwd=>'workspace_locator',workspace_roots=>'workspace_locators'},
            required=>['id'],omit=>[qw(task nickname)]},
        source_context=>{fields=>{turn=>'native_id',ts=>'timestamp',position=>'uint',model=>'model',effort=>'effort'}},
        journal_cursor=>{fields=>{key=>'inode',offset=>'uint',read_sig=>'stat_signature',skipping=>'flag',at_eof=>'flag',generation=>'uint',active=>'active_map'},
            omit=>[qw(read_bytes read_start oversized oversized_at)]},
        claude_session=>{fields=>{
            id=>'native_id',surface=>'surface',state=>'state',state_ts=>'timestamp',seen=>'timestamp',model=>'model',effort=>'effort',
            calls=>'call_map',aliases=>'alias_map',stops=>'stop_map',waits=>'flag_map',pending_notify=>'notify_map'},omit=>['cwd_relative']},
        # This role is the constructor's legacy agent-type alias. Other role
        # fields remain the closed Loomy enum; T1 pairs any later field adoption.
        claude_call=>{fields=>{
            call=>'call_id',agent=>'native_id',alias_from=>'call_id',role=>'agent_type',agent_type=>'agent_type',model=>'model',effort=>'effort',
            state=>'state',status=>'status',outcome=>'outcome',started=>'timestamp',ended=>'timestamp',seen=>'timestamp',background=>'flag',
            returned=>'flag',reopened=>'flag',terminal_evidence=>'flag',source_mtime=>'epoch'},omit=>['task']},
        terminal=>{fields=>{ts=>'timestamp',status=>'status',outcome=>'outcome'}},
        owner=>{fields=>{pid=>'uint',session=>'native_id',ts=>'timestamp',lead=>'lead_id',ended=>'timestamp',dead_at=>'timestamp',unbound=>'flag'}},
        owner_lead=>{fields=>{lead=>'lead_id',session=>'native_id'},required=>[qw(lead session)]},
        root_snapshot=>{fields=>{known=>'flag',ts=>'timestamp',owner_pid=>'uint',context_freshness=>'context_freshness',context_revision=>'uint'}},
        repair_entry=>{fields=>{agent=>'native_id',turn=>'native_id',model=>'model',effort=>'effort',ts=>'timestamp'}},
        label_ref=>{fields=>{version=>'reference_version',project_id=>'project_id',target_kind=>'target_kind',target_id=>'scope_id',attempt_id=>'scope_id',label_id=>'scope_id'},
            required=>[qw(version project_id target_kind target_id attempt_id label_id)],nullable=>1},
        task_ref=>{fields=>{version=>'reference_version',project_id=>'project_id',target_kind=>'target_kind',target_id=>'scope_id',attempt_id=>'scope_id'},
            required=>[qw(version project_id target_kind target_id attempt_id)],nullable=>1},
        label_refs=>{fields=>{slug=>'label_ref',nickname=>'label_ref',role=>'label_ref'},nullable=>1},
    );
    my %maps=(
        source_map=>['source_locator','source_state'],seen_map=>['digest','epoch'],sent_map=>['sent_key','sent_signature'],
        session_map=>['native_id','claude_session'],call_map=>['call_id','claude_call'],alias_map=>['native_id','call_id'],
        stop_map=>['native_id','terminal'],notify_map=>['call_id','terminal'],flag_map=>['native_id','flag'],
        identity_map=>['native_id','native_id'],timestamp_map=>['native_id','timestamp'],active_map=>['journal_id','flag'],
        owner_map=>['owner_key','owner'],owner_lead_map=>['owner_key','owner_lead'],counter_map=>['native_id','uint'],
        epoch_map=>['native_id','epoch'],root_snapshot_map=>['native_id','root_snapshot'],repair_map=>['codex_turn_id','repair_entry'],
        recovery_map=>['native_id','lifecycle_event'],
    );
    $CHECKPOINT={schema_revision=>1,container_version=>2,content_policy=>'structural-v1',
        api=>{project=>'project_checkpoint(state, context)',validate=>'validate_checkpoint(state, context)',
            signature=>'checkpoint_signature(key, value, context)'},
        context=>{required=>[qw(project_id source_roots workspace_roots)],optional=>['policy_generation'],
            locators=>'Explicit lexical roots; T1 separately enforces filesystem owner/type/no-follow/race checks.'},
        objects=>\%objects,maps=>{map {$_=>{key=>$maps{$_}[0],value=>$maps{$_}[1]}} keys %maps},
        arrays=>{shard_names=>{item=>'shard_name',max=>64},workspace_locators=>{item=>'workspace_locator',max=>64},start_epochs=>{item=>'epoch',max=>4096}},
        domains=>{
            uint=>'Canonical nonnegative integer <=9007199254740991; null is unknown.',epoch=>'Finite nonnegative number; null/empty is unknown.',
            native_id=>'1..100 ASCII [A-Za-z0-9_.:-]; empty/null is unknown only in values.',
            scope_id=>'1..100 ASCII [A-Za-z0-9][A-Za-z0-9_.:-]*; required in scoped references.',
            call_id=>'native_id or agent:<native_id>',journal_id=>'native_id or typed cl/cn/provider composite of native parts',
            lead_id=>'native_id or pending:<native_id>',codex_turn_id=>'cn:<native_id>:<native_id>',
            sent_key=>'session:<id>, context:<id>, or start/end/context/alias:cl:<session>:<call>',
            sent_signature=>'start 1; end UTC:status; sha256:<64 lowercase hex>; projection alone accepts reviewed serialized bodies.',
            activity_signature=>'cn:<agent>:<turn>:<model>:<effort>:<activity>:a2',
            timestamp=>'Validated UTC timestamp, optional fraction 1..9 digits; null/empty is unknown.',
            inode=>'device:inode, each 1..20 decimal digits',stat_signature=>'device:inode:size:mtime; size safe integer, mtime nonnegative finite; empty/- is unknown.',
            owner_key=>'PID >=2 plus validated UTC timestamp, separated by colon',digest=>'64 lowercase SHA-256 hex',shard_name=>'files-<64 lowercase hex>',
            flag=>'Existing checkpoint protocol: integer 0/1 or JSON boolean; null is unknown.',
            model=>'1..128 ASCII [A-Za-z0-9][A-Za-z0-9_./:-]*; empty/null is unknown.',
            agent_type=>'1..40 ASCII [A-Za-z0-9][A-Za-z0-9_.-]*; empty/null is unknown.',
            role=>[sort keys %ROLE],(map {$_=>[@{$ENUM{$_}}]} qw(effort activity state status outcome surface context_freshness)),
            project_id=>'Existing p<64 lowercase hex>, exactly equal to context.project_id',target_kind=>[qw(task session agent delegation)],
            source_locator=>'Absolute location <=4096 UTF-8 bytes under an explicit source root; no controls, empty/dot/dotdot path components.',
            workspace_locator=>'Same location grammar under an explicit workspace root; never an export permission.',
            content_marker=>'structural-v1',container_version=>2,reference_version=>1,protocol_two=>2,
            lifecycle_event=>'Closed per-type journal fields plus existing scoped references and structural envelope; no compatibility content.',
            nullable_references=>'Lifecycle task_ref/label_ref/label_refs and label_refs components may be null as R1 unknown/no authority; non-null references require every exact scoped field.',
        },
        limits=>{core_bytes=>2097152,shards=>64,shard_bytes=>262144,shards_total_bytes=>16777216,legacy_read_bytes=>33554432,
            locator_bytes=>4096,roots=>64,start_epochs=>4096,max_depth=>16},
        separate_cursors=>{usage=>{current_format=>'TSV',row=>{source_locator=>'source_locator',line_offset=>'uint'},owner=>'T1 serializer/adoption'},
            smooth=>{row=>{shown=>'uint'},owner=>'T1 serializer/adoption'}},
        required_checks=>'Projection/validation are pure. T1 owns sharding, protected writes, cursor durability and historical read manifests.'};
    return $CHECKPOINT;
}
sub checkpoint_schema {return $JSON->decode($JSON->encode(_checkpoint_contract()))}
sub _checkpoint_fail {die "invalid structural checkpoint\n"}
sub _checkpoint_decode_path {
    my ($p)=@_; return 0 unless _scalar($p);
    my $decoded=utf8::is_utf8($p) ? $p : eval {_decode_utf8($p,1)}; return 0 unless defined $decoded;
    return 0 unless $decoded =~ m{\A/} && $decoded ne '/' && $decoded !~ /[\p{Cc}\p{Cf}]/
        && length(_encode_utf8($decoded))<=4096;
    return 0 if grep {$_ eq '' || $_ eq '.' || $_ eq '..'} split m{/},substr($decoded,1),-1;
    return $decoded;
}
sub _checkpoint_path {return _checkpoint_decode_path($_[0]) ? 1 : 0}
sub _checkpoint_context {
    my ($c)=@_; _checkpoint_fail() unless ref($c) eq 'HASH'
        && !grep {!/\A(?:project_id|source_roots|workspace_roots|policy_generation)\z/} keys %$c;
    _checkpoint_fail() unless _scalar($c->{project_id}) && $c->{project_id} =~ /\Ap[0-9a-f]{64}\z/;
    my %out=(project_id=>$c->{project_id},policy_generation=>0);
    for my $key (qw(source_roots workspace_roots)) {
        _checkpoint_fail() unless ref($c->{$key}) eq 'ARRAY' && @{$c->{$key}}<=64;
        _checkpoint_fail() if grep {!_checkpoint_path($_)} @{$c->{$key}};
        $out{$key}=[map {_checkpoint_decode_path($_)} @{$c->{$key}}];
    }
    if (exists $c->{policy_generation}) {
        _checkpoint_fail() unless _scalar($c->{policy_generation}) && $c->{policy_generation} =~ /\A(?:0|[1-9][0-9]{0,15})\z/
            && $c->{policy_generation}<=$MAX_GENERATION;
        $out{policy_generation}=0+$c->{policy_generation};
    }
    return \%out;
}
sub _checkpoint_primitive {
    my ($type,$v,$c,$key)=@_;
    _checkpoint_fail() if $key && (!defined($v) || ref($v) || $v eq '');
    return undef if !defined($v) && !$key && $type !~ /\A(?:project_id|scope_id|target_kind|reference_version|content_marker|container_version|protocol_two)\z/;
    if ($type eq 'flag') {
        return $v ? JSON::PP::true : JSON::PP::false if JSON::PP::is_bool($v);
        _checkpoint_fail() unless _scalar($v) && $v =~ /\A[01]\z/; return 0+$v;
    }
    _checkpoint_fail() unless _scalar($v);
    my $part=qr/[A-Za-z0-9_.:-]{1,100}/;
    return '' if !$key && $v eq '' && $type =~ /\A(?:native_id|call_id|journal_id|lead_id|codex_turn_id|timestamp|model|agent_type|effort|epoch|context_freshness|stat_signature)\z/;
    if ($type eq 'uint') {_checkpoint_fail() unless $v =~ /\A(?:0|[1-9][0-9]{0,15})\z/ && $v<=$MAX_GENERATION; return 0+$v}
    if ($type eq 'epoch') {_checkpoint_fail() unless _number($v); return 0+$v}
    if ($type eq 'timestamp') {_checkpoint_fail() unless _timestamp($v); return $v}
    if ($type eq 'native_id') {_checkpoint_fail() unless $v =~ /\A$part\z/; return $v}
    if ($type eq 'scope_id') {_checkpoint_fail() unless _id($v); return $v}
    if ($type eq 'call_id') {_checkpoint_fail() unless $v =~ /\A(?:$part|agent:$part)\z/; return $v}
    if ($type eq 'lead_id') {_checkpoint_fail() unless $v =~ /\A(?:$part|pending:$part)\z/; return $v}
    if ($type eq 'codex_turn_id') {_checkpoint_fail() unless $v =~ /\Acn:$part:$part\z/; return $v}
    if ($type eq 'journal_id') {
        _checkpoint_fail() unless _journal_id('agent_id',$v) || $v =~ /\Acl:$part:agent:$part\z/; return $v;
    }
    if ($type eq 'project_id') {_checkpoint_fail() unless $v eq $c->{project_id}; return $v}
    if ($type eq 'target_kind') {_checkpoint_fail() unless $v =~ /\A(?:task|session|agent|delegation)\z/; return $v}
    if ($type eq 'role') {_checkpoint_fail() unless $ROLE{$v}; return $v}
    if ($ENUM{$type}) {_checkpoint_fail() unless grep {$_ eq $v} @{$ENUM{$type}}; return $v}
    if ($type eq 'model') {_checkpoint_fail() unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9_.\/:-]{0,127}\z/; return $v}
    if ($type eq 'agent_type') {_checkpoint_fail() unless $v =~ /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,39}\z/; return $v}
    if ($type eq 'inode') {_checkpoint_fail() unless $v =~ /\A[0-9]{1,20}:[0-9]{1,20}\z/; return $v}
    if ($type eq 'stat_signature') {
        return $v if $v eq '-';
        _checkpoint_fail() unless $v =~ /\A([0-9]{1,20}):([0-9]{1,20}):([^:]+):([^:]+)\z/;
        my ($size,$mtime)=($3,$4);
        _checkpoint_primitive('uint',$size,$c); _checkpoint_primitive('epoch',$mtime,$c); return $v;
    }
    if ($type eq 'owner_key') {_checkpoint_fail() unless $v =~ /\A([1-9][0-9]{0,15}):(.+)\z/ && $1>=2 && _timestamp($2); return $v}
    if ($type eq 'digest') {_checkpoint_fail() unless $v =~ /\A[0-9a-f]{64}\z/; return $v}
    if ($type eq 'shard_name') {_checkpoint_fail() unless $v =~ /\Afiles-[0-9a-f]{64}\z/; return $v}
    if ($type eq 'sent_key') {
        _checkpoint_fail() unless length($v)<=512 && ($v =~ /\A(?:session|context):$part\z/
            || $v =~ /\A(?:start|end|context|alias):cl:$part:(?:$part|agent:$part)\z/); return $v;
    }
    if ($type eq 'activity_signature') {
        my $model_part=qr/(?:[A-Za-z0-9][A-Za-z0-9_.\/:-]{0,127})?/;
        _checkpoint_fail() unless length($v)<=512 && $v =~ /\A(cn:$part:$part):($model_part):([^:]*):([^:]*):a2\z/;
        my ($model,$effort,$activity)=($2,$3,$4);
        _checkpoint_primitive('model',$model,$c); _checkpoint_primitive('effort',$effort,$c);
        _checkpoint_primitive('activity',$activity,$c); return $v;
    }
    if ($type eq 'source_locator' || $type eq 'workspace_locator') {
        $v=_checkpoint_decode_path($v); _checkpoint_fail() unless $v;
        my $roots=$c->{$type eq 'source_locator' ? 'source_roots' : 'workspace_roots'};
        _checkpoint_fail() unless grep {$v eq $_ || index($v,"$_/")==0} @$roots; return $v;
    }
    if ($type eq 'content_marker') {_checkpoint_fail() unless $v eq 'structural-v1'; return $v}
    if ($type eq 'container_version' || $type eq 'protocol_two' || $type eq 'reference_version') {
        my $want=$type eq 'reference_version' ? 1 : 2; _checkpoint_fail() unless $v eq "$want"; return $want;
    }
    _checkpoint_fail();
}
sub _checkpoint_event_value {
    my ($key,$v,$c,$strict,$depth,$claude)=@_; return undef unless defined $v;
    return _checkpoint_node($key,$v,$c,$strict,$depth+1) if $key =~ /\A(?:task_ref|label_ref|label_refs)\z/;
    return _checkpoint_primitive('agent_type',$v,$c) if $claude && $key eq 'role';
    return _checkpoint_primitive($key,$v,$c) if $key eq 'agent_type' || $key eq 'role' || $ENUM{$key};
    if ($key eq 'agent') {_checkpoint_fail() unless _id($v) || _scalar($v) && $v =~ /\Asha256:[0-9a-f]{64}\z/}
    my $out=eval {_value($key,$v,$c->{project_id})}; _checkpoint_fail() if $@ || !defined($out);
    return $out;
}
sub _checkpoint_structural_signature {
    my ($type,$v,$c,$strict,$depth)=@_;
    if (_scalar($v)) {
        return $v if $v =~ /\Asha256:[0-9a-f]{64}\z/;
        return '1' if $type eq 'delegation_start' && $v eq '1';
        if ($type eq 'delegation' && $v =~ /\A(.+Z):([^:]*)\z/) {
            my ($ts,$status)=($1,$2); _checkpoint_primitive('timestamp',$ts,$c);
            _checkpoint_primitive('status',$status,$c); return $v;
        }
    }
    _checkpoint_fail() if $strict || $depth>16;
    my $body=$v;
    if (_scalar($v)) {
        _checkpoint_fail() if length(utf8::is_utf8($v) ? _encode_utf8($v) : $v)>65536;
        $body=eval {$JSON->decode($v)}; _checkpoint_fail() if $@;
    }
    my $fields=_allow()->{"$type/checkpoint_value"};
    _checkpoint_fail() unless ref($body) eq 'HASH' && $fields;
    my %out;
    for my $key (keys %$body) {
        my $disposition=$fields->{$key}//''; _checkpoint_fail() unless $disposition eq 'keep' || $disposition eq 'omit';
        next if $disposition eq 'omit';
        my $value=$body->{$key};
        # Match R1 content_input + _signature exactly for replay. The Claude
        # call retains its agent type above; old journal signature bodies used
        # the generic role enum and null for empty optional identities/models.
        $value=undef if _scalar($value) && $value eq '' && $key =~ /\A(?:id|agent|agent_id|alias_from|alias_id|attempt_id|session|session_key|turn_id|parent_id|parent_delegation|parent_session|parent_agent_id|model|requested_model|resume_at)\z/;
        $out{$key}=_checkpoint_event_value($key,$value,$c,0,$depth+1,1);
    }
    # Only this closed, value-validated object reaches the existing projector;
    # its generic fallback cannot hash an unknown/original source object here.
    return _signature($type,\%out,$c->{project_id});
}
sub _checkpoint_sent_signature {
    my ($key,$v,$c,$strict,$depth)=@_;
    _checkpoint_primitive('sent_key',$key,$c,1);
    my $type=$key =~ /\Astart:/ ? 'delegation_start' : $key =~ /\Aend:/ ? 'delegation'
        : $key =~ /\Aalias:/ ? 'agent_alias' : $key =~ /\Acontext:cl:/ ? 'delegation_activity'
        : $key =~ /\Acontext:/ ? 'session_context' : 'session_observed';
    return _checkpoint_structural_signature($type,$v,$c,$strict,$depth);
}
sub checkpoint_signature {
    my ($key,$v,$context)=@_; my ($out,$ok);
    $ok=eval {$out=_checkpoint_sent_signature($key,$v,_checkpoint_context($context),0,0); 1};
    _checkpoint_fail() unless $ok; return $out;
}
sub _checkpoint_lifecycle {
    my ($v,$c,$strict,$depth)=@_;
    _checkpoint_fail() unless ref($v) eq 'HASH' && _scalar($v->{type})
        && $v->{type} =~ /\A(?:session_observed|session_context|delegation_start|delegation_activity|delegation|agent_link|agent_alias|agent_closed)\z/;
    my $type=$v->{type}; my $fields=_allow()->{$type}; my %out=(type=>$type);
    for my $key (keys %$v) {
        next if $key eq 'type';
        if ($key eq 'content_policy') {_checkpoint_primitive('content_marker',$v->{$key},$c) if $strict; next}
        if ($key eq 'policy_generation') {$out{$key}=_checkpoint_primitive('uint',$v->{$key},$c); next}
        my $disposition=$fields->{$key}//'';
        $disposition='keep' if $key eq 'task_ref' || $key eq 'label_ref';
        _checkpoint_fail() unless $disposition eq 'keep' || $disposition eq 'omit' || $disposition eq 'project';
        if ($disposition eq 'omit') {_checkpoint_fail() if $strict; next}
        $out{$key}=$disposition eq 'project'
            ? _checkpoint_structural_signature($type,$v->{$key},$c,$strict,$depth+1)
            : _checkpoint_event_value($key,$v->{$key},$c,$strict,$depth+1,0);
    }
    _checkpoint_fail() if $strict && (!exists($v->{content_policy}) || !exists($v->{policy_generation}));
    $out{content_policy}='structural-v1'; $out{policy_generation}//=$c->{policy_generation}; return \%out;
}
sub _checkpoint_node {
    my ($type,$v,$c,$strict,$depth)=@_; _checkpoint_fail() if $depth>16;
    my $schema=_checkpoint_contract();
    if (my $object=$schema->{objects}{$type}) {
        return undef if !defined($v) && $object->{nullable};
        _checkpoint_fail() unless ref($v) eq 'HASH'; my %out; my %omit=map {$_=>1} @{$object->{omit}//[]};
        for my $key (keys %$v) {
            if ($omit{$key}) {_checkpoint_fail() if $strict; next}
            my $domain=$object->{fields}{$key}; _checkpoint_fail() unless defined $domain;
            # Old container/envelope values are replaced only during projection.
            if (!$strict && $type eq 'checkpoint' && $key eq 'version') {
                _checkpoint_fail() unless _scalar($v->{$key}) && $v->{$key} =~ /\A[12]\z/; next;
            }
            if (!$strict && $type eq 'checkpoint' && $key eq 'content_policy') {
                _checkpoint_fail() unless _scalar($v->{$key}) && $v->{$key} =~ /\A(?:structural|legacy-excerpts)-v1\z/; next;
            }
            $out{$key}=_checkpoint_node($domain,$v->{$key},$c,$strict,$depth+1);
        }
        my @required=@{$object->{required}//[]}; @required=() if !$strict && $type eq 'checkpoint';
        _checkpoint_fail() if grep {!exists $v->{$_}} @required;
        _checkpoint_fail() if $type eq 'source_meta' && (!defined($v->{id}) || ref($v->{id}) || $v->{id} eq '');
        if ($type eq 'checkpoint' && !$strict) {@out{qw(version content_policy policy_generation)}=(2,'structural-v1',$c->{policy_generation})}
        if ($type eq 'claude_call' && defined($out{role}) && defined($out{agent_type}) && $out{role} ne $out{agent_type}) {_checkpoint_fail()}
        return \%out;
    }
    if (my $map=$schema->{maps}{$type}) {
        _checkpoint_fail() unless ref($v) eq 'HASH'; my %out;
        for my $key (keys %$v) {
            my $projected_key=_checkpoint_primitive($map->{key},$key,$c,1);
            _checkpoint_fail() if exists $out{$projected_key};
            $out{$projected_key}=$type eq 'sent_map' ? _checkpoint_sent_signature($key,$v->{$key},$c,$strict,$depth+1)
                : _checkpoint_node($map->{value},$v->{$key},$c,$strict,$depth+1);
        }
        return \%out;
    }
    if (my $array=$schema->{arrays}{$type}) {
        _checkpoint_fail() unless ref($v) eq 'ARRAY' && @$v<=$array->{max};
        _checkpoint_fail() if grep {!defined($_) || ref($_) || $_ eq ''} @$v;
        my @out=map {_checkpoint_node($array->{item},$_,$c,$strict,$depth+1)} @$v;
        if ($type eq 'shard_names') {my %seen; _checkpoint_fail() if grep {$seen{$_}++} @out}
        return \@out;
    }
    return _checkpoint_lifecycle($v,$c,$strict,$depth+1) if $type eq 'lifecycle_event';
    # Old Codex role labels are not new Loomy role identifiers. Their known
    # fallback is safe during adoption; strict new generations require the enum.
    return 'unknown' if !$strict && $type eq 'role' && _scalar($v) && !$ROLE{$v};
    return _checkpoint_primitive($type,$v,$c);
}
sub project_checkpoint {
    my ($state,$context)=@_; my ($out,$ok);
    $ok=eval {
        my $c=_checkpoint_context($context);
        _checkpoint_fail() if length($JSON->encode($state))>33554432;
        $out=_checkpoint_node('checkpoint',$state,$c,0,0); 1;
    };
    _checkpoint_fail() unless $ok; return $out;
}
sub validate_checkpoint {
    my ($state,$context)=@_; my $ok=eval {
        my $c=_checkpoint_context($context);
        _checkpoint_fail() if length($JSON->encode($state))>33554432;
        _checkpoint_node('checkpoint',$state,$c,1,0); 1;
    };
    _checkpoint_fail() unless $ok; return 1;
}

# T1 implements this callable; T6 binds it before effects. This descriptor is
# neither admission nor a replacement for MAINFIRST-LOCK verification.
sub collector_admission_contract {
    return {protocol_version=>1,callable=>'Loomy::CollectorContent::admit(request, lock_attestation)',implemented_by=>'T1',bound_by=>'T6',
        request=>{required=>[qw(protocol_version project_id requester_pid requester_birth policy_generation journal_enabled tasks_restricted)],
            fields=>{protocol_version=>1,project_id=>'existing project ID',requester_pid=>'integer >=2',requester_birth=>'validated OS process-birth identity',
                policy_generation=>'uint',journal_enabled=>'boolean',tasks_restricted=>'boolean'}},
        lock_attestation=>{required=>[qw(protocol_version project_id requester_pid requester_birth collector_pid collector_birth state owner_scope journal_enabled tasks_restricted)],
            fields=>{protocol_version=>1,project_id=>'existing project ID',requester_pid=>'integer >=2',requester_birth=>'validated OS process-birth identity',
                collector_pid=>'integer >=2 or null for a verified new/quiescent slot',collector_birth=>'validated OS process-birth identity or matching null',
                state=>[qw(new live quiescent unknown)],owner_scope=>[qw(requester owned-descendant other unknown)],journal_enabled=>'boolean',tasks_restricted=>'boolean'},
            origin=>'Verified MAINFIRST-LOCK ownership/quiescence API; caller hashes, env flags, names and PID liveness alone are not attestations.'},
        result=>{required=>[qw(protocol_version decision reason request collector_pid collector_birth)],
            fields=>{protocol_version=>1,decision=>[qw(admitted refused hold)],reason=>[qw(compatible-owned verified-quiescent new-owned invalid-request identity-unavailable
                attestation-missing attestation-unverified unsupported-collector project-mismatch process-mismatch ownership-mismatch incompatible-live-writer)],
                request=>'Exact closed validated request tuple above',collector_pid=>'admitted collector identity or null',collector_birth=>'matching process birth or null'}},
        rules=>{default=>'hold; no effects without verified supported LOCK evidence',
            admitted=>'Only compatible owned live collection, verified new owned collection, or verified LOCK quiescence followed by owned claim.',
            refused=>'Invalid/mismatched project or process identity, foreign ownership, or incompatible live content writer; before provider/append/cursor effects.',
            hold=>'Missing/unverified LOCK attestation or unknown/preprotocol collector; obtain supported ownership or verified quiescence first.',
            lifetime=>'Requesting process and its owned descendants; descendants inherit restrictions and writers recheck current policy before effects.',
            journal_disabled=>'A disabled journal admits no collector writes; callers may skip collection without widening this request.',
            durable_policy=>'No grant/policy-generation mutation, global veto, silent watch termination or promise about later independently granted readers.'}};
}

sub _cli {
    STDOUT->autoflush(1); binmode STDOUT,':raw';
    my ($cmd,$root,@args)=@ARGV; die "invalid content command\n" unless defined $root;
    if ($cmd eq 'first-use') {first_use($root); return}
    if ($cmd eq 'hint') {
        my $p=effective_policy($root);
        _say('LABEL_FULL') if label_health($root) eq 'full';
        if ($p->{gated}) {_say('GATED'); return}
        _say('HINT') if !$p->{grant_prompt_version} || $p->{label_sources} eq 'none'; return;
    }
    if ($cmd eq 'show') {
        my $p=effective_policy($root); print $JSON->encode($p),"\n"; return;
    }
    if ($cmd eq 'content' || $cmd eq 'labels' || $cmd eq 'results') {
        if (@args) {
            my $value=shift @args;
            if ($cmd eq 'labels') {
                if ($value eq 'recommended') {$value=recommended_sources()}
                elsif ($value eq 'off') {$value='none'}
                elsif ($value eq 'set' && @args) {$value=shift @args}
                else {die "invalid content command\n"}
            }
            die "invalid content command\n" if @args;
            change_policy($root,{($cmd eq 'content' ? 'journal_content' : $cmd eq 'labels' ? 'label_sources' : 'private_results')=>$value},$cmd eq 'labels');
        }
        my $p=effective_policy($root); die "invalid stored content policy\n" unless $p->{valid};
        _describe({root=>$p->{project}//$root},$p);
        my %source=(default=>'DEFAULT_SOURCE',project=>'PROJECT_SOURCE',environment=>'ENV_SOURCE',
            'environment-denied'=>'DENIED_SOURCE','tasks-veto'=>'VETO_SOURCE');
        _say('GATED') if $p->{gated};   # the grants read as absent: say why, with the remedy
        _say('POLICY_STATE',$ENV{'LOOMY_CONTENT_UI_'.$source{$p->{source}}},$p->{policy_generation});
        _say('OLD_COPIES');
        if ($cmd eq 'results') { _say('RESULT_FACTS'); }
        if ($cmd eq 'labels') {_say($p->{grant_prompt_version} ? 'ACK_DONE' : 'ACK_PENDING')}
        return;
    }
    if ($cmd eq 'label') {
        die "content labels disabled by tasks veto\n" if ($ENV{LOOMY_JOURNAL_TASKS}//'1') eq '0';
        die "human content confirmation required\n" unless human_tty();
        my ($id,$attempt,$kind,$text)=('','','agent');
        while (@args) {my $a=shift @args;
            if ($a eq '--id') {$id=shift(@args)//''}
            elsif ($a eq '--attempt') {$attempt=shift(@args)//''}
            elsif ($a eq '--kind') {$kind=shift(@args)//''}
            elsif ($a eq '--' && @args==1) {$text=shift @args}
            elsif (!defined($text) && !@args && $a !~ /^--/) {$text=$a}
            else {die "invalid content command\n"}
        }
        die "invalid label scope\n" unless _id($id) && defined($text); $attempt||=$id;
        my $stored=load_policy($root); die "invalid stored content policy\n" unless $stored->{valid};
        my $p=$stored->{policy}; my $project=effective_policy($root)->{project_id};
        my %granted=map {$_=>1} @{_sources($p->{label_sources})};
        die "invalid label scope\n" unless _scope({project_id=>$project,target_kind=>$kind,target_id=>$id,attempt_id=>$attempt},$project);
        sanitize_label($text,$p->{label_max_graphemes},$p->{label_max_bytes});
        unless ($granted{'explicit-user'}) {change_policy($root,{label_sources=>join(',',grep {$_ eq 'explicit-user' || $granted{$_}} @SOURCES)})}
        $p=effective_policy($root);
        my $ref=save_label($root,{project_id=>$p->{project_id},target_kind=>$kind,target_id=>$id,attempt_id=>$attempt,source=>'explicit-user',text=>$text});
        print $JSON->encode($ref),"\n"; return;
    }
    die "invalid content command\n";
}
unless (caller) {
    my $ok=eval {_cli(); 1}; unless ($ok) {
        # Only fixed, content-free errors leave this boundary (never raw labels/paths/JSON).
        my $err=$@; my ($unsafe_dir)=$err =~ /\Aunsafe directory: (.+) \(group\/world writable\)\n\z/s;
        # The stored policy reads as invalid when the real cause is an unsafe directory: name the directory instead.
        if (!defined($unsafe_dir) && $err eq "invalid stored content policy\n" && defined($ARGV[1])) {
            my $probe=eval {_context($ARGV[1],0); 1} ? '' : $@;
            ($unsafe_dir)=$probe =~ /\Aunsafe directory: (.+) \(group\/world writable\)\n\z/s;
        }
        $err="content operation failed\n" unless defined($unsafe_dir)
            || $err =~ /\A(?:invalid|unsafe|unknown|human|content|label|display|unclassified)[A-Za-z ;_-]+\n\z/;
        my $agent=$err eq "human content confirmation required\n" ? agent_ancestor_name() : '';
        my $key=defined($unsafe_dir) ? 'UNSAFE_DIRECTORY'
            : $err eq "display context full; label not saved\n" ? 'LABEL_FULL'
            : $err eq "invalid stored content policy\n" ? 'INVALID_POLICY'
            : $err eq "content labels disabled by tasks veto\n" ? 'TASKS_VETO'
            : $err eq "content policy changed; retry command\n" ? 'POLICY_CHANGED'
            : $err eq "human content confirmation required\n" ? ($agent ? 'AGENT_ANCESTOR' : 'HUMAN_REQUIRED')
            : $err =~ /\Acontent confirmation/ ? 'CONFIRMATION_ABORTED' : 'OPERATION_FAILED';
        if (defined $unsafe_dir) {
            my $shown=display_path($unsafe_dir);
            print STDERR exists($ENV{LOOMY_CONTENT_UI_UNSAFE_DIRECTORY}) ? _message('UNSAFE_DIRECTORY',$shown)
                : _encode_utf8("unsafe directory: $shown (group/world writable)\n");
            print STDERR _message('UNSAFE_DIRECTORY_HINT',_shell_quote($shown)) if exists $ENV{LOOMY_CONTENT_UI_UNSAFE_DIRECTORY_HINT};
        } else {
            print STDERR exists($ENV{"LOOMY_CONTENT_UI_$key"})
                ? _message($key,$key eq 'INVALID_POLICY' ? display_path("$ARGV[1]/.loomy/logs/$POLICY")
                    : $key eq 'AGENT_ANCESTOR' ? $agent : ()) : $err;
        }
        exit 1;
    }
}
1;
