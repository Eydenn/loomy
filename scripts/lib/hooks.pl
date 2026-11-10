# Exact registration catalog, pure transforms and pinned settings-file updates.
package Loomy::Hooks;
use strict;
use warnings;
use JSON::PP ();
use Scalar::Util qw(refaddr);

my $json = JSON::PP->new->canonical->allow_nonref;
my %catalog = (
    claude => [
        {event=>'SessionStart', mode=>'start', timeout=>20},
        {event=>'SessionEnd', mode=>'end', timeout=>3},
        {event=>'Stop', mode=>'stop', timeout=>10},
        {event=>'SubagentStop', mode=>'subagent', timeout=>10},
        {event=>'UserPromptSubmit', mode=>'prompt', timeout=>5},
        {event=>'PreToolUse', mode=>'agent-start', timeout=>5, matcher=>'Agent|Task'},
        {event=>'PostToolUse', mode=>'agent-return', timeout=>5, matcher=>'Agent|Task'},
        {event=>'PostToolUseFailure', mode=>'agent-failure', timeout=>5, matcher=>'Agent|Task'},
    ],
    codex => [
        {event=>'SessionStart', mode=>'start', timeout=>20},
        {event=>'SessionEnd', mode=>'end', timeout=>3},
    ],
);
my $claude_prefix = q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/loomy-context.sh" --hook };
my $codex_template = q{sh -c 'd=$PWD; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-context.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-context.sh" ] && exec bash "$d/.loomy/scripts/loomy-context.sh" --hook MODE --tool codex'};
my $statusline = q{sh -c 'd=${CLAUDE_PROJECT_DIR:-$PWD}; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-statusline.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-statusline.sh" ] && exec bash "$d/.loomy/scripts/loomy-statusline.sh"'};

# Retain only commands emitted before the 0.10 rename (49e0d92). These literal
# installer templates first appeared in 6af0aa8, 47c2159, 40eb004, bfae49d and
# 6c1f519. The Agent/Task events were introduced after the rename.
my $historical_claude_prefix = q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook };
my %historical_claude_modes = (
    SessionStart=>'start', SessionEnd=>'end', Stop=>'stop',
    SubagentStop=>'subagent', UserPromptSubmit=>'prompt',
);
my %historical_codex_modes = (SessionStart=>'start', SessionEnd=>'end');
my $historical_codex_template = q{sh -c 'd=$PWD; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/ai-context.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/ai-context.sh" ] && exec bash "$d/.loomy/scripts/ai-context.sh" --hook MODE --tool codex'};
my $historical_statusline = q{sh -c 'd=${CLAUDE_PROJECT_DIR:-$PWD}; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/ai-statusline.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/ai-statusline.sh" ] && exec bash "$d/.loomy/scripts/ai-statusline.sh"'};

sub _provider {
    my ($provider) = @_;
    die "hooks: provider must be claude or codex\n"
        unless defined($provider) && !ref($provider) && exists $catalog{$provider};
    return $provider;
}

# Keep JSON scalar types, including booleans and null, without serialization.
# The active-ref set rejects cycles but permits shared input substructures.
sub _copy {
    my ($value, $active) = @_;
    return $value unless ref($value);
    if (JSON::PP::is_bool($value)) {
        my $boolean = $$value;
        return bless \$boolean, ref($value);
    }
    my $type = ref($value);
    die "hooks: settings contain a non-JSON value\n" unless $type eq 'HASH' || $type eq 'ARRAY';
    $active //= {};
    my $address = refaddr($value);
    die "hooks: settings contain a circular value\n" if $active->{$address};
    local $active->{$address} = 1;
    return [map {_copy($_, $active)} @$value] if $type eq 'ARRAY';
    return {map {$_ => _copy($value->{$_}, $active)} keys %$value};
}

sub catalog {
    my ($provider) = @_;
    return _copy($catalog{_provider($provider)});
}

# Packaging may eventually supply a finite current/retained descriptor list.
# There is deliberately no environment, settings JSON or PATH-based discovery.
sub production_descriptors { return [] }

