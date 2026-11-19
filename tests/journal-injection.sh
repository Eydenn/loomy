#!/usr/bin/env bash
# Journal and runtime-file injection (LR9): a cloned repository can ship .loomy/logs/events.jsonl, .loomy/state,
# .loomy/failover, brief.md... Bash evaluates the text of a variable as arithmetic (a[$(cmd)] runs cmd), so no
# value read from those files may reach arithmetic unvalidated, and no raw escape may reach the terminal.
# Each case plants hostile data, runs the real command, and checks that no marker file appears and that the
# output holds no ESC. Synthetic projects only: no provider, no network. Bash 3.2 compatible.
set -uo pipefail
REPO="${LOOMY_INJECTION_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
WORK="$(mktemp -d /tmp/ljXXXXXX)"; WORK="$(cd "$WORK" && pwd -P)"
trap 'kill $SLEEPER 2>/dev/null; wait $SLEEPER 2>/dev/null; [[ -n "${LOOMY_INJECTION_KEEP:-}" ]] || rm -rf "$WORK"' EXIT
SLEEPER=""
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" XDG_STATE_HOME="$WORK/state" XDG_CACHE_HOME="$WORK/cache"
export XDG_RUNTIME_DIR="$WORK/runtime" TMPDIR="$WORK/tmp" CODEX_HOME="$WORK/codex" CLAUDE_CONFIG_DIR="$WORK/claude"
export LOOMY_HOME="$REPO" LOOMY_LANG=en LOOMY_UI_LANG=en NO_COLOR=1 LOOMY_NO_AUTOUPDATE=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_REPAIR=1
export LOOMY_TEST_GUARD=1 LOOMY_TEST_STUBS="$REPO/tests/stubs" LOOMY_START_WATCH=0
export PATH="$REPO/tests/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
mkdir -m 700 "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$XDG_RUNTIME_DIR" "$TMPDIR" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
PASS=0; FAIL=0
ok() { PASS=$(( PASS + 1 )); printf 'ok %s\n' "$1"; }
ko() { FAIL=$(( FAIL + 1 )); printf 'not ok %s\n' "$1"; }
MARK="$WORK/m"; mkdir "$MARK"
ESC=$'\033'

