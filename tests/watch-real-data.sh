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
check 'live Claude lead heading appears once in a full frame and carries no lease jargon' perl -0777 -e '
  my $s=<>; my @h=grep {/^┏━ claude app applead1/} split /\n/,$s; die "headings: @h" unless @h==1 && $h[0]=~/ · live /;
  die "jargon" if $s=~/source lease|launcher|catching up/;
' "$WORK/full"
check 'compact frame repeats the live heading only as a recap heading' perl -0777 -e '
  my $s=<>; my @h=grep {/^┏━ claude app applead1/} split /\n/,$s;
  die "no compaction:\n$s" unless @h==2; die "not marked: @h" unless $h[0]!~/recap/ && $h[1]=~/ recap/;
' "$WORK/small"
# Stale sessions: nothing running, nothing empty.
check 'stale sessions with no agent are not shown, even in the recap' perl -0777 -e '
  my $s=<>; die "empty stale group shown:\n$s" if $s=~/4194001|emptyle/;
  my @g=grep {/^┏━/} split /\n/,$s; die "group count: @g" unless @g==3;
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
  my $s=<>; die unless $s=~/^1 running ·/m && $s=~/Delta review[^\n]* running · /;
' "$WORK/full"
printf '%s watch real-data checks passed\n' "$PASS"
