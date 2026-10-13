#!/usr/bin/env bash
# Read-only native end labels, coalesced source activity and count-only ANSI emphasis.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "/tmp/loomy-native-display.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export LOOMY_HOME="$REPO" NO_COLOR=1 LOOMY_LANG=en LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0
unset CODEX_THREAD_ID LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT LOOMY_WATCH_TOOL AI_ROUTE_ENV LOOMY_JOURNAL LOOMY_JOURNAL_TASKS LOOMY_WATCH_ID
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
ROOT="$WORK/project"; J="$ROOT/.loomy/logs/events.jsonl"
PASS=0
check() { local title="$1"; shift; if "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
fixture() { perl "$REPO/tests/fixtures/native-display.pl" "$1" "$ROOT" "$$" "${2:-2}"; }
events() { bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/journal.sh"; ai_journal_display_events "$2"' _ "$REPO" "$J"; }
check 'owner close barriers preserve only that owners re-observation without duplicating terminals' bash -c '
  source "$1/scripts/lib/journal.sh"
  printf "%s\n" \
    '\''{"type":"delegation_activity","id":"a","tool":"codex","owner_pid":10,"ts":"same"}'\'' \
    '\''{"type":"delegation_activity","id":"b","tool":"codex","owner_pid":11,"ts":"same"}'\'' \
    '\''{"type":"delegation","id":"done","tool":"codex","owner_pid":11,"ts":"same"}'\'' \
    '\''{"type":"session","event":"end","tool":"codex","pid":11,"ts":"same"}'\'' \
    '\''{"type":"delegation_activity","id":"a","tool":"codex","owner_pid":10,"ts":"same"}'\'' \
    '\''{"type":"delegation_activity","id":"b","tool":"codex","owner_pid":11,"ts":"same"}'\'' \
    '\''{"type":"delegation","id":"done","tool":"codex","owner_pid":11,"ts":"same"}'\'' |
    ai_journal_canonical | perl -MJSON::PP -ne '\''++$n{decode_json($_)->{id}//""}; END {die unless $n{a}==1 && $n{b}==2 && $n{done}==1}'\''
' _ "$REPO"
fixture seed; cp "$J" "$WORK/original-journal"; events >"$WORK/events"
check 'done, idle and interrupted turn states retain task identity' perl -0777 -e 'my $s=<>; die unless $s=~/\|done\|[^\n]*response_task/ && $s=~/\|idle\|[^\n]*superseded_task/ && $s=~/\|interrupted\|[^\n]*aborted_task/; die if $s=~/\|unknown\|/;' "$WORK/events"
check 'one latest actual UTC activity per active turn, without stale start rows or private data' perl -ne 'my @v=split /\|/; if ($v[2]=~/^(waiting|running)$/){++$n; die unless $v[0] eq "2026-01-02T10:00:30Z"} die if /PRIVATE_|\|start\|.*(?:quoted|active_task_2)/; END {die unless $n==2}' "$WORK/events"
check 'JSON escapes decode safely without changing journal separators' perl -ne 'chomp; die unless (split /\|/,$_, -1)==4; $found=1 if /vocab "quoted" \\path   safe/; END {die unless $found}' "$WORK/events"
events >"$WORK/events-again"
check 'unchanged source produces stable rows, not invented heartbeats' cmp "$WORK/events" "$WORK/events-again"
for lang in en fr; do
  if [[ "$lang" == en ]]; then received='done'; unconfirmed='idle'; else received='terminé'; unconfirmed='au repos'; fi
  for mode in live list diagram; do
    args=(); [[ "$mode" != live ]] || args=(--once)
    layout=list; [[ "$mode" != diagram ]] || layout=diagram
    out="$WORK/$lang-$mode"
    NO_COLOR='' LOOMY_FORCE_COLOR=1 LOOMY_LANG="$lang" LOOMY_UI_LANG="$lang" LOOMY_TREE="$layout" COLUMNS=200 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" ${args[@]+"${args[@]}"} >"$out" 2>&1
    check "$lang $mode displays turn completion and persistent idle state" perl -0777 -e 'my ($a,$b,$f)=@ARGV; open my $h,"<",$f or die; my $s=do{local $/;<$h>}; die unless index($s,$a)>=0 && index($s,$b)>=0; die if $s=~/response received|réponse reçue|\? (unknown|inconnu)/;' "$received" "$unconfirmed" "$out"
    if [[ "$mode" == live ]]; then
      check "$lang live summary counts recap entries without calling unconfirmed turns finished" perl -0777 -e 'my $s=<>; die unless $s=~/3 (?:in recap|dans le récapitulatif)/; die if $s=~/3 (?:finished|terminés)/;' "$out"
    fi
  done
done
check 'read-side semantic rendering preserves raw lifecycle/outcome records byte for byte' cmp "$J" "$WORK/original-journal"
fixture finish; events >"$WORK/finished"
check 'finished native turns suppress even subsequently appended stale activity' perl -0777 -e 'my $s=<>; die if $s=~/\|(running|waiting)\|[^\n]*quoted/; die unless $s=~/2026-01-02T10:00:40Z\|worker\|done\|[^\n]*quoted/;' "$WORK/finished"
fixture seed; fixture typed; events >"$WORK/typed"
check 'malformed optional JSON types fall back to safe observed metadata, not private fields' perl -0777 -e 'my $s=<>; die if $s=~/PRIVATE_|HASH\(|ARRAY\(/; die unless $s=~/2026-01-02T10:00:35Z\|worker\|waiting\|[^\n]*active_task_2/ && $s=~/\|done\|[^\n]*response_task/;' "$WORK/typed"
fixture unknown-activity; events >"$WORK/unavailable"
check 'unavailable latest activity does not revive an older known-running observation' perl -0777 -e 'my $s=<>; die if $s=~/\|(running|waiting)\|[^\n]*quoted/;' "$WORK/unavailable"
fixture closed; events >"$WORK/closed"
check 'closed owner suppresses active-agent observations' perl -ne 'die if /\|(running|waiting)\|/' "$WORK/closed"
fixture seed; fixture sessionless-closed; events >"$WORK/sessionless-closed"
check 'sessionless closure suppresses explicit-session activity for the same tool and owner PID' perl -ne 'die if /\|(running|waiting)\|/' "$WORK/sessionless-closed"
fixture seed; fixture sparse-activity; fixture sessionless-closed; events >"$WORK/sparse-sessionless-closed"
check 'sessionless closure also matches partial activity through its observed start metadata' perl -ne 'die if /\|(running|waiting)\|/' "$WORK/sparse-sessionless-closed"
for action in wrong-tool-closed wrong-pid-closed other-session-closed; do
  fixture seed; fixture "$action"; events >"$WORK/$action"
  check "$action cannot close an unrelated native owner" perl -ne '++$n if /\|(running|waiting)\|/; END {die unless $n==2}' "$WORK/$action"
done
fixture seed; fixture sessionless-closed; fixture reopen; events >"$WORK/reopened"
check 'same-PID explicit reopen admits only subsequently observed activity in that session' perl -ne 'if (/\|(running|waiting)\|/){++$n; die unless /^2026-01-02T10:00:55Z\|.*quoted/} END {die unless $n==1}' "$WORK/reopened"
fixture seed; fixture sessionless-closed; fixture reopen-other; events >"$WORK/reopened-other"
check 'same-PID new explicit session does not reopen the preceding session' perl -ne 'if (/\|(running|waiting)\|/){++$n; die unless /other_owner_task/} END {die unless $n==1}' "$WORK/reopened-other"
fixture seed; fixture reopen-same-second; events >"$WORK/reopened-same-second"
check 'same-second reopening distinguishes pre-close observations from newly received activity' perl -ne 'if (/\|(running|waiting)\|/){++$n; die unless /quoted/} END {die unless $n==1}' "$WORK/reopened-same-second"
fixture seed; fixture compact-owner; events >"$WORK/compacted-owner"
check 'compaction without closure preserves existing observed activity without inventing new timestamps' perl -ne 'if (/\|(running|waiting)\|/){++$n; die unless /^2026-01-02T10:00:30Z/} END {die unless $n==2}' "$WORK/compacted-owner"
fixture seed; fixture later-turn; events >"$WORK/later-turn"
check 'late stale activity on a closed turn cannot hide the same agents current turn' perl -0777 -e 'my $s=<>; die unless $s=~/2026-01-02T10:00:45Z\|worker\|waiting\|[^\n]*resumed_task/; die if $s=~/\|(running|waiting)\|[^\n]*quoted/;' "$WORK/later-turn"
fixture tail-budget; events >"$WORK/tail"
check 'display keeps the existing 400-record tail bound and supports activity without an in-window start' perl -0777 -e 'my $s=<>; die if $s=~/OUTSIDE_TAIL/; die unless $s=~/2026-01-02T10:00:30Z\|worker\|running\|.*tail_task/;' "$WORK/tail"
fixture sessionless-closed; events >"$WORK/tail-sessionless-closed"
check 'sessionless closure works with no owner start in the 400-record tail' perl -ne 'die if /\|(running|waiting)\|/' "$WORK/tail-sessionless-closed"
fixture tail-budget; fixture closed; events >"$WORK/tail-explicit-closed"
check 'explicit closure works with no owner start in the 400-record tail' perl -ne 'die if /\|(running|waiting)\|/' "$WORK/tail-explicit-closed"
for count in 1 2 12; do
  fixture seed "$count"
  for lang in en fr; do
    for width in 124 140 170 200; do
      out="$WORK/count-$count-$lang-$width.ansi"
      NO_COLOR='' LOOMY_FORCE_COLOR=1 LOOMY_LANG="$lang" LOOMY_UI_LANG="$lang" LOOMY_TREE=diagram COLUMNS="$width" LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$out" 2>&1
      check "$lang $width count $count is the only bold text on the stable return-box row" perl "$REPO/tests/fixtures/native-display-style.pl" "$out" "$count"
    done
  done
done
printf '%s native display checks passed\n' "$PASS"
