# Lifetime election and fencing for the native lifecycle/checkpoint collector.
package Loomy::CollectorOwner;
use strict;
use warnings;
use Cwd qw(abs_path);
use Errno qw(EAGAIN EWOULDBLOCK ENOENT);
use Fcntl qw(:DEFAULT :flock :mode O_NOFOLLOW O_NONBLOCK F_GETFD F_SETFD FD_CLOEXEC);
use IO::Handle;
use JSON::PP ();
use POSIX ();
use Scalar::Util qw(blessed refaddr weaken);
use Sys::Hostname ();
use Time::HiRes qw(stat lstat);

my $LIB = abs_path(__FILE__); $LIB =~ s{/[^/]+$}{};
require "$LIB/runtime-paths.pl";
my $JSON = JSON::PP->new->utf8->canonical;
my $LOCK = 'collector.lock';
my $RECORD = 'collector-owner-v1.json';
my $MAX_RECORD = 4096;
my @RECORD_KEYS = qw(schema protocol build implementation host boot pid birth epoch scope_revision state);
my %RECORD_KEY = map { $_ => 1 } @RECORD_KEYS;

# This table authenticates actual live objects. It is not a project, PID, or
# reader registry. Object contents and a copied acquisition nonce grant nothing.
my %AUTH;
my $TEMP_SEQUENCE = 0;

