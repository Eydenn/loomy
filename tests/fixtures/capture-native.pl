# Structural native watch fixture. It contains synthetic identities and task labels only.
use strict;
use warnings;
use JSON::PP qw(encode_json);
use POSIX qw(strftime);
use File::Path qw(make_path);

my ($action, $root, $pid) = @ARGV;
die "usage: capture-native.pl <seed|finish> <project> <owner-pid>\n"
    unless ($action // '') =~ /^(seed|finish)$/ && $root && ($pid // '') =~ /^\d+$/;

my $owner = 'demo1234';
my $session_key = "claude:$owner";
our $FIXTURE_NOW = time;
sub ts { strftime('%Y-%m-%dT%H:%M:%SZ', gmtime($FIXTURE_NOW + $_[0])) }
sub append_rows {
    my ($path, $truncate, @rows) = @_;
    open my $journal, ($truncate ? '>' : '>>'), $path or die "$path: $!";
    print {$journal} encode_json($_), "\n" for @rows;
    close $journal or die "$path: $!";
}
sub turn {
    my ($n, $age, $role, $task) = @_;
    my $id = sprintf '00000000-0000-4000-8000-%012d', $n;
    return {
        ts => ts(-$age), bridge => 'claude-native', schema => 2,
        tool => 'claude', family => 'claude', session => $owner,
        session_key => $session_key, id => $id, turn_id => $id,
        agent_id => sprintf('demo-agent-%02d', $n), parent_agent_id => $session_key,
        role => $role, task => $task, model => 'claude-sonnet-5-5', effort => 'medium',
        cost_in => 'usage', cost_usd => 0,
    };
}

my $journal = "$root/.loomy/logs/events.jsonl";
if ($action eq 'seed') {
    make_path("$root/.loomy/logs");
    my $state_path = "$root/.loomy/state";
    my @state_lines;
    if (-f $state_path) {
        open my $state_in, '<', $state_path or die "$state_path: $!";
        @state_lines = grep { $_ ne '' && !/^phase=/ } split /\n/, do { local $/; <$state_in> };
        close $state_in or die "$state_path: $!";
    }
    open my $state_out, '>', $state_path or die "$state_path: $!";
    print {$state_out} "phase=build\n";
    print {$state_out} join("\n", @state_lines), "\n" if @state_lines;
    close $state_out or die "$state_path: $!";
    my @rows = (
        { ts => ts(-180), type => 'session', event => 'start', tool => 'claude', family => 'claude',
          session => $owner, pid => 0 + $pid, model => 'claude-opus-5-5', effort => 'high' },
        { ts => ts(0), type => 'session_observed', bridge => 'claude-native', schema => 2,
          tool => 'claude', family => 'claude', session => $owner, session_key => $session_key,
          owner_pid => 0 + $pid, source_active => JSON::PP::true, surface => 'cli', state => 'running',
          cwd_relative => '.', evidence => 'source lease' },
        { ts => ts(0), type => 'session_context', bridge => 'claude-native', schema => 2,
          tool => 'claude', family => 'claude', session => $owner, session_key => $session_key,
          scope => 'lead', model => 'claude-opus-5-5', effort => 'high' },
    );

    for my $spec (
        [1, 30, 'developer', 'Plan routes'],
        [2, 18, 'executor', 'Update filters'],
        [3, 8, 'reviewer', 'Review navigation'],
    ) {
        my $row = turn(@$spec);
        push @rows, { %$row, type => 'delegation_start', background => JSON::PP::true };
    }
    my $recent = turn(4, 120, 'architect', 'Earlier plan');
    push @rows,
        { %$recent, type => 'delegation_start', background => JSON::PP::true },
        { %$recent, ts => ts(-108), type => 'delegation', status => 'ok', outcome => 'done', duration_s => 12 };

    for my $spec (
        [5, 2400, 'reviewer', 'Archive check'],
        [6, 2500, 'documenter', 'Archive notes'],
    ) {
        my $row = turn(@$spec);
        push @rows,
            { %$row, type => 'delegation_start', background => JSON::PP::true },
            { %$row, ts => ts(-$spec->[1] + 12), type => 'delegation', status => 'ok', outcome => 'done', duration_s => 12 };
    }
    for my $spec (
        [7, 2400, 'explorer', 'Stale source'],
        [8, 2500, 'security', 'Expired source'],
    ) {
        my $row = turn(@$spec);
        push @rows, { %$row, type => 'delegation_start', background => JSON::PP::true };
    }
    append_rows($journal, 1, @rows);
} else {
    my $row = turn(3, 0, 'reviewer', 'Review navigation');
    append_rows($journal, 0, {
        %$row, ts => ts(0), type => 'delegation', status => 'ok', outcome => 'partial', duration_s => 8,
    });
}
