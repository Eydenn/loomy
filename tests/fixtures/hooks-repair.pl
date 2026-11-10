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

# Ownership bytes come from the documented generated templates, independently
# of the engine's serializer/catalog. Historical filename substitutions are not
# trusted without an approved known-generated historical descriptor.
my @claude = (
    ['SessionStart', 'start', 20], ['SessionEnd', 'end', 3],
    ['Stop', 'stop', 10], ['SubagentStop', 'subagent', 10],
    ['UserPromptSubmit', 'prompt', 5], ['PreToolUse', 'agent-start', 5, 'Agent|Task'],
    ['PostToolUse', 'agent-return', 5, 'Agent|Task'], ['PostToolUseFailure', 'agent-failure', 5, 'Agent|Task'],
);
my @codex = (['SessionStart', 'start', 20], ['SessionEnd', 'end', 3]);
my $status_command = q{sh -c 'd=${CLAUDE_PROJECT_DIR:-$PWD}; while [ "$d" != / ] && [ ! -f "$d/.loomy/scripts/loomy-statusline.sh" ]; do d=$(dirname "$d"); done; [ -f "$d/.loomy/scripts/loomy-statusline.sh" ] && exec bash "$d/.loomy/scripts/loomy-statusline.sh"'};
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
            my $old = $hook->{command} =~ s/loomy-context\.sh/ai-context.sh/r;
            is(Loomy::Hooks::classify_command($provider, $event, {type => 'command', command => $old}, \@descriptors), 'custom', "$provider/$event unsupported historical filename stays custom");
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
    my $null = shell_data('claude');
    $null->{statusLine} = undef;
    my $out = repaired('claude', $null);
    ok(!$out->{changed} && exists($out->{data}{statusLine}) && !defined($out->{data}{statusLine}), 'explicit null statusLine is preserved');
    is($out->{facts}{status_line}{state}, 'custom', 'explicit null statusLine is a typed custom choice');
    my $padding = shell_data('claude');
    $padding->{statusLine}{padding} = 12;
    $padding->{statusLine}{extra} = {keep => 1};
    my $native = Loomy::Hooks::fixture_native_transform('claude', $padding, $descriptor, \@descriptors);
    is_deeply(repaired('claude', $native->{data}, 'shell')->{data}, $padding, 'statusLine padding and unknown fields survive both transforms');
    my $historical = $status_command =~ s/loomy-statusline\.sh/ai-statusline.sh/gr;
    is(Loomy::Hooks::classify_command('claude', 'statusLine', {type => 'command', command => $historical}), 'custom', 'unsupported historical statusLine stays custom');
    for my $bad ([], 'scalar', {hooks => []}, {hooks => undef}, {hooks => {SessionStart => {}}}, {hooks => {SessionStart => [undef]}}, {hooks => {SessionStart => [{hooks => {}}]}}, {hooks => {SessionStart => [{hooks => [undef]}]}}, {statusLine => []}) {
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
};

done_testing();