sub _abort { die "collector-owner:$_[0]\n" }
sub _reason {
    return $1 if defined($_[0]) && $_[0] =~ /\Acollector-owner:([a-z-]+)\n\z/;
    return $_[1] // 'io-error';
}
sub _facts {
    my ($status,$reason,%other) = @_;
    return {status=>$status, reason=>$reason, %other};
}
sub _scalar { defined($_[0]) && !ref($_[0]) }
sub _build { _scalar($_[0]) && $_[0] =~ /\A[A-Za-z0-9][A-Za-z0-9_.:+-]{0,127}\z/ }
sub _diagnostic {
    return undef unless _scalar($_[0]) && length($_[0]) && length($_[0]) <= 256
        && $_[0] =~ /\A[A-Za-z0-9][A-Za-z0-9_.: +\/-]*\z/;
    return "$_[0]";
}
sub _cloexec {
    my ($h) = @_;
    my $flags = fcntl($h,F_GETFD,0);
    _abort('io-error') unless defined($flags) && fcntl($h,F_SETFD,$flags|FD_CLOEXEC);
    return $h;
}
sub _same_inode {
    my ($a,$b) = @_;
    return ref($a) eq 'ARRAY' && ref($b) eq 'ARRAY' && @$a && @$b
        && $a->[0] == $b->[0] && $a->[1] == $b->[1];
}
sub _same_file {
    my ($a,$b) = @_;
    return _same_inode($a,$b) && !grep { $a->[$_] != $b->[$_] } (2,3,4,5,7,9,10);
}
sub _private_file {
    my ($s) = @_;
    return @$s && S_ISREG($s->[2]) && $s->[4] == $< && $s->[3] == 1
        && ($s->[2]&07777) == 0600;
}
sub _close_context {
    my ($ctx) = @_;
    return unless ref($ctx) eq 'HASH';
    for my $key (qw(logs _alias_parent loomy)) {
        my $h = delete $ctx->{$key};
        close($h) if defined($h) && defined(fileno($h));
    }
}
sub _in_dir {
    my ($dir,$work) = @_;
    sysopen my $cwd,'.',O_RDONLY|O_NOFOLLOW|O_NONBLOCK or _abort('io-error');
    _cloexec($cwd);
    unless (chdir($dir)) { close($cwd); _abort('unsafe-runtime') }
    my ($value,$ok,$error);
    { local $@; $ok = eval { $value = $work->(); 1 }; $error = $@ }
    my $restored = chdir($cwd);
    my $closed = close($cwd);
    _abort('io-error') unless $restored && $closed;
    die $error unless $ok;
    return $value;
}
sub _current {
    my ($ctx) = @_;
    my $ok = eval { Loomy::RuntimePaths::assert_current($ctx); 1 };
    _abort('unsafe-runtime') unless $ok;
    return 1;
}
sub _context {
    my ($ctx) = @_;
    _abort('invalid-context') unless ref($ctx) eq 'HASH' && _scalar($ctx->{root})
        && _scalar($ctx->{requested_root});
    _current($ctx);
    my $fresh;
    my $ok = eval { $fresh = Loomy::RuntimePaths::resolve($ctx->{requested_root}); 1 };
    _abort('unsafe-runtime') unless $ok && ref($fresh) eq 'HASH';
    _abort('unsafe-runtime') unless $fresh->{root} eq $ctx->{root};
    for my $key (qw(loomy logs)) { _cloexec($fresh->{$key}) if defined($fresh->{$key}) }
    return $fresh;
}
sub _acquisition_gate_context {
    my ($original) = @_;
    _abort('invalid-context') unless ref($original) eq 'HASH' && _scalar($original->{root})
        && _scalar($original->{requested_root});
    return _context($original) unless defined($original->{loomy});
    # A peer may create logs after the caller resolved its context. Pin and
    # elect on the original parent first; do not interpret that creation as an
    # unsafe replacement, or race another absent-logs resolve before election.
    my ($loomy,$ls);
    my $ok = eval { ($loomy,$ls) = Loomy::RuntimePaths::dir("$original->{root}/.loomy"); 1 };
    _abort('unsafe-runtime') unless $ok && _same_inode($original->{ls},$ls);
    _cloexec($loomy);
    return {root=>$original->{root},requested_root=>$original->{requested_root},loomy=>$loomy,ls=>$ls};
}
sub _refresh_acquisition_context {
    my ($original,$gate_context) = @_;
    my $fresh;
    my $ok = eval { $fresh = Loomy::RuntimePaths::resolve($original->{requested_root}); 1 };
    _abort('unsafe-runtime') unless $ok && ref($fresh) eq 'HASH'
        && $fresh->{root} eq $original->{root} && defined($fresh->{loomy})
        && _same_inode($gate_context->{ls},$fresh->{ls});
    my %view = %$original;
    if (!defined($original->{logs}) && defined($fresh->{logs})) {
        # This is the sole permitted transition. Keep all original parent,
        # source and alias pins, and validate the newly existing logs normally.
        @view{qw(logs ds)} = @{$fresh}{qw(logs ds)};
    }
    _current(\%view);
    close($fresh->{loomy}) or _abort('io-error');
    $fresh->{loomy} = delete $gate_context->{loomy};
    _close_context($gate_context);
    _current($fresh);
    return $fresh;
}
sub _scope_copy {
    my ($scope) = @_;
    _abort('unsafe-runtime') unless ref($scope) eq 'HASH' && ref($scope->{roots}) eq 'ARRAY'
        && @{$scope->{roots}} && @{$scope->{roots}} <= 1024
        && _scalar($scope->{revision}) && $scope->{revision} =~ /\A[0-9a-f]{64}\z/;
    my ($previous,@roots);
    for my $root (@{$scope->{roots}}) {
        _abort('unsafe-runtime') unless _scalar($root) && $root =~ m{\A/}
            && length($root) <= 4096 && $root !~ /[\x00-\x1f\x7f]/
            && (!defined($previous) || $previous lt $root);
        push @roots,"$root"; $previous = $root;
    }
    return {roots=>\@roots,revision=>"$scope->{revision}"};
}
sub _read_probe_file {
    my ($path,$limit) = @_;
    sysopen my $h,$path,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or return undef;
    _cloexec($h);
    my $bytes = ''; my $ok = 1;
    while (length($bytes) <= $limit) {
        my $n = sysread($h,my $part,$limit+1-length($bytes));
        if (!defined($n)) { $ok=0; last }
        last unless $n;
        $bytes .= $part;
    }
    $ok = 0 unless close($h);
    return $ok && length($bytes) <= $limit ? $bytes : undef;
}
sub _command_probe {
    my (@command) = @_;
    my $pid = open my $h,'-|';
    return undef unless defined($pid);
    if (!$pid) {
        after_fork_child();
        open STDERR,'>','/dev/null' or POSIX::_exit(1);
        exec {$command[0]} @command or POSIX::_exit(1);
    }
    _cloexec($h);
    my $bytes = ''; my $ok = 1;
    while (length($bytes) <= 512) {
        my $n = sysread($h,my $part,513-length($bytes));
        if (!defined($n)) { $ok=0; last }
        last unless $n;
        $bytes .= $part;
    }
    $ok = 0 unless close($h);
    return $ok && length($bytes) <= 512 ? $bytes : undef;
}

