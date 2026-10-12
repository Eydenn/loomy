#!/usr/bin/env bash
# Targeted native Codex lifecycle, rendering, bounded-read and privacy regressions.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loomy-native-tests.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
OWNER=""
trap '[[ -z "$OWNER" ]] || { kill "$OWNER" 2>/dev/null || true; wait "$OWNER" 2>/dev/null || true; }; rm -rf "$WORK"' EXIT
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex"
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export NO_COLOR=1 LOOMY_LANG=en LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_HOME="$REPO"
unset CODEX_THREAD_ID LOOMY_JOURNAL LOOMY_JOURNAL_TASKS LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT AI_ROUTE_ENV LOOMY_WATCH_TOOL
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
ROOT="$WORK/project"; J="$ROOT/.loomy/logs/events.jsonl"
PASS=0
check() { local title="$1"; shift; if "$@"; then PASS=$(( PASS + 1 )); printf 'ok %s\n' "$title"; else printf 'FAIL %s\n' "$title" >&2; exit 1; fi; }
fixture() { perl "$REPO/tests/fixtures/codex-native.pl" "$1" "$ROOT" "$CODEX_HOME/sessions" "${OWNER:-$$}"; }
poll() { perl "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"; }
json_check() {
  perl -MJSON::PP -e 'my $test=shift; my @all; while (<>) { my $d=eval{decode_json($_)}; push @all,$d if ref($d) eq "HASH" } my @native=grep {($_->{bridge}//"") eq "codex-native"} @all; eval $test; die $@ if $@;' "$1" "$J"
}
count_start() { json_check 'die unless (grep {$_->{type} eq "delegation_start"} @native)==3'; }
fixture seed
check 'first poll discovers three agents' poll
check 'three distinct starts' count_start
check 'real model and effort, owner identity only, no usage or private content' json_check 'my %c=map {$_->{agent_id}=>1} grep {$_->{type} eq "delegation_activity" && ($_->{model}//"") eq "gpt-6-luna" && ($_->{effort}//"") eq "max"} @native; die unless keys(%c)==3; for(@native){die if exists($_->{pid}) || !$_->{owner_pid} || $_->{pid_role} ne "owner" || exists($_->{tokens_in}) || exists($_->{cost_usd})} die if grep {($_->{type}//"") eq "usage"} @all; die if encode_json(\@all)=~/PRIVATE_|Excluded|Unrelated|nonexistent-fixture/;'
cp "$J" "$WORK/before-restart"
check 'restart poll' poll
check 'restart appends nothing' cmp "$J" "$WORK/before-restart"
rm "$ROOT/.loomy/logs/codex-native.idx"
check 'lost checkpoint recovers stable journal keys' poll
check 'lost checkpoint replay appends nothing' cmp "$J" "$WORK/before-restart"
check 'checkpoint and journal are private' perl -e 'for(@ARGV){die if ((stat($_))[2]&0777)!=0600}' "$J" "$ROOT/.loomy/logs/codex-native.idx"
for layout in live tree diagram status; do
  case "$layout" in
    live) COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/$layout" 2>&1 ;;
    tree|diagram) LOOMY_TREE="$([[ "$layout" == tree ]] && echo list || echo diagram)" COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$WORK/$layout" 2>&1 ;;
    status) COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-status.sh" --root "$ROOT" >"$WORK/$layout" 2>&1 ;;
  esac
  check "$layout shows three distinct task identities" perl -0777 -e 'my $s=<>; for(qw(consolidation enrichment review)){die unless $s=~/\b\Q$_\E\b/} die if $s=~/Excluded|Unrelated|PRIVATE_/' "$WORK/$layout"
