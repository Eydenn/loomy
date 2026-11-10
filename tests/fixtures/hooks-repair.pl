#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use File::Path qw(make_path);
use File::Find ();
use Fcntl qw(O_RDONLY LOCK_EX LOCK_NB);
use IO::Handle ();
use POSIX ();
use Time::HiRes qw(time);
use Errno qw(EPERM);

my ($repo, $work, $mode) = @ARGV;
die "usage: hooks-repair.pl REPO WORK [--flock-probe]\n"
    unless defined($repo) && defined($work) && -d $work && ($mode // '') =~ /\A(?:|--flock-probe)\z/;
my $json = JSON::PP->new->utf8->canonical;
my $owner = $$;
my %children;
END {
    if ($$ == $owner) {
        for my $pid (keys %children) { kill 'TERM', $pid }
        for my $pid (keys %children) { waitpid($pid, 0) }
    }
}

sub put {
    my ($path, $data, $permissions) = @_;
    open my $fh, '>', $path or die "fixture open: $!";
    binmode $fh;
    print {$fh} $data or die "fixture print: $!";
    close $fh or die "fixture close: $!";
    chmod(defined($permissions) ? $permissions : 0640, $path) or die "fixture chmod: $!";
}
sub bytes {
    my ($path) = @_;
    open my $fh, '<', $path or die "fixture read: $!";
    binmode $fh;
    local $/;
    my $data = <$fh>;
    close $fh or die "fixture close: $!";
    return $data;
}
sub clone { return decode_json($json->encode($_[0])) }
sub root {
    my ($name) = @_;
    my $path = "$work/$name";
    make_path($path, {mode => 0700});
    return $path;
}
sub settings_path { return "$_[0]/" . ($_[1] eq 'claude' ? '.claude/settings.json' : '.codex/hooks.json') }
sub parent_path { return "$_[0]/" . ($_[1] eq 'claude' ? '.claude' : '.codex') }
sub seed {
    my ($r, $provider, $data, $permissions) = @_;
    make_path(parent_path($r, $provider), {mode => 0750});
    put(settings_path($r, $provider), ref($data) ? $json->encode($data) : $data, $permissions);
    return settings_path($r, $provider);
}
sub identity {
    my ($path) = @_;
    my @st = lstat($path);
    return @st ? [@st[0, 1], $st[2] & 07777, @st[3, 4, 5]] : undef;
}
sub parent_identity {
    my $id = identity($_[0]);
    # APFS directory link counts change when our temporary is removed.
    return $id ? [@$id[0, 1, 2, 4, 5]] : undef;
}
sub temps {
    my ($dir) = @_;
    opendir my $dh, $dir or die "fixture readdir: $!";
    my @names = sort grep { /loomy/ } readdir $dh;
    closedir $dh;
    return \@names;
}
sub manifest {
    my ($r) = @_;
    my %files;
    File::Find::find({no_chdir => 1, wanted => sub {
        my $p = $File::Find::name;
        $files{substr($p, length($r))} = [identity($p), -l $p ? readlink($p) : -f $p ? bytes($p) : undef];
    }}, $r);
    return \%files;
}
sub fork_child {
    my ($body) = @_;
    my $pid = fork();
    die "fixture fork: $!" unless defined $pid;
    if (!$pid) {
        my $ok = eval { $body->(); 1 };
        print STDERR "fixture child: $@" unless $ok;
        POSIX::_exit($ok ? 0 : 1);
    }
    $children{$pid} = 1;
    return $pid;
}
sub reap {
    my ($pid, $label) = @_;
    my $waited = waitpid($pid, 0);
    my $status = $?;
    delete $children{$pid};
    is($waited, $pid, "$label was reaped");
    is($status, 0, "$label completed");
}
sub receive {
    my ($fh) = @_;
    local $SIG{ALRM} = sub { die "fixture child barrier timed out\n" };
    alarm 10;
    my $n = sysread($fh, my $value, 1);
    alarm 0;
    die "fixture child barrier closed\n" unless defined($n) && $n == 1;
    return $value;
}

# This independent probe must fail when directory flock is unsupported. It is a
# release gate, so a venue must never replace it with an unconditional skip.
sub flock_probe {
    my $r = root('flock-probe');
    sysopen my $lock, $r, O_RDONLY or die "directory open: $!";
    ok(flock($lock, LOCK_EX | LOCK_NB), 'directory accepts an exclusive nonblocking flock') or return;
    put("$r/settings.json", '{}');
    put("$r/replacement", '{"changed":true}');
    rename("$r/replacement", "$r/settings.json") or die "fixture rename: $!";
    ok($lock->sync, 'pinned directory supports sync after settings rename');
    for my $held (1, 0) {
        close $lock or die "fixture unlock: $!" unless $held;
        pipe(my $read, my $write) or die "fixture pipe: $!";
        my $pid = fork_child(sub {
            close $read;
            close $lock if $held;
            sysopen my $other, $r, O_RDONLY or die "contender directory open: $!";
            my $got = flock($other, LOCK_EX | LOCK_NB);
            syswrite($write, $got ? 'A' : 'B') == 1 or die "fixture write: $!";
            close $other;
            close $write;
        });
        close $write;
        is(receive($read), $held ? 'B' : 'A', $held
            ? 'renaming settings retains the parent-directory lock against a second process'
            : 'closing the holder releases the directory lock to a second process');
        close $read;
        reap($pid, 'directory flock contender');
    }
}

if (($mode // '') eq '--flock-probe') {
    flock_probe();
    done_testing();
    exit;
}

require "$repo/scripts/lib/hooks.pl";

sub metadata_key { return @{$_[0]} ? join(':', @{$_[0]}[0, 1]) : '' }
sub with_settings_stats {
    my ($adjust, $body) = @_;
    my $lstat = \&Loomy::Hooks::_settings_lstat;
    my $fstat = \&Loomy::Hooks::_settings_handle_stat;
    no warnings 'redefine';
    local *Loomy::Hooks::_settings_lstat = sub {
        my $s = [@{$lstat->(@_)}];
        $adjust->($s);
        return $s;
    };
    local *Loomy::Hooks::_settings_handle_stat = sub {
        my $s = [@{$fstat->(@_)}];
        $adjust->($s);
        return $s;
    };
    return $body->();
}
sub with_reaper_stats {
    my ($adjust, $body) = @_;
    my $stat = \&Loomy::Hooks::_settings_reap_stat;
    no warnings 'redefine';
    local *Loomy::Hooks::_settings_reap_stat = sub {
        my $s = [@{$stat->(@_)}];
        $adjust->($s);
        return $s;
    };
    return $body->();
}
sub entry_snapshot {
    my ($path) = @_;
    return [identity($path), -l $path ? readlink($path) : -f $path ? bytes($path) : undef];
}
sub stale_name {
    my ($provider, $pid, $hex) = @_;
    my $file = $provider eq 'claude' ? 'settings.json' : 'hooks.json';
    return ".$file.loomy-$pid-" . ($hex x 24);
}
sub age_file {
    my ($path, $seconds) = @_;
    my $stamp = time - $seconds;
    utime($stamp, $stamp, $path) == 1 or die "fixture utime: $!";
}

# Ownership bytes come from the documented generated templates, independently
# of the engine's serializer/catalog. Historical ownership is the finite set of
# decoded commands below, not a filename substitution rule.
my @claude = (
    ['SessionStart', 'start', 20], ['SessionEnd', 'end', 3],
    ['Stop', 'stop', 10], ['SubagentStop', 'subagent', 10],
    ['UserPromptSubmit', 'prompt', 5], ['PreToolUse', 'agent-start', 5, 'Agent|Task'],
    ['PostToolUse', 'agent-return', 5, 'Agent|Task'], ['PostToolUseFailure', 'agent-failure', 5, 'Agent|Task'],
);
my @codex = (['SessionStart', 'start', 20], ['SessionEnd', 'end', 3]);
my $status_command = q{sh -c 'd=${CLAUDE_PROJECT_DIR:-$PWD}; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-statusline.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-statusline.sh" ] && exec bash "$d/.loomy/scripts/loomy-statusline.sh"'};
# Known installer history: 6af0aa8 start/end; 47c2159 Codex; 40eb004 stop
# and subagent; bfae49d prompt; 6c1f519 statusLine. 49e0d92 renamed these
# generated filenames. No historical agent-* or alternate statusLine form exists.
my %historical = (
    claude => {
        SessionStart => q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook start},
        SessionEnd => q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook end},
        Stop => q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook stop},
        SubagentStop => q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook subagent},
        UserPromptSubmit => q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook prompt},
        statusLine => q{sh -c 'd=${CLAUDE_PROJECT_DIR:-$PWD}; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/ai-statusline.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/ai-statusline.sh" ] && exec bash "$d/.loomy/scripts/ai-statusline.sh"'},
    },
    codex => {
        SessionStart => q{sh -c 'd=$PWD; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/ai-context.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/ai-context.sh" ] && exec bash "$d/.loomy/scripts/ai-context.sh" --hook start --tool codex'},
        SessionEnd => q{sh -c 'd=$PWD; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/ai-context.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/ai-context.sh" ] && exec bash "$d/.loomy/scripts/ai-context.sh" --hook end --tool codex'},
    },
);
my $descriptor = {executable => '/opt/loomy/0.17.8/bin/loomy', version => '0.17.8', resource_version => '0.17.8'};
my $retained = {executable => '/opt/loomy/0.17.9/bin/loomy', version => '0.17.9', resource_version => '0.17.9'};
my @descriptors = ($descriptor, $retained);
sub specs { return $_[0] eq 'claude' ? \@claude : \@codex }
sub shell_command {
    my ($provider, $spec) = @_;
    return q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/loomy-context.sh" --hook } . $spec->[1] if $provider eq 'claude';
    return q{sh -c 'd=$PWD; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-context.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-context.sh" ] && exec bash "$d/.loomy/scripts/loomy-context.sh" --hook } . $spec->[1] . q{ --tool codex'};
}
sub shell_data {
    my ($provider) = @_;
    my $data = {hooks => {}};
    for my $spec (@{specs($provider)}) {
        my $group = {hooks => [{type => 'command', command => shell_command($provider, $spec), timeout => $spec->[2]}]};
        $group->{matcher} = $spec->[3] if defined $spec->[3];
        $data->{hooks}{$spec->[0]} = [$group];
    }
    $data->{statusLine} = {type => 'command', padding => 0, command => $status_command} if $provider eq 'claude';
    return $data;
}
sub unrelated_events {
    my ($provider) = @_;
    my $events = {
        Notification => [{matcher => 'x', private => "PRIVATE_CUSTOM_SENTINEL\0\n日本語", values => [undef, JSON::PP::true, 7]}],
        FutureString => "PRIVATE_CUSTOM_SENTINEL\nstring",
        FutureNull => undef,
        FutureBoolean => JSON::PP::false,
        FutureNumber => 12,
        FutureMalformedGroups => [undef, 'scalar', {hooks => 'not-a-hook-array', extra => {keep => 1}}],
    };
    $events->{Stop} = [{matcher => 'Claude-only event without hooks'}] if $provider eq 'codex';
    return $events;
}
sub slot {
    my ($facts, $event) = @_;
    return $facts->{status_line} if $event eq 'statusLine';
    return (grep { $_->{event} eq $event } @{$facts->{slots}})[0];
}
sub repaired { return Loomy::Hooks::transform($_[0], $_[1], $_[2] // 'ensure', \@descriptors) }

subtest 'H01 exact typed catalog and finite native descriptors' => sub {
    is_deeply(Loomy::Hooks::production_descriptors(), [], 'production native descriptors are empty');
    for my $provider (qw(claude codex)) {
        my @catalog = map { my %v = (event => $_->[0], mode => $_->[1], timeout => $_->[2]); $v{matcher} = $_->[3] if defined $_->[3]; \%v } @{specs($provider)};
        is_deeply(Loomy::Hooks::catalog($provider), \@catalog, "$provider finite event/mode/deadline/matcher catalog");
        my $copy = Loomy::Hooks::catalog($provider);
        $copy->[0]{mode} = 'mutated';
        is_deeply(Loomy::Hooks::catalog($provider), \@catalog, "$provider catalog cannot be mutated by its caller");
        for my $spec (@{specs($provider)}) {
            my ($event, $mode) = @$spec;
            my $hook = {type => 'command', command => shell_command($provider, $spec)};
            is(Loomy::Hooks::classify_command($provider, $event, $hook), 'shell', "$provider/$event exact legacy binding is owned");
            my $native = '"' . $descriptor->{executable} . '" __hook --tool ' . $provider . ' --mode ' . $mode;
            is(Loomy::Hooks::native_command($provider, $event, $descriptor), $native, "$provider/$event fixed native argument order");
            is(Loomy::Hooks::classify_command($provider, $event, {type => 'command', command => $native}, \@descriptors), 'native', "$provider/$event finite trusted native binding is owned");
            is(Loomy::Hooks::classify_command($provider, $event, {type => 'command', command => $native}), 'custom', "$provider/$event native binding is untrusted without descriptors");
            for my $wrong (
                {type => 'prompt', command => $hook->{command}},
                {command => $hook->{command}},
                {type => 'command', command => ' ' . $hook->{command}},
                {type => 'command', command => $hook->{command} . ' --extra'},
                {type => 'command', command => $native . ' --extra'},
                {type => 'command', command => 'sh -c ' . $native},
                {type => 'command', command => $native =~ s/0\.17\.8/unknown/r},
            ) {
                is(Loomy::Hooks::classify_command($provider, $event, $wrong, \@descriptors), 'custom', "$provider/$event wrong type or near-match stays custom");
            }
            is(Loomy::Hooks::classify_command($provider, 'UnknownEvent', $hook, \@descriptors), 'custom', "$provider/$event correct bytes in wrong event stay custom");
            is(Loomy::Hooks::classify_command($provider eq 'claude' ? 'codex' : 'claude', $event, $hook, \@descriptors), 'custom', "$provider/$event correct bytes in wrong provider stay custom");
        }
        my $missing = Loomy::Hooks::inspect($provider, undef);
        is($missing->{state}, 'missing', "$provider absent document is inspectable");
        ok(!$missing->{ready} && !$missing->{native_activation}, "$provider missing/native activation readiness is false");
        my $fresh = Loomy::Hooks::transform($provider, {});
        ok($fresh->{changed}, "$provider first ensure installs shell bindings");
        is_deeply($fresh->{data}, shell_data($provider), "$provider defaults equal the independent generated-template fixture");
        is($fresh->{facts}{state}, 'shell', "$provider default facts are shell");
        ok($fresh->{facts}{ready}, "$provider all expected slots are ready");
        ok(!Loomy::Hooks::transform($provider, $fresh->{data})->{changed}, "$provider second ensure is semantically unchanged");
    }
    is(scalar(map { keys %{$historical{$_}} } keys %historical), 8, 'historical fixture contains only the eight observed generated commands');
    for my $provider (qw(claude codex)) {
        for my $event (sort keys %{$historical{$provider}}) {
            my $command = $historical{$provider}{$event};
            is(Loomy::Hooks::classify_command($provider, $event, {type => 'command', command => $command}), 'shell', "$provider/$event exact historical generated command is owned");
            for my $wrong (
                {type => 'prompt', command => $command},
                {type => 'command', command => " $command"},
                {type => 'command', command => "$command --extra"},
            ) {
                is(Loomy::Hooks::classify_command($provider, $event, $wrong), 'custom', "$provider/$event historical wrong type or near-match stays custom");
            }
            is(Loomy::Hooks::classify_command($provider, 'UnknownEvent', {type => 'command', command => $command}), 'custom', "$provider/$event historical bytes in the wrong event stay custom");
            is(Loomy::Hooks::classify_command($provider eq 'claude' ? 'codex' : 'claude', $event, {type => 'command', command => $command}), 'custom', "$provider/$event historical bytes in the wrong provider stay custom");
            if ($provider eq 'codex' || $event eq 'statusLine') {
                my $mixed_names = $command =~ s/ai-(context|statusline)\.sh/loomy-$1.sh/r;
                is(Loomy::Hooks::classify_command($provider, $event, {type => 'command', command => $mixed_names}), 'custom', "$provider/$event mixed historical and current walk paths stay custom");
            }
        }
    }
    for my $spec (grep { $_->[1] =~ /\Aagent-/ } @claude) {
        my $unowned = q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-context.sh" --hook } . $spec->[1];
        is(Loomy::Hooks::classify_command('claude', $spec->[0], {type => 'command', command => $unowned}), 'custom', "Claude/$spec->[0] ungenerated historical filename substitution stays custom");
    }
    my $unknown_status = $status_command =~ s/loomy-statusline\.sh/ai-status.sh/gr;
    is(Loomy::Hooks::classify_command('claude', 'statusLine', {type => 'command', command => $unknown_status}), 'custom', 'ungenerated historical statusLine filename stays custom');
    is(Loomy::Hooks::classify_command('claude', 'statusLine', {type => 'command', command => q{bash "${CLAUDE_PROJECT_DIR}/.loomy/scripts/ai-statusline.sh"}}), 'custom', 'ungenerated direct historical statusLine stays custom');
    is(Loomy::Hooks::classify_command('codex', 'SessionStart', {type => 'command', command => $historical{claude}{SessionStart}}), 'custom', 'ungenerated direct historical Codex hook stays custom');
    is(Loomy::Hooks::classify_command('claude', 'statusLine', {type => 'command', command => $status_command}), 'shell', 'owned statusLine is separate from the ten hooks');
    is(Loomy::Hooks::native_command('claude', 'statusLine', $descriptor), '"/opt/loomy/0.17.8/bin/loomy" __statusline', 'native statusLine has the frozen direct form');
    my $unicode = {%$descriptor, executable => '/opt/Loomy 日本語/bin/loomy'};
    is(Loomy::Hooks::native_command('claude', 'statusLine', $unicode), '"/opt/Loomy 日本語/bin/loomy" __statusline', 'safe spaces and Unicode executable path serialize exactly');
    for my $bad ('relative/loomy', '/opt/../loomy', '/opt/./loomy', '/opt//loomy', '/opt/loomy/', '/opt/loomy"', '/opt/$loomy', "/opt/loomy\n", '/opt/loomy;touch', '/opt/loomy`id`') {
        ok(!eval { Loomy::Hooks::native_command('claude', 'statusLine', {%$descriptor, executable => $bad}); 1 }, 'unsafe native executable descriptor is refused');
    }
    ok(!eval { Loomy::Hooks::native_command('claude', 'statusLine', {%$descriptor, resource_version => '0.17.9'}); 1 }, 'descriptor/resource version mismatch is refused');
};

subtest 'H02 ensure, inverse, customization and exact duplicate semantics' => sub {
    for my $provider (qw(claude codex)) {
        my $original = shell_data($provider);
        $original->{customRoot} = {permissions => ['fixture:allow'], private => 'PRIVATE_CUSTOM_SENTINEL'};
        my $event = 'SessionStart';
        my $owned = $original->{hooks}{$event}[0];
        $owned->{matcher} = 'CustomizedMatcher';
        $owned->{groupExtra} = {keep => [1, 2]};
        $owned->{hooks}[0]{timeout} = 47;
        $owned->{hooks}[0]{hookExtra} = 'keep';
        push @{$owned->{hooks}}, {type => 'command', command => 'printf PRIVATE_CUSTOM_SENTINEL', timeout => 6};
        $original->{hooks}{UnknownEvent} = [{hooks => [{type => 'custom-kind', command => 'unknown-event'}], extra => 1}];
        $original->{statusLine} = {type => 'command', command => 'printf PRIVATE_CUSTOM_SENTINEL', padding => 9, extra => {keep => 1}} if $provider eq 'claude';
        my $before = clone($original);
        my $ensure = repaired($provider, $original);
        ok(!$ensure->{changed}, "$provider ensure preserves customized owned binding without adding defaults");
        is_deeply($ensure->{data}, $before, "$provider custom siblings, matchers, deadlines, permission data and fields survive ensure");
        is_deeply($original, $before, "$provider transform never mutates its input");
        unlike($json->encode($ensure->{facts}), qr/PRIVATE_CUSTOM_SENTINEL/, "$provider typed facts do not disclose raw custom commands or data");
        my $native = Loomy::Hooks::fixture_native_transform($provider, $original, $descriptor, \@descriptors);
        my $expected = clone($original);
        for my $spec (@{specs($provider)}) {
            $expected->{hooks}{$spec->[0]}[0]{hooks}[0]{command} = Loomy::Hooks::native_command($provider, $spec->[0], $descriptor);
        }
        is_deeply($native->{data}, $expected, "$provider fixture transform changes only owned command fields");
        is_deeply(repaired($provider, $native->{data}, 'shell')->{data}, $before, "$provider inverse shell transform retains every custom value");
        my $mixed = shell_data($provider);
        my $n = clone($mixed->{hooks}{$event}[0]);
        $n->{hooks}[0]{command} = Loomy::Hooks::native_command($provider, $event, $descriptor);
        push @{$mixed->{hooks}{$event}}, $n;
        my $mixed_ensure = repaired($provider, $mixed);
        ok(!$mixed_ensure->{changed}, "$provider normal ensure keeps known shell/native mixture");
        is(slot($mixed_ensure->{facts}, $event)->{state}, 'mixed', "$provider mixed slot is reported");
        my $coalesced = repaired($provider, $mixed, 'shell');
        is_deeply($coalesced->{data}, shell_data($provider), "$provider equivalent shell/native groups coalesce only after inverse conversion");
        my $dupe = shell_data($provider);
        push @{$dupe->{hooks}{$event}}, clone($dupe->{hooks}{$event}[0]);
        is_deeply(repaired($provider, $dupe)->{data}, shell_data($provider), "$provider exact duplicate group coalesces");
        $dupe = shell_data($provider);
        push @{$dupe->{hooks}{$event}[0]{hooks}}, clone($dupe->{hooks}{$event}[0]{hooks}[0]);
        is_deeply(repaired($provider, $dupe)->{data}, shell_data($provider), "$provider exact duplicate hook within a group coalesces");
        for my $field (qw(timeout matcher extra)) {
            my $different = shell_data($provider);
            my $duplicate = clone($different->{hooks}{$event}[0]);
            if ($field eq 'timeout') { $duplicate->{hooks}[0]{timeout} = 99 }
            elsif ($field eq 'matcher') { $duplicate->{matcher} = 'AnotherMatcher' }
            else { $duplicate->{extra} = {keep => 1} }
            push @{$different->{hooks}{$event}}, $duplicate;
            my $out = repaired($provider, $different, 'shell');
            is_deeply($out->{data}, $different, "$provider differing $field survives inverse repair");
            ok(slot($out->{facts}, $event)->{ambiguous}, "$provider differing $field reports ambiguity");
        }
        my $siblings = shell_data($provider);
        my $group = clone($siblings->{hooks}{$event}[0]);
        push @{$group->{hooks}}, {type => 'command', command => 'printf sibling'};
        push @{$siblings->{hooks}{$event}}, $group;
        my $preserved = repaired($provider, $siblings);
        my @custom = map { grep { ($_->{command} // '') eq 'printf sibling' } @{$_->{hooks}} } @{$preserved->{data}{hooks}{$event}};
        is(scalar(@custom), 1, "$provider duplicate handling retains custom siblings");
        my $wrong = shell_data($provider);
        $wrong->{hooks}{$event}[0]{hooks}[0]{type} = 'prompt';
        my $fixed = repaired($provider, $wrong);
        is_deeply($fixed->{data}{hooks}{$event}[0], $wrong->{hooks}{$event}[0], "$provider wrong-type exact command is preserved as custom");
        is(slot($fixed->{facts}, $event)->{owned}, 1, "$provider missing owned slot is filled beside wrong-type custom");
    }
    for my $provider (qw(claude codex)) {
        my $historical_data = shell_data($provider);
        my $expected = clone($historical_data);
        for my $spec (@{specs($provider)}) {
            next unless exists($historical{$provider}{$spec->[0]});
            $historical_data->{hooks}{$spec->[0]}[0]{hooks}[0]{command} = $historical{$provider}{$spec->[0]};
        }
        if ($provider eq 'claude') {
            $historical_data->{statusLine}{command} = $historical{claude}{statusLine};
            # 6af0aa8 generated SessionEnd with timeout 5; only its command may change.
            $historical_data->{hooks}{SessionEnd}[0]{hooks}[0]{timeout} = 5;
            $expected->{hooks}{SessionEnd}[0]{hooks}[0]{timeout} = 5;
            $historical_data->{statusLine}{padding} = $expected->{statusLine}{padding} = 9;
            $historical_data->{statusLine}{extra} = $expected->{statusLine}{extra} = {keep => 1};
        }
        my $before = clone($historical_data);
        for my $target (qw(ensure shell)) {
            my $out = repaired($provider, $historical_data, $target);
            ok($out->{changed}, "$provider $target repairs historical generated commands");
            is_deeply($out->{data}, $expected, "$provider $target changes only historical owned commands to current shell forms");
            ok(!repaired($provider, $out->{data}, $target)->{changed}, "$provider historical $target repair is idempotent");
            for my $spec (@{specs($provider)}) {
                is(slot($out->{facts}, $spec->[0])->{owned}, 1, "$provider/$spec->[0] historical $target repair has one owned hook");
            }
        }
        is_deeply($historical_data, $before, "$provider historical repair never mutates its input");
        my $duplicates = shell_data($provider);
        for my $spec (@{specs($provider)}) {
            next unless exists($historical{$provider}{$spec->[0]});
            my $old_group = clone($duplicates->{hooks}{$spec->[0]}[0]);
            $old_group->{hooks}[0]{command} = $historical{$provider}{$spec->[0]};
            unshift @{$duplicates->{hooks}{$spec->[0]}}, $old_group;
            push @{$duplicates->{hooks}{$spec->[0]}[0]{hooks}}, clone($duplicates->{hooks}{$spec->[0]}[1]{hooks}[0]);
        }
        $duplicates->{statusLine}{command} = $historical{claude}{statusLine} if $provider eq 'claude';
        for my $target (qw(ensure shell)) {
            is_deeply(repaired($provider, $duplicates, $target)->{data}, shell_data($provider), "$provider historical/current duplicate hooks coalesce after $target conversion");
        }
        my $unrelated = shell_data($provider);
        my $unknown = unrelated_events($provider);
        @{$unrelated->{hooks}}{keys %$unknown} = values %$unknown;
        my $unrelated_before = clone($unrelated);
        my $facts = Loomy::Hooks::inspect($provider, $unrelated);
        is($facts->{unknown_event_count}, scalar(keys %$unknown), "$provider only catalog events contribute required slots");
        ok($facts->{ready} && $facts->{state} eq 'shell', "$provider malformed unrelated events do not block catalog readiness");
        unlike($json->encode($facts), qr/PRIVATE_CUSTOM_SENTINEL/, "$provider unknown event values stay out of typed facts");
        for my $target (qw(ensure shell)) {
            my $out = repaired($provider, $unrelated, $target);
            ok(!$out->{changed}, "$provider $target ignores malformed unrelated event shapes");
            is_deeply($out->{data}, $unrelated_before, "$provider $target preserves every unrelated event JSON value");
        }
        delete $unrelated->{hooks}{SessionEnd};
        is_deeply(repaired($provider, $unrelated)->{data}, $unrelated_before, "$provider a missing catalog slot is repaired alongside malformed unrelated events");
        for my $spec (@{specs($provider)}) {
            for my $groups (undef, 'scalar', {}, [undef], [{matcher => 'x'}], [{hooks => {}}], [{hooks => [undef]}]) {
                my $bad = shell_data($provider);
                $bad->{hooks}{$spec->[0]} = $groups;
                ok(!eval { Loomy::Hooks::transform($provider, $bad); 1 }, "$provider/$spec->[0] malformed catalog groups still fail validation");
            }
        }
    }
    my $null = shell_data('claude');
    $null->{statusLine} = undef;
    my $out = repaired('claude', $null);
    ok(!$out->{changed} && exists($out->{data}{statusLine}) && !defined($out->{data}{statusLine}), 'explicit null statusLine is preserved');
    is($out->{facts}{status_line}{state}, 'custom', 'explicit null statusLine is a typed custom choice');
    ok(!$out->{facts}{status_line}{ambiguous} && $out->{facts}{ready}, 'explicit null statusLine is a valid nonambiguous custom choice');
    my $string_status = shell_data('claude');
    $string_status->{statusLine} = "PRIVATE_CUSTOM_SENTINEL\ncustom statusLine";
    for my $target (qw(ensure shell)) {
        my $custom = repaired('claude', $string_status, $target);
        ok(!$custom->{changed}, "$target preserves a string statusLine without replacement");
        is_deeply($custom->{data}, $string_status, "$target preserves string statusLine bytes and all hooks");
        is_deeply($custom->{facts}{status_line}, {state => 'ambiguous', owned => 0, shell => 0, native => 0, custom => 1, ambiguous => 1}, "$target string statusLine is reported as ambiguous custom");
        ok(!$custom->{facts}{ready} && $custom->{facts}{state} eq 'ambiguous', "$target string statusLine blocks readiness");
        unlike($json->encode($custom->{facts}), qr/PRIVATE_CUSTOM_SENTINEL/, "$target string statusLine facts do not disclose its contents");
    }
    delete $string_status->{hooks}{SessionEnd};
    my $string_repaired = repaired('claude', $string_status);
    is($string_repaired->{data}{statusLine}, $string_status->{statusLine}, 'string statusLine survives a changed hook repair');
    is(slot($string_repaired->{facts}, 'SessionEnd')->{owned}, 1, 'string statusLine does not prevent a missing catalog hook from being repaired');
    for my $value ('', '123') {
        my $data = shell_data('claude');
        $data->{statusLine} = $value;
        my $custom = repaired('claude', $data);
        is($custom->{data}{statusLine}, $value, 'empty and numeric-looking string statusLine values are preserved');
        ok($custom->{facts}{status_line}{custom} && $custom->{facts}{status_line}{ambiguous}, 'empty and numeric-looking string statusLine values remain ambiguous custom');
    }
    my $padding = shell_data('claude');
    $padding->{statusLine}{padding} = 12;
    $padding->{statusLine}{extra} = {keep => 1};
    my $native = Loomy::Hooks::fixture_native_transform('claude', $padding, $descriptor, \@descriptors);
    is_deeply(repaired('claude', $native->{data}, 'shell')->{data}, $padding, 'statusLine padding and unknown fields survive both transforms');
    for my $bad ([], 'scalar', {hooks => []}, {hooks => undef}, {hooks => {SessionStart => {}}}, {hooks => {SessionStart => [undef]}}, {hooks => {SessionStart => [{hooks => {}}]}}, {hooks => {SessionStart => [{hooks => [undef]}]}}, {statusLine => []}, {statusLine => 1}, {statusLine => JSON::PP::true}) {
        ok(!eval { Loomy::Hooks::transform('claude', $bad); 1 }, 'wrong settings/container shape fails before transform');
    }
};

subtest 'H06 pure fixture upgrade, inverse and retained-descriptor contract' => sub {
    for my $provider (qw(claude codex)) {
        my $shell = shell_data($provider);
        my $native = Loomy::Hooks::fixture_native_transform($provider, $shell, $descriptor, \@descriptors)->{data};
        is(Loomy::Hooks::inspect($provider, $native, \@descriptors)->{state}, 'native', "$provider fixture native profile recognized");
        ok(!repaired($provider, $native)->{changed}, "$provider ensure retains an active recognized native profile");
        $native->{userEdit} = {permissions => ['retain'], afterUpgrade => 1};
        my $rolled_back = repaired($provider, $native, 'shell')->{data};
        $shell->{userEdit} = clone($native->{userEdit});
        is_deeply($rolled_back, $shell, "$provider inverse keeps intervening user edits");
        ok(!repaired($provider, $rolled_back)->{changed}, "$provider shell repair after inverse adds no managed groups");
        my $upgrade = Loomy::Hooks::fixture_native_transform($provider, $rolled_back, $retained, \@descriptors);
        ok(!Loomy::Hooks::fixture_native_transform($provider, $upgrade->{data}, $retained, \@descriptors)->{changed}, "$provider repeat fixture re-upgrade is idempotent");
        is_deeply(repaired($provider, $upgrade->{data}, 'shell')->{data}, $shell, "$provider retained current/rollback descriptors support inverse");
        ok(!eval { Loomy::Hooks::transform($provider, $shell, 'native', \@descriptors); 1 }, "$provider production native selection is unavailable despite trusted fixture descriptors");
        my $untrusted = Loomy::Hooks::inspect($provider, $native);
        ok(!slot($untrusted, 'SessionStart')->{native}, "$provider project native strings do not create trusted descriptor adoption");
        ok(!$untrusted->{native_activation}, "$provider unknown repair adoption cannot activate native registration");
    }
};

subtest 'H03 filesystem no-op identity, modes and hardlink aliases' => sub {
    for my $provider (qw(claude codex)) {
        my $r = root("noop-$provider");
        my $path = seed($r, $provider, " \n" . $json->encode(shell_data($provider)) . "\n\t", 0640);
        my $before = manifest($r);
        my $inspection = Loomy::Hooks::settings_inspect($r, $provider);
        ok($inspection->{ok}, "$provider complete settings inspect successfully");
        is_deeply(manifest($r), $before, "$provider inspection has zero filesystem mutations");
        my $result = Loomy::Hooks::settings_update($r, $provider);
        ok($result->{ok} && !$result->{applied} && !$result->{changed}, "$provider complete repair is a no-op");
        is_deeply(manifest($r), $before, "$provider no-op retains exact bytes, inode, mode and directory contents");
        my $alias = "$r/alias.json";
        link($path, $alias) or die "fixture link: $!";
        $before = manifest($r);
        ok(Loomy::Hooks::settings_update($r, $provider)->{ok}, "$provider hardlinked no-op succeeds");
        is_deeply(manifest($r), $before, "$provider no-op retains shared hardlink inode and link count");
        for my $permissions (0600, 0640, 0751) {
            my $changed_root = root("mode-$provider-$permissions");
            my $changed_path = seed($changed_root, $provider, {customRoot => {keep => 'mode'}}, $permissions);
            my $original = bytes($changed_path);
            my $original_id = identity($changed_path);
            my $alias_path = "$changed_root/alias.json";
            link($changed_path, $alias_path) or die "fixture link: $!";
            my $out = Loomy::Hooks::settings_update($changed_root, $provider);
            ok($out->{ok} && $out->{applied} && $out->{changed}, "$provider changed hardlinked repair succeeds with mode $permissions");
            is(identity($changed_path)->[2], $permissions, "$provider replacement preserves original file mode $permissions");
            isnt(identity($changed_path)->[1], $original_id->[1], "$provider changed file is replaced by a distinct inode");
            is(bytes($alias_path), $original, "$provider hardlink alias retains original bytes");
            is(identity($alias_path)->[2], $permissions, "$provider hardlink alias mode is untouched");
            is(decode_json(bytes($changed_path))->{customRoot}{keep}, 'mode', "$provider custom JSON survives changed repair");
            is_deeply(temps(parent_path($changed_root, $provider)), [], "$provider successful repair leaves no temporary or lock file");
        }
        my $scoped_root = root("unrelated-events-$provider");
        my $complete = shell_data($provider);
        my $unknown = unrelated_events($provider);
        @{$complete->{hooks}}{keys %$unknown} = values %$unknown;
        my $scoped_path = seed($scoped_root, $provider, " \n" . $json->encode($complete) . "\n\t", 0640);
        my $scoped_before = manifest($scoped_root);
        ok(Loomy::Hooks::settings_inspect($scoped_root, $provider)->{ok}, "$provider filesystem inspection accepts malformed unrelated event groups");
        is_deeply(manifest($scoped_root), $scoped_before, "$provider unrelated event inspection preserves exact bytes and namespace");
        my $scoped = Loomy::Hooks::settings_update($scoped_root, $provider);
        ok($scoped->{ok} && !$scoped->{changed} && !$scoped->{applied}, "$provider complete catalog with unrelated malformed groups is a no-op");
        is_deeply(manifest($scoped_root), $scoped_before, "$provider unrelated event no-op preserves bytes, mode and inode");
        my $incomplete = clone($complete);
        delete $incomplete->{hooks}{SessionEnd};
        put($scoped_path, $json->encode($incomplete), 0640);
        my $scoped_repair = Loomy::Hooks::settings_update($scoped_root, $provider);
        ok($scoped_repair->{ok} && $scoped_repair->{applied}, "$provider repairs a missing slot alongside malformed unrelated events");
        is_deeply(decode_json(bytes($scoped_path)), $complete, "$provider changed repair preserves all unrelated event JSON values");
        is(identity($scoped_path)->[2], 0640, "$provider scoped repair preserves existing file mode");
        ok(!Loomy::Hooks::settings_update($scoped_root, $provider)->{changed}, "$provider scoped repair retry is idempotent");
    }
    my $string_root = root('string-statusline');
    my $string_data = shell_data('claude');
    $string_data->{statusLine} = "PRIVATE_CUSTOM_SENTINEL\ncustom statusLine";
    my $string_path = seed($string_root, 'claude', " \n" . $json->encode($string_data) . "\n", 0640);
    my $string_before = manifest($string_root);
    my $string_noop = Loomy::Hooks::settings_update($string_root, 'claude');
    ok($string_noop->{ok} && !$string_noop->{changed} && !$string_noop->{applied}, 'custom string statusLine permits filesystem no-op repair');
    is_deeply(manifest($string_root), $string_before, 'custom string statusLine no-op preserves bytes, mode and inode');
    ok(!$string_noop->{facts}{ready} && $string_noop->{facts}{status_line}{ambiguous}, 'filesystem string statusLine result reports ambiguity without readiness');
    my $string_incomplete = clone($string_data);
    delete $string_incomplete->{hooks}{SessionEnd};
    put($string_path, $json->encode($string_incomplete), 0640);
    my $string_changed = Loomy::Hooks::settings_update($string_root, 'claude');
    ok($string_changed->{ok} && $string_changed->{applied}, 'missing hooks repair beside a custom string statusLine');
    is_deeply(decode_json(bytes($string_path)), $string_data, 'changed filesystem repair preserves custom string statusLine bytes');
    ok(!$string_changed->{facts}{ready} && $string_changed->{facts}{state} eq 'ambiguous', 'changed filesystem repair retains string statusLine ambiguity');
};

subtest 'H1c directory write permissions and primary-group policy' => sub {
    my $primary_gid = (getpwuid($>))[3];
    for my $provider (qw(claude codex)) {
        for my $location (qw(root parent)) {
            my $r = root("world-writable-$provider-$location");
            seed($r, $provider, {user => 'KEEP_WORLD_WRITABLE_ORIGINAL'});
            my $dir = $location eq 'root' ? $r : parent_path($r, $provider);
            chmod(0777, $dir) or die "fixture chmod: $!";
            my $before = manifest($r);
            for my $action (qw(inspect repair)) {
                my $out = $action eq 'inspect' ? Loomy::Hooks::settings_inspect($r, $provider)
                    : Loomy::Hooks::settings_update($r, $provider);
                ok(!$out->{ok} && !$out->{applied} && !$out->{changed}, "$provider $action refuses a world-writable $location");
                is($out->{code}, 'unsafe_parent', "$provider world-writable $location has the directory safety code");
                is_deeply(manifest($r), $before, "$provider $action leaves world-writable $location settings and namespace unchanged");
            }
        }
        my $r = "$work/primary-group-$provider";
        my $saved_umask = umask(0002);
        mkdir($r, 0775) or die "fixture mkdir: $!";
        mkdir(parent_path($r, $provider), 0775) or die "fixture mkdir: $!";
        for my $dir ($r, parent_path($r, $provider)) {
            my @s = lstat($dir);
            chown(-1, $primary_gid, $dir) == 1 or die "fixture primary-group setup: $!" if $s[5] != $primary_gid;
            is((lstat($dir))[5], $primary_gid, "$provider real umask-002 directory uses the primary gid");
            is(identity($dir)->[2], 0775, "$provider umask 002 creates a group-writable directory");
        }
        put(settings_path($r, $provider), '{"user":"KEEP_PRIMARY_GROUP"}');
        my $accepted = Loomy::Hooks::settings_update($r, $provider);
        my $remaining_umask = umask($saved_umask);
        ok($accepted->{ok} && $accepted->{applied}, "$provider real primary-group directories permit repair under umask 002");
        is($remaining_umask, 0002, "$provider group-writable repair preserves the caller umask");
        is(decode_json(bytes(settings_path($r, $provider)))->{user}, 'KEEP_PRIMARY_GROUP', "$provider primary-group repair retains custom data");
        for my $location (qw(root parent)) {
            my $foreign = root("nonprimary-group-$provider-$location");
            seed($foreign, $provider, {user => 'KEEP_NONPRIMARY_GROUP'});
            my $dir = $location eq 'root' ? $foreign : parent_path($foreign, $provider);
            chmod(0775, $dir) or die "fixture chmod: $!";
            my $key = metadata_key([lstat($dir)]);
            my $before = manifest($foreign);
            my $out = with_settings_stats(sub {
                $_[0][5] = $primary_gid + 1 if metadata_key($_[0]) eq $key;
            }, sub { Loomy::Hooks::settings_update($foreign, $provider) });
            ok(!$out->{ok} && !$out->{applied}, "$provider refuses a simulated nonprimary-group-writable $location without chgrp privileges");
            is($out->{code}, 'unsafe_parent', "$provider nonprimary-group $location has the directory safety code");
            is_deeply(manifest($foreign), $before, "$provider nonprimary-group $location refusal preserves exact settings and namespace");
        }
        for my $location (qw(root parent)) {
            for my $permission (qw(world nonprimary-group)) {
                my $raced = root("late-permissions-$provider-$location-$permission");
                my $path = seed($raced, $provider, {user => 'KEEP_LATE_PERMISSION_ORIGINAL'});
                my $dir = $location eq 'root' ? $raced : parent_path($raced, $provider);
                if ($permission eq 'nonprimary-group') {
                    chown(-1, $primary_gid, $dir) == 1 or die "fixture primary-group setup: $!" if (lstat($dir))[5] != $primary_gid;
                    chmod(0775, $dir) or die "fixture chmod: $!";
                }
                my $key = metadata_key([lstat($dir)]);
                my $before = entry_snapshot($path);
                my ($changed, $reached) = (0, 0);
                my $out = with_settings_stats(sub {
                    $_[0][5] = $primary_gid + 1 if $changed && metadata_key($_[0]) eq $key;
                }, sub {
                    Loomy::Hooks::settings_update($raced, $provider, 'ensure', {test_hook => sub {
                        return unless $_[0] eq 'after_temp_create';
                        $reached++;
                        if ($permission eq 'world') { chmod(0777, $dir) or die "fixture chmod: $!" }
                        else { $changed = 1 }
                    }});
                });
                is($reached, 1, "$provider late $permission $location mutation reaches the write boundary");
                ok(!$out->{ok} && !$out->{applied}, "$provider late $permission $location mutation refuses original replacement");
                is_deeply(entry_snapshot($path), $before, "$provider late $permission $location mutation retains exact original bytes and inode");
                is_deeply(temps(parent_path($raced, $provider)), [], "$provider late $permission $location mutation cleans its own temporary");
            }
        }
    }
};

subtest 'H1c numeric token fidelity and verified output serialization' => sub {
    my @unsupported = (
        ['large-integer', '123456789012345678901234567890'],
        ['long-decimal', '0.123456789012345678901234567890'],
        ['overflow', '1e400'], ['decimal-spelling', '1.0'],
        ['negative-zero', '-0'], ['exponent-spelling', '1e2'],
    );
    my $supported = '[0,1,-1,2147483647,9007199254740991,12.5,0.25,1000000]';
    for my $provider (qw(claude codex)) {
        for my $case (@unsupported) {
            my ($name, $number) = @$case;
            my $r = root("numeric-$provider-$name");
            seed($r, $provider, qq|{"permissions":{"deny":["PRIVATE_NUMERIC_SENTINEL"]},"nested":[{"value":$number}]}|, 0640);
            my $before = manifest($r);
            my $out = Loomy::Hooks::settings_update($r, $provider);
            ok(!$out->{ok} && !$out->{applied} && !$out->{changed}, "$provider $name refuses a lossy numeric rewrite");
            is($out->{code}, 'unsupported_number', "$provider $name returns the numeric-fidelity code");
            ok(!$out->{facts} || !$out->{facts}{ready}, "$provider $name refusal never claims ready");
            unlike($json->encode($out), qr/PRIVATE_NUMERIC_SENTINEL|12345678901234567890/, "$provider $name result does not disclose preserved private data");
            is_deeply(manifest($r), $before, "$provider $name refusal preserves original bytes, inode, mode and namespace");
        }
        for my $literal (qw(NaN Inf -Inf)) {
            my $r = root("numeric-invalid-$provider-$literal");
            seed($r, $provider, qq|{"user":"KEEP_INVALID_NUMERIC_ORIGINAL","value":$literal}|);
            my $before = manifest($r);
            my $out = Loomy::Hooks::settings_update($r, $provider);
            ok(!$out->{ok} && !$out->{applied}, "$provider bare $literal is invalid JSON and cannot become ready");
            is($out->{code}, 'invalid_settings', "$provider bare $literal has the invalid-settings code");
            is_deeply(manifest($r), $before, "$provider bare $literal preserves exact invalid input for manual repair");
        }
        my $r = root("numeric-supported-$provider");
        my $quoted = q|numbers 1e400 1.0 -0 123456789012345678901234567890 and an escaped quote: \" 1e400|;
        my $raw = '{"numbers":' . $supported . ',"quoted":' . $json->encode($quoted)
            . ',"permissions":{"deny":["KEEP_NUMERIC_DENY"]}}';
        my $path = seed($r, $provider, $raw, 0640);
        my $out = Loomy::Hooks::settings_update($r, $provider);
        ok($out->{ok} && $out->{applied}, "$provider supported number tokens and numeric-looking strings permit repair");
        my $encoded = bytes($path);
        my $decoded = eval { decode_json($encoded) };
        ok(!$@ && ref($decoded) eq 'HASH', "$provider written bytes decode as valid JSON");
        is($json->encode($decoded->{numbers}), $supported, "$provider supported values remain numeric with byte-exact token spelling");
        is($decoded->{quoted}, $quoted, "$provider numeric text inside escaped strings remains uninterpreted");
        is_deeply($decoded->{permissions}{deny}, ['KEEP_NUMERIC_DENY'], "$provider supported serialization retains permissions.deny");
        my $codec = JSON::PP->new->utf8->canonical->indent->indent_length(2)->space_after;
        is($codec->encode($decoded), $encoded, "$provider written bytes have an identical decode and re-encode");
        unlike($encoded, qr/:\s*(?:-?Inf|NaN)(?=\s|[,}])/, "$provider never writes bare non-JSON numeric constants");
        my $before = manifest($r);
        ok(!Loomy::Hooks::settings_update($r, $provider)->{changed}, "$provider supported numeric repair is idempotent");
        is_deeply(manifest($r), $before, "$provider supported numeric no-op retains exact serialized bytes and inode");
        for my $failure (qw(invalid unstable exception)) {
            my $bad = root("serialization-$provider-$failure");
            seed($bad, $provider, {user => 'KEEP_SERIALIZATION_ORIGINAL'});
            my $snapshot = manifest($bad);
            my $encode = \&Loomy::Hooks::_settings_encode;
            my $calls = 0;
            no warnings 'redefine';
            local *Loomy::Hooks::_settings_encode = sub {
                $calls++;
                die "fixture encoder failure\n" if $failure eq 'exception';
                return '{"value":Inf}' if $failure eq 'invalid';
                return $encode->(@_) . ($calls % 2 ? "\n" : '');
            };
            my $refused = Loomy::Hooks::settings_update($bad, $provider);
            ok(!$refused->{ok} && !$refused->{applied}, "$provider $failure serializer output is refused before writing");
            is($refused->{code}, $failure eq 'exception' ? 'serialization_failed' : 'invalid_serialization', "$provider $failure serializer has a clear output-validation code");
            cmp_ok($calls, '>=', $failure eq 'unstable' ? 2 : 1, "$provider $failure serializer seam was exercised");
            is_deeply(manifest($bad), $snapshot, "$provider $failure serializer preserves original bytes, inode and namespace");
        }
    }
};

subtest 'H1c original gid retention and fail-closed metadata verification' => sub {
    for my $provider (qw(claude codex)) {
        my $r = root("real-gid-$provider");
        my $path = seed($r, $provider, {user => 'KEEP_REAL_GID'}, 0640);
        my $gid = (lstat($path))[5];
        my $out = Loomy::Hooks::settings_update($r, $provider);
        ok($out->{ok} && $out->{applied}, "$provider real gid-preserving rewrite succeeds");
        is((lstat($path))[5], $gid, "$provider real replacement preserves the original gid");
        my $same = root("same-gid-chown-denied-$provider");
        my $same_path = seed($same, $provider, {user => 'KEEP_SAME_GID'});
        my $same_gid = (lstat($same_path))[5];
        my $attempted = 0;
        {
            no warnings 'redefine';
            local *Loomy::Hooks::_settings_chown = sub { $attempted++; $! = EPERM; return 0 };
            my $accepted = Loomy::Hooks::settings_update($same, $provider);
            ok($accepted->{ok} && $accepted->{applied}, "$provider denied best-effort chown succeeds when the actual temp gid is already correct");
        }
        is($attempted, 1, "$provider best-effort same-gid chown was attempted");
        is((lstat($same_path))[5], $same_gid, "$provider denied no-op chown retains the actual original gid");
        for my $behavior (qw(preserve denied ineffective late-change)) {
            my $fake = root("gid-$provider-$behavior");
            my $fake_path = seed($fake, $provider, {user => 'KEEP_GID_ORIGINAL'}, 0640);
            my $original = entry_snapshot($fake_path);
            my $original_key = metadata_key([lstat($fake_path)]);
            my $wanted_gid = (lstat($fake_path))[5] + 10000;
            my %gids = ($original_key => $wanted_gid);
            my ($calls, $after_chown, $temp_key) = (0, 0);
            my $handle_stat = \&Loomy::Hooks::_settings_handle_stat;
            my $result = with_settings_stats(sub {
                my ($s) = @_;
                my $key = metadata_key($s);
                $s->[5] = $gids{$key} if exists $gids{$key};
            }, sub {
                no warnings 'redefine';
                local *Loomy::Hooks::_settings_chown = sub {
                    my ($fh, $gid) = @_;
                    $calls++;
                    die "fixture wrong target gid\n" unless $gid == $wanted_gid;
                    $temp_key = metadata_key($handle_stat->($fh));
                    $gids{$temp_key} = $gid if $behavior eq 'preserve' || $behavior eq 'late-change';
                    $! = EPERM if $behavior eq 'denied';
                    return $behavior eq 'denied' ? 0 : 1;
                };
                return Loomy::Hooks::settings_update($fake, $provider, 'ensure', {test_hook => sub {
                    return unless $_[0] eq 'after_chown';
                    $after_chown++;
                    $gids{$temp_key} = $wanted_gid + 1 if $behavior eq 'late-change';
                }});
            });
            is($calls, 1, "$provider $behavior tests a different original gid using only metadata seams");
            if ($behavior eq 'preserve') {
                ok($result->{ok} && $result->{applied}, "$provider verifies the requested gid on the new handle before replacing");
                is($after_chown, 1, "$provider preserved-gid handle reaches the checked post-chown boundary");
                is(decode_json(bytes($fake_path))->{user}, 'KEEP_GID_ORIGINAL', "$provider successful gid preservation keeps user data");
            } else {
                ok(!$result->{ok} && !$result->{applied} && !$result->{changed}, "$provider $behavior gid preservation refuses original replacement");
                is($result->{code}, 'gid_preservation_failed', "$provider $behavior gid mismatch has a clear fail-closed code");
                is_deeply(entry_snapshot($fake_path), $original, "$provider $behavior gid mismatch preserves original bytes, inode, mode and gid");
                is($after_chown, $behavior eq 'late-change' ? 1 : 0, "$provider $behavior verifies gid before the post-chown boundary");
            }
            is_deeply(temps(parent_path($fake, $provider)), [], "$provider $behavior gid handling leaves no temporary");
        }
    }
};

subtest 'H1c global project roots and their aliases are refused' => sub {
    for my $provider (qw(claude codex)) {
        for my $global (qw(home claude-config-parent codex-home-parent)) {
            my $r = root("global-$provider-$global");
            my $config = "$r/provider-config";
            mkdir($config, 0700) or die "fixture mkdir: $!";
            my $alias = "$work/global-alias-$provider-$global";
            symlink($r, $alias) or die "fixture symlink: $!";
            local $ENV{HOME} = $global eq 'home' ? $r : $ENV{HOME};
            local $ENV{CLAUDE_CONFIG_DIR} = $global eq 'claude-config-parent' ? $config : $ENV{CLAUDE_CONFIG_DIR};
            local $ENV{CODEX_HOME} = $global eq 'codex-home-parent' ? $config : $ENV{CODEX_HOME};
            my $before = manifest($r);
            for my $input ($r, "$r/.", "$r/", $alias) {
                for my $action (qw(inspect repair)) {
                    my $out = $action eq 'inspect' ? Loomy::Hooks::settings_inspect($input, $provider)
                        : Loomy::Hooks::settings_update($input, $provider);
                    ok(!$out->{ok} && !$out->{applied} && !$out->{changed}, "$provider $action refuses $global through a canonical or alias root");
                    is($out->{code}, 'unsafe_project', "$provider $global refusal has the project-scope code");
                    is_deeply(manifest($r), $before, "$provider $action never bootstraps provider settings in $global");
                }
            }
        }
        # A bad regression must fail without ever opening or mutating /, even
        # when this hermetic fixture is run by a privileged release runner.
        my $open_dir = \&Loomy::Hooks::_settings_open_dir;
        my $root_opened = 0;
        no warnings 'redefine';
        local *Loomy::Hooks::_settings_open_dir = sub {
            if ($_[1] eq '/') { $root_opened++; die "fixture refuses to open filesystem root\n" }
            return $open_dir->(@_);
        };
        for my $input ('/', '/.') {
            my $out = Loomy::Hooks::settings_update($input, $provider);
            ok(!$out->{ok} && !$out->{applied}, "$provider refuses the filesystem-root alias before mutation");
            is($out->{code}, 'unsafe_project', "$provider filesystem root has the project-scope code");
        }
        is($root_opened, 0, "$provider rejects / before the directory-open boundary");
    }
};

subtest 'H1c stale temporary reaping is narrow, locked and best effort' => sub {
    my $dead_pid = fork_child(sub {});
    reap($dead_pid, 'known-dead stale-temp owner');
    my $uncertain_pid = fork_child(sub {});
    reap($uncertain_pid, 'simulated inaccessible stale-temp owner');
    ok(Loomy::Hooks::_settings_pid_dead($dead_pid), 'a specifically reaped fixture child is a dead owner PID');
    ok(!Loomy::Hooks::_settings_pid_dead($$), 'the running fixture process is a live owner PID');
    for my $provider (qw(claude codex)) {
        my $r = root("reap-policy-$provider");
        my $path = seed($r, $provider, shell_data($provider));
        my $parent = parent_path($r, $provider);
        my $outside = root("reap-policy-outside-$provider");
        put("$outside/sentinel", 'KEEP_REAPER_OUTSIDE');
        my %names = (
            eligible => stale_name($provider, $dead_pid, 'a'),
            live => stale_name($provider, $$, 'b'),
            recent => stale_name($provider, $dead_pid, 'c'),
            foreign => stale_name($provider, $dead_pid, 'd'),
            uncertain => stale_name($provider, $uncertain_pid, 'e'),
            hardlink => stale_name($provider, $dead_pid, 'f'),
            directory => stale_name($provider, $dead_pid, '1'),
            symlink => stale_name($provider, $dead_pid, '2'),
            fifo => stale_name($provider, $dead_pid, '3'),
            cross_provider => stale_name($provider eq 'claude' ? 'codex' : 'claude', $dead_pid, '4'),
            short_hex => substr(stale_name($provider, $dead_pid, '5'), 0, -1),
            # Keep the lowercase equivalent unused on case-insensitive APFS.
            uppercase_hex => stale_name($provider, $dead_pid, 'B'),
            malformed_pid => stale_name($provider, 'not-a-pid', '6'),
            unrelated => 'unrelated.loomy-' . $dead_pid . '-' . ('7' x 24),
        );
        for my $kind (grep { $_ ne 'directory' && $_ ne 'symlink' && $_ ne 'fifo' } keys %names) {
            put("$parent/$names{$kind}", "KEEP_REAPER_$kind");
            age_file("$parent/$names{$kind}", $kind eq 'recent' ? 60 : 1200);
        }
        link("$parent/$names{hardlink}", "$parent/hardlink-alias") or die "fixture link: $!";
        mkdir("$parent/$names{directory}", 0700) or die "fixture mkdir: $!";
        put("$parent/$names{directory}/sentinel", 'KEEP_REAPER_DIRECTORY');
        age_file("$parent/$names{directory}", 1200);
        symlink("$outside/sentinel", "$parent/$names{symlink}") or die "fixture symlink: $!";
        POSIX::mkfifo("$parent/$names{fifo}", 0600) == 0 or die "fixture mkfifo: $!";
        age_file("$parent/$names{fifo}", 1200);
        my $foreign_key = metadata_key([lstat("$parent/$names{foreign}")]);
        my $symlink_key = metadata_key([lstat("$parent/$names{symlink}")]);
        my %expected = map { $_ => entry_snapshot("$parent/$names{$_}") } keys %names;
        my $alias_before = entry_snapshot("$parent/hardlink-alias");
        my $outside_before = manifest($outside);
        my $settings_before = entry_snapshot($path);
        my $before = manifest($r);
        my $pid_dead = \&Loomy::Hooks::_settings_pid_dead;
        with_reaper_stats(sub {
            my ($s) = @_;
            $s->[4] = $> + 1 if metadata_key($s) eq $foreign_key;
            $s->[9] = time - 1200 if metadata_key($s) eq $symlink_key;
        }, sub {
            no warnings 'redefine';
            local *Loomy::Hooks::_settings_pid_dead = sub {
                if ($_[0] == $uncertain_pid) { $! = EPERM; return 0 }
                return $pid_dead->(@_);
            };
            ok(Loomy::Hooks::settings_inspect($r, $provider)->{ok}, "$provider stale-temp inspection succeeds without cleanup");
            is_deeply(manifest($r), $before, "$provider inspection never reaps even eligible stale temps");
            my $out = Loomy::Hooks::settings_update($r, $provider);
            ok($out->{ok} && !$out->{applied} && !$out->{changed}, "$provider reaps stale temps without rewriting already-complete settings");
        });
        ok(!lstat("$parent/$names{eligible}"), "$provider removes its own old single-link regular temp after its owner exited");
        for my $kind (sort grep { $_ ne 'eligible' } keys %names) {
            is_deeply(entry_snapshot("$parent/$names{$kind}"), $expected{$kind}, "$provider retains $kind temporary bytes and identity");
        }
        is_deeply(entry_snapshot("$parent/hardlink-alias"), $alias_before, "$provider never alters an old temp hardlink alias");
        is_deeply(entry_snapshot($path), $settings_before, "$provider reaping preserves complete settings bytes, inode and mode");
        is_deeply(manifest($outside), $outside_before, "$provider reaping never follows a temp symlink outside");
        my $busy_root = root("reap-locked-$provider");
        seed($busy_root, $provider, shell_data($provider));
        my $busy_parent = parent_path($busy_root, $provider);
        my $stale = "$busy_parent/" . stale_name($provider, $dead_pid, 'a');
        put($stale, 'KEEP_UNDER_CONTENTION');
        age_file($stale, 1200);
        pipe(my $ready, my $send_ready) or die "fixture pipe: $!";
        pipe(my $release, my $send_release) or die "fixture pipe: $!";
        my $holder = fork_child(sub {
            close $ready;
            close $send_release;
            sysopen my $lock, $busy_parent, O_RDONLY or die "fixture directory open: $!";
            flock($lock, LOCK_EX | LOCK_NB) or die "fixture lock: $!";
            syswrite($send_ready, 'R') == 1 or die "fixture write: $!";
            receive($release);
            close $lock;
            close $send_ready;
            close $release;
        });
        close $send_ready;
        close $release;
        is(receive($ready), 'R', "$provider stale cleanup contender holds the actual parent directory flock");
        my $busy_before = manifest($busy_root);
        my $started = time;
        my $busy = Loomy::Hooks::settings_update($busy_root, $provider);
        is($busy->{code}, 'busy', "$provider locked directory reports busy regardless of holder attribution");
        ok(!$busy->{ok} && !$busy->{applied} && time - $started < 2, "$provider cleanup lock contention is bounded and never ready");
        is_deeply(manifest($busy_root), $busy_before, "$provider never reaps before acquiring the parent lock");
        syswrite($send_release, 'G') == 1 or die "fixture write: $!";
        close $send_release;
        close $ready;
        reap($holder, "$provider stale-temp directory-lock holder");
        ok(Loomy::Hooks::settings_update($busy_root, $provider)->{ok}, "$provider cleanup retries after the lock holder exits");
        ok(!lstat($stale), "$provider stale cleanup starts only after acquiring the released lock");
    }
};

subtest 'H1c stale cleanup rechecks candidate identity, liveness and pinned namespace' => sub {
    my $dead_pid = fork_child(sub {});
    reap($dead_pid, 'stale-temp race owner');
    for my $provider (qw(claude codex)) {
        for my $replacement (qw(file symlink directory refreshed live-pid)) {
            my $r = root("reap-race-$provider-$replacement");
            my $path = seed($r, $provider, shell_data($provider));
            my $parent = parent_path($r, $provider);
            my $stale = "$parent/" . stale_name($provider, $dead_pid, 'a');
            put($stale, 'KEEP_REAPER_RACE_ORIGINAL');
            age_file($stale, 1200);
            my $outside = root("reap-race-outside-$provider-$replacement");
            put("$outside/sentinel", 'KEEP_REAPER_RACE_OUTSIDE');
            my $outside_before = manifest($outside);
            my $settings_before = entry_snapshot($path);
            my ($reached, $unknown, $expected, $parked) = (0, 0);
            my $pid_dead = \&Loomy::Hooks::_settings_pid_dead;
            no warnings 'redefine';
            local *Loomy::Hooks::_settings_pid_dead = sub { return 0 if $unknown; return $pid_dead->(@_) };
            my $out = Loomy::Hooks::settings_update($r, $provider, 'ensure', {test_hook => sub {
                return unless $_[0] eq 'before_stale_unlink';
                $reached++;
                if ($replacement eq 'refreshed') { age_file($stale, 60) }
                elsif ($replacement eq 'live-pid') { $unknown = 1 }
                else {
                    $parked = "$parent/parked-original";
                    rename($stale, $parked) or die "fixture rename: $!";
                    if ($replacement eq 'file') { put($stale, 'KEEP_REAPER_RACE_REPLACEMENT'); age_file($stale, 1200) }
                    elsif ($replacement eq 'symlink') { symlink("$outside/sentinel", $stale) or die "fixture symlink: $!" }
                    else { mkdir($stale, 0700) or die "fixture mkdir: $!" }
                }
                $expected = entry_snapshot($stale);
            }});
            is($reached, 1, "$provider $replacement candidate race reaches the final-unlink boundary");
            ok($out->{ok} && !$out->{applied}, "$provider $replacement cleanup race is best effort without rewriting complete settings");
            is_deeply(entry_snapshot($stale), $expected, "$provider preserves the $replacement candidate after the final safety recheck");
            is(bytes($parked), 'KEEP_REAPER_RACE_ORIGINAL', "$provider does not follow the renamed old temp") if defined $parked;
            is_deeply(entry_snapshot($path), $settings_before, "$provider $replacement race preserves settings bytes and inode");
            is_deeply(manifest($outside), $outside_before, "$provider $replacement race never escapes through a replacement symlink");
        }
        my $r = root("reap-parent-swap-$provider");
        my $path = seed($r, $provider, shell_data($provider));
        my $original = entry_snapshot($path);
        my $parent = parent_path($r, $provider);
        my $name = stale_name($provider, $dead_pid, 'a');
        put("$parent/$name", 'OWN_STALE_TEMP');
        age_file("$parent/$name", 1200);
        my $outside = root("reap-parent-swap-outside-$provider");
        put("$outside/$name", 'KEEP_RETARGETED_TEMP_SENTINEL');
        age_file("$outside/$name", 1200);
        put("$outside/" . ($provider eq 'claude' ? 'settings.json' : 'hooks.json'), 'KEEP_RETARGETED_SETTINGS_SENTINEL');
        my $outside_before = manifest($outside);
        my $detached = "$r/detached";
        my $reached = 0;
        my $out = Loomy::Hooks::settings_update($r, $provider, 'ensure', {test_hook => sub {
            return unless $_[0] eq 'before_stale_unlink';
            $reached++;
            rename($parent, $detached) or die "fixture rename: $!";
            symlink($outside, $parent) or die "fixture symlink: $!";
        }});
        is($reached, 1, "$provider stale cleanup reaches the parent-swap boundary");
        ok(!$out->{ok} && !$out->{applied}, "$provider retargeted cleanup never claims ready or replaces settings");
        is_deeply(manifest($outside), $outside_before, "$provider cleanup uses the pinned directory after parent retargeting");
        is_deeply(entry_snapshot("$detached/" . ($provider eq 'claude' ? 'settings.json' : 'hooks.json')), $original, "$provider retargeted cleanup retains original settings in the detached parent");
    }
};

subtest 'H04 missing parents, invalid shapes, no-follow and fenced races' => sub {
    for my $provider (qw(claude codex)) {
        my $r = root("fresh-$provider");
        my $before = manifest($r);
        my $inspection = Loomy::Hooks::settings_inspect($r, $provider);
        ok($inspection->{ok}, "$provider absent settings are inspectable");
        is_deeply(manifest($r), $before, "$provider absent inspection creates no settings parent");
        my $blocked = Loomy::Hooks::settings_update($r, $provider, 'native');
        ok(!$blocked->{ok} && !$blocked->{applied}, "$provider unavailable native target refuses before mutation");
        is_deeply(manifest($r), $before, "$provider unavailable native target does not bootstrap parent");
        my $out = Loomy::Hooks::settings_update($r, $provider);
        ok($out->{ok} && $out->{applied}, "$provider explicit shell repair bootstraps missing parent");
        is(identity(parent_path($r, $provider))->[2], 0700, "$provider new parent is private 0700");
        is(identity(settings_path($r, $provider))->[2], 0644, "$provider new settings retain baseline 0644 mode");
        is_deeply(decode_json(bytes(settings_path($r, $provider))), shell_data($provider), "$provider fresh file contains exact shell defaults");
        my $existing = root("existing-parent-$provider");
        make_path(parent_path($existing, $provider), {mode => 0755});
        chmod 0755, parent_path($existing, $provider) or die;
        ok(Loomy::Hooks::settings_update($existing, $provider)->{ok}, "$provider repair in existing parent succeeds");
        is(identity(parent_path($existing, $provider))->[2], 0755, "$provider existing parent mode survives");
        for my $invalid ('not-json', 'null', '[]', '{"hooks":null}', '{"hooks":[]}', '{"hooks":{"SessionStart":{}}}', '{"hooks":{"SessionStart":[{"hooks":{}}]}}') {
            my $bad_root = root("invalid-$provider-" . ++our $invalid_number);
            my $path = seed($bad_root, $provider, $invalid);
            my $snapshot = manifest($bad_root);
            my $result = Loomy::Hooks::settings_update($bad_root, $provider);
            ok(!$result->{ok} && !$result->{applied} && !$result->{changed}, "$provider invalid JSON/container shape refuses repair");
            is_deeply(manifest($bad_root), $snapshot, "$provider invalid file is preserved exactly");
        }
        my $outside = root("outside-$provider");
        put("$outside/" . ($provider eq 'claude' ? 'settings.json' : 'hooks.json'), 'OUTSIDE_SENTINEL');
        for my $shape (qw(parent-symlink file-symlink dangling-symlink fifo directory parent-file)) {
            my $unsafe = root("unsafe-$provider-$shape");
            my $parent = parent_path($unsafe, $provider);
            my $path = settings_path($unsafe, $provider);
            if ($shape eq 'parent-symlink') { symlink($outside, $parent) or die }
            elsif ($shape eq 'parent-file') { put($parent, 'PARENT_SENTINEL') }
            else {
                make_path($parent, {mode => 0750});
                if ($shape eq 'file-symlink') { symlink("$outside/" . ($provider eq 'claude' ? 'settings.json' : 'hooks.json'), $path) or die }
                elsif ($shape eq 'dangling-symlink') { symlink("$outside/absent", $path) or die }
                elsif ($shape eq 'fifo') { POSIX::mkfifo($path, 0600) == 0 or die "fixture mkfifo: $!" }
                else { make_path($path, {mode => 0700}) }
            }
            my $before = manifest($unsafe);
            my $outside_before = manifest($outside);
            local $SIG{ALRM} = sub { die "unsafe shape opened a blocking FIFO\n" };
            alarm 5;
            my $result = Loomy::Hooks::settings_update($unsafe, $provider);
            alarm 0;
            ok(!$result->{ok} && !$result->{applied}, "$provider $shape destination refuses repair");
            is_deeply(manifest($unsafe), $before, "$provider $shape namespace stays unchanged");
            is_deeply(manifest($outside), $outside_before, "$provider $shape never changes an outside destination");
        }
        for my $race (qw(directory symlink file)) {
            my $racing = root("parent-create-$provider-$race");
            my $parent = parent_path($racing, $provider);
            my $outside_before = manifest($outside);
            my $created = 0;
            my $result = Loomy::Hooks::settings_update($racing, $provider, 'ensure', {test_hook => sub {
                return unless $_[0] eq 'before_parent_create';
                $created++;
                if ($race eq 'directory') { mkdir($parent, 0751) or die; chmod(0751, $parent) or die }
                elsif ($race eq 'symlink') { symlink($outside, $parent) or die }
                else { put($parent, 'RACING_PARENT_FILE') }
            }});
            is($created, 1, "$provider racing $race creation boundary was reached");
            if ($race eq 'directory') {
                ok($result->{ok}, "$provider racing real parent creation is revalidated and repaired");
                is(identity($parent)->[2], 0751, "$provider racing existing parent mode is preserved");
            } else {
                ok(!$result->{ok} && !$result->{applied}, "$provider racing $race parent is refused");
                ok($race eq 'symlink' ? -l $parent : -f $parent, "$provider racing $race parent is not replaced");
            }
            is_deeply(manifest($outside), $outside_before, "$provider racing $race creation cannot change outside files");
        }
        my $replaced = root("parent-after-create-$provider");
        my $detached = "$replaced/detached";
        my $outside_before = manifest($outside);
        my $result = Loomy::Hooks::settings_update($replaced, $provider, 'ensure', {test_hook => sub {
            return unless $_[0] eq 'after_parent_create';
            rename(parent_path($replaced, $provider), $detached) or die;
            symlink($outside, parent_path($replaced, $provider)) or die;
        }});
        ok(!$result->{ok} && !$result->{applied}, "$provider symlink replacement after parent creation is refused");
        is_deeply([glob("$detached/*")], [], "$provider replaced new parent receives no settings or temporary");
        is_deeply(manifest($outside), $outside_before, "$provider post-creation parent replacement cannot escape");
    }
    for my $conflict (qw(bytes inode mode)) {
        my $r = root("editor-$conflict");
        my $path = seed($r, 'claude', {user => 'before'});
        my $expected;
        my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', {test_hook => sub {
            my ($stage) = @_;
            return unless $stage eq 'after_temp_create';
            if ($conflict eq 'bytes') { put($path, '{"user":"EDITOR_NEW_BYTES"}') }
            elsif ($conflict eq 'inode') { put("$r/editor-new", bytes($path)); rename("$r/editor-new", $path) or die }
            else { chmod 0600, $path or die }
            $expected = [bytes($path), identity($path)];
        }});
        ok(!$out->{ok} && !$out->{applied}, "noncooperating editor $conflict conflict is refused before rename");
        is_deeply([bytes($path), identity($path)], $expected, "noncooperating editor $conflict edit is not overwritten");
        is_deeply(temps(parent_path($r, 'claude')), [], "noncooperating editor $conflict conflict cleans temporary");
    }
    for my $stage ('after_temp_create', 'before_rename', 'before_namespace_check') {
        my $r = root("retarget-$stage");
        my $path = seed($r, 'claude', {user => 'pinned-original'});
        my $original = bytes($path);
        my $outside = root("retarget-outside-$stage");
        put("$outside/settings.json", '{"user":"OUTSIDE_SENTINEL"}');
        my $outside_before = manifest($outside);
        my $detached = "$r/detached";
        my $called = 0;
        my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', {test_hook => sub {
            return unless $_[0] eq $stage;
            $called++;
            rename("$r/.claude", $detached) or die "fixture retarget: $!";
            symlink($outside, "$r/.claude") or die "fixture symlink: $!";
        }});
        is($called, 1, "$stage deterministic namespace-race boundary was reached");
        ok(!$out->{ok}, "$stage changed namespace never reports readiness");
        is_deeply(manifest($outside), $outside_before, "$stage descriptor-relative operations cannot escape pinned parent");
        if ($stage eq 'after_temp_create') {
            ok(!$out->{applied} && !$out->{changed}, 'early parent retarget is refused before applying');
            is(bytes("$detached/settings.json"), $original, 'early parent retarget retains original pinned bytes');
        } else {
            ok($out->{applied} && $out->{changed}, "$stage result distinguishes applied pinned update from placement uncertainty");
            ok(exists(decode_json(bytes("$detached/settings.json"))->{hooks}), "$stage update is confined to detached pinned parent");
        }
        is_deeply(temps($detached), [], "$stage cleans temporary in the pinned parent");
    }
};

