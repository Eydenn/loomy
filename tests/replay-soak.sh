#!/usr/bin/env bash
# Two-minute accelerated structural replay, using only private PTY/tmux and CLI stubs.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-replay-soak.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_JOURNAL=1 LOOMY_JOURNAL_TASKS=1
unset LOOMY_NATIVE_NOW LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT LOOMY_WATCH_TOOL
mkdir -p "$HOME" "$XDG_CONFIG_HOME/loomy"
if [[ "${LOOMY_TEST_NATIVE_PTY:-1}" == 0 ]]; then
  perl - "$REPO" "$WORK" <<'PERL'
use strict;
use warnings;
use JSON::PP qw(decode_json);
local $ENV{LOOMY_FIXTURE_CONTENT}='structural';
my ($repo,$work)=@ARGV; require "$repo/scripts/lib/claude-native.pl";
my $root="$work/project"; my $journal="$root/.loomy/logs/events.jsonl";
sub fixture {system($^X,"$repo/tests/fixtures/replay-events.pl",$work,@_)==0 or die 'fixture failed'}
sub poll {for (1..3) {Loomy::CodexNative::poll($root,"$work/codex/sessions"); Loomy::ClaudeNative::poll($root,"$work/claude/projects")}}
sub history {
 my @events; for my $path ((sort glob "$root/.loomy/logs/archive/events-*.jsonl"),$journal) {
  open my $f,'<',$path or die; push @events,map {decode_json($_)} <$f>;
 }
 return @events;
}
fixture('seed'); poll();
Loomy::LiveState::journal_append($journal,{type=>'usage',scope=>'lead',tool=>'claude',model=>'claude-sonnet-5-5',cost_usd=>0.25});
for my $trial (1..20) {
 fixture('start',$trial); poll();
 if ($trial==10) {
  Loomy::LiveState::atomic_file("$root/.loomy/logs/month","2000-01\n");
  my $lock=Loomy::LiveState::journal_lock("$root/.loomy/logs") or die;
  Loomy::LiveState::journal_rotate($journal);
 }
 fixture('end',$trial); poll();
}
my @events=history();
my @starts=grep {$_->{type} eq 'delegation_start' && !$_->{snapshot}} @events;
my @ends=grep {$_->{type} eq 'delegation' && !$_->{snapshot}} @events;
die 'replay start/end count drift' unless @starts==120 && @ends==120;
my @usage=grep {$_->{type} eq 'usage'} @events; die 'replay usage/cost drift' unless @usage==1 && $usage[0]{cost_usd}==0.25;
die 'unprojected replay event' if grep {($_->{content_policy}//'') ne 'structural-v1' || !exists($_->{policy_generation})} @events;
die 'content escaped replay writer' if grep {exists($_->{task}) || exists($_->{why}) || exists($_->{cwd_relative})} @events;
my $before=Loomy::LiveState::file_signature($journal);
for my $tool (qw(claude codex)) {
 system($^X,"$repo/scripts/lib/$tool-native.pl",$root,"$work/$tool/".($tool eq 'claude' ? 'projects' : 'sessions'))==0 or die 'restart failed';
}
poll(); die 'replay re-emitted lifecycle/context after restart' unless Loomy::LiveState::file_signature($journal) eq $before;
print "PASS replay: 20 cycles, 120 starts/ends, monthly rotation, one usage/cost, cold restart without re-emission\n";
PERL
  printf 'SKIP replay soak PTY rendering (LOOMY_TEST_NATIVE_PTY=0)\n'
  exit 0
fi
for dependency in expect tmux; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf 'SKIP replay soak PTY (%s missing)\n' "$dependency"
    exit 0
  fi
done
printf 'notify=no\nwatch_view=tree\nplan_claude=api\nplan_codex=api\n' >"$XDG_CONFIG_HOME/loomy/config"
expect "$REPO/tests/fixtures/replay-watch.exp" "$REPO" "$WORK"
# The guard also checks every private socket and leftover process on EXIT.
test_guard_gate
