#!/usr/bin/env bash
# Regression fixtures for defects seen on real, long-lived project data in the native watch view.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "/tmp/loomy-real-data.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export LOOMY_HOME="$REPO" LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0
export LOOMY_FIXTURE_NOW=1791853200 LOOMY_NATIVE_NOW=1791853200
unset LOOMY_WATCH_TOOL AI_ROUTE_ENV LOOMY_JOURNAL LOOMY_JOURNAL_TASKS LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT LOOMY_WATCH_ID
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR/projects"
ROOT="$WORK/project"; PASS=0
check() { local title="$1"; shift; if "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
perl "$REPO/tests/fixtures/watch-real-data.pl" "$ROOT"
frame() { COLUMNS="$1" LINES="$2" LOOMY_WATCH_BODY_HEIGHT="$3" bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once 2>&1; }
frame 150 80 80 >"$WORK/full"
frame 150 20 9 >"$WORK/small"

# Reducer: a pre-schema running turn of a session without a live launcher ends as interrupted.
check 'legacy bridge turn whose launcher is gone ends interrupted, a finished one stays done' perl -e '
  my $out=`perl "$ARGV[0]/scripts/lib/live-state.pl" "$ARGV[1]" "" 2>/dev/null`;
  die "legacy run still running\n$out" if $out =~ /^N\|A\|codex:dlegacy001\|[^|]*\|[^|]*\|running\|/m;
  die "legacy run not interrupted\n$out" unless $out =~ /^N\|A\|codex:dlegacy001\|[^|]*\|[^|]*\|interrupted\|/m;
  die "finished legacy run changed" unless $out =~ /^N\|A\|codex:dlegacy002\|[^|]*\|[^|]*\|done\|/m;
' "$REPO" "$ROOT"
check 'a legacy turn with a live launcher and recent start keeps running' perl -e '
  require "$ARGV[0]/scripts/lib/live-state.pl"; my $s=Loomy::LiveState->new; my $now=1791853200;
  $s->consume({type=>"delegation_start",id=>"dlive",pid=>0+$ARGV[1],bridge=>"codex",family=>"codex",ts=>"2026-10-13T00:59:00Z"});
  my @r=$s->projections($now);
  die join("\n",@r) unless grep {/^N\|A\|codex:dlive\|[^|]*\|[^|]*\|running\|/} @r;
' "$REPO" "$$"

# One session, one live group: the live heading appears once; any repeat above the recap is marked as such.
check 'live Claude lead heading appears once above the recap and carries no lease jargon' perl -0777 -e '
  my $s=<>; my @h=grep {/^┏━ claude app applead1/} split /\n/,$s; die "headings: @h" unless @h==2 && $h[0]=~/ · live / && $h[0]!~/recap/ && $h[1]=~/ recap/;
  die "jargon" if $s=~/source lease|launcher|catching up/;
' "$WORK/full"
check 'compact frame repeats the live heading only as a recap heading' perl -0777 -e '
  my $s=<>; my @h=grep {/^┏━ claude app applead1/} split /\n/,$s;
  die "no compaction:\n$s" unless @h==2; die "not marked: @h" unless $h[0]!~/recap/ && $h[1]=~/ recap/;
' "$WORK/small"
# Stale sessions: nothing running, nothing empty.
check 'stale sessions with no agent are not shown, even in the recap' perl -0777 -e '
  my $s=<>; die "empty stale group shown:\n$s" if $s=~/4194001|emptyle/;
  my @g=grep {/^┏━/} split /\n/,$s; die "group count: @g" unless @g==4;
  die "empty group body" if $s=~/^┏━[^\n]*\n┗━/m;
' "$WORK/full"
check 'stale groups never appear in the live block of a compact frame' perl -0777 -e '
  my $s=<>; my ($live)=$s=~/^(.*?)(?=^┏━ claude app applead1[^\n]* recap)/ms; $live//=$s;
  die "stale group above the recap:\n$live" if $live=~/stale/;
' "$WORK/small"
check 'no row of a stale session is running; contradictory catch-up wording is gone' perl -0777 -e '
  my $s=<>; my $in=0; for my $l (split /\n/,$s) {
    if ($l=~/^┏━/) { $in=$l=~/stale/ ? 1 : 0 }
    die "stale row running: $l" if $in && $l=~/\brunning\b/;
  }
  die "catching up on stale" if $s=~/stale[^\n]*catching up/;
' "$WORK/full"
check 'the never-ended legacy run shows the interrupted glyph' grep -q '⊘ interrupted' "$WORK/full"
# Labels.
check 'routing legend names each family once and each model once (alias folded into the id)' perl -0777 -e '
  my $s=<>; my @l=grep {/^  LOOMY ·/} split /\n/,$s;
  die "legend: @l" unless @l==1 && $l[0] eq "  LOOMY · claude: sonnet-5-5, haiku, opus-5-5";
' "$WORK/full"
check 'turn rows never pair a done glyph with a contradicting or meaningless outcome word' perl -0777 -e '
  my $s=<>; die "contradiction" if $s=~/✓ done · (?:blocked|partial|unknown)/ || $s=~/(?:failed|interrupted) · unknown/;
  die "blocked glyph" unless $s=~/Beta review[^\n]*■ blocked/; die "partial glyph" unless $s=~/Gamma review[^\n]*△ partial/;
  die "done" unless $s=~/Alpha review[^\n]* ✓ done · 1 turn · /; die "plural" if $s=~/\b1 turns\b/;
  die "unknown effort mark" if $s=~/ \? (?:running|unknown|✓)/;
' "$WORK/full"
check 'the running child is counted and shown running' perl -0777 -e '
  my $s=<>; die unless $s=~/^2 running ·/m && $s=~/Delta review[^\n]* running · /;
' "$WORK/full"
check 'a child silent past its lease is lost: folded in the live block, listed in the recap with its last evidence' perl -0777 -e '
  my $s=<>; my ($live,$recap)=$s=~/^(.*?)(?=^┏━ claude app applead1[^\n]* recap)(.*)$/ms; die "no recap:\n$s" unless defined $recap;
  die "lost row in the live block:\n$live" if $live=~/! lost|call5/;
  die "no fold line:\n$live" unless $live=~/^  \+2 earlier · 1 lost$/m;
  die "lost row missing from the recap" unless $recap=~/^  ┣━ agent d1:call5 [^\n]*! lost · 2 h 00$/m && $recap=~/┗━ turn d1:call5 ! lost · 2 h 00$/m;
  die "lost child shown unknown or running" if $s=~/call5[^\n]*(?:unknown|running)/;
' "$WORK/full"
check 'live block order: running newest first, then recently ended newest first; nothing older' perl -0777 -e '
  my $s=<>; my ($live)=$s=~/^(.*?)(?=^┏━ claude app applead1[^\n]* recap)/ms;
  my @r=$live=~/^  ┣━ (\S+)/mg; my $got=join ",",@r;
  die "order: $got" unless $got eq "Delta,Epsilon,Gamma,Beta,Alpha";
  die "old finished row above the recap" if $live=~/Old finished/;
' "$WORK/full"
check 'the recap lists finished agents newest first (folded rows included), then the active ones' perl -0777 -e '
  my $s=<>; my ($recap)=$s=~/^(┏━ claude app applead1[^\n]* recap.*?)(?=^┏━ codex|\z)/ms; die "no recap" unless $recap;
  my @r=$recap=~/^  ┣━ (\S+)/mg; my $got=join ",",@r;
  die "recap order: $got" unless $got eq "Gamma,Beta,Alpha,agent,Old,Delta,Epsilon";
' "$WORK/full"
check 'a child silent but inside its lease keeps running' perl -0777 -e '
  my $s=<>; die unless $s=~/Epsilon quiet review[^\n]* running · 5:00/;
' "$WORK/full"
check 'a lost child is not part of the live block of a compact frame' perl -0777 -e '
  my $s=<>; my ($live)=$s=~/^(.*?)(?=^┏━ claude app applead1[^\n]* recap)/ms; $live//=$s;
  die "lost row above the recap:\n$live" if $live=~/lost/;
  die "lost row missing from the recap" unless $s=~/recap.*! lost/s;
' "$WORK/small"
check 'recap folds ten finished turns into one agent and its last turn, with the outcome on both rows' perl -0777 -e '
  my $s=<>; my ($group)=$s=~/^(┏━ codex cli ldlead01[^\n]* recap.*?)(?=^┏━|\z)/ms; die "no stale recap" unless $group;
  my @a=$group=~/^  ┣━ Repeated structural task[^\n]*/mg; die "agent rows: @a" unless @a==1 && $a[0]=~/△ partial[^\n]*10 turns/;
  my @t=$group=~/^  ┃  ┗━ turn -turn-[^\n]*/mg;
  die "historical turns shown: @t" unless @t==1 && $t[0]=~/turn -turn-10[^\n]*△ partial/;
' "$WORK/full"
check 'long bridge titles end on a complete word within 60 characters and preserve the failed glyph and word' perl -CSD -0777 -e '
  use utf8; my $s=<>; my ($a)=$s=~/^  ┣━ (A deliberately[^\n]*)$/m; die "missing failed bridge" unless $a;
  die "missing outcome: $a" unless $a=~/ ✗ failed · /;
  my ($title)=$a=~/^(.*?) (?:6\.1-sol|✗)/; die "title exceeds 60: $a" unless defined $title && length($title)<=60;
  die "unclean title: $title" unless $title=~/several…$/;
  die "second sentence shown" if $a=~/Second sentence/;
' "$WORK/full"
# The real watch cache consumes append-only records; legacy frames share the direct renderers.
LEGACY_ROOT="$WORK/legacy"
perl "$REPO/tests/fixtures/watch-real-data.pl" "$LEGACY_ROOT" legacy
check 'legacy incremental aggregates and shared frames stay byte-identical without a frame-time journal read or script launch' bash -c '
  REPO="$1"; WORK="$2"; ROOT="$3"; J="$ROOT/.loomy/logs/events.jsonl"
  LOOMY_STATUS_LIBRARY=1 source "$REPO/scripts/loomy-status.sh" --root "$ROOT"
  source "$REPO/scripts/loomy-tree.sh" --library
  loomy_live_init
  perl -e "$LOOMY_WATCH_LEGACY_PERL"'\''
    require "$ARGV[0]/scripts/lib/live-state.pl"; binmode STDOUT, ":encoding(UTF-8)";
    my $reader=Loomy::LiveState->new; my $cache=Loomy::WatchLegacy->new;
    $cache->consume($_,0,0) for $reader->journal_records($ARGV[1]);
    print "$_\n" for $cache->snapshot("claude",0);
    $reader->journal_records($ARGV[1]); die "warm history read" if $reader->{read_bytes};
    die "unchanged cache emitted" if $cache->snapshot("claude",0);
    open my $f,">>",$ARGV[1] or die $!;
    print $f q({"ts":"2026-10-13T01:00:00Z","type":"usage","scope":"lead","family":"claude","messages":3,"cost_usd":0.4}); close $f;
    die "partial append consumed" if $reader->journal_records($ARGV[1]);
    open $f,">>",$ARGV[1] or die $!; print $f "\n"; close $f;
    $cache->consume($_,0,0) for $reader->journal_records($ARGV[1]);
    die "incremental usage wrong" unless $cache->{usage}[0]==5 && abs($cache->{usage}[1]-0.6)<1e-9;
    die "done bootstrap changed" unless $cache->{phase}{phase}[2]==1 && abs($cache->{phase}{phase}[3]-0.6)<1e-9;
    my $mission=Loomy::WatchLegacy->new;
    for my $mode (qw(task_phase audit_phase)) {
      my $first=$mode eq "task_phase" ? "plan" : "scope";
      for my $cost (0.1,0.3) {
        $mission->phase_consume({type=>$mode,phase=>$first,ts=>"2026-01-01T00:00:00Z"},0,0);
        $mission->phase_consume({type=>"usage",cost_usd=>$cost},0,0);
        $mission->phase_consume({type=>$mode,phase=>"done",ts=>"2026-01-01T00:01:00Z"},0,0);
      }
      die "mission summary failed to reset" unless abs($mission->{phase}{$mode}[3]-0.3)<1e-9;
    }
    my $archived=Loomy::WatchLegacy->new;
    my $end={type=>"delegation",id=>"archived-end",cost_usd=>0.2,status=>"ok"};
    $archived->phase_consume($end,0,0);
    $archived->phase_consume({%$end,snapshot=>1},0,0);
    die "archive snapshot counted twice" unless $archived->{phase}{phase}[2]==1;

  '\'' "$REPO" "$J" >"$WORK/legacy.rows"
  # Drop the append-only test event before comparing the initial cache to direct frames.
  perl -i -ne '\''print unless /"messages":3/'\'' "$J"
  LEGACY_SEQ=0
  while IFS= read -r row; do loomy_watch_legacy_accept "$row"; done <"$WORK/legacy.rows"
  LV_NOW=1791853200; LV_CLOCK=01:00:00; loomy_live_states; loomy_live_metadata
  tick=$LV_NOW; size=--full; watch_body_height=80; tree_mode=list
  for view in status log tree list; do
    args=(); script=loomy-status.sh
    case "$view" in log) args=(--journal) ;; tree) script=loomy-tree.sh ;; list) script=loomy-tree.sh; args=(--once) ;; esac
    LOOMY_WATCH_PIN=1 LOOMY_WATCH_ID=legacy-direct LOOMY_NO_HEADER=1 LOOMY_TREE=list bash "$REPO/scripts/$script" --root "$ROOT" ${args[@]+"${args[@]}"} >"$WORK/direct-$view" 2>&1
    loomy_watch_legacy_render >"$WORK/cache-$view" 2>&1 || { cat "$WORK/cache-$view"; exit 1; }
    cmp "$WORK/direct-$view" "$WORK/cache-$view" || { diff -u "$WORK/direct-$view" "$WORK/cache-$view"; exit 1; }
  done
  view=tree; tree_mode=diagram
  LOOMY_WATCH_ID=legacy-diagram LOOMY_NO_HEADER=1 LOOMY_TREE=diagram COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$WORK/direct-diagram" 2>&1
  COLUMNS=170 LINES=65 loomy_watch_legacy_render >"$WORK/cache-diagram" 2>&1 || { cat "$WORK/cache-diagram"; exit 1; }
  cmp "$WORK/direct-diagram" "$WORK/cache-diagram"
  tree_mode=list
  # Cache-only frames must also work with every history accessor replaced by a failure.
  ai_journal_canonical() { return 99; }; ai_journal_all() { return 99; }
  loomy_live_poll() { return 99; }; ai_journal_display_events() { return 99; }
  for view in status log tree list; do
    loomy_watch_legacy_render >"$WORK/no-read-$view" 2>&1 || { cat "$WORK/no-read-$view"; exit 1; }
    cmp "$WORK/cache-$view" "$WORK/no-read-$view"
  done
' _ "$REPO" "$WORK" "$LEGACY_ROOT"
printf '%s watch real-data checks passed\n' "$PASS"