subtest 'H04 directory flock serializes cooperating writers across rename' => sub {
    flock_probe();
    my $r = root('concurrent-writers');
    my $path = seed($r, 'claude', {user => 'retained'});
    pipe(my $ready, my $send_ready) or die;
    pipe(my $release, my $send_release) or die;
    my $pid = fork_child(sub {
        close $ready;
        close $send_release;
        my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', {test_hook => sub {
            return unless $_[0] eq 'after_parent_lock';
            syswrite($send_ready, 'R') == 1 or die;
            receive($release);
        }});
        die 'first cooperating writer failed' unless $out->{ok};
        close $send_ready;
        close $release;
    });
    close $send_ready;
    close $release;
    is(receive($ready), 'R', 'first writer holds the directory lock at a known barrier');
    my $before = manifest($r);
    my $started = time;
    my $busy = Loomy::Hooks::settings_update($r, 'claude');
    ok(!$busy->{ok} && !$busy->{applied}, 'second cooperating writer refuses a held directory lock');
    is($busy->{code}, 'busy', 'a held directory flock has the documented busy code');
    ok(time - $started < 2, 'contended writer uses bounded nonblocking acquisition');
    is_deeply(manifest($r), $before, 'contender does not mutate the active writer namespace');
    syswrite($send_release, 'G') == 1 or die;
    close $send_release;
    close $ready;
    reap($pid, 'cooperating settings writer');
    my $result = Loomy::Hooks::settings_update($r, 'claude');
    ok($result->{ok} && !$result->{changed}, 'retry after writer release is complete and idempotent');
    is(decode_json(bytes($path))->{user}, 'retained', 'serialized repair retains user data');
};