sub _descriptor {
    my ($descriptor) = @_;
    die "hooks: native descriptor must be an object\n" unless ref($descriptor) eq 'HASH';
    die "hooks: native descriptor fields are invalid\n"
        unless keys(%$descriptor) == 3
            && exists($descriptor->{executable}) && exists($descriptor->{version})
            && exists($descriptor->{resource_version});
    my ($path, $version, $resource_version) = @{$descriptor}{qw(executable version resource_version)};
    die "hooks: native executable path is unsafe\n"
        unless defined($path) && !ref($path) && $path =~ m{\A/[\p{L}\p{N}\p{M} ._+/-]+\z}
            && $path !~ m{//|/\z|/(?:\.|\.\.)(?:/|\z)};
    my $version_pattern = qr/\A[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?(?:\+[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*)?\z/;
    die "hooks: native descriptor versions are invalid\n"
        unless defined($version) && !ref($version) && $version =~ $version_pattern
            && defined($resource_version) && !ref($resource_version) && $resource_version =~ $version_pattern;
    die "hooks: native executable and resource versions differ\n" unless $version eq $resource_version;
    return {executable=>$path, version=>$version, resource_version=>$resource_version};
}

sub _descriptors {
    my ($descriptors) = @_;
    return production_descriptors() unless defined($descriptors);
    die "hooks: native descriptors must be an array\n" unless ref($descriptors) eq 'ARRAY';
    return [map {_descriptor($_)} @$descriptors];
}

sub _spec {
    my ($provider, $event) = @_;
    return unless defined($event) && !ref($event);
    for my $spec (@{$catalog{$provider}}) { return $spec if $spec->{event} eq $event }
    return;
}

sub _shell_command {
    my ($provider, $event) = @_;
    return $statusline if $provider eq 'claude' && $event eq 'statusLine';
    my $spec = _spec($provider, $event);
    return unless $spec;
    return $claude_prefix . $spec->{mode} if $provider eq 'claude';
    my $command = $codex_template;
    $command =~ s/MODE/$spec->{mode}/;
    return $command;
}

sub _historical_command {
    my ($provider, $event) = @_;
    if ($provider eq 'claude') {
        return $historical_statusline if $event eq 'statusLine';
        return unless exists($historical_claude_modes{$event});
        return $historical_claude_prefix . $historical_claude_modes{$event};
    }
    return unless exists($historical_codex_modes{$event});
    my $command = $historical_codex_template;
    $command =~ s/MODE/$historical_codex_modes{$event}/;
    return $command;
}

sub _native_command {
    my ($provider, $event, $descriptor) = @_;
    my $executable = '"' . $descriptor->{executable} . '"';
    return $executable . ' __statusline' if $provider eq 'claude' && $event eq 'statusLine';
    my $spec = _spec($provider, $event);
    die "hooks: native event is unsupported\n" unless $spec;
    return $executable . ' __hook --tool ' . $provider . ' --mode ' . $spec->{mode};
}

# This is a pure serializer for trusted installation descriptors, not selection.
sub native_command {
    my ($provider, $event, $descriptor) = @_;
    _provider($provider);
    die "hooks: native event is unsupported\n" unless defined($event) && !ref($event);
    return _native_command($provider, $event, _descriptor($descriptor));
}

sub _classify {
    my ($provider, $event, $hook, $descriptors) = @_;
    return 'custom' unless ref($hook) eq 'HASH'
        && defined($hook->{type}) && !ref($hook->{type}) && $hook->{type} eq 'command'
        && defined($hook->{command}) && !ref($hook->{command});
    my $shell = _shell_command($provider, $event);
    return 'custom' unless defined($shell);
    return 'shell' if $hook->{command} eq $shell;
    my $historical = _historical_command($provider, $event);
    return 'shell' if defined($historical) && $hook->{command} eq $historical;
    for my $descriptor (@$descriptors) {
        return 'native' if $hook->{command} eq _native_command($provider, $event, $descriptor);
    }
    return 'custom';
}

sub classify_command {
    my ($provider, $event, $hook, $descriptors) = @_;
    _provider($provider);
    $descriptors = _descriptors($descriptors);
    return 'custom' unless defined($event) && !ref($event);
    return _classify($provider, $event, $hook, $descriptors);
}

sub _validate_settings {
    my ($provider, $data) = @_;
    return unless defined($data); # undef is the caller's explicit missing-file sentinel.
    die "hooks: settings must be a JSON object\n" unless ref($data) eq 'HASH';
    _copy($data); # Also reject non-JSON values/cycles in preserved unknown fields.
    if (exists($data->{hooks})) {
        die "hooks: hooks must be an object\n" unless ref($data->{hooks}) eq 'HASH';
        # Other provider events are opaque user data, including their shapes.
        for my $spec (@{$catalog{$provider}}) {
            my $event = $spec->{event};
            next unless exists($data->{hooks}{$event});
            my $groups = $data->{hooks}{$event};
            die "hooks: event groups must be an array\n" unless ref($groups) eq 'ARRAY';
            for my $group (@$groups) {
                die "hooks: group must be an object\n" unless ref($group) eq 'HASH';
                die "hooks: group hooks must be an array\n" unless ref($group->{hooks}) eq 'ARRAY';
                for my $hook (@{$group->{hooks}}) {
                    die "hooks: hook must be an object\n" unless ref($hook) eq 'HASH';
                }
            }
        }
    }
    die "hooks: statusLine must be an object, string or null\n"
        if $provider eq 'claude' && exists($data->{statusLine}) && defined($data->{statusLine})
            && ref($data->{statusLine}) ne 'HASH'
            && (ref($data->{statusLine}) || $json->encode($data->{statusLine}) !~ /\A"/);
}

# Group semantics include matcher and every unknown group field. Sibling hooks
# keep their own order and are never coalesced unless individually owned/equal.
sub _signature {
    my ($group, $hook, $include_command) = @_;
    my %group_fields = map {$_ => $group->{$_}} grep {$_ ne 'hooks'} keys %$group;
    my %hook_fields = map {$_ => $hook->{$_}}
        grep {$include_command || $_ ne 'command'} keys %$hook;
    return $json->encode([\%group_fields, \%hook_fields]);
}

sub _state {
    my ($fact) = @_;
    return 'ambiguous' if $fact->{ambiguous};
    return 'mixed' if $fact->{shell} && $fact->{native};
    return 'native' if $fact->{native};
    return 'shell' if $fact->{shell};
    return 'custom' if $fact->{custom};
    return 'missing';
}

sub _event_fact {
    my ($provider, $event, $groups, $descriptors) = @_;
    my $fact = {event=>$event, state=>'missing', owned=>0, shell=>0, native=>0,
        custom=>0, ambiguous=>0, entries=>[]};
    my %variants;
    for my $group_index (0 .. $#$groups) {
        my $group = $groups->[$group_index];
        for my $hook_index (0 .. $#{$group->{hooks}}) {
            my $hook = $group->{hooks}[$hook_index];
            my $kind = _classify($provider, $event, $hook, $descriptors);
            ++$fact->{$kind};
            push @{$fact->{entries}}, {group_index=>$group_index, hook_index=>$hook_index, kind=>$kind};
            $variants{_signature($group, $hook, 0)} = 1 if $kind ne 'custom';
        }
    }
    $fact->{owned} = $fact->{shell} + $fact->{native};
    $fact->{ambiguous} = keys(%variants) > 1 ? 1 : 0;
    $fact->{state} = _state($fact);
    return $fact;
}

sub _status_fact {
    my ($data, $descriptors) = @_;
    my $fact = {state=>'missing', owned=>0, shell=>0, native=>0, custom=>0, ambiguous=>0};
    if (exists($data->{statusLine})) {
        my $kind = _classify('claude', 'statusLine', $data->{statusLine}, $descriptors);
        $fact->{$kind} = 1;
        $fact->{owned} = $kind eq 'custom' ? 0 : 1;
        # A scalar string is an uninterpreted customization, not a replacement
        # target. Keep it but report the unsupported shape for manual review.
        $fact->{ambiguous} = 1 if defined($data->{statusLine}) && !ref($data->{statusLine});
    }
    $fact->{state} = _state($fact);
    return $fact;
}

# Facts contain indices and kinds only; custom command text never leaves here.
sub _inspect {
    my ($provider, $data, $descriptors) = @_;
    $data //= {};
    my $hooks = $data->{hooks} // {};
    my @events = map {$_->{event}} @{$catalog{$provider}};
    my %known = map {$_=>1} @events;
    my $unknown_event_count = grep {!$known{$_}} keys %$hooks;
    my @slots = map {_event_fact($provider, $_, $hooks->{$_} // [], $descriptors)} @events;
    my $status_fact = $provider eq 'claude' ? _status_fact($data, $descriptors) : undef;
    my @required = @slots[0 .. $#{$catalog{$provider}}];
    my $ready = !grep {!$_->{owned} || $_->{ambiguous}} @required;
    # A custom object or null statusLine is a valid user selection.
    $ready = 0 if $status_fact && ($status_fact->{state} eq 'missing' || $status_fact->{ambiguous});
    my @summary = (@required, $status_fact ? ($status_fact) : ());
    my $state = 'missing';
    if (grep {$_->{ambiguous}} @summary) { $state = 'ambiguous' }
    elsif (grep {$_->{state} eq 'missing'} @summary) { $state = 'missing' }
    elsif (grep {$_->{state} eq 'custom'} @summary) { $state = 'custom' }
    else {
        my $shell = grep {$_->{shell}} @summary;
        my $native = grep {$_->{native}} @summary;
        $state = $shell && $native ? 'mixed' : $native ? 'native' : 'shell';
    }
    return {provider=>$provider, state=>$state, ready=>$ready ? 1 : 0,
        native_activation=>0, unknown_event_count=>$unknown_event_count,
        slots=>\@slots, status_line=>$status_fact};
}

sub inspect {
    my ($provider, $data, $descriptors) = @_;
    _provider($provider);
    $descriptors = _descriptors($descriptors);
    _validate_settings($provider, $data);
    return _inspect($provider, $data, $descriptors);
}

sub _deduplicate {
    my ($provider, $event, $groups, $descriptors) = @_;
    my (%seen, @groups);
    for my $group (@$groups) {
        my (@hooks, $removed);
        for my $hook (@{$group->{hooks}}) {
            if (_classify($provider, $event, $hook, $descriptors) ne 'custom') {
                my $signature = _signature($group, $hook, 1);
                if ($seen{$signature}++) { $removed = 1; next }
            }
            push @hooks, $hook;
        }
        next if $removed && !@hooks;
        $group->{hooks} = \@hooks if $removed;
        push @groups, $group;
    }
    return \@groups;
}

sub _transform {
    my ($provider, $data, $target, $descriptors, $fixture_descriptor) = @_;
    _validate_settings($provider, $data);
    my $copy = defined($data) ? _copy($data) : {};
    my $before = $json->encode($copy);
    $copy->{hooks} = {} unless exists($copy->{hooks});
    for my $spec (@{$catalog{$provider}}) {
        my $event = $spec->{event};
        my $groups = $copy->{hooks}{$event} //= [];
        my $owned = 0;
        for my $group (@$groups) {
            for my $hook (@{$group->{hooks}}) {
                my $kind = _classify($provider, $event, $hook, $descriptors);
                next if $kind eq 'custom';
                ++$owned;
                my $shell = _shell_command($provider, $event);
                $hook->{command} = $shell
                    if $target eq 'shell' || ($kind eq 'shell' && $hook->{command} ne $shell);
                $hook->{command} = _native_command($provider, $event, $fixture_descriptor)
                    if $target eq 'fixture-native';
            }
        }
        unless ($owned) {
            my $command = $target eq 'fixture-native'
                ? _native_command($provider, $event, $fixture_descriptor)
                : _shell_command($provider, $event);
            my $group = {hooks=>[{type=>'command', command=>$command, timeout=>$spec->{timeout}}]};
            $group->{matcher} = $spec->{matcher} if exists($spec->{matcher});
            push @$groups, $group;
        }
        $copy->{hooks}{$event} = _deduplicate($provider, $event, $groups, $descriptors);
    }
    if ($provider eq 'claude') {
        if (!exists($copy->{statusLine})) {
            my $command = $target eq 'fixture-native'
                ? _native_command($provider, 'statusLine', $fixture_descriptor) : $statusline;
            $copy->{statusLine} = {type=>'command', padding=>0, command=>$command};
        }
        else {
            my $kind = _classify($provider, 'statusLine', $copy->{statusLine}, $descriptors);
            if ($kind ne 'custom') {
                $copy->{statusLine}{command} = $statusline
                    if $target eq 'shell' || ($kind eq 'shell' && $copy->{statusLine}{command} ne $statusline);
                $copy->{statusLine}{command} = _native_command($provider, 'statusLine', $fixture_descriptor)
                    if $target eq 'fixture-native';
            }
        }
    }
    return {data=>$copy, changed=>$before eq $json->encode($copy) ? 0 : 1,
        facts=>_inspect($provider, $copy, $descriptors)};
}

sub transform {
    my ($provider, $data, $target, $descriptors) = @_;
    _provider($provider);
    $target //= 'ensure';
    die "hooks: native registration is unavailable\n" if !ref($target) && $target eq 'native';
    die "hooks: target must be ensure or shell\n"
        unless !ref($target) && ($target eq 'ensure' || $target eq 'shell');
    return _transform($provider, $data, $target, _descriptors($descriptors));
}

# Fixture-only, pure forward transform. No production writer calls this API.
# The target joins the finite descriptor list so post-transform facts recognize it.
sub fixture_native_transform {
    my ($provider, $data, $descriptor, $descriptors) = @_;
    _provider($provider);
    $descriptor = _descriptor($descriptor);
    $descriptors = _descriptors($descriptors);
    push @$descriptors, $descriptor;
    return _transform($provider, $data, 'fixture-native', $descriptors, $descriptor);
}

1;

# Filesystem entrypoints run in the isolated hooks.pl helper used by hooks.sh.
# The Perl API also restores its caller's cwd. All mutations use names relative
# to an opened directory, so a renamed/replaced parent cannot redirect a write.
use Cwd ();
use Errno qw(ENOENT EEXIST ENOTEMPTY EAGAIN EWOULDBLOCK ESRCH);
use Fcntl qw(:DEFAULT :flock :mode O_DIRECTORY O_NOFOLLOW O_NONBLOCK);
use File::Basename ();
use File::Spec ();
use IO::Handle ();
use POSIX ();
use Time::HiRes ();

sub _settings_error {
    my ($c,$code)=@_; $c->{error_code}=$code; die "$code\n";
}
sub _settings_stage {
    my ($c,$stage)=@_;
    return unless $c->{options}{test_hook};
    $c->{error_code}='test_hook_failed';
    $c->{options}{test_hook}->($stage,$c);
    delete $c->{error_code};
}
sub _settings_fail_at {
    my ($c,$stage)=@_;
    _settings_error($c,"${stage}_failed") if ($c->{options}{fail_at}//'') eq $stage;
}
sub _settings_lstat {
    my ($c,$name)=@_; $!=0;
    my @s=Time::HiRes::lstat($name);
    _settings_error($c,'stat_failed') if !@s && $! != ENOENT;
    return \@s;
}
sub _settings_same {
    my ($a,$b)=@_; return !@$a && !@$b if !@$a || !@$b;
    for my $i (0,1,2,3,4,5,7,9,10) { return 0 if $a->[$i] != $b->[$i] }
    return 1;
}
sub _settings_written_same {
    my ($a,$b)=@_; return 0 unless @$a && @$b;
    # rename may change ctime. Identity, permissions, size, mtime and the complete
    # bytes are checked separately after replacement.
    for my $i (0,1,2,3,4,5,7,9) { return 0 if $a->[$i] != $b->[$i] }
    return 1;
}
sub _settings_handle_stat { return [Time::HiRes::stat($_[0])] }
sub _settings_primary_gid { my @user=getpwuid($>); return $user[3] }
sub _settings_safe_dir {
    my ($s)=@_;
    return 0 unless @$s && S_ISDIR($s->[2]) && $s->[4]==$> && !($s->[2]&0002);
    return 1 unless $s->[2]&0020;
    my $primary=_settings_primary_gid();
    return defined($primary) && $s->[5]==$primary;
}
sub _settings_dir_identity {
    my ($a,$b)=@_;
    return _settings_safe_dir($a) && _settings_safe_dir($b)
        && $a->[0]==$b->[0] && $a->[1]==$b->[1]
        && $a->[2]==$b->[2] && $a->[4]==$b->[4] && $a->[5]==$b->[5];
}
sub _settings_open_dir {
    my ($c,$path,$code)=@_;
    my $s=_settings_lstat($c,$path);
    _settings_error($c,$code) unless @$s && S_ISDIR($s->[2]) && $s->[4]==$>;
    _settings_error($c,'unsafe_parent') unless _settings_safe_dir($s);
    sysopen my $h,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_NONBLOCK
        or _settings_error($c,$code);
    my $f=_settings_handle_stat($h);
    _settings_error($c,'unsafe_parent') unless _settings_safe_dir($f);
    _settings_error($c,$code) unless _settings_dir_identity($s,$f);
    return ($h,$f);
}
sub _settings_assert_project {
    my ($c)=@_;
    _settings_error($c,'unsafe_project') if $c->{root} eq '/';
    my @user=getpwuid($>);
    for my $home ($ENV{HOME},$user[7]) {
        next unless defined($home) && length($home) && index($home,"\0")<0;
        my $resolved=Cwd::abs_path(File::Spec->rel2abs($home));
        _settings_error($c,'unsafe_project') if defined($resolved) && $resolved eq $c->{root};
    }
    for my $name (qw(CLAUDE_CONFIG_DIR CODEX_HOME)) {
        my $value=$ENV{$name};
        next unless defined($value) && length($value) && index($value,"\0")<0;
        my $path=File::Spec->canonpath(File::Spec->rel2abs($value));
        my $resolved=Cwd::abs_path($path);
        # Check both the configured location and a symlink's destination. A
        # trailing slash/dot does not turn a global config parent into a project.
        for my $config ($path,defined($resolved) ? ($resolved) : ()) {
            my $parent=Cwd::abs_path(File::Basename::dirname($config));
            _settings_error($c,'unsafe_project') if defined($parent) && $parent eq $c->{root};
        }
    }
}
sub _settings_assert_namespace {
    my ($c,$with_parent)=@_;
    my $resolved=Cwd::abs_path($c->{root_input});
    _settings_error($c,'parent_changed') unless defined($resolved) && $resolved eq $c->{root};
    my $root=_settings_lstat($c,$c->{root});
    _settings_error($c,'parent_changed') unless _settings_dir_identity($c->{root_stat},$root)
        && _settings_dir_identity($root,_settings_handle_stat($c->{root_h}));
    return unless $with_parent;
    my $parent=_settings_lstat($c,"$c->{root}/$c->{parent}");
    _settings_error($c,'parent_changed') unless _settings_dir_identity($c->{parent_stat},$parent)
        && _settings_dir_identity($parent,_settings_handle_stat($c->{parent_h}));
}
sub _settings_create_parent {
    my ($c)=@_;
    _settings_stage($c,'before_parent_create');
    $c->{saved_umask}=umask;
    umask(0077);
    _settings_stage($c,'after_parent_umask');
    # Defer termination until mkdir's new inode and descriptor are recorded.
    # The cleanup path must know ownership even when the first callback dies.
    my $blocked=POSIX::SigSet->new(POSIX::SIGINT(),POSIX::SIGTERM(),POSIX::SIGHUP());
    my $saved=POSIX::SigSet->new;
    defined POSIX::sigprocmask(POSIX::SIG_BLOCK(),$blocked,$saved)
        or _settings_error($c,'signal_mask_failed');
    my ($created,$mkdir_errno);
    my $pinned=eval {
        # EEXIST belongs to the racing creator, never to this cleanup path.
        $created=mkdir($c->{parent},0700); $mkdir_errno=$!;
        if ($created) {
            $c->{created_parent}=1;
            $c->{created_parent_stat}=_settings_lstat($c,$c->{parent});
            ($c->{parent_h},$c->{parent_stat})=_settings_open_dir($c,$c->{parent},'unsafe_parent');
            _settings_error($c,'parent_changed')
                unless _settings_dir_identity($c->{created_parent_stat},$c->{parent_stat});
        }
        1;
    };
    my $exception=$@;
    umask(delete $c->{saved_umask});
    my $restored=POSIX::sigprocmask(POSIX::SIG_SETMASK(),$saved);
    _settings_error($c,'signal_mask_failed') unless defined $restored;
    die $exception unless $pinned;
    _settings_error($c,'parent_create_failed') unless $created || $mkdir_errno==EEXIST;
    _settings_stage($c,'after_parent_create');
    if ($created) {
        $c->{root_h}->sync or _settings_error($c,'parent_sync_failed');
        _settings_assert_namespace($c,1);
    }
    return _settings_lstat($c,$c->{parent});
}
sub _settings_cleanup_parent {
    my ($c)=@_;
    return unless $c->{created_parent} && $c->{created_parent_stat} && $c->{root_h} && $c->{parent_h};
    # An early bootstrap failure may precede our initial flock. Preserve the
    # namespace if another cooperating writer already owns this empty inode.
    # Repeating flock on our existing descriptor retains its lock until close.
    if (!flock($c->{parent_h},LOCK_EX|LOCK_NB)) {
        return if $! == EAGAIN || $! == EWOULDBLOCK;
        return 'cleanup_parent_lock_failed';
    }
    return 'cleanup_parent_chdir_failed' unless chdir($c->{root_h});
    # Test exceptions or repeated termination here cannot skip the identity
    # check. Real cleanup remains relative to the opened project directory,
    # even if its original path or the newly-created child has been replaced.
    eval { _settings_stage($c,'before_parent_cleanup'); 1 };
    return 'cleanup_parent_chdir_failed' unless chdir($c->{root_h});
    $!=0;
    my @now=Time::HiRes::lstat($c->{parent});
    return 'cleanup_parent_stat_failed' if !@now && $! != ENOENT;
    my $created=$c->{created_parent_stat};
    return unless @now && S_ISDIR($now[2]) && $now[0]==$created->[0] && $now[1]==$created->[1];
    # rmdir is the emptiness check; never enumerate then recursively remove.
    # A user/editor's new entry makes this fail harmlessly without being touched.
    return if rmdir($c->{parent}) || $! == ENOTEMPTY || $! == EEXIST || $! == ENOENT;
    return 'cleanup_parent_remove_failed';
}
sub _settings_read {
    my ($c,$name)=@_; my $s=_settings_lstat($c,$name);
    return (undef,$s) unless @$s;
    _settings_error($c,'unsafe_settings') unless S_ISREG($s->[2]) && $s->[4]==$>;
    sysopen my $h,$name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK
        or _settings_error($c,'settings_open_failed');
    _settings_error($c,'conflict') unless _settings_same($s,_settings_handle_stat($h));
    my $raw='';
    while (1) {
        my $n=sysread($h,my $part,65536);
        _settings_error($c,'settings_read_failed') unless defined $n;
        last unless $n; $raw.=$part;
    }
    _settings_error($c,'conflict') unless _settings_same($s,_settings_handle_stat($h))
        && _settings_same($s,_settings_lstat($c,$name));
    close $h or _settings_error($c,'settings_close_failed');
    return ($raw,$s);
}
sub _settings_assert_original {
    my ($c)=@_; my ($raw,$s)=_settings_read($c,$c->{file});
    _settings_error($c,'conflict') unless _settings_same($c->{original_stat},$s)
        && ((!defined($raw) && !defined($c->{original_bytes}))
            || (defined($raw) && defined($c->{original_bytes}) && $raw eq $c->{original_bytes}));
}
sub _settings_check_numbers {
    my ($c,$bytes)=@_;
    my $number_json=JSON::PP->new->utf8->canonical->allow_nonref;
    # The complete document was decoded first. Skip quoted strings (including
    # escaped quotes) so digits in user commands and object keys stay opaque.
    while ($bytes =~ /"(?:[^"\\]|\\.)*"|(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/g) {
        next unless defined($1);
        my $token=$1;
        my $encoded=eval {$number_json->encode($number_json->decode($token))};
        _settings_error($c,'unsupported_number') if $@ || !defined($encoded) || $encoded ne $token;
    }
}
sub _settings_encode {
    return JSON::PP->new->utf8->canonical->indent->indent_length(2)->space_after->encode($_[0]);
}
sub _settings_checked_encoding {
    my ($c,$data)=@_;
    my $bytes=eval {_settings_encode($data)};
    _settings_error($c,'serialization_failed') if $@;
    _settings_error($c,'invalid_serialization') unless defined($bytes) && !ref($bytes);
    my $decoded=eval {JSON::PP->new->utf8->decode($bytes)};
    _settings_error($c,'invalid_serialization') if $@ || ref($decoded) ne 'HASH';
    my $reencoded=eval {_settings_encode($decoded)};
    _settings_error($c,'invalid_serialization') if $@ || !defined($reencoded)
        || ref($reencoded) || $bytes ne $reencoded;
    return $bytes;
}
sub _settings_pid_dead {
    my ($pid)=@_;
    return 0 unless $pid =~ /\A[1-9][0-9]{0,9}\z/ && $pid<=2147483647;
    local $!=0;
    return 0 if kill(0,$pid);
    return $! == ESRCH; # EPERM and other uncertain results retain the file.
}
sub _settings_reap_stat { return [Time::HiRes::lstat($_[0])] }
sub _settings_reap_stale {
    my ($c)=@_;
    # Best effort only under the pinned parent-directory lock. Never adopt a
    # symlink, hardlink, live/unknown PID or another user's similarly named file.
    opendir my $dir,'.' or return;
    my $cutoff=Time::HiRes::time()-600;
    while (defined(my $name=readdir($dir))) {
        next unless $name =~ /\A\.\Q$c->{file}\E\.loomy-([1-9][0-9]*)-[0-9a-f]{24}\z/;
        my $pid=$1;
        my $s=_settings_reap_stat($name);
        next unless @$s && S_ISREG($s->[2]) && $s->[3]==1 && $s->[4]==$>
            && $s->[9]<$cutoff && _settings_pid_dead($pid);
        _settings_stage($c,'before_stale_unlink');
        chdir($c->{parent_h}) or _settings_error($c,'unsafe_parent');
        my $now=_settings_reap_stat($name);
        next unless _settings_same($s,$now) && _settings_pid_dead($pid);
        unlink($name);
    }
    closedir $dir;
}
sub _settings_temp {
    my ($c)=@_; _settings_fail_at($c,'create');
    # O_EXCL is the authority; random names also avoid collisions with leftovers
    # from a killed process without adopting or removing somebody else's file.
    sysopen my $rng,'/dev/urandom',O_RDONLY or _settings_error($c,'temp_create_failed');
    my $random='';
    while (length($random)<12) {
        my $n=sysread($rng,my $part,12-length($random));
        _settings_error($c,'temp_create_failed') unless defined($n) && $n;
        $random.=$part;
    }
    close $rng or _settings_error($c,'temp_create_failed');
    my $name=".$c->{file}.loomy-$$-".unpack('H*',$random);
    sysopen my $h,$name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600
        or _settings_error($c,'temp_create_failed');
    $c->{temp}=$name; $c->{temp_h}=$h;
    $c->{temp_stat}=_settings_handle_stat($h);
    # mkdir/sysopen respect umask. fchmod only the new private inode, never the
    # original or one of its hardlink aliases.
    chmod 0600,$h or _settings_error($c,'temp_create_failed');
    _settings_stage($c,'after_temp_create');
    return $h;
}
sub _settings_replace {
    my ($c)=@_;
    _settings_fail_at($c,'rename');
    # Defer termination across rename + applied bookkeeping. A delivered signal
    # must not turn a successful rename into an "untouched original" result.
    my $blocked=POSIX::SigSet->new(POSIX::SIGINT(),POSIX::SIGTERM(),POSIX::SIGHUP());
    my $saved=POSIX::SigSet->new;
    defined POSIX::sigprocmask(POSIX::SIG_BLOCK(),$blocked,$saved)
        or _settings_error($c,'signal_mask_failed');
    my $ok=rename($c->{temp},$c->{file});
    $c->{applied}=1 if $ok;
    my $restored=POSIX::sigprocmask(POSIX::SIG_SETMASK(),$saved);
    _settings_error($c,'signal_mask_failed') unless defined $restored;
    _settings_error($c,'rename_failed') unless $ok;
}
sub _settings_chown { return chown(-1,$_[1],$_[0]) }
sub _settings_write {
    my ($c,$bytes)=@_; my $h=_settings_temp($c);
    _settings_fail_at($c,'print');
    print {$h} $bytes or _settings_error($c,'print_failed');
    _settings_stage($c,'after_print');
    _settings_fail_at($c,'flush');
    $h->flush or _settings_error($c,'flush_failed');
    _settings_stage($c,'after_flush');
    _settings_fail_at($c,'sync');
    $h->sync or _settings_error($c,'sync_failed');
    _settings_stage($c,'after_sync');
    if (@{$c->{original_stat}}) {
        _settings_fail_at($c,'chown');
        my $gid=$c->{original_stat}[5];
        _settings_chown($h,$gid); # A refused no-op is safe only if fstat proves the gid already matches.
        my $s=_settings_handle_stat($h);
        _settings_error($c,'gid_preservation_failed') unless @$s && $s->[5]==$gid;
        _settings_stage($c,'after_chown');
    }
    # Atomic replacement preserves mode and gid, but the new inode does not
    # preserve ACLs or extended attributes from the original settings file.
    _settings_fail_at($c,'chmod');
    my $mode=@{$c->{original_stat}} ? $c->{original_stat}[2]&07777 : 0644;
    chmod $mode,$h or _settings_error($c,'chmod_failed');
    _settings_stage($c,'after_chmod');
    # Persist the chmod as well as the data before replacing the original.
    $h->sync or _settings_error($c,'sync_failed');
    $c->{written_stat}=_settings_handle_stat($h);
    _settings_error($c,'chmod_failed') unless @{$c->{written_stat}}
        && ($c->{written_stat}[2]&07777)==$mode;
    _settings_error($c,'gid_preservation_failed') if @{$c->{original_stat}}
        && $c->{written_stat}[5]!=$c->{original_stat}[5];
    _settings_fail_at($c,'close');
    close $h or _settings_error($c,'close_failed');
    delete $c->{temp_h};
    _settings_stage($c,'after_close');
    _settings_error($c,'conflict') unless _settings_same($c->{written_stat},_settings_lstat($c,$c->{temp}));
    _settings_assert_namespace($c,1);
    _settings_assert_original($c);
    # This seam deliberately runs AFTER the final pre-rename namespace check:
    # tests replace the directory here to prove the rename stays descriptor-relative.
    _settings_stage($c,'before_rename');
    _settings_replace($c);
    _settings_stage($c,'after_rename');
    _settings_fail_at($c,'directory_sync');
    $c->{parent_h}->sync or _settings_error($c,'directory_sync_failed');
    _settings_stage($c,'after_directory_sync');
    _settings_stage($c,'before_namespace_check');
    _settings_assert_namespace($c,1);
    my ($written,$s)=_settings_read($c,$c->{file});
    _settings_error($c,'conflict') unless _settings_written_same($c->{written_stat},$s)
        && defined($written) && $written eq $bytes;
}
sub _settings_run {
    my ($root,$provider,$target,$options,$repair)=@_; $options//={};
    my $c={provider=>$provider,options=>$options,applied=>0};
    return {ok=>0,code=>'invalid_options',applied=>0,changed=>0}
        unless ref($options) eq 'HASH'
        && (!exists($options->{test_hook}) || ref($options->{test_hook}) eq 'CODE');
    return {ok=>0,code=>'invalid_provider',applied=>0,changed=>0}
        unless defined($provider) && ($provider eq 'claude' || $provider eq 'codex');
    return {ok=>0,code=>'native_unavailable',applied=>0,changed=>0}
        if $repair && defined($target) && $target eq 'native';
    return {ok=>0,code=>'invalid_target',applied=>0,changed=>0}
        if $repair && (!defined($target) || ($target ne 'ensure' && $target ne 'shell'));
    $c->{parent}=$provider eq 'claude' ? '.claude' : '.codex';
    $c->{file}=$provider eq 'claude' ? 'settings.json' : 'hooks.json';
    my ($cwd,$result);
    my $interrupted=sub {
        $c->{interrupted}=1; $c->{error_code}='interrupted';
        die "interrupted\n" if $c->{in_body};
    };
    local $SIG{INT}=$interrupted;
    local $SIG{TERM}=$interrupted;
    local $SIG{HUP}=$interrupted;
    my $ok=eval {
        # local unwinds before eval returns on success or exception. Repeated
        # termination during cleanup records failure without skipping cleanup.
        local $c->{in_body}=1;
        _settings_error($c,'interrupted') if $c->{interrupted};
        sysopen $cwd,'.',O_RDONLY|O_DIRECTORY|O_NOFOLLOW or _settings_error($c,'cwd_unavailable');
        _settings_error($c,'unsafe_project') unless defined($root) && !ref($root) && length($root) && index($root,"\0")<0;
        $c->{root_input}=File::Spec->rel2abs($root);
        $c->{root}=Cwd::abs_path($c->{root_input})//_settings_error($c,'unsafe_project');
        _settings_assert_project($c);
        ($c->{root_h},$c->{root_stat})=_settings_open_dir($c,$c->{root},'unsafe_project');
        chdir $c->{root_h} or _settings_error($c,'unsafe_project');
        _settings_assert_namespace($c,0);
        my $parent=_settings_lstat($c,$c->{parent});
        if (!@$parent && $repair) {
            # Only a direct child of the pinned project is ever bootstrapped.
            $parent=_settings_create_parent($c);
        }
        if (!@$parent) {
            _settings_assert_namespace($c,0);
            _settings_error($c,'parent_changed') if @{_settings_lstat($c,$c->{parent})};
            $result={ok=>1,code=>'missing',applied=>0,changed=>0,exists=>0,
                facts=>inspect($provider,undef,production_descriptors())};
        } else {
            ($c->{parent_h},$c->{parent_stat})=_settings_open_dir($c,$c->{parent},'unsafe_parent')
                unless $c->{parent_h};
            if ($repair) {
                # A different local user can hold this readable directory's
                # flock and force busy. This only denies repair; it never
                # produces a false ready result. Retry after the lock releases.
                flock($c->{parent_h},LOCK_EX|LOCK_NB) or _settings_error($c,
                    ($! == EAGAIN || $! == EWOULDBLOCK) ? 'busy' : 'directory_lock_failed');
            }
            chdir $c->{parent_h} or _settings_error($c,'unsafe_parent');
            _settings_assert_namespace($c,1);
            _settings_stage($c,'after_parent_lock') if $repair;
            _settings_reap_stale($c) if $repair;
            ($c->{original_bytes},$c->{original_stat})=_settings_read($c,$c->{file});
            _settings_stage($c,'after_read');
            my $data;
            if (defined($c->{original_bytes})) {
                $data=eval {JSON::PP->new->utf8->decode($c->{original_bytes})};
                _settings_error($c,'invalid_settings') if $@ || ref($data) ne 'HASH';
                _settings_check_numbers($c,$c->{original_bytes});
            }
            my $facts=eval {inspect($provider,$data,production_descriptors())};
            _settings_error($c,'invalid_settings') if $@;
            if ($repair) {
                my $transformed=eval {transform($provider,$data,$target,production_descriptors())};
                _settings_error($c,'invalid_settings') if $@;
                if ($transformed->{changed}) {
                    my $bytes=_settings_checked_encoding($c,$transformed->{data});
                    _settings_write($c,$bytes);
                } else {
                    _settings_assert_namespace($c,1);
                    _settings_assert_original($c);
                }
                $facts=$transformed->{facts};
            } else {
                _settings_assert_namespace($c,1);
                _settings_assert_original($c);
            }
            $result={ok=>1,code=>$c->{applied} ? 'updated' : defined($c->{original_bytes}) ? 'unchanged' : 'missing',
                applied=>$c->{applied},changed=>$c->{applied},exists=>($c->{applied} || defined($c->{original_bytes})) ? 1 : 0,facts=>$facts};
        }
        1;
    };
    my $error=$c->{error_code}//'operation_failed';
    umask(delete $c->{saved_umask}) if exists($c->{saved_umask});
    # Cleanup remains in the pinned parent even if its path was moved. Never
    # unlink a replacement temporary that no longer has our inode identity.
    if ($c->{temp_h}) {
        close $c->{temp_h} or $error='cleanup_close_failed';
        delete $c->{temp_h};
    }
    if ($c->{temp} && !$c->{applied}) {
        if (!$c->{parent_h} || !chdir($c->{parent_h})) {
            $error='cleanup_parent_chdir_failed';
        } else {
            my @now=Time::HiRes::lstat($c->{temp});
            if (@now && $c->{temp_stat} && $now[0]==$c->{temp_stat}[0] && $now[1]==$c->{temp_stat}[1]) {
                unlink($c->{temp}) or $error='cleanup_unlink_failed';
            }
        }
    }
    if (!$ok || $c->{interrupted}) {
        my $cleanup_error=_settings_cleanup_parent($c);
        $error=$cleanup_error if defined($cleanup_error);
    }
    if ($cwd) {
        if (!chdir($cwd)) { $ok=0; $error='cwd_restore_failed' }
        close $cwd or do {$ok=0; $error='cwd_close_failed'};
    }
    for my $key (qw(parent_h root_h)) {
        next unless $c->{$key};
        close $c->{$key} or do {$ok=0; $error='directory_close_failed'};
    }
    if ($c->{interrupted}) { $ok=0; $error='interrupted' }
    return $result if $ok;
    my $failed={ok=>0,provider=>$provider,code=>$c->{applied} ? 'applied_unconfirmed' : $error,
        error_code=>$error,applied=>$c->{applied},changed=>$c->{applied}};
    $failed->{facts}={provider=>$provider,state=>'invalid',ready=>0,native_activation=>0,slots=>[]}
        if $error eq 'invalid_settings';
    return $failed;
}
sub settings_inspect { my ($root,$provider,$options)=@_; return _settings_run($root,$provider,undef,$options,0) }
sub settings_update { my ($root,$provider,$target,$options)=@_; $target//='ensure'; return _settings_run($root,$provider,$target,$options,1) }

# JSON-only interface for H2 consumers; no provider launches, upkeep or prompts.
# Native descriptor provisioning is deliberately an installation resource API,
# never a command-line/env setting. Tests call the pure fixture API directly.
sub main {
    my (@args)=@_; my ($action,$root,$provider,$flag)=@args;
    my $valid=@args>=3 && @args<=4 && defined($action) && defined($provider)
        && ($action eq 'inspect' || $action eq 'repair')
        && (!defined($flag) || ($action eq 'repair' && $flag eq '--shell'));
    my $r=$valid ? ($action eq 'inspect' ? settings_inspect($root,$provider)
        : settings_update($root,$provider,defined($flag) ? 'shell' : 'ensure'))
        : {ok=>0,code=>'invalid_arguments',applied=>0,changed=>0};
    print STDOUT JSON::PP->new->utf8->canonical->encode($r),"\n" or return 1;
    return $r->{ok} ? 0 : 1;
}

unless (caller) { exit main(@ARGV) }
1;
