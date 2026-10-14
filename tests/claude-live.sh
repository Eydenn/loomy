#!/usr/bin/env bash
# S2 CLI/app foreground/background cells and content-free hookless transcript fallback.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=fixtures/watchdog.sh
source "$REPO/tests/fixtures/watchdog.sh"
WORK="$(mktemp -d "/tmp/loomy-claude-live.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
trap 'exit 143' TERM HUP
trap 'exit 130' INT
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CLAUDE_CONFIG_DIR="$WORK/claude" CODEX_HOME="$WORK/codex"
export LOOMY_NATIVE_NOW=1791853207 LOOMY_HOME="$REPO" NO_COLOR=1 LOOMY_LANG=en LOOMY_UI_LANG=en LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1
export LOOMY_FIXTURE_NOW=1791853200 PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
unset LOOMY_DELEGATION LOOMY_PROJECT_ROOT AI_ROUTE_ENV LOOMY_WATCH_TOOL LOOMY_JOURNAL LOOMY_JOURNAL_TASKS LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
PASS=0
check() { local title="$1"; shift; if test_step "$@"; then PASS=$((PASS+1)); printf 'PASS %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
fixture() { perl "$REPO/tests/fixtures/claude-native.pl" "$1" "$ROOT" "$CLAUDE_CONFIG_DIR/projects" "$SURFACE" "$BG" "${2:-1}"; }
poll() { perl "$REPO/scripts/lib/claude-native.pl" "$ROOT" "$CLAUDE_CONFIG_DIR/projects"; }
assert_cell() {
  perl -MJSON::PP -e '
    my ($module,$root,$sid,$state)=@ARGV; require $module;
    my $s=Loomy::LiveState->new; $s->read_journal("$root/.loomy/logs/events.jsonl");
    my @r=$s->projections($ENV{LOOMY_NATIVE_NOW});
    die "lead group absent" unless grep {/\|G\|claude:\Q$sid\E\|.*\|live\|/} @r;
    my @a=grep {/^N\|A\|claude:\Q$sid\E:/} @r;
    die "duplicate/missing agent @a" unless @a==1;
    die "agent state @a" unless $a[0]=~/\|\Q$state\E\|/;
  ' "$REPO/scripts/lib/live-state.pl" "$ROOT" "$SURFACE-lead" "$1"
}
for SURFACE in cli app; do
  for BG in 0 1; do
    ROOT="$WORK/$SURFACE-$BG"; fixture seed; fixture hooks; poll
    check "$SURFACE background=$BG running and one group" assert_cell running
    check "$SURFACE foreground waits and background keeps the lead running" perl -MJSON::PP -e '
      my ($path,$bg)=@ARGV; open my $f,"<",$path or die; my @e=map {decode_json($_)} <$f>;
      my @s=grep {$_->{type} eq "session_observed"} @e; die unless $s[-1]{state} eq ($bg ? "running" : "waiting");
    ' "$ROOT/.loomy/logs/events.jsonl" "$BG"
    fixture return; fixture hook-return; poll
    if [[ "$BG" == 1 ]]; then check "$SURFACE async return leaves the agent running" assert_cell running; fi
    if [[ "$BG" == 0 ]]; then check "$SURFACE async foreground return leaves the agent running before notification" assert_cell running; fi
    fixture stop; fixture hook-stop; poll
    check "$SURFACE background=$BG done with one row" assert_cell 'done'
    cp "$ROOT/.loomy/logs/events.jsonl" "$ROOT/before"; poll
    check "$SURFACE background=$BG replay writes nothing" cmp "$ROOT/before" "$ROOT/.loomy/logs/events.jsonl"
    check "$SURFACE background=$BG one lifecycle and one cost" perl -MJSON::PP -e '
      my @e=map {decode_json($_)} <>; my @n=grep {($_->{bridge}//"") eq "claude-native"} @e;
      die unless (grep {$_->{type} eq "delegation_start"} @n)==1 && (grep {$_->{type} eq "delegation"} @n)==1;
      my @u=grep {$_->{type} eq "usage"} @e; die unless @u==1 && $u[0]{cost_usd}==0.25;
    ' "$ROOT/.loomy/logs/events.jsonl"
    check "$SURFACE background=$BG journal shows one terminal, no duplicate hook row" bash -c '
      source "$1/scripts/lib/journal.sh"; ai_journal_display_events "$2" >"$3";
      test "$(grep -c "|developer|" "$3")" = 1 && grep -q "|developer|done|" "$3"
    ' _ "$REPO" "$ROOT/.loomy/logs/events.jsonl" "$ROOT/display"
  done
done
ROOT="$WORK/stop-hook"; fixture seed
check 'actual Stop hook marks only Claude idle and leaves Codex ownership untouched' bash -c '
  printf "%s" "{\"session_id\":\"idle-claude\"}" | bash "$1/scripts/loomy-context.sh" --root "$2" --hook stop
  printf "%s" "{\"session_id\":\"idle-codex\"}" | bash "$1/scripts/loomy-context.sh" --root "$2" --hook stop --tool codex
  perl -MJSON::PP -e '\''my @e=map {decode_json($_)} <>; die unless @e==1 && $e[0]{type} eq "session_activity" && $e[0]{tool} eq "claude" && $e[0]{session} eq "idle-claude" && $e[0]{state} eq "idle"'\'' "$2/.loomy/logs/events.jsonl"
' _ "$REPO" "$ROOT"
check 'source boundaries, aliases, hook-only states, bounded replay and privacy regressions' perl "$REPO/tests/fixtures/claude-live-regressions.pl" "$REPO" "$WORK/regressions"
SURFACE=app; BG=1; ROOT="$WORK/hookless"; fixture seed; poll
# A child discovered before its return initially has a provisional identity.
fixture return; poll
check 'hookless app aliases transcript child to the exact call without duplicate rows' assert_cell running
fixture stop; poll
check 'hookless app task-notification completes the row' assert_cell 'done'
# A just-finished subagent must read done within one second of its task-notification line being written.
ROOT="$WORK/notify-latency"; fixture seed; poll; fixture return; poll
latency_start="$(perl -MTime::HiRes=time -e 'print time')"; fixture stop; poll
latency_ms="$(perl -MTime::HiRes=time -e 'printf "%d", (time-$ARGV[0])*1000' "$latency_start")"
check "task-notification shows the agent done within one second of being written (${latency_ms} ms)" assert_cell done
check 'notification latency bound' test "$latency_ms" -lt 1000
check 'hookless terminal preserves source milliseconds and duration, costs stay unknown' perl -MJSON::PP -e '
 my @e=map {decode_json($_)} <>; my @end=grep {$_->{type} eq "delegation" && ($_->{id}//"") eq "cl:app-lead:call1"} @e;
 die unless @end==1 && $end[0]{ts} eq "2026-10-13T01:00:04.250Z" && $end[0]{duration_s}==3;
 die if grep {$_->{type} eq "usage" || ($_->{cost_usd}//0)>0} @e;
' "$ROOT/.loomy/logs/events.jsonl"
ROOT="$WORK/reverse"; fixture seed; fixture hooks; fixture hook-stop; poll
fixture return; fixture hook-return; poll
check 'out-of-order stop before async return completes the right agent once' assert_cell 'done'
ROOT="$WORK/privacy"; fixture seed; fixture hooks; LOOMY_JOURNAL_TASKS=0 poll
check 'new adapter never copies prompts, arguments, file contents or private task labels' perl -0777 -e '
 for (@ARGV) {open my $f,"<",$_ or die; my $s=do{local $/;<$f>}; die unless ((stat($f))[2]&0777)==0600; die if $s=~/PRIVATE_|Implement fixture/}
' "$ROOT/.loomy/logs/claude-native.idx"
# Raw hook excerpts were authorized earlier; only new normalized events must respect the opt-out.
check 'opt-out normalized projections have empty tasks' perl -MJSON::PP -e 'for (map {decode_json($_)} <>) {die if ($_->{bridge}//"") eq "claude-native" && ($_->{task}//"") ne ""}' "$ROOT/.loomy/logs/events.jsonl"
check 'journal and checkpoint remain private and contain no transcript content' perl -0777 -e 'for (@ARGV){open my $f,"<",$_ or die;my $s=do{local $/;<$f>};die unless ((stat($f))[2]&0777)==0600;die if $s=~/PRIVATE_/}' "$ROOT/.loomy/logs/events.jsonl" "$ROOT/.loomy/logs/claude-native.idx"
ROOT="$WORK/multi"; fixture seed; fixture return
perl "$REPO/tests/fixtures/codex-native.pl" compact-seed "$ROOT" "$CODEX_HOME/sessions" "$$"
perl "$REPO/tests/fixtures/codex-native.pl" ownerless-cli "$ROOT" "$CODEX_HOME/sessions" "$$"
poll
perl "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"
check 'simultaneous Claude and Codex leads keep separate live groups' perl -e '
 require $ARGV[0];my $s=Loomy::LiveState->new;$s->read_journal($ARGV[1]);my @r=$s->projections($ENV{LOOMY_NATIVE_NOW});
 die unless grep {/^N\|G\|claude:app-lead\|.*\|live\|/} @r;
 die unless grep {/^N\|G\|codex:.*\|live\|/} @r;
' "$REPO/scripts/lib/live-state.pl" "$ROOT/.loomy/logs/events.jsonl"
ROOT="$WORK/frame"; fixture seed; fixture return; poll
for view in tree list; do
 check "$view displays hookless Claude lead and its child" bash -c '
 ROOT=$2
 source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/phases.sh";
 source "$1/scripts/loomy-tree.sh" --library; loomy_live_init; loomy_live_poll "$2/.loomy/logs/events.jsonl";
 LV_NOW=$LOOMY_NATIVE_NOW; loomy_live_states; loomy_live_metadata; loomy_live_header;
 LOOMY_NO_HEADER=1 LOOMY_WATCH_VIEW=$3 loomy_live_render >"$2/frame-$3";
 grep -q "claude app app-lead" "$2/frame-$3" && grep -q "developer.*running" "$2/frame-$3"
 ' _ "$REPO" "$ROOT" "$view"
done
check 'zero source/journal reads and no writes on warm idle, bounded signature CPU' perl -MTime::HiRes=clock_gettime,CLOCK_PROCESS_CPUTIME_ID -e '
 my ($module,$root,$projects)=@ARGV;require $module;
 Loomy::ClaudeNative::poll($root,$projects) for 1..3;
 my $idx="$root/.loomy/logs/claude-native.idx";my $journal="$root/.loomy/logs/events.jsonl";
 my $sig=Loomy::ClaudeNative::signature($idx);my $size=-s $journal;
 Loomy::ClaudeNative::watch_changed($root,$projects);
 my $t=clock_gettime(CLOCK_PROCESS_CPUTIME_ID);
 for (1..100) {die "idle change" if Loomy::ClaudeNative::watch_changed($root,$projects)}
 my $elapsed=clock_gettime(CLOCK_PROCESS_CPUTIME_ID)-$t;
 die "idle probe CPU exceeds 3%" if $elapsed>0.6;
 {no warnings "redefine";local *Loomy::CodexNative::open_read=sub {die "idle read"};Loomy::ClaudeNative::poll($root,$projects)}
 die "idle write" unless Loomy::ClaudeNative::signature($idx) eq $sig && (-s $journal)==$size;
 printf "100 idle probes %.3f ms (20s polling equivalent)\n",$elapsed*1000;
' "$REPO/scripts/lib/claude-native.pl" "$ROOT" "$CLAUDE_CONFIG_DIR/projects"
ROOT="$WORK/detection-cost"; fixture seed; fixture return
check 'forty transcript/hook detection paths stay below 80 ms CPU with one retry' perl "$REPO/tests/fixtures/claude-live-cost.pl" "$REPO" "$ROOT" "$CLAUDE_CONFIG_DIR/projects"
ROOT="$WORK/latency"; fixture seed; fixture return
check 'forty transcript/hook watch frames complete within five seconds with one retry' perl "$REPO/tests/fixtures/claude-live-latency.pl" "$REPO" "$ROOT" "$CLAUDE_CONFIG_DIR/projects"
for finding in F1 F2 F3 F5 F6 F7 F8 F9 F10 F11 F12 F14; do
 check "$finding review regression" perl "$REPO/tests/fixtures/claude-findings.pl" "$REPO" "$WORK/findings" "$finding"
done
for finding in R1 R2 R3 R4 R6 R7 R5 R8 R9 R10; do
 check "$finding Round 2 regression" perl "$REPO/tests/fixtures/claude-round2.pl" "$REPO" "$WORK/round2" "$finding"
done
for finding in N1 N2 N3 N3-shot N4; do
 check "$finding Round 3 regression" perl "$REPO/tests/fixtures/claude-round3.pl" "$REPO" "$WORK/round3" "$finding"
done
if [[ "${LOOMY_TEST_NATIVE_PTY:-1}" == 0 ]]; then
 printf 'SKIP tests/fixtures/claude-live-watch.exp (run on Mac PTY)\n'
else check 'Claude CLI/app foreground/background PTY frames' expect "$REPO/tests/fixtures/claude-live-watch.exp"; fi
printf '%s S2 Claude live checks passed\n' "$PASS"