done
check 'live view explicitly marks unknown native usage' grep -q 'native usage unknown' "$WORK/live"
fixture finish; check 'finish/abort/partial poll' poll
check 'terminal states do not confer review approval' json_check 'my @e=grep {$_->{type} eq "delegation"} @native; die unless @e==3; die unless (grep {$_->{outcome} eq "done"} @e)==1 && (grep {$_->{outcome} eq "interrupted"} @e)==1 && (grep {$_->{outcome} eq "partial"} @e)==1; die if grep {exists($_->{approved}) || exists($_->{review_approved})} @e;'
fixture later; check 'later turn poll' poll
check 'later turn uses new identity and observable waiting state' json_check 'die unless (grep {$_->{type} eq "delegation_start"} @native)==4; die unless grep {($_->{activity}//"") eq "waiting"} @native;'
fixture supersede; check 'missing terminal predecessor poll' poll
check 'superseded turn is unknown, not successful' json_check 'die unless grep {$_->{type} eq "delegation" && ($_->{status}//"") eq "unknown" && $_->{outcome} eq "unknown"} @native;'
fixture unknown; fixture blocked; check 'unknown and blocked poll' poll
check 'unknown final text remains unknown; blocked stays blocked' json_check 'die unless grep {$_->{type} eq "delegation" && $_->{outcome} eq "unknown" && $_->{status} eq "ok"} @native; die unless grep {$_->{type} eq "delegation" && $_->{outcome} eq "blocked"} @native;'
COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-stats.sh" --root "$ROOT" >"$WORK/native-stats" 2>&1
check 'native-only stats show unknown usage, not measured model/duration rows' perl -0777 -e 'my $s=<>; die unless $s=~/native usage unknown/; die if $s=~/BY MODEL|BY ROLE|in total .*on average|nothing logged yet/;' "$WORK/native-stats"
fixture bridge-stats
COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-stats.sh" --root "$ROOT" >"$WORK/mixed-stats" 2>&1
check 'mixed stats retain bridge aggregates and exclude native turns' perl -0777 -e 'my $s=<>; die unless $s=~/native usage unknown/ && $s=~/fixture-model/ && $s=~/10 s in total .*10 s on average/; die if $s=~/gpt-6-luna/;' "$WORK/mixed-stats"

# Compaction repeats the live owner start; its original boundary still owns earlier child turns.
ROOT="$WORK/compact-before"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/compact-before-codex"
fixture compact-seed; fixture compact
check 'compact before first native ingestion poll' poll
check 'precompact child turns remain associated with the original owner' json_check 'my @s=grep {$_->{type} eq "delegation_start"} @native; die unless @s==3 && !grep {($_->{session}//"") ne "00000000-0000-4000-8000-000000000001"} @s;'
check 'compact owner index keeps its initial live boundary' perl -MJSON::PP -e 'my ($index,$journal)=@ARGV; open my $i,"<",$index or die; my $s=decode_json(do{local $/;<$i>}); my @o=values %{$s->{owners}}; open my $j,"<",$journal or die; my @e=map {decode_json($_)} <$j>; my ($first)=grep {($_->{type}//"") eq "session" && ($_->{event}//"") eq "start"} @e; die unless @o==1 && $o[0]{ts} eq $first->{ts} && $o[0]{session} eq $first->{session};' "$ROOT/.loomy/logs/codex-native.idx" "$J"

ROOT="$WORK/compact-active"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/compact-active-codex"
fixture compact-seed; check 'initial active native ingestion' poll
fixture compact; check 'compact after active native ingestion' poll
check 'compact preserves active native rows without replay duplicates' json_check 'die unless (grep {$_->{type} eq "delegation_start"} @native)==3 && (grep {$_->{type} eq "delegation_activity"} @native)==6 && !grep {$_->{type} eq "delegation"} @native;'
fixture claude-later
AI_LEAD=claude LOOMY_WATCH_TOOL=codex AI_ROUTE_ENV=claude COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/compact-tree-codex" 2>&1
check 'Codex watch filter wins over stale Claude route with both sessions open' perl -0777 -e 'my $s=<>; die unless $s=~/3 running/; for(qw(consolidation enrichment review)){die unless $s=~/\b\Q$_\E\b/} die if $s=~/No roles running/;' "$WORK/compact-tree-codex"
AI_LEAD=codex LOOMY_WATCH_TOOL=claude AI_ROUTE_ENV=codex COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/compact-tree-claude" 2>&1
check 'Claude watch filter wins over stale Codex route' perl -0777 -e 'my $s=<>; die unless $s=~/No roles running/; die if $s=~/3 running|consolidation|enrichment|review/;' "$WORK/compact-tree-claude"
env -u LOOMY_WATCH_TOOL -u AI_ROUTE_ENV AI_LEAD=codex COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/compact-tree-default" 2>&1
check 'unset watch filter falls back to lead, not stale AI_ROUTE_ENV' perl -0777 -e 'my $s=<>; die unless $s=~/3 running/;' "$WORK/compact-tree-default"
env -u AI_ROUTE_ENV AI_LEAD=codex LOOMY_WATCH_TOOL=invalid COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/compact-tree-invalid" 2>&1
check 'invalid watch filter falls back to lead' perl -0777 -e 'my $s=<>; die unless $s=~/3 running/;' "$WORK/compact-tree-invalid"
check 'app orchestrator fallback clears route and watch-only selector' grep -qF 'env -u AI_ROUTE_ENV -u LOOMY_WATCH_TOOL bash' "$REPO/scripts/loomy-start.sh"
check 'terminal orchestrator fallback clears route and watch-only selector' grep -qF 'env -u LOOMY_SCREEN_OWNER -u LOOMY_PAGE_OUT -u AI_ROUTE_ENV -u LOOMY_WATCH_TOOL LOOMY_START_IN=terminal bash' "$REPO/scripts/loomy-start.sh"