sleep 300 & SLEEPER=$!
disown $SLEEPER 2>/dev/null || true
P="$WORK/p"; mkdir "$P"; cd "$P" || exit 2
git init -q && git commit -q --allow-empty -m init
bash "$REPO/bin/loomy" init --yes --no-wizard . >/dev/null 2>&1
mkdir -p .loomy/logs
# The brief gates the context hooks and the report: a cloned repository ships it too.
printf -- '---\nname: "x\tn=PATH[$(touch %s/briefname)]"\nslug: s\nai_mode: ORCHESTRATED\nai_lead: claude\n---\n' "$MARK" >.loomy/brief.md
J=.loomy/logs/events.jsonl
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Payloads (kept short: the status list clips tasks to 60 characters): PATH is always a bound variable, so PATH[$(cmd)] reaches the subscript expansion whatever `set -u` says.
m() { printf 'PATH[$(touch %s/%s)]' "$MARK" "$1"; }
plant() {   # plant <json lines...>: replaces the journal
  : >"$J"; local l; for l in "$@"; do printf '%s\n' "$l" >>"$J"; done
}
hostile_journal() {
  local ts="$NOW" pid="$SLEEPER"
  plant \
   "{\"type\":\"delegation_start\",\"id\":\"d1\",\"pid\":$pid,\"bridge\":\"codex\",\"role\":\"architect\",\"family\":\"codex\",\"model\":\"m\",\"task\":\"x|$(m status-task)\",\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation_start\",\"id\":\"d2\",\"pid\":$pid,\"bridge\":\"codex\",\"role\":\"x|$(m status-role)|y\",\"family\":\"codex\",\"model\":\"\`touch $MARK/backtick\`\",\"task\":\"\\u001b[31mRED\\u001b]0;PWN\\u0007\\nnext\",\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation_start\",\"id\":\"d3\",\"pid\":0,\"bridge\":\"codex\",\"role\":\"developer\",\"family\":\"codex\",\"model\":\"m\",\"task\":\"pid zero\",\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation_start\",\"id\":\"d4\",\"pid\":-1,\"bridge\":\"codex\",\"role\":\"developer\",\"family\":\"codex\",\"model\":\"m\",\"task\":\"pid negative\",\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation\",\"id\":\"e1\",\"bridge\":\"codex\",\"family\":\"codex\",\"role\":\"developer\",\"model\":\"m\",\"status\":\"ok\",\"duration_s\":\"$(m dur)\",\"cost_usd\":\"$(m cost)\",\"tokens_in\":1e9,\"tokens_out\":-1,\"task\":\"t\",\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation\",\"id\":\"e2\",\"bridge\":\"codex\",\"family\":\"x|$(m stats-family)\",\"role\":\"r|$(m stats-role)\",\"model\":\"mo|$(m stats-model)\",\"status\":\"ok\",\"duration_s\":1e9,\"outcome\":\"\\u001b[2J\",\"ts\":\"$ts\"}" \
   "{\"type\":\"usage\",\"scope\":\"lead\",\"tool\":\"claude\",\"model\":\"u|$(m usage-model)\",\"messages\":99999999999999999999,\"ts\":\"x|$(m stats-ts)|y\"}" \
   "{\"type\":\"usage\",\"scope\":\"lead\",\"tool\":\"claude\",\"model\":\"m\",\"cost_usd\":\"$(m cost2)\",\"pid\":\"$(m upid)\",\"ts\":\"$ts\"}" \
   "{\"type\":\"session\",\"event\":\"start\",\"tool\":\"cl|aude\",\"session\":\"s|$(m sess)\",\"pid\":$pid,\"ts\":\"$ts\"}" \
   "{\"type\":\"session\",\"event\":\"start\",\"tool\":\"claude\",\"session\":\"s2\",\"pid\":\"$(m sesspid)\",\"ts\":\"x|$(m sessts)\"}" \
   "{\"type\":\"delegation_start\",\"id\":\"d9\",\"pid\":$pid,\"bridge\":\"codex-native\",\"owner_pid\":$pid,\"role\":\"explorer\",\"family\":\"codex\",\"tool\":\"codex\",\"session\":\"s1\",\"agent_id\":\"$(m agent)\",\"schema\":2,\"task\":\"$(m ntask)\",\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation\",\"id\":\"e3\",\"bridge\":\"codex\",\"family\":\"codex\",\"role\":\"developer\",\"model\":\"m\",\"status\":\"paused\",\"resume_at\":\"$(m resume)\",\"ts\":\"$ts\"}" \
   "not json $(m garbage) $ESC[31m raw escape line"
  # A raw ESC inside a JSON string is invalid JSON: it must be dropped, never displayed.
  printf '{"type":"delegation_start","id":"d5","pid":%s,"bridge":"codex","role":"%s[31mraw","model":"m","task":"t","ts":"%s"}\n' "$SLEEPER" "$ESC" "$NOW" >>"$J"
}
hostile_state() {
  printf 'phase=%s[31mbuild%s]0;PWN\007\nupdated=%s\n' "$ESC" "$ESC" "$(m updated)" >.loomy/state
  printf 'master=claude\nacting=co%s[31mdex\nreason=%s[2Jquota %s\nresume_at=%s\nused_percent=%s\n' "$ESC" "$ESC" "$(m reason)" "$(m resume2)" "$(m used)" >.loomy/failover
  mkdir -p "$XDG_CONFIG_HOME/loomy"
  printf 'five_hour_pct=%s\nfive_hour_reset=%s\nseven_day_pct=%s\nseven_day_reset=99999999999\n' "$(m pct)" "$(m reset)" "$(m pct7)" >"$XDG_CONFIG_HOME/loomy/claude-limits"
}
export P