# Localize this subroutine in a hermetic test to supply missing, reused, or
# inaccessible birth/boot evidence. None of these diagnostics can steal a lock.
sub _probe_identity {
    my ($pid) = @_;
    my $identity = {host=>_diagnostic(eval { Sys::Hostname::hostname() })};
    if ($^O eq 'linux') {
        my $boot = _read_probe_file('/proc/sys/kernel/random/boot_id',128);
        if (defined($boot)) { $boot =~ s/\s+\z//; $identity->{boot} = _diagnostic($boot) }
        my $process = _read_probe_file("/proc/$pid/stat",4096);
        if (defined($process) && $process =~ /\A[0-9]+ \(.*\) [A-Za-z] (.*)\z/s) {
            my @fields = split /\s+/,$1;
            $identity->{birth} = "linux-start-ticks:$fields[18]"
                if defined($fields[18]) && $fields[18] =~ /\A[0-9]+\z/;
        }
    } elsif ($^O eq 'darwin') {
        my $boot = _command_probe('/usr/sbin/sysctl','-n','kern.boottime');
        $identity->{boot} = "darwin-boottime:$1:$2"
            if defined($boot) && $boot =~ /\bsec\s*=\s*([0-9]+),\s*usec\s*=\s*([0-9]+)/;
        my $birth = _command_probe('/bin/ps','-p',"$pid",'-o','lstart=');
        if (defined($birth)) {
            $birth =~ s/\A\s+|\s+\z//g;
            # ps lstart has second resolution and is diagnostic evidence only.
            $identity->{birth} = _diagnostic("darwin-lstart:$birth") if length($birth);
        }
    }
    return $identity;
}
sub _identity {
    my $probe = eval { _probe_identity($$) };
    $probe = {} unless ref($probe) eq 'HASH';
    return {map { $_=>_diagnostic($probe->{$_}) } qw(host boot birth)};
}
sub _epoch {
    sysopen my $h,'/dev/urandom',O_RDONLY|O_NOFOLLOW|O_NONBLOCK or _abort('io-error');
    _cloexec($h);
    my $bytes = '';
    while (length($bytes) < 32) {
        my $n = sysread($h,my $part,32-length($bytes));
        unless (defined($n) && $n) { close($h); _abort('io-error') }
        $bytes .= $part;
    }
    close($h) or _abort('io-error');
    return unpack('H*',$bytes);
}
sub _validate_record {
    my ($record,$raw) = @_;
    _abort('invalid-record') unless ref($record) eq 'HASH' && exists($record->{schema});
    _abort('unsupported-schema') unless _scalar($record->{schema}) && $record->{schema} eq '1';
    _abort('invalid-record') unless exists($record->{protocol});
    _abort('unsupported-protocol') unless _scalar($record->{protocol}) && $record->{protocol} eq '1';
    _abort('invalid-record') unless keys(%$record) == @RECORD_KEYS
        && !grep { !$RECORD_KEY{$_} } keys %$record;
    # Values in this schema are scalar, so each object-key token must be unique.
    my %seen;
    while ($raw =~ /("(?:[^"\\]|\\.)*")\s*:/g) {
        my $key = eval { $JSON->decode($1) };
        _abort('invalid-record') if $@ || !defined($key) || $seen{$key}++;
    }
    _abort('invalid-record') unless _build($record->{build})
        && _build($record->{implementation})
        && _scalar($record->{pid}) && $record->{pid} =~ /\A[1-9][0-9]{0,15}\z/
        && _scalar($record->{epoch}) && $record->{epoch} =~ /\A[0-9a-f]{64}\z/
        && _scalar($record->{scope_revision}) && $record->{scope_revision} =~ /\A[0-9a-f]{64}\z/
        && _scalar($record->{state}) && $record->{state} =~ /\A(?:collecting|draining|released)\z/;
    for my $key (qw(host boot birth)) {
        _abort('invalid-record') if defined($record->{$key}) && !defined(_diagnostic($record->{$key}));
    }
    return $record;
}
sub _read_record_here {
    my @before = lstat($RECORD);
    unless (@before) { _abort('io-error') unless $! == ENOENT; return undef }
    _abort('unsafe-record') unless _private_file(\@before) && $before[7] <= $MAX_RECORD;
    sysopen my $h,$RECORD,O_RDONLY|O_NOFOLLOW|O_NONBLOCK or _abort('unsafe-record');
    _cloexec($h);
    my @opened = stat($h);
    unless (_private_file(\@opened) && _same_file(\@before,\@opened)) {
        close($h); _abort('unsafe-record');
    }
    my $raw = '';
    while (length($raw) <= $MAX_RECORD) {
        my $n = sysread($h,my $part,$MAX_RECORD+1-length($raw));
        unless (defined($n)) { close($h); _abort('io-error') }
        last unless $n;
        $raw .= $part;
    }
    my @after = stat($h);
    close($h) or _abort('io-error');
    my @named = lstat($RECORD);
    _abort('unsafe-record') unless length($raw) <= $MAX_RECORD
        && _same_file(\@before,\@after) && _same_file(\@after,\@named);
    my $record = eval { $JSON->decode($raw) };
    _abort('invalid-record') if $@;
    return _validate_record($record,$raw);
}
sub _open_lock_here {
    my ($create) = @_;
    my @before = lstat($LOCK);
    my $h;
    if (!@before) {
        _abort('io-error') unless $! == ENOENT;
        _abort('missing-lock') if lstat($RECORD);
        return undef unless $create;
        my $mask = umask 0077;
        my $made = sysopen($h,$LOCK,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK,0600);
        umask $mask;
        _abort('unsafe-lock') unless $made;
        @before = lstat($LOCK);
    } else {
        _abort('unsafe-lock') unless _private_file(\@before);
        sysopen($h,$LOCK,($create ? O_RDWR : O_RDONLY)|O_NOFOLLOW|O_NONBLOCK)
            or _abort('unsafe-lock');
    }
    _cloexec($h);
    my @opened = stat($h); my @named = lstat($LOCK);
    unless (_private_file(\@before) && _private_file(\@opened)
        && _same_file(\@before,\@opened) && _same_file(\@opened,\@named)) {
        close($h); _abort('unsafe-lock');
    }
    return {fh=>$h,stat=>\@opened};
}
sub _verify_lock_here {
    my ($state) = @_;
    my @opened = stat($state->{fh}); my @named = lstat($LOCK);
    _abort('unsafe-lock') unless _private_file(\@opened) && _private_file(\@named)
        && _same_inode($state->{lock_stat},\@opened) && _same_inode(\@opened,\@named);
    return 1;
}
sub _record_equal {
    my ($a,$b) = @_;
    return !defined($a) && !defined($b) if !defined($a) || !defined($b);
    return $JSON->encode($a) eq $JSON->encode($b);
}
sub _storage_here {
    my ($state) = @_;
    _verify_lock_here($state);
    my $current = _read_record_here();
    _abort('invalid-record') unless _record_equal($current,$state->{record});
    return 1;
}
sub _write_record {
    my ($state,$next) = @_;
    my $raw = $JSON->encode($next)."\n";
    _abort('invalid-record') if length($raw) > $MAX_RECORD;
    _current($state->{ctx});
    _in_dir($state->{ctx}{logs},sub {
        _storage_here($state);
        my $tmp = '.collector-owner-v1.'.$$.'.'.$state->{epoch}.'.'.(++$TEMP_SEQUENCE).'.tmp';
        my ($h,$created,$renamed,@temporary);
        my ($ok,$error);
        {
            local $@;
            $ok = eval {
                my $mask = umask 0077;
                $created = sysopen($h,$tmp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_NONBLOCK,0600);
                umask $mask;
                _abort('io-error') unless $created;
                _cloexec($h); @temporary = stat($h);
                _abort('unsafe-record') unless _private_file(\@temporary);
                print {$h} $raw or _abort('io-error');
                $h->flush or _abort('io-error');
                $h->sync or _abort('io-error');
                close($h) or _abort('io-error'); undef $h;
                _current($state->{ctx});
                _storage_here($state);
                my @named = lstat($tmp);
                _abort('unsafe-record') unless _private_file(\@named) && _same_inode(\@temporary,\@named);
                rename($tmp,$RECORD) or _abort('io-error'); $renamed=1;
                $state->{record} = {%$next};
                $state->{ctx}{logs}->sync or _abort('io-error');
                _current($state->{ctx});
                _storage_here($state);
                1;
            };
            $error = $@;
        }
        close($h) if defined($h) && defined(fileno($h));
        if ($created && !$renamed) {
            my @named = lstat($tmp);
            unlink($tmp) if _same_inode(\@temporary,\@named);
        }
        die $error unless $ok;
        return 1;
    });
    return 1;
}
sub _close_state {
    my ($state,$terminal) = @_;
    # Closing, rather than LOCK_UN, is essential after fork: the parent's open
    # file description must retain its kernel lock when a child drops its copy.
    _close_context($state->{ctx});
    my $h = delete $state->{fh};
    close($h) if defined($h) && defined(fileno($h));
    $state->{terminal} = $terminal if defined($terminal);
    return 1;
}
sub _auth {
    my ($guard) = @_;
    die "collector owner INVALID_GUARD\n" unless blessed($guard)
        && $guard->isa('Loomy::CollectorOwner::Guard');
    my $state = $AUTH{refaddr($guard)};
    die "collector owner INVALID_GUARD\n" unless $state && defined($state->{guard})
        && refaddr($state->{guard}) == refaddr($guard);
    if ($state->{pid} != $$) {
        _close_state($state,'FORKED'); die "collector owner FORKED\n";
    }
    die "collector owner $state->{terminal}\n" if defined($state->{terminal});
    return $state;
}