subtest 'H05 checked operations, cleanup, interruption and partial-provider retry' => sub {
    for my $operation (qw(create print flush sync chmod close rename)) {
        my $r = root("failure-$operation");
        my $path = seed($r, 'claude', {user => 'original'}, 0640);
        my $before = manifest($r);
        my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', {fail_at => $operation});
        ok(!$out->{ok} && !$out->{applied} && !$out->{changed}, "$operation failure reports pre-rename unchanged result");
        ok(defined($out->{code}) && length($out->{code}), "$operation failure has a diagnostic code");
        is_deeply(manifest($r), $before, "$operation failure preserves bytes/inode/mode and cleans temporary");
    }
    for my $provider (qw(claude codex)) {
        for my $operation (qw(create print flush sync chmod close rename)) {
            my $r = root("bootstrap-failure-$provider-$operation");
            my $before = manifest($r);
            my $out = Loomy::Hooks::settings_update($r, $provider, 'ensure', {fail_at => $operation});
            ok(!$out->{ok} && !$out->{applied} && !$out->{changed}, "$provider bootstrap $operation failure is unapplied");
            is_deeply(manifest($r), $before, "$provider bootstrap $operation failure removes only its new empty parent and temporary");
        }
        for my $interruption ('exception', 'TERM') {
            for my $stage ('after_parent_create', 'after_parent_lock', 'after_temp_create', 'before_parent_cleanup') {
                my $r = root("bootstrap-$provider-$interruption-$stage");
                my $before = manifest($r);
                pipe(my $read, my $write) or die;
                my $pid = fork_child(sub {
                    close $read;
                    my $called = 0;
                    my $options = {test_hook => sub {
                        return unless $_[0] eq $stage;
                        $called++;
                        die "fixture bootstrap exception\n" if $interruption eq 'exception';
                        kill('TERM', $$) == 1 or die 'fixture self-TERM failed';
                    }};
                    $options->{fail_at} = 'create' if $stage eq 'before_parent_cleanup';
                    my $out = Loomy::Hooks::settings_update($r, $provider, 'ensure', $options);
                    my $facts = ($called == 1 ? 'C' : 'E')
                        . (!$out->{ok} && !$out->{applied} && !$out->{changed} ? 'R' : 'E');
                    syswrite($write, $facts) == 2 or die;
                    close $write;
                });
                close $write;
                is(receive($read), 'C', "$provider $interruption reaches $stage");
                is(receive($read), 'R', "$provider $interruption at $stage returns an unapplied failure");
                close $read;
                reap($pid, "$provider $interruption bootstrap writer at $stage");
                is_deeply(manifest($r), $before, "$provider $interruption at $stage removes its own new empty parent");
            }
        }
        for my $origin ('existing', 'racing') {
            my $r = root("bootstrap-preserve-$provider-$origin");
            my $parent = parent_path($r, $provider);
            my $expected;
            if ($origin eq 'existing') {
                mkdir($parent, 0751) or die;
                chmod(0751, $parent) or die;
                $expected = manifest($r);
            }
            my $out = Loomy::Hooks::settings_update($r, $provider, 'ensure', {test_hook => sub {
                if ($origin eq 'racing' && $_[0] eq 'before_parent_create') {
                    mkdir($parent, 0751) or die;
                    chmod(0751, $parent) or die;
                    $expected = manifest($r);
                }
                die "fixture existing-parent failure\n" if $_[0] eq 'after_parent_lock';
            }});
            ok(!$out->{ok} && !$out->{applied}, "$provider failure in $origin empty parent is unapplied");
            is_deeply(manifest($r), $expected, "$provider failure preserves $origin empty parent inode and mode");
        }
        my $outside = root("bootstrap-outside-$provider");
        put("$outside/sentinel", 'OUTSIDE_SENTINEL');
        for my $stage ('after_parent_create', 'after_temp_create', 'before_parent_cleanup') {
            for my $replacement ('nonempty', 'directory', 'symlink') {
                my $r = root("bootstrap-race-$provider-$stage-$replacement");
                my $parent = parent_path($r, $provider);
                my $detached = "$r/detached";
                my $outside_before = manifest($outside);
                my ($called, $expected_parent, $expected_detached) = (0);
                my $options = {test_hook => sub {
                    return unless $_[0] eq $stage;
                    $called++;
                    if ($replacement eq 'nonempty') {
                        put("$parent/sentinel", 'KEEP_NONEMPTY_PARENT');
                    } else {
                        rename($parent, $detached) or die;
                        if ($replacement eq 'directory') {
                            mkdir($parent, 0751) or die;
                            chmod(0751, $parent) or die;
                        } else {
                            symlink($outside, $parent) or die;
                        }
                        $expected_detached = parent_identity($detached);
                    }
                    $expected_parent = parent_identity($parent);
                    die "fixture bootstrap namespace failure\n";
                }};
                $options->{fail_at} = 'create' if $stage eq 'before_parent_cleanup';
                my $out = Loomy::Hooks::settings_update($r, $provider, 'ensure', $options);
                is($called, 1, "$provider $replacement replacement reaches $stage");
                ok(!$out->{ok} && !$out->{applied}, "$provider $replacement at $stage reports an unapplied failure");
                is_deeply(parent_identity($parent), $expected_parent, "$provider $replacement at $stage retains the replacement or nonempty parent inode, mode and owner");
                if ($replacement eq 'nonempty') {
                    is(bytes("$parent/sentinel"), 'KEEP_NONEMPTY_PARENT', "$provider $stage preserves the new nonempty parent contents");
                    is_deeply(temps($parent), [], "$provider $stage cleans only its own temporary in the nonempty parent");
                } else {
                    is_deeply(parent_identity($detached), $expected_detached, "$provider $stage preserves the detached original parent inode, mode and owner");
                    is_deeply(temps($detached), [], "$provider $stage cleans its own temporary in the detached parent");
                }
                is_deeply(manifest($outside), $outside_before, "$provider $replacement at $stage never changes the outside directory");
            }
        }
        my $busy_root = root("bootstrap-contender-$provider");
        my $busy_parent = parent_path($busy_root, $provider);
        pipe(my $ready, my $send_ready) or die;
        pipe(my $release, my $send_release) or die;
        my ($contender, $busy_before);
        my $busy = Loomy::Hooks::settings_update($busy_root, $provider, 'ensure', {test_hook => sub {
            return unless $_[0] eq 'after_parent_create';
            $contender = fork_child(sub {
                close $ready;
                close $send_release;
                sysopen my $lock, $busy_parent, O_RDONLY or die;
                flock($lock, LOCK_EX | LOCK_NB) or die;
                syswrite($send_ready, 'R') == 1 or die;
                receive($release);
                close $lock;
                close $send_ready;
                close $release;
            });
            close $send_ready;
            close $release;
            receive($ready) eq 'R' or die;
            $busy_before = manifest($busy_root);
            die "fixture failure while another writer owns the new parent lock\n";
        }});
        ok(!$busy->{ok} && !$busy->{applied}, "$provider bootstrap failure stays unapplied while another writer holds the new parent");
        is($busy->{code}, 'test_hook_failed', "$provider busy cleanup preserves the original failure diagnostic");
        is_deeply(manifest($busy_root), $busy_before, "$provider cleanup preserves the empty parent owned by a live competing writer");
        syswrite($send_release, 'G') == 1 or die;
        close $send_release;
        close $ready;
        reap($contender, "$provider new-parent lock contender");
        ok(Loomy::Hooks::settings_update($busy_root, $provider)->{ok}, "$provider retry repairs the preserved parent after contender release");
        my $applied_root = root("bootstrap-applied-$provider");
        my $applied = Loomy::Hooks::settings_update($applied_root, $provider, 'ensure', {fail_at => 'directory_sync'});
        ok(!$applied->{ok} && $applied->{applied} && $applied->{changed}, "$provider post-rename bootstrap failure reports applied state");
        is_deeply(decode_json(bytes(settings_path($applied_root, $provider))), shell_data($provider), "$provider post-rename failure preserves the populated new parent and settings");
    }
    for my $stage ('after_temp_create', 'after_print', 'after_flush', 'after_sync', 'after_chmod', 'after_close') {
        my $r = root("interrupted-$stage");
        seed($r, 'claude', {user => 'original'});
        my $before = manifest($r);
        my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', {test_hook => sub {
            die "fixture interrupted at $stage\n" if $_[0] eq $stage;
        }});
        ok(!$out->{ok} && !$out->{applied}, "$stage caught interruption is pre-rename");
        is_deeply(manifest($r), $before, "$stage caught interruption cleans all temporary state");
    }
    for my $interruption ('exception', 'TERM') {
        my $r = root("bootstrap-umask-$interruption");
        my $before = manifest($r);
        pipe(my $read, my $write) or die;
        my $pid = fork_child(sub {
            close $read;
            my $original_umask = umask(0027);
            my $called = 0;
            my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', {test_hook => sub {
                return unless $_[0] eq 'after_parent_umask';
                $called++;
                die "fixture bootstrap interruption\n" if $interruption eq 'exception';
                kill('TERM', $$) == 1 or die 'fixture self-TERM failed';
            }});
            my $restored = umask;
            umask($original_umask);
            my $facts = ($called == 1 ? 'C' : 'E')
                . (!$out->{ok} && !$out->{applied} && !$out->{changed} ? 'R' : 'E')
                . ($restored == 0027 ? 'U' : 'E');
            syswrite($write, $facts) == 3 or die;
            close $write;
        });
        close $write;
        is(receive($read), 'C', "$interruption reaches the temporary bootstrap umask boundary");
        is(receive($read), 'R', "$interruption during bootstrap reports unapplied failure");
        is(receive($read), 'U', "$interruption during bootstrap restores the caller umask");
        close $read;
        reap($pid, "$interruption bootstrap writer");
        is_deeply(manifest($r), $before, "$interruption during bootstrap creates no parent or temporary");
    }
    for my $boundary ('directory_sync', 'after_rename') {
        my $r = root("postrename-$boundary");
        my $path = seed($r, 'claude', {user => 'retained'});
        my $options = $boundary eq 'directory_sync' ? {fail_at => $boundary} : {test_hook => sub { die "fixture post-rename interruption\n" if $_[0] eq $boundary }};
        my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', $options);
        ok(!$out->{ok} && $out->{applied} && $out->{changed}, "$boundary failure reports applied update with uncertainty");
        my $current = decode_json(bytes($path));
        is($current->{user}, 'retained', "$boundary failure retains custom data in the applied file");
        ok(exists($current->{hooks}), "$boundary failure does not pretend original file is untouched");
        is_deeply(temps(parent_path($r, 'claude')), [], "$boundary failure leaves no temporary");
        $current->{laterEdit} = 'must survive retry';
        put($path, $json->encode($current));
        my $retry = Loomy::Hooks::settings_update($r, 'claude', 'shell');
        ok($retry->{ok} && !$retry->{changed}, "$boundary retry uses current JSON without stale backup restoration");
        is(decode_json(bytes($path))->{laterEdit}, 'must survive retry', "$boundary retry retains intervening user edit");
    }
    my $r = root('term-interruption');
    seed($r, 'claude', {user => 'original'});
    my $before = manifest($r);
    pipe(my $ready, my $send_ready) or die;
    pipe(my $hold, my $send_hold) or die;
    my $pid = fork_child(sub {
        close $ready;
        close $send_hold;
        my $out = Loomy::Hooks::settings_update($r, 'claude', 'ensure', {test_hook => sub {
            return unless $_[0] eq 'after_temp_create';
            syswrite($send_ready, 'R') == 1 or die;
            receive($hold);
        }});
        die 'TERM interruption was not reported before rename' if $out->{ok} || $out->{applied};
        close $send_ready;
        close $hold;
    });
    close $send_ready;
    close $hold;
    is(receive($ready), 'R', 'own child reaches a real TERM interruption boundary');
    is(kill('TERM', $pid), 1, 'TERM is delivered only to the fixture child');
    reap($pid, 'interrupted settings writer');
    close $ready;
    close $send_hold;
    is_deeply(manifest($r), $before, 'real TERM interruption cleans temporary and preserves original');
    my $partial = root('partial-providers');
    my $claude_path = seed($partial, 'claude', {user => 'claude'});
    my $codex_path = seed($partial, 'codex', 'INVALID_CODEX_JSON');
    my $first = Loomy::Hooks::settings_update($partial, 'claude');
    my $second = Loomy::Hooks::settings_update($partial, 'codex');
    ok($first->{ok} && !$second->{ok}, 'provider files report independent partial completion');
    is(bytes($codex_path), 'INVALID_CODEX_JSON', 'successful Claude repair never replaces failed Codex input');
    my $claude_before = [bytes($claude_path), identity($claude_path)];
    put($codex_path, '{}');
    ok(Loomy::Hooks::settings_update($partial, 'codex')->{ok}, 'failed provider can be repaired after input correction');
    my $retry = Loomy::Hooks::settings_update($partial, 'claude');
    ok($retry->{ok} && !$retry->{changed}, 'already completed provider retry is a no-op');
    is_deeply([bytes($claude_path), identity($claude_path)], $claude_before, 'partial retry retains successful provider bytes/inode/mode');
};