check() {   # check <name> <command...>: marker files and raw ESC
  local name="$1"; shift
  rm -f "$MARK"/*
  ( cd "$P" && CLAUDE_PROJECT_DIR="$P" LOOMY_PROJECT_ROOT="$P" timeout 90 "$@" </dev/null >"$WORK/out.txt" 2>&1 )
  local hits; hits="$(ls "$MARK" 2>/dev/null | tr '\n' ' ')"
  if [[ -z "$hits" ]]; then ok "$name: no marker file"; else ko "$name: injected commands ran ($hits)"; fi
  if LC_ALL=C grep -q "$ESC" "$WORK/out.txt"; then ko "$name: raw ESC reached the output"; else ok "$name: no raw ESC in the output"; fi
  if LC_ALL=C grep -q $'\xc2[\x80-\x9f]' "$WORK/out.txt"; then ko "$name: a C1 control (C2 80..9F) reached the output"; else ok "$name: no C1 control in the output"; fi
}

hostile_journal; hostile_state
L="$REPO/bin/loomy"
check "status" bash "$L" status
check "status --compact" bash "$L" status --compact
check "tree --once" bash "$L" tree --once
check "stats" bash "$L" stats
check "log" bash "$L" log -n 50
check "log --csv" bash "$L" log --csv
check "report (brief name with a tab)" bash "$L" report
check "statusline" bash -c "echo '{}' | bash '$REPO/scripts/loomy-statusline.sh'"
check "context (start hook)" bash "$REPO/scripts/loomy-context.sh" --hook start --root "$P"
check "context (resume text)" bash "$REPO/scripts/loomy-context.sh" --root "$P"

# ---- LR9-2: text columns that carry spaces (model, role, ts, advisor model) next to numbers. A `read` on the
# default IFS used to shift the text into a numeric variable. Journal events are now schema-checked where they
# are read, and the readers validate every number again.
# A value with spaces in front, then a payload without whitespace (${IFS} expands to a space only inside the subscript),
# so that `read` puts it whole into one variable, whichever column it lands in.
sp() { printf 'x 1 1 PATH[$(touch${IFS}%s/%s)]' "$MARK" "$1"; }
hostile_journal2() {
  local ts="$NOW" pid="$SLEEPER" c1; c1="$(printf 'a\xc2\x9bb')"
  plant \
   "{\"type\":\"session\",\"event\":\"start\",\"tool\":\"claude\",\"session\":\"s1\",\"pid\":$pid,\"model\":\"claude-sonnet-5-5\",\"effort\":\"high\",\"ts\":\"$ts\"}" \
   "{\"type\":\"phase\",\"phase\":\"brief\",\"ts\":\"2026-11-01T00:00:00Z $(sp bstart)\"}" \
   "{\"type\":\"phase\",\"phase\":\"done\",\"ts\":\"2026-11-01T01:00:00Z $(sp bend)\"}" \
   "{\"type\":\"advisor\",\"tool\":\"claude\",\"family\":\"claude\",\"model\":\"a\\u009bb $c1\",\"calls\":1,\"tokens_in\":10,\"ts\":\"$ts\"}" \
   "{\"type\":\"advisor\",\"tool\":\"claude\",\"family\":\"claude\",\"scope\":\"lead\",\"model\":\"a b $(printf 'PATH[$(touch${IFS}%s/advisor)]' "$MARK")\",\"calls\":2,\"tokens_in\":3000,\"tokens_out\":1,\"cost_usd\":0.1,\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation\",\"id\":\"m1\",\"bridge\":\"codex\",\"family\":\"codex\",\"role\":\"$(sp role)\",\"model\":\"$(sp model)\",\"status\":\"ok\",\"duration_s\":3,\"tokens_in\":5,\"tokens_out\":5,\"cost_usd\":0.2,\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation\",\"id\":\"m2\",\"bridge\":\"codex\",\"family\":\"codex\",\"role\":\"developer\",\"model\":\"a\\u009bb\",\"status\":\"ok\",\"duration_s\":3,\"tokens_in\":5,\"task\":\"t $c1 u\\u009bv\",\"ts\":\"$ts\"}" \
   "{\"type\":\"delegation\",\"id\":\"m3\",\"bridge\":\"claude\",\"family\":\"claude\",\"role\":\"reviewer\",\"model\":\"$(sp model2)\",\"status\":\"$(sp status)\",\"tokens_in\":5,\"ts\":\"$ts\"}" \
   "{\"type\":\"usage\",\"scope\":\"lead\",\"tool\":\"claude\",\"model\":\"$(sp umodel)\",\"messages\":2,\"ts\":\"$ts $(sp uts)\"}" \
   "{\"type\":\"delegation_start\",\"id\":\"m4\",\"pid\":$pid,\"bridge\":\"codex\",\"role\":\"$(sp srole)\",\"family\":\"codex\",\"model\":\"$(sp smodel)\",\"task\":\"$c1\",\"ts\":\"$ts\"}"
}
hostile_journal2
mkdir -p "$XDG_CONFIG_HOME/loomy"; printf 'advisor=opus\n' >"$XDG_CONFIG_HOME/loomy/config"   # the tree draws the advisor
printf 'phase=done\nupdated=2026-11-01 01:00\n' >.loomy/state; rm -f .loomy/failover
check "status (spaces in model, role, ts; bootstrap done)" bash "$L" status
check "status --compact (spaces)" bash "$L" status --compact
check "tree --once (spaces, advisor configured)" bash "$L" tree --once
check "stats (spaces)" bash "$L" stats
check "log (spaces)" bash "$L" log -n 50
check "report (spaces)" bash "$L" report

# The watch views render from the sampler cache (the reducer rows, then the frame): status and the tree diagram.
cat >"$WORK/watch-view.sh" <<'WATCH'
# usage: watch-view.sh <repo> <root> <status|tree|list>: one frame of the watch views, from the sampler rows.
REPO="$1"; ROOT="$2"; VIEW="$3"; J="$ROOT/.loomy/logs/events.jsonl"
export LOOMY_STATUS_LIBRARY=1
source "$REPO/scripts/loomy-status.sh" --root "$ROOT"
source "$REPO/scripts/loomy-tree.sh" --library
set +eu   # the frame code runs without errexit and nounset, as in loomy watch
loomy_live_init
LEGACY_USAGE="0 0 0 0 0 0"; LEGACY_ADVISOR="0 0 0 -"; LEGACY_TOTAL="0 0"; LEGACY_COUNT=0; LEGACY_NATIVE=0; LEGACY_HAS_USAGE=0; LEGACY_HAS_ADVISOR=0
rows="$(perl -e "$LOOMY_WATCH_LEGACY_PERL"'
  require "$ARGV[0]/scripts/lib/live-state.pl"; binmode STDOUT, ":encoding(UTF-8)";
  my $reader=Loomy::LiveState->new; my $cache=Loomy::WatchLegacy->new;
  $cache->consume($_,0,0) for $reader->journal_records($ARGV[1]);
  print "$_\n" for $cache->snapshot("claude",0);
' "$REPO" "$J")"
LEGACY_SEQ=0
while IFS= read -r row; do loomy_watch_legacy_accept "$row"; done <<<"$rows"
LV_NOW="$(date +%s)"; LV_CLOCK=01:00:00; loomy_live_states; loomy_live_metadata
tick=$LV_NOW; size=--full; watch_body_height=80; tree_mode=list; view="$VIEW"
[[ "$VIEW" != tree ]] || tree_mode=diagram
loomy_watch_legacy_pretty
COLUMNS=170 LINES=65 loomy_watch_legacy_render
WATCH
check "watch status view (spaces, bootstrap done)" bash "$WORK/watch-view.sh" "$REPO" "$P" status
check "watch tree diagram (spaces, advisor configured)" bash "$WORK/watch-view.sh" "$REPO" "$P" tree
if grep -q 'opus' "$WORK/out.txt"; then ok "the watch tree shows the advisor line"; else ko "the watch tree lost the advisor line"; fi
check "watch tree list (spaces)" bash "$WORK/watch-view.sh" "$REPO" "$P" list

# The reported case: the task text ends the line, its last field was evaluated as arithmetic.
plant "{\"type\":\"delegation_start\",\"id\":\"d4\",\"pid\":$SLEEPER,\"bridge\":\"codex\",\"role\":\"architect\",\"family\":\"codex\",\"model\":\"m\",\"task\":\"x|$(m reported)\",\"ts\":\"$NOW\"}"
check "status (reported single line)" bash "$L" status
if grep -q 'architect' "$WORK/out.txt"; then ok "status still shows the running delegation"; else ko "status lost the running delegation"; fi

printf '%s ok, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