sub try_acquire {
    my ($context,$build,$protocol) = @_;
    return _facts('unavailable','disabled') if defined($ENV{LOOMY_JOURNAL}) && $ENV{LOOMY_JOURNAL} eq '0';
    $protocol //= 1;
    return _facts('unsafe','invalid-build') unless _build($build);
    return _facts('incompatible','unsupported-protocol') unless _scalar($protocol) && $protocol eq '1';
    my $identity = _identity();
    my ($ctx,$lock,$state,$guard,$facts,$gate);
    my ($ok,$error);
    {
        local $@;
        $ok = eval {
          ACQUIRE: {
            $ctx = _acquisition_gate_context($context);
            if (!defined($ctx->{loomy})) { $facts=_facts('unavailable','missing-runtime'); last ACQUIRE }
            unless (flock($ctx->{loomy},LOCK_EX|LOCK_NB)) {
                _abort('io-error') unless $! == EAGAIN || $! == EWOULDBLOCK;
                $facts=_facts('busy','bootstrap-busy'); last ACQUIRE;
            }
            $gate=1;
            $ctx = _refresh_acquisition_context($context,$ctx);
            unless (defined($ctx->{logs})) {
                _in_dir($ctx->{loomy},sub {
                    _abort('unsafe-runtime') if lstat('logs');
                    _abort('io-error') unless $! == ENOENT;
                    my $mask=umask 0077; my $made=mkdir('logs',0700); umask $mask;
                    _abort('io-error') unless $made;
                    return 1;
                });
                $ctx = _refresh_acquisition_context($context,$ctx);
                _abort('unsafe-runtime') unless defined($ctx->{logs});
            }
            $lock = _in_dir($ctx->{logs},sub { _open_lock_here(1) });
            unless (flock($lock->{fh},LOCK_EX|LOCK_NB)) {
                _abort('io-error') unless $! == EAGAIN || $! == EWOULDBLOCK;
                my $record = _in_dir($ctx->{logs},sub { _read_record_here() });
                $facts = _facts('busy','locked',defined($record) ? (record=>{%$record}) : ());
                last ACQUIRE;
            }
            _current($ctx);
            my $record = _in_dir($ctx->{logs},sub { _read_record_here() });
            my $scope = _scope_copy(Loomy::RuntimePaths::scope_set($ctx));
            my $epoch = _epoch();
            my $opaque;
            $guard = bless \$opaque,'Loomy::CollectorOwner::Guard';
            $state = {guard=>$guard,ctx=>$ctx,fh=>$lock->{fh},lock_stat=>$lock->{stat},
                pid=>$$,epoch=>$epoch,scope=>$scope,record=>$record,phase=>'collecting',published=>0};
            weaken($state->{guard}); $AUTH{refaddr($guard)}=$state;
            my $next = {schema=>1,protocol=>1,build=>"$build",implementation=>'perl',
                %$identity,pid=>0+$$,epoch=>$epoch,scope_revision=>$scope->{revision},state=>'collecting'};
            _write_record($state,$next); $state->{published}=1;
            flock($ctx->{loomy},LOCK_UN) or _abort('io-error'); $gate=0;
            $facts = _facts('owned','owned',guard=>$guard,record=>{%$next},scope_set=>_scope_copy($scope));
          }
            1;
        };
        $error = $@;
    }
    unless ($ok && $facts && $facts->{status} eq 'owned') {
        if ($state) { _close_state($state,'FENCED') }
        else {
            close($lock->{fh}) if $lock && defined(fileno($lock->{fh}));
            _close_context($ctx);
        }
    }
    return $facts if $ok;
    my $reason = _reason($error,'unsafe-runtime');
    return _facts($reason =~ /\Aunsupported-/ ? 'incompatible' : $reason eq 'io-error' ? 'unavailable' : 'unsafe',$reason);
}