# Journal generations carry only live turn snapshots; history remains deduplicated.
ROOT="$WORK/rotation"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/rotation-codex"
fixture seed; poll
cp "$J" "$WORK/legacy-before"; fixture legacy-index; poll
check 'legacy checkpoint migration does not append duplicate starts' cmp "$J" "$WORK/legacy-before"
COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/rotation-before" 2>&1
cp "$J" "$WORK/rotation-source"
fixture rotate; poll
check 'new journal generation restores three stable starts with original source timestamps' perl -MJSON::PP -e 'my @logs; for my $file(@ARGV){open my $f,"<",$file or die; push @logs,[map {decode_json($_)} <$f>]} my %starts=map {$_->{id}=>$_} grep {$_->{type} eq "delegation_start"} @{$logs[0]}; my %activity; for(@{$logs[0]}){$activity{$_->{id}}=$_ if $_->{type} eq "delegation_activity"} my @s=grep {$_->{type} eq "delegation_start"} @{$logs[1]}; my @a=grep {$_->{type} eq "delegation_activity"} @{$logs[1]}; die unless @s==3 && @a==3; for(@s){die unless $starts{$_->{id}} && $_->{ts} eq $starts{$_->{id}}{ts} && $_->{turn_id} eq $starts{$_->{id}}{turn_id}} for(@a){die unless $_->{ts} eq $activity{$_->{id}}{ts} && $_->{activity} eq $activity{$_->{id}}{activity} && $_->{model} eq "gpt-6-luna" && $_->{effort} eq "max"} die if grep {$_->{type} eq "delegation" || $_->{type} eq "usage" || exists($_->{cost_usd}) || exists($_->{tokens_in})} @{$logs[1]};' "$WORK/rotation-source" "$J"
COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/rotation-after" 2>&1
check 'rendered three-agent list survives inode replacement' perl -0777 -e 'for(@ARGV){open my $f,"<",$_ or die; local $/; my $s=<$f>; die unless $s=~/3 running/; for(qw(consolidation enrichment review)){die unless $s=~/\b\Q$_\E\b/} die if $s=~/No roles running/;}' "$WORK/rotation-before" "$WORK/rotation-after"
cp "$J" "$WORK/rotation-restored"
check 'restart after restoration' poll
check 'unchanged restart after restoration appends nothing' cmp "$J" "$WORK/rotation-restored"
fixture truncate-journal; poll
check 'same-inode truncation restores three current turns' count_start
COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" --once >"$WORK/truncation-after" 2>&1
check 'rendered list survives same-inode truncation' grep -q '3 running' "$WORK/truncation-after"
cp "$J" "$WORK/truncation-restored"; poll
check 'next poll after same-inode restoration appends nothing' cmp "$J" "$WORK/truncation-restored"