subtest 'H1 sourced shell compatibility wrappers survive cwd changes' => sub {
    my $r = root('wrapper project with spaces');
    make_path("$r/nested", {mode => 0700});
    my $status = system('bash', '-c', q{
        set -euo pipefail
        cd "$1"
        source scripts/lib/hooks.sh
        cd "$2/nested"
        loomy_hooks_inspect "$2" claude >"$3/wrapper-inspect.json"
        [[ ! -e "$2/.claude" ]]
        loomy_claude_hooks_merge "$2" >"$3/wrapper-merge-output"
        loomy_codex_hooks_merge "$2" >>"$3/wrapper-merge-output"
        loomy_hooks_repair "$2" claude --shell >"$3/wrapper-repair.json"
    }, 'hooks-wrapper-smoke', $repo, $r, $work);
    is($status, 0, 'relative source and later cwd changes retain the installed Perl helper');
    return unless $status == 0;
    is(bytes("$work/wrapper-merge-output"), '', 'legacy Claude and new Codex merge APIs are quiet on success');
    is(decode_json(bytes("$work/wrapper-inspect.json"))->{facts}{state}, 'missing', 'inspection wrapper returns typed missing facts without bootstrap');
    for my $provider (qw(claude codex)) {
        is_deeply(decode_json(bytes(settings_path($r, $provider))), shell_data($provider), "$provider compatibility merge writes exact shared shell catalog");
    }
    my $repair = decode_json(bytes("$work/wrapper-repair.json"));
    ok($repair->{ok} && !$repair->{changed} && !$repair->{applied}, 'explicit shell repair wrapper returns sanitized no-op result');
    for my $provider (qw(claude codex)) {
        my $bad = root("wrapper-unsupported-number-$provider");
        seed($bad, $provider, '{"permissions":{"deny":["PRIVATE_WRAPPER_SENTINEL"]},"value":123456789012345678901234567890}');
        my $before = manifest($bad);
        my $output = "$work/wrapper-unsupported-$provider.json";
        my $errors = "$work/wrapper-unsupported-$provider.stderr";
        my $refused = system('bash', '-c', q{
            set -euo pipefail
            cd "$1"
            source scripts/lib/hooks.sh
            cd "$2"
            loomy_hooks_repair "$2" "$3" --shell >"$4" 2>"$5"
        }, 'hooks-wrapper-refusal', $repo, $bad, $provider, $output, $errors);
        is($refused, 256, "$provider sourced repair wrapper propagates the nonzero engine refusal status");
        my $raw = bytes($output);
        my $result = eval { decode_json($raw) };
        ok(!$@ && ref($result) eq 'HASH', "$provider sourced refusal stays valid typed JSON");
        $result //= {};
        is($result->{code}, 'unsupported_number', "$provider sourced refusal preserves the public numeric-fidelity code");
        ok(!$result->{ok} && !$result->{applied} && (!$result->{facts} || !$result->{facts}{ready}), "$provider sourced refusal never reports ready or applied");
        unlike($raw . bytes($errors), qr/PRIVATE_WRAPPER_SENTINEL|12345678901234567890/, "$provider sourced refusal does not disclose custom settings bytes");
        is_deeply(manifest($bad), $before, "$provider sourced refusal preserves exact original settings and namespace");
    }
};

done_testing();