sub inspect {
    my ($context) = @_;
    return _facts('unavailable','disabled') if defined($ENV{LOOMY_JOURNAL}) && $ENV{LOOMY_JOURNAL} eq '0';
    my ($ctx,$lock,$facts,$ok,$error);
    {
        local $@;
        $ok = eval {
          INSPECT: {
            $ctx = _context($context);
            if (!defined($ctx->{loomy})) {
                $facts=_facts('unavailable','missing-runtime'); last INSPECT;
            }
            # Inspection must not take the lifetime lock between a bootstrap
            # winner's first creation and flock, making that creator a loser.
            unless (flock($ctx->{loomy},LOCK_EX|LOCK_NB)) {
                _abort('io-error') unless $! == EAGAIN || $! == EWOULDBLOCK;
                $facts=_facts('busy','bootstrap-busy'); last INSPECT;
            }
            _current($ctx);
            if (!defined($ctx->{logs})) {
                $facts=_facts('unavailable','missing-runtime'); last INSPECT;
            }
            $lock = _in_dir($ctx->{logs},sub { _open_lock_here(0) });
            unless ($lock) { $facts=_facts('unavailable','missing-runtime'); last INSPECT }
            my $free = flock($lock->{fh},LOCK_EX|LOCK_NB);
            _abort('io-error') unless $free || $! == EAGAIN || $! == EWOULDBLOCK;
            my $record=_in_dir($ctx->{logs},sub { _read_record_here() });
            if (!$free) {
                $facts=_facts('busy','locked',defined($record) ? (record=>{%$record}) : ());
            } else {
                _current($ctx);
                _in_dir($ctx->{logs},sub { _verify_lock_here({fh=>$lock->{fh},lock_stat=>$lock->{stat}}) });
                $facts=_facts('unavailable','free',defined($record) ? (record=>{%$record}) : ());
            }
          }
            1;
        };
        $error=$@;
    }
    close($lock->{fh}) if $lock && defined(fileno($lock->{fh}));
    _close_context($ctx);
    return $facts if $ok;
    my $reason = _reason($error,'unsafe-runtime');
    return _facts($reason =~ /\Aunsupported-/ ? 'incompatible' : $reason eq 'io-error' ? 'unavailable' : 'unsafe',$reason);
}