ROOT="$WORK/mixed-rotation"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/mixed-rotation-codex"
fixture seed; poll; fixture finish; poll; fixture later; poll
cp "$J" "$WORK/mixed-rotation-source"; fixture rotate; poll
check 'rotation restores only active later turn and keeps waiting state' json_check 'my @s=grep {$_->{type} eq "delegation_start"} @native; my @a=grep {$_->{type} eq "delegation_activity"} @native; die unless @s==1 && @a==1 && $s[0]{turn_id} eq "00000000-0000-4000-8000-000000000022" && $a[0]{activity} eq "waiting"; die if grep {$_->{type} eq "delegation" || $_->{type} eq "usage" || exists($_->{tokens_in}) || exists($_->{cost_usd})} @native;'
check 'archived historical completion keys remain deduplicated' perl -MJSON::PP -e 'my ($history,$index)=@ARGV; open my $f,"<",$history or die; my @e=map {decode_json($_)} <$f>; open my $h,"<",$index or die; my $s=decode_json(do{local $/;<$h>}); for(grep {$_->{type} eq "delegation" && ($_->{bridge}//"") eq "codex-native"} @e){die unless $s->{seen}{$_->{native_key}}}' "$WORK/mixed-rotation-source" "$ROOT/.loomy/logs/codex-native.idx"
COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-stats.sh" --root "$ROOT" >"$WORK/rotation-stats" 2>&1
check 'restored snapshots do not duplicate historical statistics' grep -q 'native usage unknown.*3 finished' "$WORK/rotation-stats"
cp "$J" "$WORK/mixed-rotation-restored"; poll
check 'mixed rotation restart is append-free' cmp "$J" "$WORK/mixed-rotation-restored"

# Bounded replay persists progress even before the journal owner record is reached.
ROOT="$WORK/large-journal"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/large-codex"
fixture seed; fixture large-journal
check 'large journal poll one' poll
check 'large journal checkpoint advances' perl -MJSON::PP -e 'my $s=decode_json(do{local $/;<>}); die unless $s->{journal}{offset}>0' "$ROOT/.loomy/logs/codex-native.idx"
check 'large journal poll two' poll
check 'large journal eventually discovers all children' count_start

ROOT="$WORK/huge-child"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/huge-codex"
fixture seed; fixture huge-terminal
check 'oversized child first bounded poll' poll
fixture end-owner
check 'oversized child second poll after owner end' poll
check 'no premature interruption while terminal still unread' json_check 'die if grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "consolidation"} @native;'
for (( catchup=0; catchup<8; catchup++ )); do
  poll
  if json_check 'die unless grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "consolidation"} @native;' 2>/dev/null; then break; fi
done
check 'completion beyond oversized record survives owner exit' json_check 'my @e=grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "consolidation"} @native; die unless @e==1 && $e[0]{outcome} eq "done";'

ROOT="$WORK/huge-no-end"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/no-end-codex"
fixture seed; fixture huge-child; poll; fixture end-owner; poll
check 'missing terminal is not synthesized before EOF' json_check 'die if grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "consolidation"} @native;'
for (( catchup=0; catchup<8; catchup++ )); do
  poll
  if json_check 'die unless grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "consolidation"} @native;' 2>/dev/null; then break; fi
done
check 'owner exit without terminal interrupts only after EOF' json_check 'my @e=grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "consolidation"} @native; die unless @e==1 && $e[0]{outcome} eq "interrupted" && !defined($e[0]{duration_s});'

ROOT="$WORK/nine"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/nine-codex"
fixture seed; fixture nine; poll; fixture nine-grow; fixture end-owner; poll
check 'budget-skipped ninth child cannot reuse stale EOF' json_check 'die if grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "nine10"} @native;'
poll
check 'rotating budget reaches ninth child valid completion next poll' json_check 'my @e=grep {$_->{type} eq "delegation" && ($_->{task}//"") eq "nine10"} @native; die unless @e==1 && $e[0]{outcome} eq "done";'

ROOT="$WORK/growing"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/growing-codex"
fixture seed; fixture malformed; fixture incomplete; poll
check 'malformed and incomplete records do not imply success' json_check 'die if grep {$_->{type} eq "delegation"} @native;'
fixture complete-line; poll
check 'completed append is retried successfully' json_check 'die unless (grep {$_->{type} eq "delegation" && $_->{outcome} eq "done"} @native)==1;'
fixture truncate; poll
check 'truncation cannot duplicate starts or terminal events' count_start

ROOT="$WORK/resume"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/resume-codex"
fixture seed; fixture resume; fixture tomorrow; poll
check 'resume recovery and tomorrow date directory' count_start
ROOT="$WORK/ambiguous"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/ambiguous-codex"
fixture seed; fixture ambiguous; poll
check 'ambiguous lead ownership is not guessed' json_check 'die if @native;'