sub assert_owner {
    my ($guard,$phase,$target_context) = @_;
    $phase //= 'write';
    my $state = _auth($guard);
    die "collector owner INVALID_PHASE\n" unless $phase eq 'write' || $phase eq 'batch';
    die "collector owner DRAINING\n" if $phase eq 'batch' && $state->{phase} eq 'draining';
    my $ok = eval {
        _abort('invalid-record') unless $state->{published};
        _current($state->{ctx});
        _in_dir($state->{ctx}{logs},sub { _storage_here($state) });
        1;
    };
    unless ($ok) { _close_state($state,'FENCED'); die "collector owner FENCED\n" }
    if (defined($target_context)) {
        # Validate the guard first: a wrong target cannot conceal lost authority.
        # Target mismatch alone leaves an otherwise valid guard usable.
        my $matches = eval {
            Loomy::RuntimePaths::assert_current($target_context);
            ref($target_context) eq 'HASH' && defined($target_context->{loomy})
                && defined($target_context->{logs})
                && _same_inode($state->{ctx}{ls},$target_context->{ls})
                && _same_inode($state->{ctx}{ds},$target_context->{ds});
        };
        die "collector owner WRONG_RUNTIME\n" unless $matches;
    }
    return 1;
}
sub begin_drain {
    my ($guard) = @_;
    assert_owner($guard);
    my $state = _auth($guard);
    return 1 if $state->{phase} eq 'draining';
    my $next = {%{$state->{record}},state=>'draining'};
    my $ok=eval { _write_record($state,$next); 1 };
    unless ($ok) { _close_state($state,'FENCED'); die "collector owner IO_ERROR\n" }
    $state->{phase}='draining';
    return 1;
}
sub refresh_scope {
    my ($guard) = @_;
    assert_owner($guard,'batch');
    my $state = _auth($guard);
    my ($scope,$ok);
    $ok=eval {
        $scope=_scope_copy(Loomy::RuntimePaths::scope_set($state->{ctx}));
        my $next={%{$state->{record}},scope_revision=>$scope->{revision}};
        _write_record($state,$next) if $scope->{revision} ne $state->{scope}{revision};
        1;
    };
    unless ($ok) { _close_state($state,'FENCED'); die "collector owner FENCED\n" }
    $state->{scope}=$scope;
    return _scope_copy($scope);
}
sub scope_set {
    my ($guard) = @_;
    assert_owner($guard);
    return _scope_copy(_auth($guard)->{scope});
}
sub release {
    my ($guard) = @_;
    assert_owner($guard);
    my $state = _auth($guard);
    my $next = {%{$state->{record}},state=>'released'};
    my $ok=eval { _write_record($state,$next); 1 };
    unless ($ok) { _close_state($state,'FENCED'); die "collector owner IO_ERROR\n" }
    # Runtime handles close first; the lifetime lock descriptor closes last.
    _close_state($state,'RELEASED');
    return 1;
}
sub after_fork_child {
    for my $state (values %AUTH) {
        _close_state($state,'FORKED') if $state->{pid} != $$;
    }
    return 1;
}
sub _destroy {
    my ($guard) = @_;
    my $id=refaddr($guard); my $state=$AUTH{$id};
    return unless $state && defined($state->{guard}) && refaddr($state->{guard}) == $id;
    if ($state->{pid} != $$) { _close_state($state,'FORKED') }
    elsif (!defined($state->{terminal}) && $state->{published}) { eval { release($guard) }; _close_state($state,'RELEASED') }
    else { _close_state($state,$state->{terminal}//'FENCED') }
    delete $AUTH{$id};
}

package Loomy::CollectorOwner::Guard;
use strict;
use warnings;
sub DESTROY { Loomy::CollectorOwner::_destroy($_[0]) }

1;