ROOT="$WORK/private-labels"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/private-codex"
fixture seed
LOOMY_JOURNAL_TASKS=0 poll
check 'task privacy suppresses path labels and nicknames in journal and checkpoint' perl -0777 -e 'for(@ARGV){open my $f,"<",$_ or die; local $/; my $s=<$f>; die if $s=~/consolidation|enrichment|review|Native[234]|\/root\//;}' "$J" "$ROOT/.loomy/logs/codex-native.idx"
LOOMY_JOURNAL_TASKS=0 LOOMY_TREE=list COLUMNS=170 LINES=65 bash "$REPO/scripts/loomy-tree.sh" --root "$ROOT" >"$WORK/private-tree" 2>&1
check 'private tree keeps distinct safe role/id identities' perl -0777 -e 'my $s=<>; for(qw(00000002 00000003 00000004)){die unless $s=~/\Q$_\E/} die if $s=~/consolidation|enrichment|Native[234]/;' "$WORK/private-tree"
ROOT="$WORK/disabled"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/disabled-codex"
fixture seed; cp "$J" "$WORK/disabled-original"
check 'disabled one-shot ingester does not write' env LOOMY_JOURNAL=0 perl "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"
check 'disabled in-process sampler does not write' env LOOMY_JOURNAL=0 perl -e 'require shift; Loomy::CodexNative::poll(@ARGV)' "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"
check 'disabled tracking leaves journal unchanged and no checkpoint' bash -c 'cmp "$1" "$2" && test ! -e "$3"' _ "$J" "$WORK/disabled-original" "$ROOT/.loomy/logs/codex-native.idx"

ROOT="$WORK/dead-owner"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/dead-codex"
sleep 30 & OWNER=$!
fixture seed; poll; kill "$OWNER"; wait "$OWNER" 2>/dev/null || true; poll
check 'verified owner process exit interrupts all active agents' json_check 'die unless (grep {$_->{type} eq "delegation" && $_->{outcome} eq "interrupted"} @native)==3;'
OWNER=""

ROOT="$WORK/security"; J="$ROOT/.loomy/logs/events.jsonl"; export CODEX_HOME="$WORK/security-codex"
fixture seed; cp "$J" "$WORK/journal-target"; rm "$J"; ln -s "$WORK/journal-target" "$J"; cp "$WORK/journal-target" "$WORK/journal-original"
check 'journal symlink rejected' poll
check 'journal symlink target untouched' cmp "$WORK/journal-target" "$WORK/journal-original"
rm "$J"; cp "$WORK/journal-original" "$J"; ln -s "$WORK/journal-target" "$ROOT/.loomy/logs/codex-native.idx"
check 'checkpoint symlink rejected' poll
check 'checkpoint symlink target untouched' cmp "$WORK/journal-target" "$WORK/journal-original"
rm "$ROOT/.loomy/logs/codex-native.idx"
check 'locked journal poll stays bounded' perl -MFcntl=:flock -e 'my ($file,$script,$root,$sessions)=@ARGV; open my $f,"+<",$file or die $!; flock($f,LOCK_EX); local $SIG{ALRM}=sub{die "journal lock blocked watch\n"}; alarm 2; system($^X,$script,$root,$sessions)==0 or die; alarm 0;' "$J" "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions"
check 'recovery after lock contention' poll
check 'recovery after contention sees three agents' count_start

# Measure the actual in-process sampler path, not shell startup time.
check '100 unchanged polls stay below five seconds and append nothing' perl -MTime::HiRes=time -e 'my ($module,$root,$sessions,$journal)=@ARGV; require $module; my $size=-s $journal; my $begin=time; for(1..100){Loomy::CodexNative::poll($root,$sessions)} my $elapsed=time-$begin; printf "100 polls: %.3f s\n",$elapsed; die if $elapsed>5 || (-s $journal)!=$size;' "$REPO/scripts/lib/codex-native.pl" "$ROOT" "$CODEX_HOME/sessions" "$J"
if command -v expect >/dev/null 2>&1; then
  check 'real watch sampler displays identities and refreshes terminal outcomes' expect "$REPO/tests/fixtures/native-watch.exp"
else printf 'SKIP native watch PTY: expect unavailable\n'; fi
printf '%s native Codex checks passed\n' "$PASS"
