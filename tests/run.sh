#!/usr/bin/env bash
# Loomy tests: full terminal walkthroughs, without network or token.
# The claude and codex CLIs are replaced by test doubles (tests/stubs), the rest is real (git, bash, awk, sed).
#   tests/run.sh            runs every test
#   tests/run.sh -v         shows the output of failing commands
# Bash 3.2 compatible.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/loomy-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Settings inherited from the calling session (a Loomy project, a bridge, a routed role) must not leak in: the tests
# would act on that project instead of their own folders.
LIVE_ARTIFACTS="${LOOMY_TEST_LIVE_ARTIFACTS:-}"
TEST_TIMES="${LOOMY_TEST_TIMES:-0}"   # the suite's own setting, read before the cleanup below
for _v in $(env | sed -nE 's/^((LOOMY|AI|DELEGATE)_[A-Z0-9_]*|CLAUDE_PROJECT_DIR|CODEX_HOME)=.*/\1/p'); do unset "$_v"; done
# Isolated environment: controlled configuration, HOME and PATH, no colours.
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" NO_COLOR=1
export PATH="$HERE/stubs:/usr/bin:/bin:/usr/sbin:/sbin"
export LOOMY_CODEX_BIN="$HERE/stubs/codex"
# Project relays (.loomy/scripts/*.sh): the "installed" Loomy is this repository.
export LOOMY_HOME="$REPO"
# The agent stubs exit at once: live tracking beside them (the default of loomy start) is tested on its own.
export LOOMY_START_WATCH=0
# Official skills served from local test doubles (no network).
export LOOMY_SKILLS_FIXTURES="$HERE/fixtures/skills"
# No network check of the published catalog during tests.
export LOOMY_CATALOG_CHECK=0
export LOOMY_NO_AUTOUPDATE=1
# English interface for these tests (the language tests set it themselves).
export LOOMY_LANG=en
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME" "$XDG_CONFIG_HOME"
# Simulated GitHub: the gh double creates repositories in $GH_STUB_REMOTES, and Git redirects https://github.com/ there.
export GH_STUB_REMOTES="$WORK/github"; mkdir -p "$GH_STUB_REMOTES"
git config --global url."$GH_STUB_REMOTES/".insteadOf "https://github.com/"
LOOMY="$REPO/bin/loomy"

PASS=0; FAIL=0; OUT="$WORK/out.txt"

ok() { PASS=$(( PASS + 1 )); printf '  \033[32m✓\033[0m %s\n' "$1"; }
ko() {
  FAIL=$(( FAIL + 1 )); printf '  \033[31m✗ %s\033[0m\n' "$1"
  if (( VERBOSE )) && [[ -f "$OUT" ]]; then sed 's/^/      │ /' "$OUT" | tail -25; fi
}
# LOOMY_TEST_TIMES=1: time spent per section, slowest first, at the end (to keep the suite fast).
SEC_NAME=""; SEC_START=$SECONDS; SEC_TIMES=""
_sec_close() { [[ -n "$SEC_NAME" ]] && SEC_TIMES="$SEC_TIMES$(( SECONDS - SEC_START ))	$SEC_NAME"$'\n'; return 0; }
section() { _sec_close; SEC_NAME="$1"; SEC_START=$SECONDS; printf '\n\033[1m%s\033[0m\n' "$1"; }

# run <description> <command…>: the command must succeed.
run() { local d="$1"; shift; if "$@" >"$OUT" 2>&1; then ok "$d"; else ko "$d (code $?)"; fi; }
# fails <description> <expected code> <command…>: the command must fail with this code.
fails() {
  local d="$1" want="$2"; shift 2
  "$@" >"$OUT" 2>&1; local got=$?
  if [[ "$got" == "$want" ]]; then ok "$d"; else ko "$d (code $got, expected $want)"; fi
}
# has <description> <pattern>: the last output contains the pattern (grep -E).
has() { if grep -qE -- "$2" "$OUT"; then ok "$1"; else ko "$1 (pattern missing: $2)"; fi; }
hasnt() { if grep -qE -- "$2" "$OUT"; then ko "$1 (pattern present: $2)"; else ok "$1"; fi; }
file_has() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else ko "$1 (pattern missing from ${2##*/}: $3)"; fi; }

delegation_options_tests() {
  section "Delegation options"
  local op="$WORK/delegation-options" J first
  mkdir -p "$op"; git -C "$op" init -q
  run "delegation options: project initialized" "$LOOMY" init "$op" --yes --no-clipboard
  git -C "$op" add -A && git -C "$op" commit -qm "initialize delegation options fixture"
  J="$op/.loomy/logs/events.jsonl"; mkdir -p "${J%/*}"; : >"$J"
  delegation_pair_has() {
    local desc="$1" req="$2" off="$3" why="$4" effort="$5" sandbox="$6" files="$7" task="$8"
    if perl -MJSON::PP -e '
      my ($path,$want_req,$want_off,$want_why,$want_effort,$want_sandbox,$want_files,$want_task)=@ARGV;
      open my $f,"<",$path or die; my @e=map { decode_json($_) } grep { /\S/ } <$f>; die unless @e==2;
      die unless $e[0]{type} eq "delegation_start" && $e[1]{type} eq "delegation";
      for my $e (@e) {
        die "requested mismatch" unless (($e->{requested} ? "true" : "false") eq $want_req);
        die "off-routing/why mismatch: ".($e->{off_routing}//"")."/".($e->{why}//"") unless (($e->{off_routing}//"") eq $want_off && ($e->{why}//"") eq $want_why);
        die "effort/sandbox: expected $want_effort/$want_sandbox, got ".($e->{effort}//"")."/".($e->{sandbox}//"") unless (($e->{effort}//"") eq $want_effort && ($e->{sandbox}//"") eq $want_sandbox);
        die "task mismatch: ".($e->{task}//"") unless (($e->{task}//"") eq $want_task);
      }
      die if $want_files ne "skip" && ($e[1]{files_changed}//-1) != $want_files;
    ' "$J" "$req" "$off" "$why" "$effort" "$sandbox" "$files" "$task"; then ok "$desc"; else ko "$desc"; fi
  }

  run "codex: requested write with routing overrides" bash -c 'cd "$1" && STUB_WRITE=1 "$2" delegate codex architect --model gpt-6.1-sol --effort high --write --why "user request" "design it"' _ "$op" "$LOOMY"
  first="$(head -n 1 "$OUT")"
  if [[ "$first" == *"requested (user request)"* && "$first" == *"off routing: tool,sandbox"* ]]; then ok "codex: first stderr line explains requested and off routing"; else ko "codex: requested/off-routing banner missing"; fi
  delegation_pair_has "codex: both journal events and write result" true tool,sandbox "user request" high workspace-write 1 "design it"

  : >"$J"
  run "claude: explicit alias and effort" bash -c 'cd "$1" && LOOMY_BRIDGE_OK=1 "$2" delegate claude architect --model opus --effort max --why x "design it"' _ "$op" "$LOOMY"
  delegation_pair_has "claude: model and effort are off routing" true model,effort x max read-only 0 "design it"

  : >"$J"
  run "codex: environment effort is requested" bash -c 'cd "$1" && DELEGATE_CODEX_EFFORT=low "$2" delegate codex architect "environment effort"' _ "$op" "$LOOMY"
  delegation_pair_has "codex: environment effort recorded" true tool,effort "" low read-only 0 "environment effort"

  : >"$J"
  run "codex: option overrides environment effort" bash -c 'cd "$1" && DELEGATE_CODEX_EFFORT=low "$2" delegate codex architect --effort high "option wins"' _ "$op" "$LOOMY"
  delegation_pair_has "codex: option wins over environment effort" true tool "" high read-only 0 "option wins"

  : >"$J"
  run "codex: plain call" bash -c 'cd "$1" && "$2" delegate codex architect "plain call"' _ "$op" "$LOOMY"
  delegation_pair_has "codex: plain call is unrequested" false tool "" high read-only 0 "plain call"

  fails "codex: model with spaces rejected" 2 bash -c 'cd "$1" && "$2" delegate codex architect --model "a b" task' _ "$op" "$LOOMY"
  fails "claude: Codex model rejected" 2 bash -c 'cd "$1" && "$2" delegate claude architect --model gpt-5 task' _ "$op" "$LOOMY"
  fails "claude: write refused without failover" 2 bash -c 'cd "$1" && "$2" delegate claude architect --write task' _ "$op" "$LOOMY"
  fails "delegation: invalid effort rejected" 2 bash -c 'cd "$1" && "$2" delegate codex architect --effort impossible task' _ "$op" "$LOOMY"
  fails "delegation: unknown option rejected" 2 bash -c 'cd "$1" && "$2" delegate codex architect --opt task' _ "$op" "$LOOMY"
  fails "delegation: option without value rejected" 2 bash -c 'cd "$1" && "$2" delegate codex architect --model' _ "$op" "$LOOMY"
  run "claude: write accepted during Codex failover" bash -c 'cd "$1" && LOOMY_FAILOVER_FROM=codex "$2" delegate claude executor --write "failover write"' _ "$op" "$LOOMY"

  : >"$J"
  if (cd "$op" && env LOOMY_UI_LANG=fr "$LOOMY" delegate codex architect --model gpt-6.1-sol --why raison "tâche") >"$WORK/fr.out" 2>"$WORK/fr.err"; then
    if grep -q 'demandé.*hors routage' "$WORK/fr.err"; then ok "delegation: French stderr translates requested and off routing"; else ko "delegation: French banner translation missing"; fi
  else ko "delegation: French bridge failed"; fi

  : >"$J"
  run "delegation: task and why privacy" bash -c 'cd "$1" && LOOMY_JOURNAL_TASKS=0 "$2" delegate codex architect --why SECRET-WHY SECRET-TASK' _ "$op" "$LOOMY"
  if perl -MJSON::PP -e 'my $p=shift; open my $f,"<",$p or die; my @e=map { decode_json($_) } grep { /\S/ } <$f>; die unless @e==2; for my $e (@e) { die unless ($e->{why}//"x") eq "" && ($e->{task}//"x") eq "" }' "$J"; then ok "delegation: journal omits why and task text"; else ko "delegation: why or task leaked into journal"; fi

  local cap_tmp="$WORK/capture-watch-tmp" cap_bin="$WORK/capture-watch-bin"
  mkdir -p "$cap_tmp" "$cap_bin"
  cat >"$cap_bin/mkdir" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do [[ "$arg" == */demo-project ]] && exit 1; done
exec /bin/mkdir "$@"
STUB
  chmod +x "$cap_bin/mkdir"
  fails "capture watch: init setup failure exits" 1 env TMPDIR="$cap_tmp" PATH="$cap_bin:$PATH" bash "$REPO/tools/capture-watch.sh" en "$WORK/capture-watch.svg"
  if find "$cap_tmp" -mindepth 1 -maxdepth 1 -name 'loomy-watch-capture.*' -print | grep -q .; then ko "capture watch: failed init left its temp dir"; else ok "capture watch: failed init removes its temp dir"; fi

  local bridge_pid child_pid attempts codex_pid_file="$WORK/codex-child.pid" claude_pid_file="$WORK/claude-child.pid"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"interrupted-bridge-test","pid":%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" >>"$J"
  bash -c 'cd "$1" && exec env STUB_SLEEP=30 STUB_PID_FILE="$2" "$3" delegate codex architect --effort low --why "cancel codex" "Interrupt codex"' _ "$op" "$codex_pid_file" "$LOOMY" >"$OUT" 2>&1 &
  bridge_pid=$!
  attempts=0
  while ! grep -q '"type":"delegation_start".*"task":"Interrupt codex"' "$J"; do
    attempts=$(( attempts + 1 )); (( attempts < 100 )) || break; sleep 0.05
  done
  attempts=0
  while [[ ! -s "$codex_pid_file" ]]; do
    attempts=$(( attempts + 1 )); (( attempts < 100 )) || break; sleep 0.05
  done
  kill -TERM "$bridge_pid" 2>/dev/null || true
  wait "$bridge_pid"; local codex_exit=$?
  [[ "$codex_exit" == 143 ]] && ok "codex: TERM exits with 143" || ko "codex: TERM exit was $codex_exit"
  run "codex: one interrupted final event preserves start metadata" perl -MJSON::PP -e '
    my ($path,$task,$signal,$bridge)=@ARGV; open my $f,"<",$path or die; my @e=map { decode_json($_) } grep { /\S/ } <$f>;
    my ($s)=grep { ($_->{type}//"") eq "delegation_start" && ($_->{task}//"") eq $task } @e;
    die "start missing" unless $s; my @f=grep { ($_->{type}//"") eq "delegation" && ($_->{id}//"") eq $s->{id} } @e;
    die "expected one final event" unless @f==1; my $d=$f[0];
    die "interrupted fields missing" unless $d->{status} eq "interrupted" && $d->{outcome} eq "interrupted" && $d->{signal} eq $signal && $d->{bridge} eq $bridge && $d->{duration_s}=~/^\d+$/;
    for my $k (qw(id role family model effort sandbox requested requested_model off_routing why task)) { die "$k mismatch" unless ($d->{$k}//"") eq ($s->{$k}//"") }
    die "nonzero usage" unless $d->{tokens_in}==0 && $d->{tokens_cached}==0 && $d->{tokens_out}==0 && $d->{cost_usd}==0;
  ' "$J" "Interrupt codex" TERM codex
  if [[ -s "$codex_pid_file" ]]; then child_pid="$(cat "$codex_pid_file")"; if kill -0 "$child_pid" 2>/dev/null; then ko "codex: stub child remains alive"; kill -KILL "$child_pid" 2>/dev/null || true; else ok "codex: stub child is gone"; fi; else ko "codex: stub child pid was not recorded"; fi
  run "codex: interrupted final event renders with duration in tree" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$op" --once
  has "codex: tree shows interrupted state and duration" '⊘ Architect.*0:[0-9][0-9].*· interrupted'

  perl -e '$SIG{INT}="DEFAULT"; exec @ARGV' bash -c 'cd "$1" && exec env STUB_SLEEP=30 STUB_PID_FILE="$2" LOOMY_BRIDGE_OK=1 "$3" delegate claude architect --effort low --why "cancel claude" "Interrupt claude"' _ "$op" "$claude_pid_file" "$LOOMY" >"$OUT" 2>&1 &
  bridge_pid=$!
  attempts=0
  while ! grep -q '"type":"delegation_start".*"task":"Interrupt claude"' "$J"; do
    attempts=$(( attempts + 1 )); (( attempts < 100 )) || break; sleep 0.05
  done
  attempts=0
  while [[ ! -s "$claude_pid_file" ]]; do
    attempts=$(( attempts + 1 )); (( attempts < 100 )) || break; sleep 0.05
  done
  kill -INT "$bridge_pid" 2>/dev/null || true
  wait "$bridge_pid"; local claude_exit=$?
  [[ "$claude_exit" == 130 ]] && ok "claude: INT exits with 130" || ko "claude: INT exit was $claude_exit"
  run "claude: one interrupted final event preserves start metadata" perl -MJSON::PP -e '
    my ($path,$task,$signal,$bridge)=@ARGV; open my $f,"<",$path or die; my @e=map { decode_json($_) } grep { /\S/ } <$f>;
    my ($s)=grep { ($_->{type}//"") eq "delegation_start" && ($_->{task}//"") eq $task } @e;
    die "start missing" unless $s; my @f=grep { ($_->{type}//"") eq "delegation" && ($_->{id}//"") eq $s->{id} } @e;
    die "expected one final event" unless @f==1; my $d=$f[0];
    die "interrupted fields missing" unless $d->{status} eq "interrupted" && $d->{outcome} eq "interrupted" && $d->{signal} eq $signal && $d->{bridge} eq $bridge && $d->{duration_s}=~/^\d+$/;
    for my $k (qw(id role family model effort sandbox requested requested_model off_routing why task)) { die "$k mismatch" unless ($d->{$k}//"") eq ($s->{$k}//"") }
    die "nonzero usage" unless $d->{tokens_in}==0 && $d->{tokens_cached}==0 && $d->{tokens_out}==0 && $d->{cost_usd}==0;
  ' "$J" "Interrupt claude" INT claude
  if [[ -s "$claude_pid_file" ]]; then child_pid="$(cat "$claude_pid_file")"; if kill -0 "$child_pid" 2>/dev/null; then ko "claude: stub child remains alive"; kill -KILL "$child_pid" 2>/dev/null || true; else ok "claude: stub child is gone"; fi; else ko "claude: stub child pid was not recorded"; fi
  run "claude: interrupted final event renders with duration in tree" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$op" --once
  has "claude: tree shows interrupted state and duration" '⊘ Architect.*0:[0-9][0-9].*· interrupted'

  local status_only="$WORK/interrupted-status-only"
  mkdir -p "$status_only/.loomy/logs"; cp "$op/.loomy/brief.md" "$status_only/.loomy/brief.md"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"status-only","pid":%s}\n{"ts":"%s","type":"delegation_start","session":"status-only","id":"status-only","pid":99999999,"bridge":"codex","role":"architect","family":"codex","model":"gpt-6-luna","effort":"low","task":"status only"}\n{"ts":"%s","type":"delegation","session":"status-only","id":"status-only","bridge":"codex","role":"architect","family":"codex","model":"gpt-6-luna","effort":"low","status":"interrupted","duration_s":7,"signal":"TERM","tokens_in":0,"tokens_cached":0,"tokens_out":0,"cost_usd":0}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$status_only/.loomy/logs/events.jsonl"
  run "tree: status interrupted maps to the interrupted outcome" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$status_only" --once
  has "tree: status-only event uses ⊘ and recorded duration" '⊘ Architect.*0:07.*· interrupted'
}

interrupted_delegation_tests() {
  section "Interrupted delegations"
  local op="$WORK/interrupted-delegations" cli_dir="$WORK/interrupted-cli" bridge mode task pid_file descendant_file bridge_pid attempts status started elapsed pid
  mkdir -p "$op" "$cli_dir"
  git -C "$op" init -q
  run "interrupted: project initialized" "$LOOMY" init "$op" --yes --no-clipboard
  git -C "$op" add -A && git -C "$op" commit -qm "initialize interrupted delegation fixture"
  local J="$op/.loomy/logs/events.jsonl"
  cat >"$cli_dir/stub" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  --version)
    if [[ "${0##*/}" == claude ]]; then echo "2.1.300 (Claude Code)"; else echo "codex-cli 0.160.0"; fi
    exit 0 ;;
  exec) shift ;;
esac
[[ -z "${STUB_CLI_PID_FILE:-}" ]] || printf '%s\n' "$$" >"$STUB_CLI_PID_FILE"
if [[ "${STUB_MODE:-}" == ignore-term ]]; then trap '' TERM; fi
sleep 30 &
descendant=$!
[[ -z "${STUB_DESCENDANT_PID_FILE:-}" ]] || printf '%s\n' "$descendant" >"$STUB_DESCENDANT_PID_FILE"
if [[ "${STUB_MODE:-}" == ignore-term ]]; then
  while :; do sleep 30; done
else
  wait "$descendant"
fi
STUB
  cp "$cli_dir/stub" "$cli_dir/codex"
  cp "$cli_dir/stub" "$cli_dir/claude"
  chmod +x "$cli_dir/codex" "$cli_dir/claude"

  for bridge in codex claude; do
    for mode in normal ignore-term; do
      task="Interrupt $bridge $mode"
      pid_file="$WORK/$bridge-$mode-cli.pid"
      descendant_file="$WORK/$bridge-$mode-descendant.pid"
      rm -f "$pid_file" "$descendant_file"
      if [[ "$bridge" == codex ]]; then
        bash -c 'cd "$1" && exec env STUB_MODE="$2" STUB_CLI_PID_FILE="$3" STUB_DESCENDANT_PID_FILE="$4" LOOMY_CODEX_BIN="$5" "$6" delegate codex architect --effort low "$7"' \
          _ "$op" "$mode" "$pid_file" "$descendant_file" "$cli_dir/codex" "$LOOMY" "$task" >"$OUT" 2>&1 &
      else
        bash -c 'cd "$1" && exec env STUB_MODE="$2" STUB_CLI_PID_FILE="$3" STUB_DESCENDANT_PID_FILE="$4" LOOMY_BRIDGE_OK=1 PATH="$5:$PATH" "$6" delegate claude architect --effort low "$7"' \
          _ "$op" "$mode" "$pid_file" "$descendant_file" "$cli_dir" "$LOOMY" "$task" >"$OUT" 2>&1 &
      fi
      bridge_pid=$!
      attempts=0
      while [[ ! -s "$pid_file" || ! -s "$descendant_file" ]]; do
        attempts=$(( attempts + 1 )); (( attempts < 200 )) || break; sleep 0.05
      done
      if [[ ! -s "$pid_file" || ! -s "$descendant_file" ]]; then
        kill -TERM "$bridge_pid" 2>/dev/null || true
        wait "$bridge_pid" 2>/dev/null || true
        ko "$bridge: $mode stub did not start"
        continue
      fi

      started="$(date +%s)"
      kill -TERM "$bridge_pid" 2>/dev/null || true
      wait "$bridge_pid"; status=$?
      elapsed=$(( $(date +%s) - started ))
      [[ "$status" == 143 ]] && ok "$bridge: $mode TERM exits with 143" || ko "$bridge: $mode TERM exit was $status"
      if [[ "$mode" == ignore-term ]]; then
        (( elapsed <= 6 )) && ok "$bridge: ignored TERM is bounded to ${elapsed}s" || ko "$bridge: ignored TERM took ${elapsed}s"
      fi

      for pid_file in "$pid_file" "$descendant_file"; do
        pid="$(cat "$pid_file")"
        if kill -0 "$pid" 2>/dev/null; then
          ko "$bridge: $mode process $pid remains alive"
          kill -KILL "$pid" 2>/dev/null || true
        else ok "$bridge: $mode process $pid is gone"; fi
      done
      if perl -MJSON::PP -e '
        my ($path,$task,$bridge)=@ARGV; open my $f,"<",$path or die; my @e=map { decode_json($_) } grep { /\S/ } <$f>;
        my ($s)=grep { ($_->{type}//"") eq "delegation_start" && ($_->{task}//"") eq $task } @e;
        die "start missing" unless $s; my @f=grep { ($_->{type}//"") eq "delegation" && ($_->{id}//"") eq $s->{id} } @e;
        die "expected one final event" unless @f==1; my $d=$f[0];
        die "interrupted fields missing" unless $d->{status} eq "interrupted" && $d->{outcome} eq "interrupted" && $d->{signal} eq "TERM" && $d->{bridge} eq $bridge && $d->{duration_s}=~/^\d+$/;
      ' "$J" "$task" "$bridge"; then ok "$bridge: $mode writes one interrupted final event"; else ko "$bridge: $mode final event missing or duplicated"; fi
    done
  done
}

# ------------------------------------------------------------------ live native agents and watch
live_view_tests() {
  section "Live view"
  local lv="$WORK/live" nowz before
  mkdir -p "$lv/.loomy/logs" "$lv/.claude/agents"
  printf -- '---\nname: Live demo\nai_mode: ORCHESTRATED\nai_lead: claude\nbudget: equilibre\n---\n' >"$lv/.loomy/brief.md"
  printf 'phase=done\n' >"$lv/.loomy/state"
  printf -- '---\nname: developer\nmodel: claude-sonnet-5-5\neffort: high\n---\n' >"$lv/.claude/agents/developer.md"
  nowz="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"live","pid":%s}\n' "$nowz" "$$" >"$lv/.loomy/logs/events.jsonl"
  printf '%s\n' '{"session_id":"live","prompt":"Make the agents visible, with a \"live\" timer"}' | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook prompt >"$OUT"
  file_has "prompt: request and escaped excerpt" "$lv/.loomy/logs/events.jsonl" '"type":"request"'
  before="$(wc -c <"$lv/.loomy/logs/events.jsonl")"
  printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"ignored"}}' | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook agent-start
  [[ "$(wc -c <"$lv/.loomy/logs/events.jsonl")" == "$before" ]] && ok "ordinary tools: no event" || ko "ordinary tools: event written"
  printf '%s' '{"session_id":"live","tool_use_id":"native-1","tool_name":"Agent","tool_input":{"subagent_type":"loomy-developer","description":"Add native live tracking","run_in_background":true}}' | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook agent-start
  file_has "native start: role, model and effort from front matter" "$lv/.loomy/logs/events.jsonl" '"bridge":"subagent","role":"developer","family":"claude","model":"claude-sonnet-5-5","effort":"high"'
  file_has "native start: default is unrequested and routing differences are computed" "$lv/.loomy/logs/events.jsonl" '"id":"native-1".*"requested":false,"off_routing":"effort"'
  file_has "native start: id and session" "$lv/.loomy/logs/events.jsonl" '"id":"native-1","session":"live","pid":[0-9]+'
  run "live frame by request" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$lv" --once
  has "live: request group and task" 'Make the agents visible|Add native live tracking'
  has "live: in-progress header" 'IN PROGRESS'
  awk '/IN PROGRESS/{a=1} /^SESSION/{a=0} a' "$OUT" >"$lv/running.txt"
  grep -q Developer "$lv/running.txt" && ok "native running in progress" || ko "native missing from progress"
  awk '/^SESSION/{a=1} a' "$OUT" >"$lv/finished.txt"
  grep -q Developer "$lv/finished.txt" && ko "running agent in recap" || ok "running agent excluded from recap"
  printf '%s' '{"session_id":"live","tool_use_id":"native-1","tool_name":"Agent","tool_response":{"agentId":"a1","isAsync":true}}' | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook agent-return
  printf '%s\n' '{"type":"user","message":{"content":"Add native live tracking"}}' '{"type":"assistant","message":{"id":"msg_native","model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":20},"content":[{"type":"text","text":"STATUS: done\nSUMMARY: live tracking works"}]}}' >"$lv/transcript.jsonl"
  printf '{"session_id":"live","agent_type":"developer","agent_id":"a1","agent_transcript_path":"%s"}' "$lv/transcript.jsonl" | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook subagent
  file_has "native stop: closes the original id" "$lv/.loomy/logs/events.jsonl" '"type":"delegation","agent_id":"a1".*"duration_s":[0-9]+.*"id":"native-1".*"outcome":"done".*"tokens_in":0.*"tokens_out":0'
  file_has "native stop: cost belongs to usage" "$lv/.loomy/logs/events.jsonl" '"cost_in":"usage"'
  file_has "native stop: existing usage retained" "$lv/.loomy/logs/events.jsonl" '"type":"usage".*"scope":"subagent"'
  [[ -n "$(find "$lv/.loomy/memory/delegations" -name '*.md' -print 2>/dev/null)" ]] && ok "native stop: memory retained" || ko "native stop: no memory"
  printf '{"session_id":"live","agent_type":"developer","agent_id":"a1","agent_transcript_path":"%s"}' "$lv/transcript.jsonl" | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook subagent
  [[ "$(grep -c '"type":"delegation",' "$lv/.loomy/logs/events.jsonl")" == 1 ]] && ok "duplicate stop: no duplicate completion" || ko "duplicate completion"
  run "live completed frame" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$lv" --once
  awk '/IN PROGRESS/{a=1} /^SESSION/{a=0} a' "$OUT" >"$lv/running.txt"
  grep -q Developer "$lv/running.txt" && ko "finished agent still in progress" || ok "finished excluded from progress"
  has "finished appears in session recap" '✓ Developer'
  local lost="$WORK/live-lost" ended="$WORK/live-ended" recent="$WORK/live-recent" dead="$WORK/live-dead" oldz recentz f
  nowz="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  oldz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime(time-20))')"
  recentz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime(time-2))')"
  for f in "$lost" "$ended" "$recent" "$dead"; do mkdir -p "$f/.loomy/logs"; cp "$lv/.loomy/brief.md" "$f/.loomy/brief.md"; done
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"lost","pid":%s}\n' "$nowz" "$$" >"$lost/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation_start","session":"lost","id":"orphan","pid":%s,"bridge":"subagent","role":"developer","family":"claude","model":"claude-sonnet-5-5","background":true,"task":"background task"}\n' "$oldz" "$$" >>"$lost/.loomy/logs/events.jsonl"
  run "old native async start is lost in the session recap" env LOOMY_SUBAGENT_MAX_S=10 COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$lost" --once
  has "lost native agent appears in recap" '^  ! lost Developer'
  has "lost native agent is counted in session" '^SESSION · 1 finished'
  awk '/IN PROGRESS/{a=1} /^SESSION/{a=0} a' "$OUT" >"$WORK/lost-progress.txt"
  grep -q Developer "$WORK/lost-progress.txt" && ko "lost native agent remains in progress" || ok "lost native agent removed from progress"
  local lost_count
  lost_count="$(awk '/^SESSION/{a=1} a' "$OUT" | grep -o 'lost' | wc -l | tr -d ' ')"
  [[ "$lost_count" == 1 ]] && ok "lost is shown once in the session recap" || ko "lost appears $lost_count times in the recap"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"ended","pid":%s}\n' "$nowz" "$$" >"$ended/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation_start","session":"ended","id":"ended-agent","pid":%s,"bridge":"subagent","role":"developer","family":"claude","model":"claude-sonnet-5-5","background":true}\n{"ts":"%s","type":"session","event":"end","tool":"claude","session":"ended","pid":%s}\n' "$recentz" "$$" "$nowz" "$$" >>"$ended/.loomy/logs/events.jsonl"
  run "ended lead session interrupts native start" env LOOMY_SUBAGENT_MAX_S=10 NO_COLOR= LOOMY_FORCE_COLOR=1 COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$ended" --once
  has "ended session shows interrupted glyph and outcome" '⊘ Developer.*· interrupted'
  if perl -0777 -e 'local $/; my $s=<>; exit($s =~ /\e\[2m\e\[31m  ⊘ Developer/ ? 0 : 1)' "$OUT"; then ok "interrupted native row is dim red"; else ko "interrupted native row is not dim red"; fi
  run "French ended session uses interrupted label" env LOOMY_UI_LANG=fr COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$ended" --once
  has "French interrupted label" '⊘ Développeur.*· interrompu'
  run "diagram closed session shows only its closed state" env LOOMY_TREE=diagram COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$ended"
  has "diagram lead: closed session label" 'session closed'
  hasnt "diagram lead: closed session omits done" 'session closed.*done'
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"recent","pid":%s}\n{"ts":"%s","type":"delegation_start","session":"recent","id":"recent-agent","pid":%s,"bridge":"subagent","role":"developer","family":"claude","model":"claude-sonnet-5-5","background":true}\n' "$nowz" "$$" "$recentz" "$$" >"$recent/.loomy/logs/events.jsonl"
  run "recent native async start remains in progress" env LOOMY_SUBAGENT_MAX_S=10 COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$recent" --once
  awk '/IN PROGRESS/{a=1} /^SESSION/{a=0} a' "$OUT" >"$WORK/recent-progress.txt"
  grep -q Developer "$WORK/recent-progress.txt" && ok "recent native agent remains in progress" || ko "recent native agent missing from progress"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"dead","pid":99999999}\n{"ts":"%s","type":"delegation_start","session":"dead","id":"dead-parent-agent","pid":%s,"bridge":"subagent","role":"developer","family":"claude","model":"claude-sonnet-5-5","background":true}\n' "$nowz" "$recentz" "$$" >"$dead/.loomy/logs/events.jsonl"
  run "dead lead pid interrupts native start" env LOOMY_SUBAGENT_MAX_S=10 COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$dead" --once
  has "dead lead pid shows interrupted glyph and outcome" '⊘ Developer.*· interrupted'
  local bridge_dead="$WORK/live-bridge-dead" readside="$WORK/live-read-side" rsj="$WORK/live-read-side/.loomy/logs/events.jsonl"
  mkdir -p "$bridge_dead/.loomy/logs" "$readside/.loomy/logs"
  cp "$lv/.loomy/brief.md" "$bridge_dead/.loomy/brief.md"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"bridge-live","pid":%s}\n{"ts":"%s","type":"delegation_start","session":"bridge-live","id":"bridge-dead","pid":99999999,"bridge":"codex","role":"developer","family":"codex","model":"gpt-6-luna","effort":"low","task":"Bridge lost before completion"}\n' "$nowz" "$$" "$nowz" >"$bridge_dead/.loomy/logs/events.jsonl"
  run "dead bridge is interrupted in live recap" env NO_COLOR= LOOMY_FORCE_COLOR=1 COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$bridge_dead" --once
  has "dead bridge recap uses interrupted glyph and outcome" '⊘ Developer.*· interrupted'
  awk '/^SESSION/{a=1} a' "$OUT" >"$bridge_dead/recap.txt"
  grep -q '⊘ Developer.*· interrupted' "$bridge_dead/recap.txt" && ok "interrupted delegation remains visible in recap" || ko "interrupted delegation missing from recap"
  if perl -0777 -e 'local $/; my $s=<>; exit($s =~ /\e\[2m\e\[31m[^\n]*⊘ Developer/ ? 0 : 1)' "$OUT"; then ok "interrupted bridge row is dim red"; else ko "interrupted bridge row is not dim red"; fi
  local layout="$WORK/live-interrupted-layout" base_epoch next_epoch own_epoch link_epoch stop_epoch last_epoch end_epoch done_epoch basez nextz ownz linkz stopz lastz endz donez
  mkdir -p "$layout/.loomy/logs"; cp "$lv/.loomy/brief.md" "$layout/.loomy/brief.md"
  base_epoch="$(perl -MTime::Local=timegm -e 'print timegm(0,0,0,1,0,2026)')"; next_epoch=$(( base_epoch + 37 )); own_epoch=$(( base_epoch + 40 )); link_epoch=$(( base_epoch + 50 )); stop_epoch=$(( base_epoch + 64 )); last_epoch=$(( base_epoch + 70 )); end_epoch=$(( base_epoch + 80 )); done_epoch=$(( base_epoch + 90 ))
  basez="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$base_epoch")"
  nextz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$next_epoch")"
  ownz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$own_epoch")"
  linkz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$link_epoch")"
  stopz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$stop_epoch")"
  lastz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$last_epoch")"
  endz="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$end_epoch")"
  donez="$(perl -MPOSIX=strftime -e 'print strftime("%Y-%m-%dT%H:%M:%SZ",gmtime($ARGV[0]))' "$done_epoch")"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"stable","pid":%s}\n{"ts":"%s","type":"delegation_start","session":"stable","id":"interrupted","pid":99999999,"bridge":"codex","role":"developer","family":"codex","model":"gpt-6-luna","effort":"high","task":"Interrupted task"}\n{"ts":"%s","type":"delegation_start","session":"stable","id":"next","pid":99999998,"bridge":"codex","role":"debugger","family":"codex","model":"gpt-6-luna","effort":"medium","task":"Next task"}\n{"ts":"%s","type":"delegation_start","session":"stable","id":"own","pid":%s,"bridge":"subagent","role":"reviewer","family":"claude","model":"claude-sonnet-5-5","effort":"low","task":"Native task"}\n{"ts":"%s","type":"subagent_link","session":"stable","id":"own","agent_id":"native-a"}\n{"ts":"%s","type":"subagent_stop","session":"stable","agent_id":"native-a"}\n{"ts":"%s","type":"delegation_start","session":"stable","id":"last","pid":99999997,"bridge":"codex","role":"architect","family":"codex","model":"gpt-6-luna","effort":"medium","task":"Last task"}\n{"ts":"%s","type":"session","event":"end","tool":"claude","session":"stable","pid":%s}\n{"ts":"%s","type":"delegation","session":"stable","id":"complete","role":"developer","family":"codex","model":"gpt-6-luna","effort":"high","status":"ok","outcome":"done","duration_s":12,"task":"Completed task"}\n' "$basez" "$$" "$basez" "$nextz" "$ownz" "$$" "$linkz" "$stopz" "$lastz" "$endz" "$$" "$donez" >"$layout/.loomy/logs/events.jsonl"
  run "interrupted rows keep outcome after aligned task columns" env COLUMNS=100 LINES=30 NO_COLOR= LOOMY_FORCE_COLOR=1 bash "$REPO/scripts/loomy-tree.sh" --root "$layout" --once
  has "interrupted status column contains only glyph" '⊘ Developer.*Interrupted task · interrupted'
  cp "$OUT" "$layout/frame.txt"
  run "interrupted role and task columns align with completed row" perl -MEncode=decode -e '
    use utf8; my ($role_done,$role_interrupted,$task_done,$task_interrupted);
    while (<>) { my $s=decode("UTF-8",$_); $s =~ s/\e\[[0-9;]*[[:alpha:]]//g;
      if ($s =~ /^  ✓ Developer/) { $role_done=index($s,"Developer"); $task_done=index($s,"Completed task") }
      if ($s =~ /^  ⊘ Developer/) { $role_interrupted=index($s,"Developer"); $task_interrupted=index($s,"Interrupted task"); die if $s =~ /^  ⊘ interrupted/ }
    }
    die unless defined($role_done) && defined($role_interrupted) && defined($task_done) && defined($task_interrupted);
    die unless $role_done==$role_interrupted && $task_done==$task_interrupted;
  ' "$layout/frame.txt"
  file_has "bridge without an endpoint shows an em dash" "$layout/frame.txt" '⊘ Architect.*—'
  run "interrupted own-event and fallback durations stay fixed five seconds apart" bash -c '
    source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/config.sh"; source "$1/scripts/lib/usage.sh"; source "$1/scripts/lib/phases.sh"; source "$1/scripts/loomy-tree.sh" --library
    duration_at() { loomy_live_init; loomy_live_poll "$3"; LV_NOW="$1"; loomy_live_states; printf "%s:%s" "${LV_DURATION[0]}" "${LV_DURATION[2]}"; }
    one="$(duration_at "$(( $2 + 100 ))" unused "$4")"; two="$(duration_at "$(( $2 + 105 ))" unused "$4")"
    test "$one:$two" = "37:24:37:24"
  ' _ "$REPO" "$base_epoch" unused "$layout/.loomy/logs/events.jsonl"
  run "dead bridge uses interrupted state in the diagram" env NO_COLOR= LOOMY_FORCE_COLOR=1 LOOMY_TREE=diagram COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$bridge_dead"
  has "diagram interrupted box shows glyph and label" '⊘ interrupted'
  if perl -0777 -e 'local $/; my $s=<>; exit($s =~ /\e\[2m\e\[31m[^\n]*⊘ interrupted/ ? 0 : 1)' "$OUT"; then ok "diagram interrupted state is dim red"; else ko "diagram interrupted state is not dim red"; fi
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"read-side","pid":%s}\n{"ts":"%s","type":"delegation_start","session":"read-side","id":"dead-bridge","pid":99999999,"bridge":"codex","role":"developer","family":"codex","model":"gpt-6-luna"}\n{"ts":"%s","type":"delegation_start","session":"read-side","id":"closed-native","pid":%s,"bridge":"subagent","role":"reviewer","family":"claude","model":"claude-sonnet-5-5"}\n{"ts":"%s","type":"session","event":"end","tool":"claude","session":"read-side","pid":%s}\n{"ts":"%s","type":"delegation","id":"failed-final","role":"debugger","family":"codex","model":"gpt-6-luna","status":"error","outcome":"failed"}\n' "$nowz" "$$" "$nowz" "$nowz" "$$" "$nowz" "$$" "$nowz" >"$rsj"
  run "journal reader classifies orphan starts without changing final failures" bash -c '
    source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"
    ai_journal_display_events "$2" >"$3"
    grep -q "|developer|interrupted|" "$3" && grep -q "|reviewer|interrupted|" "$3" && grep -q "|debugger|failed|" "$3"
  ' _ "$REPO" "$rsj" "$readside/events.txt"
  run "invalid native timeout uses the default" env LOOMY_SUBAGENT_MAX_S=invalid bash -c 'source "$1/scripts/loomy-tree.sh" --library; test "$LOOMY_SUBAGENT_MAX_S" = 7200' _ "$REPO"
  # Legacy Task, unknown role, escaped payload, and session fallback.
  printf '%s' '{"session_id":"live","tool_use_id":"native-2","tool_name":"Task","tool_input":{"subagent_type":"Explore","description":"Inspect \"hooks\"\ncarefully"}}' | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook agent-start
  file_has "legacy Task: unknown role preserved" "$lv/.loomy/logs/events.jsonl" '"role":"Explore".*"model":"claude-opus'
  printf '%s' '{"session_id":"live","prompt":"Second request"}' | env LOOMY_JOURNAL_TASKS=0 bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook prompt >/dev/null
  file_has "prompt privacy: empty excerpt" "$lv/.loomy/logs/events.jsonl" '"excerpt":"".*"type":"request"'
  printf '%s' '{"session_id":"live","tool_use_id":"native-3","tool_name":"Agent","tool_input":{"subagent_type":"developer","description":"Second role"}}' | env LOOMY_JOURNAL_TASKS=0 bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook agent-start
  file_has "delegation privacy: empty task" "$lv/.loomy/logs/events.jsonl" '"id":"native-3".*"task":""'
  printf '%s' '{"session_id":"live","tool_use_id":"native-4","tool_name":"Agent","tool_input":{"subagent_type":"developer","model":"claude-opus-5-5","description":"Lead-selected model"}}' | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook agent-start
  file_has "native explicit model: real model and requested mark" "$lv/.loomy/logs/events.jsonl" '"id":"native-4".*"model":"claude-opus-5-5".*"requested":true,"off_routing":"model,effort"'
  printf '%s' '{"session_id":"live","tool_use_id":"native-5","tool_name":"Agent","tool_input":{"subagent_type":"architect","model":"claude-opus-5-5","description":"Explicitly requested routed model"}}' | bash "$REPO/scripts/loomy-context.sh" --root "$lv" --hook agent-start
  file_has "native explicit routed model: requested with empty off routing" "$lv/.loomy/logs/events.jsonl" '"id":"native-5".*"model":"claude-opus-5-5".*"requested":true,"off_routing":""'
  run "group by request: private request numbered" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$lv" --once
  has "request grouping: numbered second prompt" 'request 2'
  cp "$OUT" "$lv/request-frame.txt"
  run "watch_group saved" bash -c 'source "$1/scripts/lib/config.sh"; loomy_config_set watch_group model; test "$(loomy_config_get watch_group request)" = model' _ "$REPO"
  run "group by model from configuration" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$lv" --once
  has "model grouping: running count" '┌─ claude-sonnet-5-5 · 1 running'
  has "model grouping: separate session" '^SESSION · 1 finished'
  cp "$OUT" "$lv/model-frame.txt"
  run "compact 45 columns" env COLUMNS=45 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$lv" --once
  hasnt "compact: no bar or task column" '▮|▯|Second role'
  cp "$OUT" "$lv/compact-frame.txt"
  perl -MEncode=decode -e 'my ($f,$w)=@ARGV; open my $h,"<",$f or die; while (<$h>) {chomp; exit 1 if length(decode("UTF-8",$_))>$w}' "$lv/compact-frame.txt" 44 && ok "compact: no wrapping" || ko "compact wraps"
  if [[ -n "$LIVE_ARTIFACTS" ]]; then mkdir -p "$LIVE_ARTIFACTS"; cp "$lv/"*-frame.txt "$LIVE_ARTIFACTS/"; fi
  # Incremental reader: unchanged offsets, partial writes, truncate/rotate, and lead lifetime.
  run "incremental reader and lead liveness" bash -c '
    source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/config.sh"; source "$1/scripts/lib/usage.sh"; source "$1/scripts/lib/phases.sh"; source "$1/scripts/loomy-tree.sh" --library
    loomy_live_init; loomy_live_poll "$2/.loomy/logs/events.jsonl"; a=$LV_OFFSET; n=$LV_SEQ
    loomy_live_poll "$2/.loomy/logs/events.jsonl"; test "$a:$n" = "$LV_OFFSET:$LV_SEQ" || exit 1
    printf "%s" "{\"type\":\"request\",\"id\":\"partial\"" >>"$2/.loomy/logs/events.jsonl"
    loomy_live_poll "$2/.loomy/logs/events.jsonl"; test "$a" = "$LV_OFFSET" || exit 1
    printf "%s\n" "}" >>"$2/.loomy/logs/events.jsonl"; loomy_live_poll "$2/.loomy/logs/events.jsonl"; test "$LV_SEQ" = "$(( n + 1 ))" || exit 1
    LV_NOW=$(date +%s); LV_PID[1]=99999999; LV_BRIDGE[1]=codex; loomy_live_states; test "${LV_STATUS[1]}" = interrupted || exit 1
    printf "{}\n" >"$2/.loomy/logs/events.jsonl"; loomy_live_poll "$2/.loomy/logs/events.jsonl"; test "$LV_SEQ" = 0
  ' _ "$REPO" "$lv"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"echo user"}]}]},"statusLine":{"command":"user status"}}' >"$lv/.claude/settings.json"
  run "hooks merge twice" bash -c 'source "$1/scripts/lib/hooks.sh"; loomy_claude_hooks_merge "$2"; loomy_claude_hooks_merge "$2"' _ "$REPO" "$lv"
  run "hook merge idempotent, user hooks kept" perl -MJSON::PP -e 'local $/; my $d=decode_json(<>); my $g=$d->{hooks}{PreToolUse}; die unless @$g==2 && $g->[0]{hooks}[0]{command} eq "echo user" && $g->[1]{matcher} eq "Agent|Task" && $g->[1]{hooks}[0]{command}=~/--hook agent-start/ && $d->{statusLine}{command} eq "user status"' "$lv/.claude/settings.json"
  # Resolver and terminal launcher use functions/stubs: never a real open.
  run "orchestrator app vs terminal, acting lead" bash -c '
    source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/config.sh"; source "$1/scripts/loomy-start.sh" --open-library
    uname() { echo Darwin; }; open() { [[ "${AVAILABLE:-}" == "$2" ]]; }
    AVAILABLE=Claude; loomy_orchestrator_target "$2"; test "$LOOMY_OPEN_TARGET:$LOOMY_OPEN_APP" = app:Claude || exit 1
    AVAILABLE=""; loomy_orchestrator_target "$2"; test "$LOOMY_OPEN_TARGET" = terminal || exit 1
    printf "master=claude\nacting=codex\n" >"$2/.loomy/failover"
    AVAILABLE=Codex; loomy_orchestrator_target "$2"; test "$LOOMY_OPEN_TOOL:$LOOMY_OPEN_APP" = codex:Codex || exit 1
    AVAILABLE=ChatGPT; loomy_orchestrator_target "$2"; test "$LOOMY_OPEN_APP" = ChatGPT || exit 1
    AVAILABLE=""; TMUX=stub; SCRIPT_DIR="$1/scripts"; tmux() { printf "%s\n" "$*" >"$LIVE_ROOT/opened.txt"; }; LIVE_ROOT="$2"; export TMUX
    loomy_open_orchestrator "$2"; grep -q "new-window.*--resume.*--watch" "$2/opened.txt"
  ' _ "$REPO" "$lv"
  # An explicit Codex override and a native Claude task remain readable in both groupings.
  local demo="$WORK/live-frames" costs="$WORK/live-costs"
  mkdir -p "$demo/.loomy/logs" "$costs/.loomy/logs"
  cp "$lv/.loomy/brief.md" "$demo/.loomy/brief.md"; cp "$lv/.loomy/state" "$demo/.loomy/state"
  cp "$lv/.loomy/brief.md" "$costs/.loomy/brief.md"
  printf '{"ts":"%s","type":"delegation","id":"old","role":"security","status":"error","outcome":"blocked","task":"Stale failure"}\n' "$nowz" >"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"frames","pid":%s}\n' "$nowz" "$$" >>"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"request","session":"frames","id":"r1","excerpt":"Improve live tracking"}\n' "$nowz" >>"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation_start","session":"frames","id":"arch","pid":%s,"role":"architect","family":"codex","model":"gpt-6-astra","effort":"max","task":"Review watch clarity","requested":true,"off_routing":"tool,model"}\n' "$nowz" "$$" >>"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation_start","session":"frames","id":"dev","pid":%s,"bridge":"subagent","role":"developer","family":"claude","model":"claude-sonnet-5-5","effort":"medium","task":"Implement live view"}\n' "$nowz" "$$" >>"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation","session":"frames","id":"review","role":"reviewer","family":"codex","model":"gpt-6-luna","effort":"high","status":"ok","outcome":"partial","duration_s":83,"task":"Check terminal keys","cost_usd":0.03}\n' "$nowz" >>"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation","session":"frames","id":"done","role":"explorer","family":"codex","model":"gpt-6-luna","effort":"medium","status":"ok","outcome":"done","duration_s":12,"task":"Map the working tree"}\n' "$nowz" >>"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation","session":"frames","id":"blocked","role":"security","family":"codex","model":"gpt-6-luna","effort":"high","status":"ok","outcome":"blocked","duration_s":34,"task":"Inspect the trust boundary"}\n' "$nowz" >>"$demo/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"delegation","session":"frames","id":"failed","role":"debugger","family":"codex","model":"gpt-6-luna","effort":"high","status":"error","outcome":"failed","duration_s":8,"task":"Reproduce the failure"}\n' "$nowz" >>"$demo/.loomy/logs/events.jsonl"
  sed -i.bak 's/Review watch clarity/Review watch clarity and preserve at least thirty readable task columns/' "$demo/.loomy/logs/events.jsonl" && rm -f "$demo/.loomy/logs/events.jsonl.bak"
  run "request frame: override metadata and task" env LOOMY_WATCH_GROUP=request COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$demo" --once
  has "override: tool, real model, word, task and short flags" 'Architect.*Codex.*6-astra.*▮▮▮▮ max.*Review watch clarity and preserve.*⚑ ⇢ tool,model'
  has "native: Claude, med word and task" 'Developer.*Claude.*sonnet-5-5.*▮▮▯▯ med.*Implement live view'
  has "completion: partial uses triangle and keeps task" '△ Reviewer.*high.*1:23  Check terminal keys'
  has "completion: done uses check" '✓ Explorer.*0:12  Map the working tree'
  has "completion: blocked uses square" '■ Security.*Inspect the trust boundary'
  has "completion: failed uses cross" '✗ Debugger.*Reproduce the failure'
  hasnt "current session: old failure dropped" 'Stale failure|Done.*open'
  cp "$OUT" "$lv/request-frame.txt"
  run "request task has 30 columns at 100 columns" perl -MEncode=decode -e 'use utf8; my $found=0; while (<>) { my $s=decode("UTF-8", $_); if ($s =~ /Architect/ && $s =~ /⇢ tool,model/) { $found=1; die unless $s =~ /max\s+\d+:\d\d  (.*?) ⚑ ⇢ tool,model/; die if length($1)<30 || length($s)>100; } } exit($found ? 0 : 1)' "$lv/request-frame.txt"
  if awk '/^SESSION/{a=1} a' "$lv/request-frame.txt" | grep -q '◐'; then ko "finished recap never uses the running glyph"; else ok "finished recap never uses the running glyph"; fi
  if [[ "$(grep -o '⚑ requested · ⇢ off routing' "$lv/request-frame.txt" | wc -l | tr -d ' ')" == 1 ]]; then ok "footer legend appears once"; else ko "footer legend missing or duplicated"; fi
  run "model frame: two tool families" env LOOMY_WATCH_GROUP=model COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$demo" --once
  has "model grouping: explicit model" '┌─ gpt-6-astra · 1 running'
  cp "$OUT" "$lv/model-frame.txt"
  run "compact frame: tool and effort words retained" env LOOMY_WATCH_GROUP=request COLUMNS=45 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$demo" --once
  has "compact: Codex max retained" 'Architect.*Codex.*max'
  has "compact: routing annotations retained" '⚑ ⇢ tool,model'
  has "compact: Claude med retained" 'Developer.*Claude.*med'
  hasnt "compact: model, bar and task dropped" '6-astra|sonnet-5-5|▮|▯|Implement live view'
  cp "$OUT" "$lv/compact-frame.txt"
  run "compact frame: no line wraps" perl -MEncode=decode -e 'while (<>) {chomp; die if length(decode("UTF-8",$_))>44}' "$lv/compact-frame.txt"
  run "French live role labels" env LOOMY_UI_LANG=fr COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$demo" --once
  has "translated role labels" 'Développeur.*Claude'
  has "translated routing legend" '⚑ demandé · ⇢ hors routage'
  # A relay must have an acting session, with its own recorded model rather than the master's routing.
  printf '{"ts":"%s","type":"session","event":"start","tool":"codex","session":"acting","pid":%s,"model":"gpt-6.1-sol","effort":"high"}\n' "$nowz" "$$" >>"$demo/.loomy/logs/events.jsonl"
  printf 'master=claude\nacting=codex\n' >"$demo/.loomy/failover"
  run "relay frame: acting tool and model" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$demo" --once
  has "relay: acting lead marker" 'Orchestrator.*⇄ Codex.*6[.-]'
  hasnt "relay: Claude model on Codex lead" 'Orchestrator.*Codex.*opus'
  rm -f "$demo/.loomy/failover"
  local routed="$WORK/live-routed-effort" rj
  mkdir -p "$routed/.loomy/logs"
  cp "$lv/.loomy/brief.md" "$routed/.loomy/brief.md"; cp "$lv/.loomy/state" "$routed/.loomy/state"
  printf 'lead=high\n' >"$routed/.loomy/efforts"
  rj="$routed/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"routed-effort","pid":%s}\n' "$nowz" "$$" >"$rj"
  run "lead: missing session effort falls back to routed effort" env COLUMNS=120 LINES=50 bash "$REPO/scripts/loomy-tree.sh" --root "$routed" --once
  has "lead: live header shows routed high effort" '^Orchestrator · Claude \? high'
  hasnt "lead: live header never shows unknown effort" '^Orchestrator .* \? ·'
  run "lead: diagram shows routed effort and open idle state" env LOOMY_TREE=diagram COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$routed"
  has "lead: diagram shows routed high effort" 'effort ▮▮▮▯ high'
  has "diagram lead: open session is idle" 'session open · idle'
  hasnt "diagram lead: open session omits done" 'session open.*done'
  has "diagram back box: idle roles show reviews and checks" 'reviews \+ checks'
  local running="$WORK/live-running-only" rnj usage_only="$WORK/live-usage-only" unj
  mkdir -p "$running/.loomy/logs" "$usage_only/.loomy/logs"
  cp "$lv/.loomy/brief.md" "$running/.loomy/brief.md"; cp "$lv/.loomy/state" "$running/.loomy/state"
  cp "$lv/.loomy/brief.md" "$usage_only/.loomy/brief.md"; cp "$lv/.loomy/state" "$usage_only/.loomy/state"
  rnj="$running/.loomy/logs/events.jsonl"; unj="$usage_only/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"running-only","pid":%s}\n{"ts":"%s","type":"delegation_start","session":"running-only","id":"running-role","pid":%s,"bridge":"codex","role":"developer","family":"codex","model":"gpt-6-luna","effort":"low"}\n' "$nowz" "$$" "$nowz" "$$" >"$rnj"
  run "diagram lead works while a role runs without prompt activity" env LOOMY_TREE=diagram COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$running"
  has "diagram role-only activity shows working" 'session open · working'
  has "diagram role-only activity waits for the role" 'waiting for 1 role'
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"usage-only","pid":%s}\n{"ts":"%s","type":"usage","session":"usage-only","tool":"claude","scope":"lead","model":"claude-sonnet-5-5"}\n' "$nowz" "$$" "$nowz" >"$unj"
  run "diagram lead works after recent usage without running roles" env LOOMY_TREE=diagram COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$usage_only"
  has "diagram usage-only activity shows working" 'session open · working'
  has "diagram usage-only activity has no waiting roles" 'reviews \+ checks'
  # Truthful classic boxes, request hook readback, titles, durations and complete French labels.
  local polish="$WORK/live-polish" pj
  mkdir -p "$polish/.loomy/logs"
  cp "$lv/.loomy/brief.md" "$polish/.loomy/brief.md"; cp "$lv/.loomy/state" "$polish/.loomy/state"
  pj="$polish/.loomy/logs/events.jsonl"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"previous","pid":99999999}\n' "$oldz" >"$pj"
  printf '{"ts":"%s","type":"delegation","id":"stale","session":"previous","role":"security","family":"claude","model":"claude-stale","effort":"low","status":"ok"}\n' "$oldz" >>"$pj"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"polish","pid":%s,"model":"claude-opus-5-5","effort":"max"}\n' "$nowz" "$$" >>"$pj"
  printf '{"ts":"%s","type":"delegation","id":"earlier","session":"polish","role":"explorer","family":"codex","model":"gpt-6-luna","effort":"medium","duration_s":3780,"status":"ok","task":"GOAL: Map the journal. SCOPE: hidden details"}\n' "$nowz" >>"$pj"
  printf '%s\n' '{"session_id":"polish","prompt":"TASK: Clean the labels. SCOPE: private implementation"}' | bash "$REPO/scripts/loomy-context.sh" --root "$polish" --hook prompt >/dev/null
  printf '{"ts":"%s","type":"delegation","id":"dev-last","session":"polish","role":"developer","family":"codex","model":"gpt-6.1-sol","effort":"low","duration_s":1,"status":"ok"}\n' "$nowz" >>"$pj"
  printf '{"ts":"%s","type":"delegation","id":"doc","session":"polish","role":"documenter","family":"codex","model":"gpt-6.1-sol","effort":"low","duration_s":1,"status":"ok","task":"OBJECTIF : Write the docs\\nSCOPE: hidden detail"}\n' "$nowz" >>"$pj"
  printf '{"ts":"%s","type":"delegation_start","id":"dev-run","session":"polish","pid":%s,"role":"developer","family":"codex","model":"gpt-6-astra","effort":"high","task":"GOAL: Polish every visible label with complete words and truthful delegation metadata for every request in this journal. SCOPE: invisible"}\n' "$nowz" "$$" >>"$pj"
  run "polish: live request groups" env LOOMY_WATCH_GROUP=request COLUMNS=120 LINES=50 bash "$REPO/scripts/loomy-tree.sh" --root "$polish" --once
  has "prompt hook: recorded request is read as its title" '^┌─ Clean the labels\.'
  has "legacy delegation: Earlier work group" '^┌─ Earlier work'
  has "lead: recorded tool, model and effort" '^Orchestrator · Claude opus-5-5 max'
  has "duration: role above an hour" 'Explorer.*1 h 03'
  has "duration: session total above an hour" '^SESSION · 3 finished · 1 h 03'
  has "title: leading GOAL stripped" 'Developer.*Polish every visible label'
  has "title: first sentence only" 'Explorer.*Map the journal\.'
  has "title: first line only" 'Documenter.*Write the docs'
  hasnt "titles: ticket labels and scope absent" 'GOAL:|TASK:|OBJECTIF|SCOPE:|hidden detail|invisible'
  run "title helper: ellipsis at a complete word" bash -c 'source "$1/scripts/lib/journal.sh"; ai_task_title "Alpha beta gamma delta" 12; test "$AI_TASK_TITLE" = "Alpha beta…"; ai_task_title "unbreakable word" 5; test "$AI_TASK_TITLE" = "…"; ai_display_duration 3599; test "$AI_DURATION" = 59:59; ai_display_duration 3600; test "$AI_DURATION" = "1 h 00"' _ "$REPO"
  run "polish: classic diagram" env COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$polish"
  sed -n '28,36p' "$OUT" >"$polish/boxes.txt"
  grep -q 'gpt-6-astra.*gpt-6.1-sol.*gpt-6-luna' "$polish/boxes.txt" && ok "diagram: actual running and last completed models" || ko "diagram: delegation models missing"
  grep -q 'effort.*high.*effort.*low.*effort.*med' "$polish/boxes.txt" && ok "diagram: actual running and completed efforts" || ko "diagram: effort differs from delegation"
  grep -q 'planned' "$polish/boxes.txt" && ok "diagram: unused role is planned" || ko "diagram: planned state missing"
  has "diagram: effort label permits recorded overrides" 'delegate to roles · model \+ effort'
  has "diagram lead: running role makes open session working" 'session open · working'
  hasnt "diagram lead: working session omits done" 'session open.*done'
  has "diagram: return waits for running roles" 'waiting for 1 role'
  hasnt "diagram: running return does not show reviews and checks" 'reviews \+ checks'
  grep -q claude-stale "$polish/boxes.txt" && ko "diagram: stale session model" || ok "diagram: no stale session model"
  hasnt "diagram log: task titles strip ticket labels" 'GOAL:|TASK:|OBJECTIF|SCOPE:|invisible|hidden detail'
  run "polish: planned model is dimmed" env NO_COLOR= LOOMY_FORCE_COLOR=1 COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$polish"
  cp "$OUT" "$polish/planned.txt"
  run "diagram: planned model has dim ANSI colour" perl -e 'local $/; my $s=<>; die unless $s =~ /\e\[2m[^\e\n]*gpt-6.1-sol/' "$polish/planned.txt"
  run "polish: French full labels and durations" env LOOMY_UI_LANG=fr LOOMY_WATCH_GROUP=request COLUMNS=120 LINES=50 bash "$REPO/scripts/loomy-tree.sh" --root "$polish" --once
  cp "$OUT" "$polish/french.txt"
  run "French: role column aligns Unicode labels" perl -MEncode=decode -e 'use utf8; my ($col,$n); while (<>) { my $s=decode("UTF-8",$_); next unless $s =~ /^  . (?:Développeur|Documentaliste|Explorateur)\s+Codex/; my $c=index($s,"Codex"); $col //= $c; die if $c!=$col; ++$n } die unless ($n//0)>=3' "$polish/french.txt"
  cp "$polish/french.txt" "$OUT"
  has "French: longest labels are whole" 'Documentaliste.*Codex'
  has "French: Explorer is whole" 'Explorateur.*Codex.*1 h 03'
  has "French: earlier work translated" '^┌─ Travail antérieur'
  hasnt "French: no clipped role words" 'Documentalis |Explorate '
  run "French: diagram lead and return labels" env LOOMY_UI_LANG=fr LOOMY_TREE=diagram COLUMNS=170 LINES=60 bash "$REPO/scripts/loomy-tree.sh" --root "$polish"
  has "French diagram: active lead session is working" 'session ouverte · en cours'
  has "French diagram: running role is awaited" 'attend 1 rôle'
  run "polish: tight French labels" env LOOMY_UI_LANG=fr COLUMNS=45 LINES=50 bash "$REPO/scripts/loomy-tree.sh" --root "$polish" --once
  has "tight French: longest label remains whole" 'Documentaliste.*Codex'
  cp "$OUT" "$polish/tight.txt"
  run "tight French: no line wraps" perl -MEncode=decode -e 'while (<>) {chomp; die if length(decode("UTF-8",$_))>44}' "$polish/tight.txt"
  # A newer dead start cannot replace the living lead; concurrent tool usage stays paired.
  printf '{"ts":"%s","type":"session","event":"start","tool":"codex","session":"concurrent","pid":%s,"model":"gpt-6-luna","effort":"low"}\n' "$nowz" "$$" >>"$pj"
  printf '{"ts":"%s","type":"usage","tool":"claude","scope":"lead","model":"claude-sonnet-5-5"}\n' "$nowz" >>"$pj"
  printf '{"ts":"%s","type":"usage","tool":"codex","scope":"lead","model":"gpt-6.1-sol"}\n' "$nowz" >>"$pj"
  printf '{"ts":"%s","type":"session","event":"start","tool":"claude","session":"dead-newest","pid":99999999,"model":"claude-dead"}\n' "$nowz" >>"$pj"
  run "lead: brief preference among living sessions" env COLUMNS=120 LINES=50 bash "$REPO/scripts/loomy-tree.sh" --root "$polish" --once
  has "lead: preferred living session and matching usage" '^Orchestrator · Claude sonnet-5-5 max'
  has "lead: concurrent session preserves roles" 'Developer.*Codex.*6-astra'
  hasnt "lead: dead start and other tool model rejected" '^Orchestrator.*(claude-dead|6.1-sol|6-luna)'
  printf 'master=claude\nacting=codex\n' >"$polish/.loomy/failover"
  run "lead: live acting session during relay" env COLUMNS=120 LINES=50 bash "$REPO/scripts/loomy-tree.sh" --root "$polish" --once
  has "lead: relay uses acting tool and its usage model" '^Orchestrator · ⇄ Codex 6.1-sol low'
  hasnt "lead: relay never uses Claude model" '^Orchestrator.*Codex.*sonnet'
  # End the acting session and let incremental selection return to the preferred living lead.
  run "lead: incremental reselection after acting session ends" bash -c '
    source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; source "$1/scripts/loomy-tree.sh" --library
    AI_LEAD=codex; loomy_live_init; loomy_live_poll "$2"; test "$LV_SESSION" = concurrent || exit 1
    printf "{\"ts\":\"%s\",\"type\":\"session\",\"event\":\"end\",\"tool\":\"codex\",\"session\":\"concurrent\"}\n" "$3" >>"$2"
    AI_LEAD=claude; loomy_live_poll "$2"; test "$LV_SESSION:$LV_SESSION_MODEL" = polish:claude-sonnet-5-5
  ' _ "$REPO" "$pj" "$nowz"
  # Legacy native completions with repeated figures also count only their usage event.
  cat >"$costs/.loomy/logs/events.jsonl" <<'JSON'
{"ts":"2026-10-09T10:00:00Z","type":"usage","family":"claude","scope":"subagent","model":"claude-sonnet-5-5","tokens_in":100,"tokens_out":20,"cost_usd":1.25}
{"ts":"2026-10-09T10:00:00Z","type":"delegation","id":"native","bridge":"subagent","family":"claude","role":"developer","model":"claude-sonnet-5-5","status":"ok","duration_s":12,"tokens_in":100,"tokens_out":20,"cost_usd":1.25}
{"ts":"2026-10-09T10:00:00Z","type":"delegation","id":"bridge","bridge":"codex","family":"codex","role":"architect","model":"gpt-6-astra","status":"ok","duration_s":12,"tokens_in":50,"tokens_out":10,"cost_usd":0.75}
JSON
  run "stats: native usage counted once, bridge cost retained" bash "$REPO/scripts/loomy-stats.sh" --root "$costs"
  has "stats: input and output once" '150 in.*30 out'
  has "stats: total cost once" 'API cost.*\$2.00'
  run "tree session: native usage counted once" env COLUMNS=100 LINES=30 bash "$REPO/scripts/loomy-tree.sh" --root "$costs" --once
  has "tree: usage plus bridge cost" 'SESSION.*\$2.0000'
  run "lead: active only with recent activity, alive process" bash -c '
    source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/loomy-tree.sh" --library
    loomy_live_init; LV_SESSION_OPEN=1; LV_SESSION_PID=$$; LV_NOW=200; LV_ACTIVITY=0; loomy_live_states; test "$LV_ACTIVE" = 0 || exit 1
    LV_ACTIVITY=81; loomy_live_states; test "$LV_ACTIVE" = 1 || exit 1
    LV_ACTIVITY=80; loomy_live_states; test "$LV_ACTIVE" = 0 || exit 1
    LV_ACTIVITY=199; LV_SESSION_PID=99999999; loomy_live_states; test "$LV_ACTIVE" = 0
  ' _ "$REPO"
  printf '%s\n' '{"hooks":{"PreToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"echo user"}]}]},"statusLine":{"command":"user status"}}' >"$lv/.claude/settings.json"
  run "project repair: old settings gain hooks once" bash -c '
    source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/config.sh"; source "$1/scripts/lib/project.sh"
    loomy_project_repair "$2"; cp "$2/.claude/settings.json" "$2/settings-once.json"
    loomy_project_repair "$2"; cmp "$2/settings-once.json" "$2/.claude/settings.json"
  ' _ "$REPO" "$lv"
  run "project repair: user hooks preserved" perl -MJSON::PP -e 'local $/; my $d=decode_json(<>); my $g=$d->{hooks}{PreToolUse}; die unless @$g==2 && $g->[0]{hooks}[0]{command} eq "echo user" && $g->[1]{matcher} eq "Agent|Task" && $d->{statusLine}{command} eq "user status"' "$lv/.claude/settings.json"
  run "hooks repair: no rewrite when unchanged" bash -c '
    source "$1/scripts/lib/hooks.sh"; ln "$2/.claude/settings.json" "$2/settings-link.json"; loomy_claude_hooks_merge "$2"
    test "$2/settings-link.json" -ef "$2/.claude/settings.json"
  ' _ "$REPO" "$lv"
  run "config set watch_group request" "$LOOMY" config set watch_group request
  run "config set watch_group model" "$LOOMY" config set watch_group model
  fails "config set watch_group rejects unknown" 2 "$LOOMY" config set watch_group bogus
  if command -v expect >/dev/null 2>&1; then
    cat >"$WORK/watch.exp" <<'EXPECT'
set timeout 15
log_user 0
# The spawned PTY's window size does not follow the COLUMNS/LINES environment overrides.
set stty_init "rows $env(LINES) columns $env(COLUMNS)"
spawn bash $env(LIVE_REPO)/scripts/loomy-status.sh --root $env(LIVE_PROJECT) --watch
expect {
  -re {group by request} {}
  timeout {exit 1}
  eof {exit 2}
}
send "v"
expect {
  -re {group by model} {}
  timeout {exit 3}
  eof {exit 4}
}
send "t"
expect {
  -re {LOOMY AGENT TREE} {}
  timeout {exit 5}
  eof {exit 6}
}
send "t"
expect {
  -re {IN PROGRESS} {}
  timeout {exit 7}
  eof {exit 8}
}
send "q"
expect eof
catch wait result
exit [lindex $result 3]
EXPECT
    run "real terminal: v toggles, t opens the diagram, q quits" env LIVE_REPO="$REPO" LIVE_PROJECT="$demo" COLUMNS=170 LINES=60 expect "$WORK/watch.exp"
    run "real terminal: v choice persists" bash -c 'source "$1/scripts/lib/config.sh"; test "$(loomy_config_get watch_group)" = request' _ "$REPO"
  else ko "real terminal: expect unavailable"; fi
  if [[ -n "$LIVE_ARTIFACTS" ]]; then mkdir -p "$LIVE_ARTIFACTS"; cp "$lv/"*-frame.txt "$LIVE_ARTIFACTS/"; fi
  rm -f "$XDG_CONFIG_HOME/loomy/config"
}
# ------------------------------------------------------------------ release review regressions
release_defects_tests() {
  section "Release defects"
  local rd="$WORK/release-defects" perm="$WORK/journal-private" qcfg="$WORK/model-failover-config" qhome="$WORK/model-failover-codex" from to model
  mkdir -p "$rd/.loomy" "$rd/.claude" "$perm/.loomy" "$qcfg/loomy" "$qhome/sessions"
  printf -- '---\nname: Review\nai_mode: SOLO\nai_lead: claude\nbudget: equilibre\n---\n' >"$rd/.loomy/brief.md"
  cp "$rd/.loomy/brief.md" "$perm/.loomy/brief.md"
  printf 'shared ignore\n' >"$rd/target"; chmod 640 "$rd/target"; ln -s target "$rd/.gitignore"
  run "gitignore repair refuses symlink" bash -c '
    source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"
    test "$LP_GI_CHANGED" = 0 && test -L "$2/.gitignore" && test "$(cat "$2/target")" = "shared ignore" || exit 1
    perl -e '\''die unless ((stat($ARGV[0]))[2]&0777)==0640'\'' "$2/target"
  ' _ "$REPO" "$rd"
  run "journal created private under umask 022" bash -c '
    umask 022; source "$1/scripts/lib/journal.sh"; ai_journal_write "$2" "\"type\":\"request\""
    perl -e '\''die unless ((stat($ARGV[0]))[2]&0777)==0700 && ((stat($ARGV[1]))[2]&0777)==0600'\'' "$2/.loomy/logs" "$2/.loomy/logs/events.jsonl"
  ' _ "$REPO" "$perm"
  chmod 755 "$perm/.loomy/logs"; chmod 644 "$perm/.loomy/logs/events.jsonl"
  run "fast prompt tightens existing journal permissions" bash -c '
    umask 022; printf "%s" "{\"session_id\":\"private\",\"prompt\":\"secret excerpt\"}" | bash "$1/scripts/loomy-context.sh" --root "$2" --hook prompt
    perl -e '\''die unless ((stat($ARGV[0]))[2]&0777)==0700 && ((stat($ARGV[1]))[2]&0777)==0600'\'' "$2/.loomy/logs" "$2/.loomy/logs/events.jsonl"
    grep -q "secret excerpt" "$2/.loomy/logs/events.jsonl"
  ' _ "$REPO" "$perm"
  run "fast prompt creates private journal" bash -c '
    umask 022; printf "%s" "{\"prompt\":\"first request\"}" | bash "$1/scripts/loomy-context.sh" --root "$2" --hook prompt
    perl -e '\''die unless ((stat($ARGV[0]))[2]&0777)==0700 && ((stat($ARGV[1]))[2]&0777)==0600'\'' "$2/.loomy/logs" "$2/.loomy/logs/events.jsonl"
  ' _ "$REPO" "$rd"
  run "journal writer tightens existing files and archives" bash -c '
    umask 022; mkdir -p "$2/.loomy/logs/archive"; echo old >"$2/.loomy/logs/archive/events-2020-01.jsonl"
    chmod 755 "$2/.loomy/logs" "$2/.loomy/logs/archive"; chmod 644 "$2/.loomy/logs/events.jsonl"
    source "$1/scripts/lib/journal.sh"; ai_journal_write "$2" "\"type\":\"request\""
    perl -e '\''for (@ARGV) { die unless ((stat($_))[2]&0777)==(-d $_ ? 0700 : 0600) }'\'' "$2/.loomy/logs" "$2/.loomy/logs/events.jsonl" "$2/.loomy/logs/archive" "$2/.loomy/logs/archive/events-2020-01.jsonl"
  ' _ "$REPO" "$perm"
  run "prompt and journal refuse linked file, directory and metadata without chmod of targets" bash -c '
    source "$1/scripts/lib/journal.sh"; umask 022
    for kind in file directory metadata archive parent; do
      p="$2/link-$kind"; mkdir -p "$p/.loomy/logs" "$p/target-dir"; cp "$2/.loomy/brief.md" "$p/.loomy/brief.md"
      echo untouched >"$p/target"; chmod 644 "$p/target"; chmod 755 "$p/target-dir"
      case "$kind" in
        file) ln -s "$p/target" "$p/.loomy/logs/events.jsonl" ;;
        directory) rmdir "$p/.loomy/logs"; ln -s "$p/target-dir" "$p/.loomy/logs" ;;
        metadata) ln -s "$p/target" "$p/.loomy/logs/month" ;;
        archive) ln -s "$p/target-dir" "$p/.loomy/logs/archive" ;;
        parent) mv "$p/.loomy" "$p/target-dir/loomy"; ln -s "$p/target-dir/loomy" "$p/.loomy" ;;
      esac
      ai_journal_write "$p" "\"type\":\"request\""
      printf "%s" "{\"prompt\":\"must not write\"}" | bash "$1/scripts/loomy-context.sh" --root "$p" --hook prompt
      test "$(cat "$p/target")" = untouched || exit 1
      perl -e '\''die unless ((stat($ARGV[0]))[2]&0777)==0644 && ((stat($ARGV[1]))[2]&0777)==0755'\'' "$p/target" "$p/target-dir" || exit 1
      test ! -e "$p/target-dir/events.jsonl" || exit 1
    done
  ' _ "$REPO" "$perm"
  run "same-role agents reverse finish with stable identities, tasks, durations and no duplicate" bash -c '
    source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"
    ai_journal_agent_start "$2" '\''{"session_id":"reverse","tool_use_id":"t1","tool_input":{"subagent_type":"developer","description":"first task","run_in_background":true}}'\'' $$
    ai_journal_agent_start "$2" '\''{"session_id":"reverse","tool_use_id":"t2","tool_input":{"subagent_type":"developer","description":"second task","run_in_background":true}}'\'' $$
    perl -MJSON::PP -MPOSIX=strftime -i -pe '\''my $d=decode_json($_); if (($d->{type}//"") eq "delegation_start") {$d->{ts}=strftime("%Y-%m-%dT%H:%M:%SZ",gmtime(time-($d->{id} eq "t1" ? 100 : 30))); $_=encode_json($d)."\n"}'\'' "$2/.loomy/logs/events.jsonl"
    for n in 1 2; do ai_journal_agent_return "$2" "{\"session_id\":\"reverse\",\"tool_use_id\":\"t$n\",\"tool_response\":{\"agentId\":\"a$n\",\"isAsync\":true}}"; done
    for n in 2 2; do ai_journal_agent_stop "$2" '\''{"session_id":"reverse","agent_type":"developer","agent_id":"a2"}'\'' 0 "STATUS: done" & done
    wait
    for n in 2 1 2; do ai_journal_agent_stop "$2" "{\"session_id\":\"reverse\",\"agent_type\":\"developer\",\"agent_id\":\"a$n\"}" 0 "STATUS: done"; done
    ai_journal_agent_return "$2" '\''{"session_id":"reverse","tool_use_id":"t2","tool_response":{"agentId":"a2"}}'\''
    perl -MJSON::PP -e '\''my @e=grep { $_->{type} eq "delegation" && ($_->{session}//"") eq "reverse" } map { decode_json($_) } <>; die unless @e==2 && $e[0]{id} eq "t2" && $e[0]{task} eq "second task" && $e[1]{id} eq "t1" && $e[1]{task} eq "first task"; for (@e) { my $want=$_->{id} eq "t1" ? 100 : 30; die unless $_->{duration_s}>=$want && $_->{duration_s}<$want+10 && $_->{outcome} eq "done" }'\'' "$2/.loomy/logs/events.jsonl"
  ' _ "$REPO" "$rd"
  run "stop before return waits for identity, foreground fallback and background launch stay distinct" bash -c '
    source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"
    for id in pending foreground background failed async; do
      bg=false; test "$id" = background && bg=true
      ai_journal_agent_start "$2" "{\"session_id\":\"fallback\",\"tool_use_id\":\"$id\",\"tool_input\":{\"subagent_type\":\"developer\",\"description\":\"$id task\",\"run_in_background\":$bg}}" $$
    done
    ai_journal_agent_stop "$2" '\''{"session_id":"fallback","agent_type":"developer","agent_id":"unmapped"}'\'' 0 "STATUS: partial"
    ! grep -q '\''"type":"delegation".*"session":"fallback"'\'' "$2/.loomy/logs/events.jsonl" || exit 1
    ai_journal_agent_return "$2" '\''{"session_id":"fallback","tool_use_id":"pending","tool_response":{"agentId":"unmapped","isAsync":true}}'\''
    ai_journal_agent_return "$2" '\''{"session_id":"fallback","tool_use_id":"foreground","tool_response":{"agentId":"fg","content":[{"text":"STATUS: done"}]}}'\''
    ai_journal_agent_return "$2" '\''{"session_id":"fallback","tool_use_id":"background","tool_response":{"agentId":"bg","isAsync":true}}'\''
    ai_journal_agent_return "$2" '\''{"session_id":"fallback","tool_use_id":"async","tool_response":{"agentId":"auto-bg","isAsync":true}}'\''
    printf '\''%s'\'' '\''{"session_id":"fallback","tool_use_id":"failed","tool_name":"Agent","error":"launch failed"}'\'' | bash "$1/scripts/loomy-context.sh" --root "$2" --hook agent-failure
    ai_journal_agent_stop "$2" '\''{"session_id":"fallback","agent_type":"developer","agent_id":"fg"}'\'' 0 "STATUS: done"
    perl -MJSON::PP -e '\''my @e=grep { $_->{type} eq "delegation" && ($_->{session}//"") eq "fallback" } map { decode_json($_) } <>; die unless @e==3; my %e=map { $_->{id}=>$_ } @e; die unless $e{pending}{outcome} eq "partial" && $e{foreground}{outcome} eq "done" && $e{failed}{status} eq "error" && !$e{background} && !$e{async}'\'' "$2/.loomy/logs/events.jsonl"
    ai_journal_agent_stop "$2" '\''{"session_id":"fallback","agent_type":"developer","agent_id":"bg"}'\'' 0 "STATUS: done"
    ai_journal_agent_stop "$2" '\''{"session_id":"fallback","agent_type":"developer","agent_id":"auto-bg"}'\'' 0 "STATUS: done"
    perl -MJSON::PP -e '\''my @e=grep { $_->{type} eq "delegation" && ($_->{session}//"") eq "fallback" } map { decode_json($_) } <>; die unless @e==5'\'' "$2/.loomy/logs/events.jsonl"
  ' _ "$REPO" "$rd"
  printf '%s\n' '{"hooks":{"PostToolUse":[{"matcher":"Read","hooks":[{"type":"command","command":"echo user"}]}]},"statusLine":{"command":"user status"}}' >"$rd/.claude/settings.json"
  chmod 640 "$rd/.claude/settings.json"
  run "repair migrates completion hooks once, settings style/mode and user hooks preserved" bash -c '
    source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/config.sh"; source "$1/scripts/lib/project.sh"
    loomy_project_repair "$2"; cp "$2/.claude/settings.json" "$2/settings-first"
    loomy_project_repair "$2"; cmp "$2/settings-first" "$2/.claude/settings.json" || exit 1
    perl -MJSON::PP -e '\''local $/; my $p=shift; open my $f,"<",$p or die; my $s=<$f>; my $d=decode_json($s); die unless ((stat($p))[2]&0777)==0640 && $s =~ /^  "hooks": \{/m && $d->{statusLine}{command} eq "user status"; my $g=$d->{hooks}{PostToolUse}; die unless @$g==2 && $g->[0]{hooks}[0]{command} eq "echo user" && $g->[1]{matcher} eq "Agent|Task"; for my $event (qw(PostToolUse PostToolUseFailure)) { die unless scalar(grep { $_->{matcher} eq "Agent|Task" } @{$d->{hooks}{$event}})==1 }'\'' "$2/.claude/settings.json"
  ' _ "$REPO" "$rd"
  # CLI doubles only, with isolated subscription quotas: the requested model is substituted by the destination routing.
  printf 'plan_claude=pro\nplan_codex=business\n' >"$qcfg/loomy/config"
  for from in codex claude; do
    if [[ "$from" == codex ]]; then
      to=claude; model=gpt-6-astra
      printf '{"type":"event_msg","payload":{"rate_limits":{"rate_limit_reached_type":"workspace_member_credits_depleted"}}}\n' >"$qhome/sessions/r.jsonl"
      printf 'five_hour_pct=20\nfive_hour_reset=%s\n' "$(( $(date +%s) + 3600 ))" >"$qcfg/loomy/claude-limits"
    else
      to=codex; model=opus
      printf '{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":20,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' "$(( $(date +%s) + 3600 ))" >"$qhome/sessions/r.jsonl"
      printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$(( $(date +%s) + 3600 ))" >"$qcfg/loomy/claude-limits"
    fi
    : >"$rd/.loomy/logs/events.jsonl"
    run "$from model-only quota failover" env XDG_CONFIG_HOME="$qcfg" CODEX_HOME="$qhome" bash -c 'cd "$1"; "$2" delegate "$3" reviewer --model "$4" "model-only request"' _ "$rd" "$LOOMY" "$from" "$model"
    has "$from failover banner explains requested model and actual destination" "requested \($model\)"
    run "$from failover preserves requested metadata in both events" perl -MJSON::PP -e '
      my ($p,$model,$family)=@ARGV; open my $f,"<",$p or die; my @e=map { decode_json($_) } <$f>; die unless @e==2;
      for (@e) { die unless $_->{requested} && $_->{requested_model} eq $model && $_->{family} eq $family && $_->{model} ne $model }
    ' "$rd/.loomy/logs/events.jsonl" "$model" "$to"
  done
}
# The relay section owns its fixtures and can run without the full terminal walkthrough.
if [[ "${1:-}" != --section || "${2:-}" != 'Lead relay (quota)' ]]; then
if [[ "${1:-}" == --section && "${2:-}" == 'Release defects' ]]; then
  release_defects_tests
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 )); exit $?
fi

if [[ "${1:-}" == --section && "${2:-}" == 'Delegation options' ]]; then
  delegation_options_tests
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 )); exit $?
fi
if [[ "${1:-}" == --section && "${2:-}" == 'Interrupted delegations' ]]; then
  interrupted_delegation_tests
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 )); exit $?
fi
live_view_tests
if [[ "${1:-}" == --section && "${2:-}" == 'Live view' ]]; then
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 )); exit $?
fi

release_defects_tests

# ------------------------------------------------------------------ syntaxe
section "Syntax and static analysis"
SCRIPTS="$(cd "$REPO" && ls bin/loomy install.sh scripts/*.sh scripts/lib/*.sh tests/run.sh tests/stubs/*)"
bad=""
for f in $SCRIPTS; do
  case "$f" in install.sh) sh -n "$REPO/$f" || bad="$bad $f" ;; *) bash -n "$REPO/$f" || bad="$bad $f" ;; esac
done
if [[ -z "$bad" ]]; then ok "bash -n / sh -n on $(echo "$SCRIPTS" | wc -l | tr -d ' ') scripts"; else ko "syntax errors:$bad"; fi
SHELLCHECK="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v shellcheck || true)"
if [[ -n "$SHELLCHECK" ]]; then
  if (cd "$REPO/scripts" && printf '%s\0' ../bin/loomy ../install.sh ./*.sh lib/*.sh ../tests/run.sh ../tests/stubs/* | xargs -0 -n 1 -P "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" "$SHELLCHECK" -x -S warning) >"$OUT" 2>&1
  then ok "shellcheck (warning level)"; else ko "shellcheck (warning level)"; fi
else
  printf '  \033[2m○ shellcheck missing: static analysis skipped\033[0m\n'
fi

# A variable followed by an accented character ("$var…") breaks bash 3.2 outside a UTF-8 locale: write ${var}.
if LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$REPO/bin/loomy" "$REPO"/scripts/*.sh "$REPO"/scripts/lib/*.sh >"$OUT"; then ko "variables stuck to a non-ASCII character: $(head -1 "$OUT")"; else ok "no variable stuck to a non-ASCII character"; fi

# ------------------------------------------------------------------ commande loomy
section "loomy command"
run "loomy version" "$LOOMY" version
has "version shown from VERSION" "^loomy $(cat "$REPO/VERSION") "
V="$(cat "$REPO/VERSION")"
grep -q "\"version\": \"$V\"" "$REPO/package.json" && grep -q "badge/version-$V-" "$REPO/README.md" && grep -q "badge/version-$V-" "$REPO/README.fr.md" && grep -q "^## $V " "$REPO/CHANGELOG.md" \
  && ok "version consistent: VERSION, package.json, README badges, CHANGELOG" || ko "version mismatch around $V"
run "loomy help" "$LOOMY" help
has "help: structured sections" "◇  TRACKING"
hasnt "help: no colour outside a terminal" $'\033\\['
hasnt "help: no more route json" "json"
bad=""
for c in init brief assess stats route status watch log doctor config delegate worktrees; do
  "$LOOMY" "$c" --help >"$OUT" 2>&1 </dev/null || bad="$bad $c"
done
if [[ -z "$bad" ]]; then ok "--help answers for every command"; else ko "--help failing:$bad"; fi
fails "unknown command refused" 2 "$LOOMY" nimporte
fails "unknown configuration key refused" 2 "$LOOMY" config set couleur bleu
fails "delegate without target refused" 2 "$LOOMY" delegate

# Install method inferred from the location (it picks the loomy update command).
for spec in "npm:lib/node_modules/loomy" "npm:opt/homebrew/lib/node_modules/loomy" "bun:bunprefix/install/global/node_modules/loomy" "brew:Cellar/loomy/0.0.0/libexec" "brew:opt/homebrew/Cellar/loomy/0.0.0/libexec"; do
  want="${spec%%:*}"; dir="$WORK/methodes/${spec#*:}"
  mkdir -p "$dir" && (cd "$REPO" && tar cf - bin scripts VERSION) | (cd "$dir" && tar xf -)
  got="$(bash "$dir/bin/loomy" version | sed -n 's/^loomy [^ ]* (\([a-z]*\) .*/\1/p')"
  if [[ "$got" == "$want" ]]; then ok "method detected: $want"; else ko "method $want detected as \"$got\""; fi
done

# Several installs in the PATH: each one recognised, with its removal command.
IP="$WORK/installs"; mkdir -p "$IP/prefix" "$IP/npm/bin" "$IP/npm/lib/node_modules/loomy"
LOOMY_PREFIX="$IP/prefix" sh "$REPO/install.sh" >/dev/null 2>&1
(cd "$REPO" && tar cf - bin scripts VERSION) | (cd "$IP/npm/lib/node_modules/loomy" && tar xf -)
ln -s ../lib/node_modules/loomy/bin/loomy "$IP/npm/bin/loomy"
PATH="$IP/prefix/bin:$IP/npm/bin:$PATH" "$LOOMY" version --all >"$OUT" 2>&1
has "installs: the install.sh one recognised (git)" "git v"
has "installs: the npm one recognised" "npm v"
has "installs: npm removal command" "npm uninstall -g loomy"
PATH="$IP/prefix/bin:$IP/npm/bin:$PATH" "$LOOMY" version >"$OUT" 2>&1
has "version: flags several installs" "Several loomy installs"
rm -rf "$IP"
# Start outside a UTF-8 locale (macOS bash 3.2 in the C locale).
PC="$WORK/projet-c"; mkdir -p "$PC/.loomy" && printf -- '---\nname: C\nai_mode: SOLO\nai_lead: claude\n---\n' >"$PC/.loomy/brief.md" && touch "$PC/START.md"
run "start --new in the C locale" env LC_ALL=C LANG=C "$LOOMY" start --root "$PC" --new

# ------------------------------------------------------------------ configuration
section "Configuration"
run "config set plan_claude max20" "$LOOMY" config set plan_claude max20
run "config get plan_claude" "$LOOMY" config get plan_claude
has "value read back" "^max20$"
fails "invalid plan value refused" 2 "$LOOMY" config set plan_claude gratuit
fails "non-numeric price refused" 2 "$LOOMY" config set plan_codex_price beaucoup
run "config set overwrites without duplicating" "$LOOMY" config set plan_claude pro
if [[ "$(grep -c '^plan_claude=' "$XDG_CONFIG_HOME/loomy/config")" == "1" ]]; then ok "a single plan_claude line"; else ko "duplicate plan_claude"; fi
run "config list" "$LOOMY" config list
has "list: plan_claude=pro" "^plan_claude=pro$"
rm -f "$XDG_CONFIG_HOME/loomy/config"

# ------------------------------------------------------------------ routage
section "Routing"
P="$WORK/route"; mkdir -p "$P"
for env in claude codex hybrid-claude hybrid-codex; do
  for prof in econome equilibre qualite; do
    if "$LOOMY" route --root "$P" --env "$env" --profile "$prof" markdown >"$OUT" 2>&1 && grep -q '^| ' "$OUT"; then :; else ko "route $env / $prof"; continue 2; fi
  done
done
ok "matrix produced for 4 environments × 3 profiles"
cd "$P" || exit 1
run "route all" "$LOOMY" route all
has "route all: 4 environment columns" "Hybrid, Codex lead"
run "route lead" "$LOOMY" route lead
has "lead agent on the best model" "opus|astra"
run "route get executor" "$LOOMY" route get executor
if [[ "$(wc -w <"$OUT" | tr -d ' ')" == "3" ]]; then ok "route get: family model effort"; else ko "route get: unexpected format ($(cat "$OUT"))"; fi
got="$(bash -c 'source "$1/scripts/lib/models.sh"; ai_resolve lead hybrid-claude econome; a="$R_MODEL $R_EFFORT"; ai_resolve architect hybrid-claude econome; b="$R_MODEL $R_EFFORT"; ai_resolve lead hybrid-codex econome; echo "$a | $b | $R_MODEL $R_EFFORT"' _ "$REPO")"
[[ "$got" == "claude-sonnet-5-5 medium | claude-opus-5-5 medium | gpt-6.1-sol medium" ]] && ok "Thrifty: Claude lead on Sonnet 5.5 medium, hard roles on Opus, Codex lead unchanged" || ko "Thrifty routing: $got"

# Fallback: without Codex, a hybrid mode falls back to Claude alone.
# Each environment puts the lead agent and the executor on the right family.
lead_of() { "$LOOMY" route --root "$P" --env "$1" get lead 2>/dev/null | cut -d' ' -f2; }
exec_of() { "$LOOMY" route --root "$P" --env "$1" get executor 2>/dev/null | cut -d' ' -f1; }
if [[ "$(lead_of claude)" == claude-opus* && "$(lead_of codex)" == gpt-6.1-sol && "$(lead_of hybrid-claude)" == claude-opus* && "$(lead_of hybrid-codex)" == gpt-6.1-sol ]]
then ok "lead agent: Opus on Claude, Astra on Codex"; else ko "lead agent misrouted ($(lead_of claude) / $(lead_of codex) / $(lead_of hybrid-claude) / $(lead_of hybrid-codex))"; fi
if [[ "$(exec_of claude)" == claude && "$(exec_of codex)" == codex && "$(exec_of hybrid-claude)" == codex ]]
then ok "executor: Luna in hybrid Claude lead"; else ko "executor misrouted"; fi
if [[ "$("$LOOMY" route --root "$P" --env claude --profile econome get lead)" != "$("$LOOMY" route --root "$P" --env claude --profile qualite get lead)" ]]
then ok "profiles change the lead agent effort"; else ko "profiles have no effect on the lead agent"; fi

# Fallback: a hybrid brief without Codex installed falls back to Claude alone.
mkdir -p "$P/.loomy" && printf -- '---\nai_mode: ORCHESTRATED\nai_lead: claude\n---\n' >"$P/.loomy/brief.md"
if [[ "$("$LOOMY" route --root "$P" get executor | cut -d' ' -f1)" == codex ]]; then ok "hybrid brief: executor on Codex"; else ko "hybrid brief: executor not on Codex"; fi
run "fallback without Codex" env LOOMY_CODEX_BIN=/inexistant "$LOOMY" route --root "$P" get executor
has "executor routed to Claude" "^claude "
rm -rf "$P/.loomy"

# ------------------------------------------------------------------ install into a project
section "loomy init (non-interactive)"
PROJ="$WORK/projet"; mkdir -p "$PROJ"
run "init --yes in an empty folder" "$LOOMY" init "$PROJ" --yes --no-clipboard
for f in START.md .loomy/brief.md .loomy/state .loomy/VERSION .loomy/scripts/loomy-status.sh .loomy/templates/AGENTS.md; do
  if [[ -e "$PROJ/$f" ]]; then :; else ko "file missing after init: $f"; fi
done
ok "control plane files copied"
file_has "brief: complete front matter" "$PROJ/.loomy/brief.md" "^push_after_commit: "
file_has "initial phase: discovery" "$PROJ/.loomy/state" "^phase=discover$"
file_has ".gitignore: managed history block installed" "$PROJ/.gitignore" "^# >>> Loomy: local history and work files, never versioned$"
has "next step: terminal tracking" "loomy watch|loomy-status.sh --watch"
if [[ ! -f "$XDG_CONFIG_HOME/loomy/config" ]] || ! grep -q '^plan_' "$XDG_CONFIG_HOME/loomy/config"; then ok "--yes saves no plan"; else ko "--yes saved a plan"; fi
fails "second init outside a terminal: guides without changing anything" 1 "$LOOMY" init "$PROJ" --no-wizard
has "second init: offers to resume" "loomy start"
has "second init: offers the update" "loomy init --update"
# Project update: scripts copied again, brief and phase kept.
echo "0.0.1" >"$PROJ/.loomy/VERSION"; rm -f "$PROJ/.loomy/scripts/loomy-start.sh"; cp "$PROJ/.loomy/brief.md" "$WORK/brief.avant"
run "init --update" "$LOOMY" init "$PROJ" --update
file_has "update: project version up to date" "$PROJ/.loomy/VERSION" "^$(cat "$REPO/VERSION")$"
[[ -f "$PROJ/.loomy/scripts/loomy-start.sh" ]] && ok "update: new scripts copied" || ko "update: scripts missing"
cmp -s "$PROJ/.loomy/brief.md" "$WORK/brief.avant" && ok "update: brief kept" || ko "update: brief modified"
file_has "update: phase kept" "$PROJ/.loomy/state" "^phase=discover$"
fails "update without project refused" 1 "$LOOMY" init "$WORK/pas-un-projet-$$" --update
mkdir -p "$WORK/pas-un-projet-$$"
fails "update without project refused" 1 "$LOOMY" init "$WORK/pas-un-projet-$$" --update
PR="$WORK/projet-reset"; mkdir -p "$PR"
run "init of a project to reset" "$LOOMY" init "$PR" --yes --no-clipboard
"$LOOMY" status --root "$PR" set build >/dev/null 2>&1
run "init --reset --no-wizard" "$LOOMY" init "$PR" --reset --no-wizard
[[ ! -f "$PR/.loomy/state" && -f "$PR/.loomy/brief.previous.md" && -f "$PR/START.md" ]] && ok "reset: phase reset, old brief kept, START.md present" || ko "reset incomplete"
FS="$WORK/start-etranger"; mkdir -p "$FS" && echo "autre" >"$FS/START.md"
fails "foreign START.md refused" 1 "$LOOMY" init "$FS" --no-wizard
PROJ2="$WORK/projet2"; mkdir -p "$PROJ2"
run "init --answers reuses a brief" "$LOOMY" init "$PROJ2" --answers "$PROJ/.loomy/brief.md" --yes --no-clipboard
file_has "brief reused: same name" "$PROJ2/.loomy/brief.md" "^name: "

# ------------------------------------------------------------------ start or resume
section "loomy start"
L="$WORK/start.log"
(cd "$PROJ" && "$LOOMY" start) >"$OUT" 2>&1; st=$?
if [[ $st == 0 ]]; then ok "start outside a terminal: shows the commands"; else ko "start outside a terminal (code $st)"; fi
has "start: lead agent command" "claude --model claude-opus"
has "start: bootstrap startup prompt" "Set up this project by strictly following START.md"
hasnt "start: no resume without a session" "resume:"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --new) >"$OUT" 2>&1
if grep -q $'^claude\t--model\tclaude-opus[^\t]*\t--effort\t[a-z]*\tSet up this project' "$L" 2>/dev/null; then ok "start --new runs claude with model, effort and prompt"; else ko "start --new: unexpected call ($(cat "$L" 2>/dev/null))"; fi
: >"$L"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --resume) >"$OUT" 2>&1
if grep -q $'\tSet up this project' "$L" && ! grep -q -- '--continue' "$L"; then ok "start --resume without a session: new session"; else ko "start --resume without a session ($(cat "$L"))"; fi
SESS="$HOME/.claude/projects/$(cd "$PROJ" && pwd -P | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$SESS" && touch "$SESS/s.jsonl"
: >"$L"
(cd "$PROJ" && STUB_LOG="$L" "$LOOMY" start --resume) >"$OUT" 2>&1
if grep -q $'^claude\t--continue\t--model' "$L"; then ok "start --resume resumes the folder session"; else ko "start --resume ($(cat "$L"))"; fi
(cd "$PROJ" && "$LOOMY" start --print) >"$OUT" 2>&1
has "start: resume offered when a session exists" "resume: claude --continue"
rm -rf "$HOME/.claude/projects"
# Project led by Codex.
PX="$WORK/projet-codex"; mkdir -p "$PX/.loomy" && printf -- '---\nname: X\nai_mode: SOLO\nai_lead: codex\nbudget: equilibre\n---\n' >"$PX/.loomy/brief.md" && touch "$PX/START.md"
: >"$L"
(cd "$PX" && STUB_LOG="$L" "$LOOMY" start --new) >"$OUT" 2>&1
if grep -q $'^codex\t-m\tgpt-6.1-sol\t-c\tmodel_reasoning_effort=' "$L"; then ok "start --new runs codex when Codex leads"; else ko "start codex ($(cat "$L"))"; fi
fails "start without brief refused" 1 "$LOOMY" start --root "$WORK/route-vide-$$"
mkdir -p "$WORK/route-vide-$$"
fails "start without brief refused" 1 "$LOOMY" start --root "$WORK/route-vide-$$"

# ------------------------------------------------------------------ scenarios
section "Scenarios"
# Loomy project in a subfolder of a Git repository: found from any subfolder.
MONO="$WORK/mono"; mkdir -p "$MONO/apps/site/src"
git -C "$MONO" init -q && git -C "$MONO" commit -q --allow-empty -m init
run "init in a subfolder of a repository" "$LOOMY" init "$MONO/apps/site" --yes --no-clipboard
(cd "$MONO/apps/site/src" && "$LOOMY" status) >"$OUT" 2>&1
has "status from a subfolder: project found" "Project status +~?.*apps/site"
(cd "$MONO/apps/site/src" && "$LOOMY" delegate claude explorer "sous-dossier") >/dev/null 2>&1
[[ -s "$MONO/apps/site/.loomy/logs/events.jsonl" ]] && grep -q '"type":"delegation",' "$MONO/apps/site/.loomy/logs/events.jsonl" && ok "delegation logged in the subfolder project" || ko "delegation not logged in the subfolder"
(cd "$MONO/apps/site/src" && "$LOOMY" start --print) >"$OUT" 2>&1
has "start from a subfolder" "claude --model"
# loomy brief outside a project, and brief redone midway.
(cd "$WORK" && mkdir -p hors-projet && cd hors-projet && "$LOOMY" brief) >"$OUT" 2>&1; st=$?
[[ $st == 1 ]] && grep -q "loomy init" "$OUT" && ok "brief outside a project: points to loomy init" || ko "brief outside a project (code $st)"
[[ ! -e "$WORK/hors-projet/.loomy" ]] && ok "brief outside a project: nothing created" || ko "brief outside a project: .loomy created"
"$LOOMY" status --root "$MONO/apps/site" set build >/dev/null 2>&1
(cd "$MONO/apps/site" && "$LOOMY" brief --yes --no-clipboard) >/dev/null 2>&1
file_has "brief redone midway: phase kept" "$MONO/apps/site/.loomy/state" "^phase=build$"
# Folders that aren't projects.
(cd "$HOME" && "$LOOMY" init --no-wizard) >"$OUT" 2>&1; st=$?
[[ $st == 1 && ! -e "$HOME/START.md" ]] && ok "init refused in the home folder" || ko "init in the home folder (code $st)"
# loomy init creates the given folder, and guides outside a terminal when no folder is given in the wrong place.
run "init of a folder that doesn't exist yet" "$LOOMY" init "$WORK/cree-par-init/app" --yes --no-clipboard
[[ -f "$WORK/cree-par-init/app/.loomy/brief.md" ]] && ok "init: folder created and project set up" || ko "init: folder not created"
(cd "$HOME" && "$LOOMY" init --no-wizard) >"$OUT" 2>&1
has "init outside a terminal in the home folder: suggests loomy init <name>" "loomy init my-project"
if command -v expect >/dev/null 2>&1; then
  PARENT="$WORK/parent"; mkdir -p "$PARENT/autre" "$PARENT/encore"
  cat >"$WORK/init-dossier.exp" <<EXP
set timeout 20
cd "$PARENT"
spawn "$LOOMY" init --no-clipboard
expect "Project name" ; expect "⏎ confirm" ; send "Projet Été 2026\r"
expect "Where to create the project" ; expect "⏎ confirm" ; send "\r"
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {Open the lead agent session} { expect "⏎ confirm" ; send "\033\[B" ; after 300 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  run "interactive init from a parent folder" expect "$WORK/init-dossier.exp"
  D="$PARENT/projet-ete-2026"
  [[ -n "$D" && -f "$D/.loomy/brief.md" ]] && ok "init: folder created from the project name ($(basename "$D"))" || ko "init: project folder missing ($(ls "$PARENT" | tr '\n' ' '))"
  [[ -n "$D" ]] && file_has "init: project name kept in the brief" "$D/.loomy/brief.md" '^name: "Projet Été 2026"$'
  has "init: reminder to cd into the new folder" "cd projet-"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
fi

# New project in a folder that is itself inside a Git repository: dedicated repository offered, then GitHub repository.
if command -v expect >/dev/null 2>&1; then
  PARD="$WORK/parent-git"; mkdir -p "$PARD" && git -C "$PARD" init -q && git -C "$PARD" commit -q --allow-empty -m parent
  cat >"$WORK/dans-parent.exp" <<EXP
set timeout 20
cd "$PARD"
spawn "$LOOMY" init sous-projet --no-clipboard
for {set i 0} {\$i < 80} {incr i} {
  expect {
    -re {Open the lead agent session} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  run "init in a subfolder of a parent repository" expect "$WORK/dans-parent.exp"
  has "dedicated repository offered" "Create a dedicated Git repository for this project"
  [[ -d "$PARD/sous-projet/.git" ]] && ok "dedicated Git repository created for the project" || ko "no dedicated repository"
  [[ "$(git -C "$PARD/sous-projet" config --get remote.origin.url)" == "https://github.com/testeur/sous-projet.git" ]] && ok "GitHub repository created in the dedicated repository" || ko "remote: $(git -C "$PARD/sous-projet" config --get remote.origin.url)"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
fi

# Full screen: loomy watch redraws in place, without piling anything into the terminal history; q quits.
TMUX_BIN="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v tmux || true)"
tmux() { "$TMUX_BIN" "$@"; }
if [[ -n "$TMUX_BIN" && -d "${PARD:-}/sous-projet" ]]; then
  tmux -L loomy-test kill-server 2>/dev/null || true
  tmux -L loomy-test new-session -d -s w -x 100 -y 30 -c "$PARD/sous-projet" "bash '$LOOMY' watch 1; echo SORTIE_OK; sleep 30"
  sleep 4
  [[ "$(tmux -L loomy-test display -p -t w '#{history_size}')" == "0" ]] && ok "watch: nothing piles up in the history" || ko "watch: history $(tmux -L loomy-test display -p -t w '#{history_size}')"
  tmux -L loomy-test send-keys -t w q; sleep 1.5
  tmux -L loomy-test capture-pane -t w -p | grep -q SORTIE_OK && ok "watch: q quits and restores the normal screen" || ko "watch: q doesn't quit"
  tmux -L loomy-test kill-server 2>/dev/null || true
  # Home: full-screen app with a fixed frame; views open inside the frame, q quits leaving nothing behind.
  # Active wait (slower continuous integration machines): up to 20 s for the expected text to show up.
  tw() { local k=0; until tmux -L loomy-test capture-pane -t h -p 2>/dev/null | grep -q "$1"; do sleep 0.25; k=$(( k + 1 )); (( k > 80 )) && return 1; done; return 0; }
  # The previous test's tmux server must be stopped before starting another one under the same name (otherwise "server exited
  # unexpectedly" on slow machines); launch retried if needed.
  tstart() {
    local k=0
    while tmux -L loomy-test ls >/dev/null 2>&1 && (( k < 20 )); do tmux -L loomy-test kill-server 2>/dev/null || true; sleep 0.25; k=$(( k + 1 )); done
    for k in 1 2 3; do tmux -L loomy-test new-session -d "$@" 2>/dev/null && return 0; sleep 0.5; done
    return 1
  }
  tstart -s h -x 100 -y 34 -c "$PARD/sous-projet" "bash '$LOOMY'; echo FIN_ACCUEIL; sleep 60"
  tw "What do you want to do" && tmux -L loomy-test capture-pane -t h -p | tail -1 | grep -q "loomy" \
    && ok "home: frame (menu in the body, version in the footer)" || ko "home: frame missing"
  tmux -L loomy-test send-keys -t h Down Down; sleep 0.5; tmux -L loomy-test send-keys -t h Enter
  tw "PHASES" && tmux -L loomy-test capture-pane -t h -p | grep -q "Detailed status" \
    && ok "home: status shown in the frame" || ko "home: status view missing"
  tmux -L loomy-test send-keys -t h Enter
  tw "What do you want to do" && ok "home: back from the view" || ko "home: no way back"
  tmux -L loomy-test send-keys -t h q
  if tw "FIN_ACCUEIL" && ! tmux -L loomy-test capture-pane -t h -p -S -200 | grep -q "What do you want to do"; then
    ok "home: q quits, nothing left in the terminal"
  else ko "home: exit"; fi
  tmux -L loomy-test kill-server 2>/dev/null || true
  # loomy start --watch in tmux: a tracking pane next to the agent, closed with it.
  mkdir -p "$WORK/lent"
  printf '#!/bin/bash\n[[ "$1" == "--version" ]] && { echo "2.1.300 (Claude Code)"; exit 0; }\nsleep 4\n' >"$WORK/lent/claude"; chmod +x "$WORK/lent/claude"
  tstart -s s -x 120 -y 50 -c "$PARD/sous-projet" "PATH='$WORK/lent':'$(dirname "$TMUX_BIN")':\$PATH bash '$LOOMY' start --new --watch; sleep 30"
  sleep 2.5
  [[ "$(tmux -L loomy-test list-panes -t s | wc -l | tr -d ' ')" == "2" ]] && ok "start --watch: tracking pane open" || ko "start --watch: $(tmux -L loomy-test list-panes -t s | wc -l) pane(s)"
  sleep 5
  [[ "$(tmux -L loomy-test list-panes -t s | wc -l | tr -d ' ')" == "1" ]] && ok "start --watch: tracking closed with the session" || ko "start --watch: tracking still open"
  tmux -L loomy-test kill-server 2>/dev/null || true
fi

# UTF-8 locale picked even under pipefail (otherwise slow text measuring and split accents).
loc="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c 'set -euo pipefail; source "$1/scripts/lib/models.sh"; p="é"; echo "${#p}"' _ "$REPO")"
[[ "$loc" == "1" ]] && ok "locale UTF-8 choisie sous pipefail" || ko "locale not picked under pipefail ($loc)"
fit="$(env -i PATH=/usr/bin:/bin LC_ALL=C bash -c 'source "$1/scripts/lib/ui.sh"; _ui_fit "prompt de démarrage prêt" 13; printf "%s" "$UI_FIT"' _ "$REPO")"
[[ "$fit" == "prompt de dé…" ]] && ok "truncation by characters (accents intact)" || ko "truncation: $fit"
steps="$(env -i PATH=/usr/bin:/bin HOME="$HOME" bash -c 'source "$1/scripts/lib/ui.sh"; ui_steps_begin "MISE EN PLACE" "Étape A" "Étape B"; ui_step_run 0; ui_step_done 0 ok "A faite" "détail"; ui_step_run 1; ui_step_done 1 warn "B partielle" "à revoir"; ui_steps_end' _ "$REPO" 2>&1)"
grep -q "✓ A faite détail" <<<"$steps" && grep -q "! B partielle à revoir" <<<"$steps" && ok "steps: final lines outside full screen" || ko "steps: $steps"

# Readable log and loomy watch views.
if [[ -s "$PROJ/.loomy/logs/events.jsonl" ]]; then
  run "readable loomy log" bash "$REPO/scripts/loomy-log.sh" --root "$PROJ" -n 5
  if grep -q '^{' "$OUT"; then ko "loomy log: raw JSON instead of the readable format"; else ok "loomy log: readable format"; fi
  run "loomy log --raw" bash "$REPO/scripts/loomy-log.sh" --root "$PROJ" -n 1 --raw
  has "loomy log --raw: JSON" '^\{"ts"'
  run "watch log view" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/loomy-status.sh" --root "$PROJ" --compact --journal
  has "log view: LOG section" "◇  LOG"
fi
run "compact view" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/loomy-status.sh" --root "$PROJ" --compact
if grep -q "FICHIERS IA" "$OUT"; then ko "compact view: detailed sections present"; else ok "compact view: detailed sections absent"; fi

# Resumed session (claude --continue): same id, a new start after an end = open session.
RS="$WORK/reprise"; mkdir -p "$RS/.loomy/logs"; : >"$RS/.loomy/brief.md"
sleep 60 & RPID=$!
printf '%s\n' '{"ts":"2026-09-25T00:00:00Z","type":"session","event":"start","tool":"claude","session":"abc","pid":1}' \
  '{"ts":"2026-09-25T00:10:00Z","type":"session","event":"end","tool":"claude","session":"abc","pid":1}' \
  "{\"ts\":\"2026-09-25T09:00:00Z\",\"type\":\"session\",\"event\":\"start\",\"tool\":\"claude\",\"session\":\"abc\",\"pid\":$RPID}" >"$RS/.loomy/logs/events.jsonl"
st="$(bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; ai_session_state "$2"' _ "$REPO" "$RS")"
[[ "$st" == open* ]] && ok "resumed session seen as open" || ko "resumed session: $st"
kill "$RPID" 2>/dev/null || true

# loomy effort: effort set per project, over the profile, used by loomy start.
if [[ -f "$PROJ/.loomy/brief.md" ]]; then
  run "lead agent effort set" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/loomy-effort.sh" --root "$PROJ" low
  grep -qx "lead=low" "$PROJ/.loomy/efforts" && ok "effort saved in .loomy/efforts" || ko "effort not saved"
  run "start --print with the set effort" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/loomy-start.sh" --root "$PROJ" --print
  has "start uses the set effort" "effort low"
  fails "effort: unknown level refused" 2 bash "$REPO/scripts/loomy-effort.sh" --root "$PROJ" turbo
  run "effort --reset" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/loomy-effort.sh" --root "$PROJ" --reset
  [[ ! -f "$PROJ/.loomy/efforts" ]] && ok "effort back to the profile" || ko "setting still present"
fi

# loomy feedback: anonymised issue text (no name, goal or task text), nothing sent with --print.
FB="$WORK/retour"; mkdir -p "$FB/.loomy/logs"
printf -- '---\nname: "NomSecret42"\ngoal: "ObjectifSecret42"\ntype: web\nai_mode: ORCHESTRATED\nai_lead: claude\n---\n' >"$FB/.loomy/brief.md"
printf 'phase=build\n' >"$FB/.loomy/state"
printf '%s\n' '{"ts":"2026-09-25T10:00:00Z","type":"delegation","id":"f1","role":"executor","family":"codex","model":"gpt-6-luna","status":"ok","duration_s":5,"cost_usd":0.001,"task":"TacheSecrete42"}' >"$FB/.loomy/logs/events.jsonl"
run "feedback --print" bash "$REPO/scripts/loomy-feedback.sh" --root "$FB" --print "un retour de test"
has "feedback: message attached" "un retour de test"
has "feedback: versions attached" "\| Loomy \|"
has "feedback: project state attached" "phase build"
if grep -qE "NomSecret42|ObjectifSecret42|TacheSecrete42|$FB" "$OUT"; then ko "feedback: project data leaked"; else ok "feedback: no name, goal, path or task text"; fi

# Project relays: no more script copies; they find Loomy through the loomy command in the PATH.
if [[ -d "$PROJ/.loomy/scripts" ]]; then
  [[ ! -d "$PROJ/.loomy/scripts/lib" ]] && ok "relays: no more library copied into the project" || ko "relays: lib copied"
  mkdir -p "$WORK/bin-loomy" && ln -sf "$REPO/bin/loomy" "$WORK/bin-loomy/loomy"
  run "relays without LOOMY_HOME, through the PATH" env -u LOOMY_HOME PATH="$WORK/bin-loomy:$PATH" bash "$PROJ/.loomy/scripts/loomy-route.sh" lead
  has "relays: lead agent routing" "claude|codex"
  fails "relays: clear message without Loomy" 127 env -u LOOMY_HOME LOOMY_RELAY_PATHS= PATH=/usr/bin:/bin bash "$PROJ/.loomy/scripts/loomy-route.sh" lead
fi

# Catalog: the repository one matches the built-in values (whole fallback chains); a newer downloaded catalog replaces them,
# without ever running its content.
cat_vals="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_CATALOG_DATE $AI_CHAIN_CLAUDE_TOP $AI_CHAIN_CLAUDE_MID $AI_CHAIN_CLAUDE_FAST $AI_CHAIN_CODEX_TOP $AI_CHAIN_CODEX_MID $AI_CHAIN_CODEX_FAST"' _ "$REPO")"
file_vals="$(awk -F= '/^date=/{d=$2} /^model\.claude\.top=/{a=$2} /^model\.claude\.mid=/{b=$2} /^model\.claude\.fast=/{c=$2} /^model\.codex\.top=/{e=$2} /^model\.codex\.mid=/{f=$2} /^model\.codex\.fast=/{g=$2} END{print d, a, b, c, e, f, g}' "$REPO/catalog/models.conf" | tr -d ',')"
[[ "$cat_vals" == "$file_vals" ]] && ok "repository catalog = built-in values" || ko "catalog: $cat_vals ≠ $file_vals"
mkdir -p "$XDG_CONFIG_HOME/loomy"
sed 's/^date=.*/date=2099-01-01/; s/^model.codex.fast=.*/model.codex.fast=luna-test/; s/^price.gpt-6-sol=.*/price.gpt-6-sol=9 9 9/' "$REPO/catalog/models.conf" >"$XDG_CONFIG_HOME/loomy/catalog.conf"
echo 'model.claude.top=$(touch '"$WORK"'/injecte)' >>"$XDG_CONFIG_HOME/loomy/catalog.conf"
got="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_CATALOG_SOURCE $AI_MODEL_CODEX_FAST $AI_MODEL_CLAUDE_TOP $(ai_price gpt-6-sol)"' _ "$REPO")"
[[ "$got" == "downloaded luna-test claude-opus-5-5 9 9 9" ]] && ok "downloaded catalog taken into account" || ko "downloaded catalog: $got"
[[ ! -e "$WORK/injecte" ]] && ok "catalog: content never executed" || ko "catalog: injection executed"
echo 'model.claude.mid=--dangerously-skip-permissions, claude-sonnet-5' >>"$XDG_CONFIG_HOME/loomy/catalog.conf"
got="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_MODEL_CLAUDE_MID"' _ "$REPO")"
[[ "$got" != -* ]] && ok "catalog: a model id never starts with a hyphen" || ko "catalog: option injected ($got)"
rm -f "$XDG_CONFIG_HOME/loomy/catalog.conf"

# Fallback chains: first available model, fallback when refused or missing from Codex, pinning, rebalancing.
CH="$WORK/chaines"; mkdir -p "$CH/cfg/loomy" "$CH/codex"
printf '%s\n' 'date=2099-01-01' 'model.claude.mid=claude-sonnet-9, claude-sonnet-5' 'model.codex.top=gpt-9-astra, gpt-6-astra' 'route.claude.explorer=MID low' >"$CH/cfg/loomy/catalog.conf"
echo '{"models":[{"slug":"gpt-6-astra"}]}' >"$CH/codex/models_cache.json"
chq() { XDG_CONFIG_HOME="$CH/cfg" CODEX_HOME="$CH/codex" bash -c 'source "$1/scripts/lib/models.sh"; ai_route explorer claude equilibre; echo "$AI_MODEL_CLAUDE_MID $AI_MODEL_CODEX_TOP $R_MODEL $R_EFFORT"' _ "$REPO"; }
[[ "$(chq)" == "claude-sonnet-9 gpt-6-astra claude-sonnet-9 low" ]] && ok "chains: newest first, Codex limited to its models, role rebalanced" || ko "chains: $(chq)"
echo "claude-sonnet-9=ko" >"$CH/cfg/loomy/models.state"
[[ "$(chq)" == "claude-sonnet-5 gpt-6-astra claude-sonnet-5 low" ]] && ok "chains: fallback when the model is refused" || ko "fallback: $(chq)"
echo "model.claude.mid=claude-sonnet-4" >"$CH/cfg/loomy/config"
[[ "$(chq)" == "claude-sonnet-4 gpt-6-astra claude-sonnet-4 low" ]] && ok "chains: pinned model takes priority" || ko "pinning: $(chq)"

# Real Claude Code cost: Stop and SubagentStop hooks, read from the transcript (no duplicates, no rereading).
US="$WORK/usage"; mkdir -p "$US/.loomy"; : >"$US/.loomy/brief.md"
TR="$WORK/transcript.jsonl"
for i in 1 1 2; do printf '{"type":"assistant","message":{"id":"msg_%s","model":"claude-haiku-4-5-20251001","usage":{"input_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' "$i"; done >"$TR"
printf '{"session_id":"s","transcript_path":"%s"}' "$TR" | LOOMY_HOME="$REPO" bash "$REPO/scripts/loomy-context.sh" --root "$US" --hook stop
printf '{"session_id":"s","transcript_path":"%s"}' "$TR" | LOOMY_HOME="$REPO" bash "$REPO/scripts/loomy-context.sh" --root "$US" --hook stop
n_usage="$(grep -c '"type":"usage"' "$US/.loomy/logs/events.jsonl" 2>/dev/null || echo 0)"
[[ "$n_usage" == "1" ]] && ok "usage: one event, transcript not reread" || ko "usage: $n_usage event(s)"
grep -q '"messages":2,.*"cost_usd":2.000000' "$US/.loomy/logs/events.jsonl" && ok "usage: duplicates discarded, cost at public price" || ko "usage: $(cat "$US/.loomy/logs/events.jsonl")"
printf '{"session_id":"s2","transcript_path":"%s"}' "$TR" | LOOMY_DELEGATION=1 bash "$REPO/scripts/loomy-context.sh" --root "$US" --hook start
grep -q '"session":"s2"' "$US/.loomy/logs/events.jsonl" && ko "Loomy delegation counted as a session" || ok "Loomy delegations ignored by the hooks"
run "status: lead agent cost" env LOOMY_NO_CLEAR=1 bash "$REPO/scripts/loomy-status.sh" --root "$US"
has "status: lead agent measured" "Lead agent .*2 repl"
run "log --csv" bash "$REPO/scripts/loomy-log.sh" --root "$US" --csv
has "csv: header" "^date_utc,type,role"
has "csv: lead agent cost" "usage,lead,,claude,claude-haiku-4-5-20251001,ok"

# Log: monthly archive, full history for --since.
AR="$WORK/archive"; mkdir -p "$AR/.loomy/logs"; : >"$AR/.loomy/brief.md"
printf '%s\n' '{"ts":"2000-01-05T10:00:00Z","type":"phase","phase":"build"}' >"$AR/.loomy/logs/events.jsonl"
bash "$REPO/scripts/loomy-status.sh" --root "$AR" set verify >/dev/null
[[ -f "$AR/.loomy/logs/archive/events-2000-01.jsonl" ]] && ok "log: previous month archived" || ko "log: no archive"
run "log --since in the archives" bash "$REPO/scripts/loomy-log.sh" --root "$AR" --since 2000-01-01
has "log --since: archived event" "Build"

# Claude Code hooks: Stop and SubagentStop added to an existing settings.json, leaving the user's hooks alone.
HK="$WORK/hooks"; mkdir -p "$HK/.claude"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo perso"}]}]}}\n' >"$HK/.claude/settings.json"
UI_ASSUME_DEFAULTS=1 bash "$LOOMY" init "$HK" --yes >/dev/null 2>&1 || true
grep -q 'echo perso' "$HK/.claude/settings.json" && grep -q -- '--hook stop' "$HK/.claude/settings.json" && grep -q -- '--hook subagent' "$HK/.claude/settings.json" \
  && ok "Stop and SubagentStop hooks added, existing hooks kept" || ko "hooks: $(cat "$HK/.claude/settings.json")"

# Help and side commands.
run "help init" "$LOOMY" help init
has "help <command>: command help" "Usage: loomy init"
run "update --help updates nothing" "$LOOMY" update --help
has "update --help: help" "Usage: loomy update"
run "uninstall" "$LOOMY" uninstall
has "uninstall: removal command" "rm |uninstall"
has "uninstall: removing a project" "rm -rf .loomy START.md"

# ------------------------------------------------------------------ AI files visibility
section "AI files visibility (loomy privacy)"
PV="$WORK/prive"; mkdir -p "$PV"
run "project for loomy privacy" "$LOOMY" init "$PV" --yes --no-clipboard
file_has "brief: ai_files versioned by default" "$PV/.loomy/brief.md" "^ai_files: versioned$"
mkdir -p "$PV/.loomy/docs" && echo "# agents" >"$PV/AGENTS.md" && echo "rules" >"$PV/.loomy/docs/AI_WORKFLOW.md" && echo "code" >"$PV/app.txt"
git -C "$PV" add -A && git -C "$PV" commit -qm "with AI files"
run "privacy local" "$LOOMY" privacy --root "$PV" local
file_has "local: mode recorded in the brief" "$PV/.loomy/brief.md" "^ai_files: local$"
file_has "local: exclusion set in .git/info/exclude" "$PV/.git/info/exclude" "^/AGENTS.md$"
has "local: files already tracked flagged" "Still tracked by the project repository"
has "local: command to stop tracking them" "git rm -r --cached"
git -C "$PV" rm -r -q --cached -- .loomy START.md AGENTS.md .claude >/dev/null && git -C "$PV" commit -qm "AI files out of the repository"
[[ -z "$(git -C "$PV" status --porcelain)" ]] && ok "local: AI files no longer show in git status" || ko "local: AI files still visible ($(git -C "$PV" status --porcelain | head -3 | tr '\n' ' '))"
[[ -f "$PV/AGENTS.md" && -f "$PV/.loomy/brief.md" ]] && ok "local: files kept on disk" || ko "local: files lost"
if git -C "$PV" check-ignore -q .gitignore; then ko ".gitignore excluded by mistake"; else ok "the rest of the project stays versioned"; fi
# Separate private repository (local repository instead of GitHub).
BARE="$WORK/prive-ai.git"; git init --bare -q -b main "$BARE"
run "privacy private --remote" "$LOOMY" privacy --root "$PV" private --remote "$BARE"
file_has "private: mode recorded" "$PV/.loomy/brief.md" "^ai_files: private$"
git --git-dir="$BARE" ls-tree -r --name-only main >"$OUT" 2>&1
has "private: AGENTS.md backed up" "^AGENTS.md$"
has "private: brief backed up" "^.loomy/brief.md$"
hasnt "private: project code absent from the private repository" "^app.txt$"
hasnt "private: log absent from the private repository" "^.loomy/logs/"
echo "new rule" >>"$PV/AGENTS.md"
"$LOOMY" status --root "$PV" >"$OUT" 2>&1
has "status: unsaved changes flagged" "unsaved change"
run "privacy sync" "$LOOMY" privacy --root "$PV" sync
[[ "$(git --git-dir="$BARE" show main:AGENTS.md | tail -1)" == "new rule" ]] && ok "sync: change pushed" || ko "sync: change missing"
# Second machine: project clone (without AI files), then restore.
M2="$WORK/machine2"; git clone -q "$PV" "$M2"
[[ ! -e "$M2/AGENTS.md" ]] && ok "clone: AI files absent from the project repository" || ko "clone: AI files present"
echo "different local version" >"$M2/AGENTS.md"
run "privacy restore" "$LOOMY" privacy --root "$M2" restore "$BARE"
[[ -f "$M2/AGENTS.md" && -f "$M2/.loomy/brief.md" && -f "$M2/.loomy/docs/AI_WORKFLOW.md" ]] && ok "restore: AI files recovered" || ko "restore: files missing"
has "restore: different local files set aside" "set aside"
file_has "restore: exclusion set on the new machine" "$M2/.git/info/exclude" "^/AGENTS.md$"
[[ -z "$(git -C "$M2" status --porcelain)" ]] && ok "restore: project repository clean" || ko "restore: project repository modified"
echo "depuis la machine 2" >>"$M2/AGENTS.md"
run "sync from the second machine" "$LOOMY" privacy --root "$M2" sync
run "sync of the first machine after the second" "$LOOMY" privacy --root "$PV" sync
# A tracked AI file that disappears (START.md archived at the end of the setup): its deletion must be committed.
echo "# start" >"$PV/START.md"
run "privacy sync with START.md" "$LOOMY" privacy --root "$PV" sync
git --git-dir="$PV/.loomy/ai.git" --work-tree="$PV" ls-files >"$OUT" 2>&1
has "sync: START.md tracked by the private repository" "^START.md$"
mkdir -p "$PV/.loomy/docs/bootstrap" && mv "$PV/START.md" "$PV/.loomy/docs/bootstrap/START.md"
run "privacy sync after START.md was archived" "$LOOMY" privacy --root "$PV" sync
git --git-dir="$PV/.loomy/ai.git" --work-tree="$PV" ls-files >"$OUT" 2>&1
hasnt "sync: removed START.md no longer tracked" "^START.md$"
has "sync: archived START.md tracked" "^.loomy/docs/bootstrap/START.md$"
[[ -z "$(git --git-dir="$PV/.loomy/ai.git" --work-tree="$PV" diff --name-only)" ]] && ok "sync: private repository working tree clean" || ko "sync: private repository still dirty"
run "back to versioned mode" "$LOOMY" privacy --root "$PV" versioned
if grep -q "loomy : fichiers IA" "$PV/.git/info/exclude"; then ko "versioned: exclusion still present"; else ok "versioned: exclusion removed"; fi
fails "sync outside private mode refused" 1 "$LOOMY" privacy --root "$PV" sync
# Project in a subfolder: patterns anchored on the subfolder.
run "privacy local in a subfolder" "$LOOMY" privacy --root "$MONO/apps/site" local
file_has "subfolder: prefixed pattern" "$MONO/.git/info/exclude" "^/apps/site/AGENTS.md$"

# ------------------------------------------------------------------ history and work files stay out of Git
section "History never versioned"

# A fresh project in Git gets the managed block; only its history and local work files are ignored.
HIST="$WORK/history-git"; mkdir -p "$HIST"; git -C "$HIST" init -q
run "history: init in a Git repository" "$LOOMY" init "$HIST" --yes --no-clipboard
HIST_BEGIN="# >>> Loomy: local history and work files, never versioned"
HIST_END="# <<< Loomy"
if [[ "$(grep -Fxc "$HIST_BEGIN" "$HIST/.gitignore")" == 1 && "$(grep -Fxc "$HIST_END" "$HIST/.gitignore")" == 1 ]]; then
  ok "history: managed block markers appear once"
else
  ko "history: managed block markers missing or duplicated"
fi
awk -v begin="$HIST_BEGIN" -v end="$HIST_END" '$0 == begin { inside = 1 } inside { print } $0 == end { inside = 0 }' \
  "$HIST/.gitignore" >"$WORK/history-block.txt"
bad=""
for p in .loomy/logs/ .loomy/memory/ .loomy/docs/HANDOFF.md .loomy/tasks/ .loomy/audits/ .loomy/assessment.md; do
  grep -qxF "$p" "$WORK/history-block.txt" || bad="$bad $p"
done
if [[ -z "$bad" ]]; then ok "history: managed block covers logs, memory, handoff, tasks, audits and assessment"; else ko "history: missing ignore patterns:$bad"; fi
mkdir -p "$HIST/.loomy/logs" "$HIST/.loomy/memory" "$HIST/.loomy/tasks" "$HIST/.loomy/audits/a" "$HIST/.loomy/docs"
touch "$HIST/.loomy/logs/x" "$HIST/.loomy/memory/STATE.md" "$HIST/.loomy/tasks/t.md" \
  "$HIST/.loomy/audits/a/r.md" "$HIST/.loomy/docs/HANDOFF.md"
git -C "$HIST" status --porcelain --ignored --untracked-files=all >"$OUT" 2>&1
bad=""
for p in .loomy/logs/x .loomy/memory/STATE.md .loomy/tasks/t.md .loomy/audits/a/r.md .loomy/docs/HANDOFF.md; do
  grep -qxF "!! $p" "$OUT" || bad="$bad $p"
done
if [[ -z "$bad" ]]; then ok "history: logs, memory, tasks, audits and HANDOFF show ignored in Git status"; else ko "history: files not ignored in Git status:$bad"; fi
if grep -qxF '?? .loomy/docs/AI_WORKFLOW.md' "$OUT" && grep -qxF '?? .loomy/brief.md' "$OUT"; then
  ok "history: AI_WORKFLOW.md and brief.md remain visible in Git status"
else
  ko "history: AI_WORKFLOW.md or brief.md is missing or ignored in Git status"
fi

# No Git repository and no pre-existing .gitignore: syncing must leave the file absent.
source "$REPO/scripts/lib/project.sh"
HIST_NG="$WORK/history-no-git"; mkdir -p "$HIST_NG"
loomy_gitignore_sync "$HIST_NG"
if [[ "$LP_GI_CHANGED" == 0 && ! -e "$HIST_NG/.gitignore" ]]; then
  ok "history: no .gitignore created outside Git"
else
  ko "history: .gitignore created outside Git"
fi

# Upgrade the older one-line rules without touching user rules; the operation is idempotent and repairs edits.
HIST_UP="$WORK/history-upgrade"; mkdir -p "$HIST_UP"; git -C "$HIST_UP" init -q
cat >"$HIST_UP/.gitignore" <<'EOF'
node_modules/

# Loomy: local activity log
.loomy/logs/

# Loomy: delegation results (shared memory, may hold sensitive findings)
.loomy/memory/delegations/
EOF
loomy_gitignore_sync "$HIST_UP"
if [[ "$LP_GI_CHANGED" == 1 && "$(grep -Fxc "$HIST_BEGIN" "$HIST_UP/.gitignore")" == 1 \
  && "$(grep -Fxc "$HIST_END" "$HIST_UP/.gitignore")" == 1 ]] \
  && grep -qxF 'node_modules/' "$HIST_UP/.gitignore" \
  && [[ "$(grep -Fxc '.loomy/logs/' "$HIST_UP/.gitignore")" == 1 ]] \
  && ! grep -qF '# Loomy: local activity log' "$HIST_UP/.gitignore" \
  && ! grep -qF '# Loomy: delegation results (shared memory, may hold sensitive findings)' "$HIST_UP/.gitignore" \
  && ! grep -qxF '.loomy/memory/delegations/' "$HIST_UP/.gitignore"; then
  ok "history: upgrade removes legacy lines, keeps node_modules and installs one block"
else
  ko "history: upgrade did not preserve or replace the old rules correctly"
fi
cp "$HIST_UP/.gitignore" "$WORK/history-upgrade.before"
loomy_gitignore_sync "$HIST_UP"
if [[ "$LP_GI_CHANGED" == 0 ]] && cmp -s "$WORK/history-upgrade.before" "$HIST_UP/.gitignore"; then
  ok "history: second sync leaves .gitignore unchanged"
else
  ko "history: second sync changed .gitignore or reported a change"
fi
sed 's#^\.loomy/audits/$#.loomy/audits-edited/#' "$HIST_UP/.gitignore" >"$WORK/history-upgrade.edited"
mv "$WORK/history-upgrade.edited" "$HIST_UP/.gitignore"
loomy_gitignore_sync "$HIST_UP"
if [[ "$LP_GI_CHANGED" == 1 ]] && grep -qxF '.loomy/audits/' "$HIST_UP/.gitignore" \
  && ! grep -qxF '.loomy/audits-edited/' "$HIST_UP/.gitignore"; then
  ok "history: edited managed block is rewritten"
else
  ko "history: edited managed block was not restored"
fi

# The doctor reports tracked history without changing it; --fix removes only index entries and keeps files.
HIST_D="$WORK/history-doctor"; mkdir -p "$HIST_D"; git -C "$HIST_D" init -q
run "history: doctor fixture initialized" "$LOOMY" init "$HIST_D" --yes --no-clipboard
mkdir -p "$HIST_D/.loomy/logs" "$HIST_D/.loomy/memory"
touch "$HIST_D/.loomy/memory/STATE.md" "$HIST_D/.loomy/logs/events.jsonl" "$HIST_D/.loomy/task.state"
git -C "$HIST_D" add -f -- .loomy/memory/STATE.md .loomy/logs/events.jsonl .loomy/task.state \
  && git -C "$HIST_D" commit -qm "track local history for doctor test"
"$LOOMY" doctor --root "$HIST_D" >"$OUT" 2>&1 || true
has "history: doctor reports tracked history files" "Loomy history file\(s\) tracked by Git"
if [[ "$(git -C "$HIST_D" ls-files -- .loomy/memory/STATE.md .loomy/logs/events.jsonl .loomy/task.state | wc -l | tr -d ' ')" == 3 ]]; then
  ok "history: doctor without --fix keeps files tracked"
else
  ko "history: doctor without --fix untracked files"
fi
"$LOOMY" doctor --fix --root "$HIST_D" >"$OUT" 2>&1 || true
if [[ -z "$(git -C "$HIST_D" ls-files -- .loomy/memory/STATE.md .loomy/logs/events.jsonl .loomy/task.state)" \
  && -f "$HIST_D/.loomy/memory/STATE.md" && -f "$HIST_D/.loomy/logs/events.jsonl" && -f "$HIST_D/.loomy/task.state" ]]; then
  ok "history: doctor --fix removes tracked history from the index and keeps files"
else
  ko "history: doctor --fix did not untrack the files or removed them from disk"
fi
git -C "$HIST_D" status --porcelain -- .loomy/memory/STATE.md .loomy/logs/events.jsonl .loomy/task.state >"$OUT" 2>&1
bad=""
for p in .loomy/memory/STATE.md .loomy/logs/events.jsonl .loomy/task.state; do
  grep -qxF "D  $p" "$OUT" || bad="$bad $p"
done
if [[ -z "$bad" ]]; then ok "history: doctor --fix shows index deletions in Git status"; else ko "history: index deletions missing from Git status:$bad"; fi

# Reuse the private-mode project and local bare origin from the AI files visibility section. When this section is
# run by itself, seed the same small fixture here.
if [[ -z "${PV:-}" || ! -d "${PV:-}/.loomy/ai.git" || -z "${BARE:-}" || ! -d "${BARE:-}" ]]; then
  PV="$WORK/history-private"; BARE="$WORK/history-private-origin.git"
  mkdir -p "$PV"; git -C "$PV" init -q
  run "history: private fixture initialized" "$LOOMY" init "$PV" --yes --no-clipboard
  git -C "$PV" add -A && git -C "$PV" commit -qm "initialize private history fixture"
  git init --bare -q -b main "$BARE"
  run "history: private fixture origin created" "$LOOMY" privacy --root "$PV" private --remote "$BARE"
fi
mkdir -p "$PV/.loomy/memory/delegations" "$PV/.loomy/logs" "$PV/.loomy/tasks" "$PV/.loomy/docs"
touch "$PV/.loomy/memory/STATE.md" "$PV/.loomy/docs/HANDOFF.md" "$PV/.loomy/logs/events.jsonl" \
  "$PV/.loomy/memory/delegations/result.md" "$PV/.loomy/tasks/t.md"
run "history: private fixture synced" "$LOOMY" privacy --root "$PV" private --remote "$BARE"
git --git-dir="$PV/.loomy/ai.git" ls-files >"$OUT" 2>&1
if grep -qxF '.loomy/memory/STATE.md' "$OUT" && grep -qxF '.loomy/docs/HANDOFF.md' "$OUT"; then
  ok "history: private sync force-adds STATE.md and HANDOFF.md"
else
  ko "history: private sync missed STATE.md or HANDOFF.md"
fi
if grep -qE '^\.loomy/(logs/|memory/delegations/|tasks/|ai\.git|state$)' "$OUT"; then
  ko "history: private sync tracks a history or work file"
else
  ok "history: private sync omits logs, delegations, tasks, companion and state"
fi
printf 'previously tracked history\n' >"$PV/.loomy/logs/old.jsonl"
git --git-dir="$PV/.loomy/ai.git" --work-tree="$PV" add -f -- .loomy/logs/old.jsonl \
  && git --git-dir="$PV/.loomy/ai.git" --work-tree="$PV" commit -qm "track legacy history for sync test"
if git --git-dir="$PV/.loomy/ai.git" --work-tree="$PV" ls-files -- .loomy/logs/old.jsonl | grep -qxF '.loomy/logs/old.jsonl'; then
  ok "history: legacy history is tracked before the next private sync"
else
  ko "history: legacy history fixture was not tracked"
fi
run "history: private sync after legacy history was tracked" "$LOOMY" privacy --root "$PV" sync
git --git-dir="$PV/.loomy/ai.git" ls-files >"$OUT" 2>&1
if ! grep -qxF '.loomy/logs/old.jsonl' "$OUT" && [[ -f "$PV/.loomy/logs/old.jsonl" ]]; then
  ok "history: private sync drops previously tracked history and keeps it on disk"
else
  ko "history: private sync kept the legacy history tracked or removed the file"
fi

# Loomy's own checkout keeps all orchestration files outside its versioned tree.
git -C "$REPO" ls-files >"$OUT" 2>&1
if ! grep -qE '^(\.loomy/|\.claude/|\.codex/|AGENTS\.md$|CLAUDE\.md$|START\.md$)' "$OUT"; then
  ok "history: Loomy repository tracks no private AI files"
else
  ko "history: Loomy repository tracks an AI file ($(grep -E '^(\.loomy/|\.claude/|\.codex/|AGENTS\.md$|CLAUDE\.md$|START\.md$)' "$OUT" | head -1))"
fi

section "History block hardening"

HIST_HARD_BEGIN="# >>> Loomy: local history and work files, never versioned"
HIST_HARD_END="# <<< Loomy"
bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_history_block' \
  _ "$REPO" >"$WORK/history-hardening.expected-block"

# An orphan BEGIN marker and surrounding user rules survive; a complete managed block is appended.
HIST_HARD_MISSING="$WORK/history-missing-end"; mkdir -p "$HIST_HARD_MISSING"; git -C "$HIST_HARD_MISSING" init -q
printf 'node_modules/\n%s\n.env\nfoo\n' "$HIST_HARD_BEGIN" >"$HIST_HARD_MISSING/.gitignore"
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"; printf "%s\n" "$LP_GI_CHANGED"' \
  _ "$REPO" "$HIST_HARD_MISSING" >"$OUT" 2>&1; then
  has "history block: missing END marker is repaired" '^1$'
else
  ko "history block: missing END marker sync failed"
fi
file_has "history block: missing END keeps node_modules" "$HIST_HARD_MISSING/.gitignore" '^node_modules/$'
file_has "history block: missing END keeps .env" "$HIST_HARD_MISSING/.gitignore" '^\.env$'
file_has "history block: missing END keeps foo" "$HIST_HARD_MISSING/.gitignore" '^foo$'
HIST_HARD_BLOCK_LINE="$(grep -nFx "$HIST_HARD_BEGIN" "$HIST_HARD_MISSING/.gitignore" | tail -n 1 | cut -d: -f1)"
tail -n "+$HIST_HARD_BLOCK_LINE" "$HIST_HARD_MISSING/.gitignore" >"$WORK/history-missing-end.actual"
if cmp -s "$WORK/history-hardening.expected-block" "$WORK/history-missing-end.actual"; then
  ok "history block: missing END appends a complete block"
else
  ko "history block: missing END appended an incomplete block"
fi
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"; printf "%s\n" "$LP_GI_CHANGED"' \
  _ "$REPO" "$HIST_HARD_MISSING" >"$OUT" 2>&1; then
  has "history block: missing END repair is idempotent" '^0$'
else
  ko "history block: second missing END sync failed"
fi

# A negation after a valid block moves ahead of it, so the managed ignore rule wins.
HIST_HARD_NEGATION="$WORK/history-negation"; mkdir -p "$HIST_HARD_NEGATION"; git -C "$HIST_HARD_NEGATION" init -q
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"' \
  _ "$REPO" "$HIST_HARD_NEGATION" >"$OUT" 2>&1; then
  ok "history block: negation fixture synchronized"
else
  ko "history block: negation fixture sync failed"
fi
printf '%s\n' '!.loomy/audit.md' >>"$HIST_HARD_NEGATION/.gitignore"
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"; printf "%s\n" "$LP_GI_CHANGED"' \
  _ "$REPO" "$HIST_HARD_NEGATION" >"$OUT" 2>&1; then
  has "history block: negation after the block triggers repair" '^1$'
else
  ko "history block: negation repair sync failed"
fi
HIST_HARD_NEG_LINE="$(grep -nFx '!.loomy/audit.md' "$HIST_HARD_NEGATION/.gitignore" | cut -d: -f1)"
HIST_HARD_NEG_BEGIN="$(grep -nFx "$HIST_HARD_BEGIN" "$HIST_HARD_NEGATION/.gitignore" | tail -n 1 | cut -d: -f1)"
if [[ "$HIST_HARD_NEG_LINE" -lt "$HIST_HARD_NEG_BEGIN" \
  && "$(tail -n 1 "$HIST_HARD_NEGATION/.gitignore")" == "$HIST_HARD_END" ]] \
  && git -C "$HIST_HARD_NEGATION" check-ignore -q -- .loomy/audit.md; then
  ok "history block: negation precedes the final block and audit.md stays ignored"
else
  ko "history block: negation still overrides the managed ignore rule"
fi
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"; printf "%s\n" "$LP_GI_CHANGED"' \
  _ "$REPO" "$HIST_HARD_NEGATION" >"$OUT" 2>&1; then
  has "history block: negation repair is idempotent" '^0$'
else
  ko "history block: third negation sync failed"
fi

# A user line after the block is retained and the block is moved back to the end.
HIST_HARD_TRAILING="$WORK/history-trailing-line"; mkdir -p "$HIST_HARD_TRAILING"; git -C "$HIST_HARD_TRAILING" init -q
cp "$WORK/history-hardening.expected-block" "$HIST_HARD_TRAILING/.gitignore"
printf 'z/\n' >>"$HIST_HARD_TRAILING/.gitignore"
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"; printf "%s\n" "$LP_GI_CHANGED"' \
  _ "$REPO" "$HIST_HARD_TRAILING" >"$OUT" 2>&1; then
  has "history block: trailing user line moves the block" '^1$'
else
  ko "history block: trailing user line sync failed"
fi
HIST_HARD_TRAILING_BEGIN="$(grep -nFx "$HIST_HARD_BEGIN" "$HIST_HARD_TRAILING/.gitignore" | tail -n 1 | cut -d: -f1)"
HIST_HARD_Z_LINE="$(grep -nFx 'z/' "$HIST_HARD_TRAILING/.gitignore" | cut -d: -f1)"
tail -n "+$HIST_HARD_TRAILING_BEGIN" "$HIST_HARD_TRAILING/.gitignore" >"$WORK/history-trailing-line.actual"
if [[ "$HIST_HARD_Z_LINE" -lt "$HIST_HARD_TRAILING_BEGIN" \
  && "$(tail -n 1 "$HIST_HARD_TRAILING/.gitignore")" == "$HIST_HARD_END" ]] \
  && cmp -s "$WORK/history-hardening.expected-block" "$WORK/history-trailing-line.actual"; then
  ok "history block: z/ is preserved before the complete block at EOF"
else
  ko "history block: z/ was lost or the block is not last"
fi

# Git glob pathspecs recurse only where the managed patterns intend them to.
HIST_HARD_GLOB="$WORK/history-glob-pathspecs"; mkdir -p "$HIST_HARD_GLOB/.loomy/docs" "$HIST_HARD_GLOB/.loomy/logs"
git -C "$HIST_HARD_GLOB" init -q
touch "$HIST_HARD_GLOB/.loomy/docs/tutorial.state" "$HIST_HARD_GLOB/.loomy/state" \
  "$HIST_HARD_GLOB/.loomy/logs/x" "$HIST_HARD_GLOB/.loomy/a.state"
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"' \
  _ "$REPO" "$HIST_HARD_GLOB" >"$OUT" 2>&1; then
  ok "history block: glob fixture synchronized"
else
  ko "history block: glob fixture sync failed"
fi
run "history block: glob fixture files staged" git -C "$HIST_HARD_GLOB" add -f -- \
  .loomy/docs/tutorial.state .loomy/state .loomy/logs/x .loomy/a.state
run "history block: glob fixture committed" git -C "$HIST_HARD_GLOB" commit -qm "track history glob fixtures"
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_history_tracked "$2"' \
  _ "$REPO" "$HIST_HARD_GLOB" >"$OUT" 2>&1; then
  if [[ "$(cat "$OUT")" == $'.loomy/a.state\n.loomy/logs/x\n.loomy/state' ]]; then
    ok "history block: glob pathspecs report only intended tracked paths"
  else
    ko "history block: glob pathspecs returned unexpected tracked paths"
  fi
else
  ko "history block: glob pathspec lookup failed"
fi

# Temporary files are ignored at the Loomy root and below it; similarly named files are not.
HIST_HARD_TMP="$WORK/history-tmp-patterns"; mkdir -p "$HIST_HARD_TMP/.loomy/sub"; git -C "$HIST_HARD_TMP" init -q
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"' \
  _ "$REPO" "$HIST_HARD_TMP" >"$OUT" 2>&1; then
  ok "history block: temporary file fixture synchronized"
else
  ko "history block: temporary file fixture sync failed"
fi
touch "$HIST_HARD_TMP/.loomy/state.tmp" "$HIST_HARD_TMP/.loomy/sub/q.tmp.12" "$HIST_HARD_TMP/.loomy/tmp.x"
run "history block: check-ignore prints temporary files" git -C "$HIST_HARD_TMP" check-ignore -- .loomy/state.tmp .loomy/sub/q.tmp.12
has "history block: root temporary file is ignored" '^\.loomy/state\.tmp$'
has "history block: nested suffixed temporary file is ignored" '^\.loomy/sub/q\.tmp\.12$'
fails "history block: tmp.x is not ignored" 1 git -C "$HIST_HARD_TMP" check-ignore -q -- .loomy/tmp.x

# The doctor removes tracked history from the index while keeping it on disk; a locked index must report the failure.
HIST_HARD_DOCTOR_OK="$WORK/history-doctor-ok"; mkdir -p "$HIST_HARD_DOCTOR_OK"; git -C "$HIST_HARD_DOCTOR_OK" init -q
run "history block: doctor success fixture initialized" "$LOOMY" init "$HIST_HARD_DOCTOR_OK" --yes --no-clipboard
mkdir -p "$HIST_HARD_DOCTOR_OK/.loomy/logs" "$HIST_HARD_DOCTOR_OK/.loomy/memory"
touch "$HIST_HARD_DOCTOR_OK/.loomy/logs/events.jsonl" "$HIST_HARD_DOCTOR_OK/.loomy/memory/STATE.md"
run "history block: doctor success fixture staged" git -C "$HIST_HARD_DOCTOR_OK" add -f -- .loomy/logs/events.jsonl .loomy/memory/STATE.md
run "history block: doctor success fixture committed" git -C "$HIST_HARD_DOCTOR_OK" commit -qm "track history for doctor success"
"$LOOMY" doctor --fix --root "$HIST_HARD_DOCTOR_OK" >"$OUT" 2>&1 || true
has "history block: doctor --fix reports untracked history" 'history files untracked'
if [[ -z "$(git -C "$HIST_HARD_DOCTOR_OK" ls-files -- .loomy/logs/events.jsonl .loomy/memory/STATE.md)" \
  && -f "$HIST_HARD_DOCTOR_OK/.loomy/logs/events.jsonl" && -f "$HIST_HARD_DOCTOR_OK/.loomy/memory/STATE.md" ]]; then
  ok "history block: doctor --fix untracks files and keeps them on disk"
else
  ko "history block: doctor --fix failed to untrack files or removed them"
fi

HIST_HARD_DOCTOR_LOCK="$WORK/history-doctor-lock"; mkdir -p "$HIST_HARD_DOCTOR_LOCK"; git -C "$HIST_HARD_DOCTOR_LOCK" init -q
run "history block: doctor lock fixture initialized" "$LOOMY" init "$HIST_HARD_DOCTOR_LOCK" --yes --no-clipboard
mkdir -p "$HIST_HARD_DOCTOR_LOCK/.loomy/logs" "$HIST_HARD_DOCTOR_LOCK/.loomy/memory"
touch "$HIST_HARD_DOCTOR_LOCK/.loomy/logs/events.jsonl" "$HIST_HARD_DOCTOR_LOCK/.loomy/memory/STATE.md"
run "history block: doctor lock fixture staged" git -C "$HIST_HARD_DOCTOR_LOCK" add -f -- .loomy/logs/events.jsonl .loomy/memory/STATE.md
run "history block: doctor lock fixture committed" git -C "$HIST_HARD_DOCTOR_LOCK" commit -qm "track history for doctor lock"
touch "$HIST_HARD_DOCTOR_LOCK/.git/index.lock"
"$LOOMY" doctor --fix --root "$HIST_HARD_DOCTOR_LOCK" >"$OUT" 2>&1 || true
has "history block: doctor --fix reports history still tracked" 'still tracked by Git'
hasnt "history block: failed doctor fix omits success message" 'history files untracked'
rm -f "$HIST_HARD_DOCTOR_LOCK/.git/index.lock"

# CRLF is preserved for both original user rules and every line in the managed block.
HIST_HARD_CRLF="$WORK/history-crlf"; mkdir -p "$HIST_HARD_CRLF"
printf 'a\r\nb\r\n' >"$HIST_HARD_CRLF/.gitignore"
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"; printf "%s\n" "$LP_GI_CHANGED"' \
  _ "$REPO" "$HIST_HARD_CRLF" >"$OUT" 2>&1; then
  has "history block: first CRLF sync reports a change" '^1$'
else
  ko "history block: first CRLF sync failed"
fi
if bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/project.sh"; loomy_gitignore_sync "$2"; printf "%s\n" "$LP_GI_CHANGED"' \
  _ "$REPO" "$HIST_HARD_CRLF" >"$OUT" 2>&1; then
  has "history block: second CRLF sync is idempotent" '^0$'
else
  ko "history block: second CRLF sync failed"
fi
if [[ "$(tr -d '\r' <"$HIST_HARD_CRLF/.gitignore" | grep -Fxc "$HIST_HARD_BEGIN")" == 1 ]]; then
  ok "history block: CRLF BEGIN marker appears exactly once"
else
  ko "history block: CRLF BEGIN marker count is wrong"
fi
if awk 'substr($0, length($0), 1) != "\r" { exit 1 } END { if (NR < 2) exit 1 }' "$HIST_HARD_CRLF/.gitignore" \
  && [[ "$(tail -c 2 "$HIST_HARD_CRLF/.gitignore" | od -An -tx1 | tr -d ' \n')" == "0d0a" ]]; then
  ok "history block: CRLF lines keep CRLF endings through EOF"
else
  ko "history block: managed block does not keep CRLF endings"
fi
if awk 'NR == 1 && $0 != "a\r" { exit 1 } NR == 2 && $0 != "b\r" { exit 1 } END { if (NR < 2) exit 1 }' \
  "$HIST_HARD_CRLF/.gitignore"; then
  ok "history block: original CRLF user lines are unchanged"
else
  ko "history block: original CRLF user lines changed"
fi

# ------------------------------------------------------------------ session continuity
section "Continuity (context, hooks, sessions, home)"
PC2="$WORK/continuite"
run "init for continuity" "$LOOMY" init "$PC2" --yes --no-clipboard
file_has "Claude Code hooks installed" "$PC2/.claude/settings.json" 'loomy-context.sh\\" --hook start'
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PC2/.claude/settings.json" && ok "settings.json valide" || ko "settings.json invalide"
  PM="$WORK/fusion"; mkdir -p "$PM/.claude" && echo '{"permissions":{"allow":["Bash(ls:*)"]}}' >"$PM/.claude/settings.json"
  "$LOOMY" init "$PM" --yes --no-clipboard >/dev/null 2>&1
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['permissions']['allow']==['Bash(ls:*)'] and d['hooks']['SessionStart']" "$PM/.claude/settings.json" \
    && ok "existing settings.json: hooks added, settings kept" || ko "existing settings.json badly merged"
fi
file_has "Codex hooks installed" "$PC2/.codex/hooks.json" 'loomy-context.sh.*--hook start --tool codex'
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$PC2/.codex/hooks.json" && ok ".codex/hooks.json valide" || ko ".codex/hooks.json invalide"
  CX_CMD="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['hooks']['SessionStart'][0]['hooks'][0]['command'])" "$PC2/.codex/hooks.json")"
  mkdir -p "$PC2/src/deep"
  (cd "$PC2/src/deep" && echo '{"session_id":"cx-test","source":"startup"}' | eval "$CX_CMD") >"$OUT" 2>&1
  has "Codex hook from a subfolder: context returned" "Resume context"
  file_has "Codex hook: session recorded with the codex tool" "$PC2/.loomy/logs/events.jsonl" '"tool":"codex","session":"cx-test"'
  echo '{"session_id":"cx-test"}' | (cd "$PC2" && bash .loomy/scripts/loomy-context.sh --hook end --tool codex) >/dev/null 2>&1
fi
bash "$PC2/.loomy/scripts/loomy-context.sh" >"$OUT" 2>&1
has "context: project and phase" "Resume context for project"
has "context: resume instruction" "Resume START.md from this phase"
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status: no session → open the session" "open the lead agent session"
echo '{"session_id":"s-test","source":"startup"}' | bash "$PC2/.loomy/scripts/loomy-context.sh" --hook start >"$OUT" 2>&1
has "start hook: context returned to Claude" "Resume context"
file_has "start hook: session recorded" "$PC2/.loomy/logs/events.jsonl" '"type":"session","event":"start"'
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status: session open" "Lead agent session open since"
echo '{"session_id":"s-test"}' | bash "$PC2/.loomy/scripts/loomy-context.sh" --hook end >/dev/null 2>&1
"$LOOMY" status --root "$PC2" >"$OUT" 2>&1
has "status: session closed" "closed at"
has "status: resume instruction" "reopen the lead agent session"
(cd "$PC2" && "$LOOMY") >"$OUT" 2>&1
has "loomy alone outside a terminal: help" "◇  TRACKING"

# ------------------------------------------------------------------ repository name
section "Repository name consistent with the project"
file_has "brief: technical name" "$PC2/.loomy/brief.md" "^slug: continuite$"
file_has "brief: --yes creates no GitHub repository" "$PC2/.loomy/brief.md" "^github_repo: no$"
[[ -z "$(git -C "$PC2" remote)" ]] && ok "--yes: no remote added" || ko "--yes: remote added"
PR2="$WORK/nom-different"; mkdir -p "$PR2" && git -C "$PR2" init -q && git -C "$PR2" remote add origin "https://github.com/testeur/autre-nom.git"
run "init with a differently named remote repository" "$LOOMY" init "$PR2" --yes --no-clipboard
file_has "name mismatch flagged in the brief" "$PR2/.loomy/brief.md" "remote repository 'autre-nom', project name 'nom-different'"
file_has "brief: existing repository name" "$PR2/.loomy/brief.md" "^repo_name: autre-nom$"
PV2="$WORK/prive-gh"
run "project for a private repository created by gh" "$LOOMY" init "$PV2" --yes --no-clipboard
run "privacy private without --remote (simulated GitHub)" "$LOOMY" privacy --root "$PV2" private
[[ -d "$GH_STUB_REMOTES/testeur/prive-gh-ai.git" ]] && ok "private repository named after the project (prive-gh-ai)" || ko "private repository missing or misnamed ($(ls "$GH_STUB_REMOTES/testeur" 2>/dev/null | tr '\n' ' '))"
git --git-dir="$GH_STUB_REMOTES/testeur/prive-gh-ai.git" ls-tree -r --name-only main 2>/dev/null | grep -q '^.loomy/brief.md$' && ok "private repository: AI files pushed" || ko "private repository empty"
file_has "brief: private repository name" "$PV2/.loomy/brief.md" "^ai_repo_name: prive-gh-ai$"

# ------------------------------------------------------------------ questionnaire interactif
section "loomy init (interactive, real terminal via expect)"
if command -v expect >/dev/null 2>&1; then
  # Confirms each question with its default value (Enter), in a pseudo-terminal.
  wizard_expect() {
    cat >"$WORK/wizard.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/loomy-init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
    WIZ_DIR="$1" expect "$WORK/wizard.exp"
  }
  W1="$WORK/interactif1"; mkdir -p "$W1"
  run "full questionnaire, plans not set" wizard_expect "$W1"
  has "11 steps when plans must be asked" "question 11/11"
  has "Claude plan question" "your Claude plan"
  file_has "plans saved" "$XDG_CONFIG_HOME/loomy/config" "^plan_codex=api$"
  file_has "brief written" "$W1/.loomy/brief.md" "^ai_mode: "
  [[ "$(git -C "$W1" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/interactif1.git" && -d "$GH_STUB_REMOTES/testeur/interactif1.git" ]] && ok "GitHub repository created with the project name" || ko "unexpected remote: $(git -C "$W1" config --get remote.origin.url 2>&1)"
  file_has "brief: private GitHub repository" "$W1/.loomy/brief.md" "^github_repo: private$"
  W2="$WORK/interactif2"; mkdir -p "$W2"
  run "full questionnaire, plans already known" wizard_expect "$W2"
  has "10 steps" "question 10/10"
  hasnt "questionnaire: no raw variable on screen" '\$save_desc|\$\(t '
  hasnt "plans not asked again" "your Claude plan|/11"
  # GitHub repository name already taken: never overwritten; another name (default) or the existing repository linked.
  mkdir -p "$GH_STUB_REMOTES/testeur" && git init --bare -q -b main "$GH_STUB_REMOTES/testeur/deja-pris.git"
  git clone -q "$GH_STUB_REMOTES/testeur/deja-pris.git" "$WORK/i3-seed" 2>/dev/null && git -C "$WORK/i3-seed" add -A 2>/dev/null; echo "# Initial specs" >"$WORK/i3-seed/SPECS.md"; git -C "$WORK/i3-seed" add SPECS.md && git -C "$WORK/i3-seed" -c user.name=t -c user.email=t@t commit -q -m seed && git -C "$WORK/i3-seed" push -q origin HEAD:main 2>/dev/null
  W5="$WORK/deja-pris"; mkdir -p "$W5"
  run "questionnaire, repository name already taken" wizard_expect "$W5"
  has "existing repository detected" "already exists"
  [[ "$(git -C "$W5" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/deja-pris-loomy.git" ]] && ok "taken name: another name suggested and created" || ko "taken name: remote $(git -C "$W5" config --get remote.origin.url 2>&1)"
  [[ "$(git --git-dir="$GH_STUB_REMOTES/testeur/deja-pris.git" rev-list --count main)" == "1" ]] && ok "existing repository left untouched" || ko "existing repository changed"
  cat >"$WORK/lier.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/loomy-init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {already exists \\(} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  W6="$WORK/deja-relie"; mkdir -p "$W6"; mv "$GH_STUB_REMOTES/testeur/deja-pris.git" "$GH_STUB_REMOTES/testeur/deja-relie.git"
  run "questionnaire, existing repository linked" env WIZ_DIR="$W6" expect "$WORK/lier.exp"
  [[ "$(git -C "$W6" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/deja-relie.git" ]] && ok "existing repository linked as origin" || ko "link: remote $(git -C "$W6" config --get remote.origin.url 2>&1)"
  file_has "brief: existing repository" "$W6/.loomy/brief.md" "^github_repo: existing$"
  [[ -f "$W6/SPECS.md" ]] && ok "existing repository content brought into the folder" || ko "existing content missing"
  [[ "$(git -C "$W6" symbolic-ref --short HEAD)" == "loomy/setup" ]] && ok "setup on the loomy/setup branch" || ko "branch: $(git -C "$W6" symbolic-ref --short HEAD)"
  file_has "agent told to read the existing content" "$W6/.loomy/brief.md" "already had content"
  file_has "agent told to reconcile through the branch" "$W6/.loomy/brief.md" "loomy/setup"
  [[ "$(git --git-dir="$GH_STUB_REMOTES/testeur/deja-relie.git" rev-list --count main)" == "1" ]] && ok "linked repository left untouched" || ko "linked repository changed"
  # Tab: the suggestion becomes editable text (here the repository name, completed rather than retyped).
  cat >"$WORK/tab.exp" <<EXP
set timeout 15
set tabbed 0
spawn bash "$REPO/scripts/loomy-init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 60} {incr i} {
  expect {
    -re {GitHub repository name \\(} { if {\$tabbed} { exp_continue } ; set tabbed 1 ; expect "edit the suggestion" ; send "\t" ; after 200 ; send -- "-edit\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  W7="$WORK/tabulation"; mkdir -p "$W7"
  run "questionnaire, Tab edits the suggestion" env WIZ_DIR="$W7" expect "$WORK/tab.exp"
  [[ "$(git -C "$W7" config --get remote.origin.url 2>/dev/null)" == "https://github.com/testeur/tabulation-edit.git" ]] && ok "Tab: suggested name completed, not retyped" || ko "Tab: remote $(git -C "$W7" config --get remote.origin.url 2>&1)"
  # ← goes back to the previous question, which keeps the answer already given.
  cat >"$WORK/retour.exp" <<EXP
set timeout 15
spawn bash "$REPO/scripts/loomy-init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
expect "question 1/" ; expect "⏎ confirm" ; send "Projet Retour\r"
expect "question 2/" ; expect "⏎ confirm" ; send "\033\[D"
expect "question 1/" ; expect "Projet Retour" ; exit 0
EXP
  W3="$WORK/interactif3"; mkdir -p "$W3"
  run "← goes back to the previous question with its answer" env WIZ_DIR="$W3" expect "$WORK/retour.exp"
  # Two repositories: public project + AI files in a private repository, names confirmed together.
  cat >"$WORK/deux-depots.exp" <<EXP
set timeout 20
spawn bash "$REPO/scripts/loomy-init-wizard.sh" "\$env(WIZ_DIR)" --no-clipboard
for {set i 0} {\$i < 80} {incr i} {
  expect {
    -re {Create a GitHub repository for this project} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {Where to keep the AI files} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\033\[B" ; after 200 ; send "\r" }
    -re {Create these two repositories} { expect "⏎ confirm" ; send "\r" }
    -re {Open the lead agent session} { expect "⏎ confirm" ; send "\033\[B" ; after 200 ; send "\r" }
    -re {⏎ confirm} { send "\r" }
    eof { exit [lindex [wait] 3] }
    timeout { exit 3 }
  }
}
exit 4
EXP
  W4="$WORK/deux-depots"; mkdir -p "$W4"
  run "questionnaire: two repositories confirmed" env WIZ_DIR="$W4" expect "$WORK/deux-depots.exp"
  has "confirmation of both names asked" "Create these two repositories"
  hasnt "questionnaire: no raw code on screen" '\$\(t |\$save_desc|\$[A-Z_]+\b'
  [[ -d "$GH_STUB_REMOTES/testeur/deux-depots.git" && -d "$GH_STUB_REMOTES/testeur/deux-depots-ai.git" ]] && ok "two repositories created: deux-depots (public) and deux-depots-ai (private)" || ko "repositories missing ($(ls "$GH_STUB_REMOTES/testeur" | tr '\n' ' '))"
  file_has "brief: public repository" "$W4/.loomy/brief.md" "^github_repo: public$"
  file_has "brief: AI files in the private repository" "$W4/.loomy/brief.md" "^ai_files: private$"
  rm -f "$XDG_CONFIG_HOME/loomy/config"
else
  printf '  \033[2m○ expect missing: interactive questionnaire not tested\033[0m\n'
fi

# ------------------------------------------------------------------ status and log
section "loomy status (log in every state)"
cd "$PROJ" || exit 1
git rev-parse --git-dir >/dev/null 2>&1 || git init -q .
git add -A && git commit -qm init
J="$PROJ/.loomy/logs/events.jsonl"
run "status: log with phases only" "$LOOMY" status
has "status: Git section reached" "branch main"
has "status: no finished delegation" "no finished delegation"
run "status: empty log" sh -c ": > '$J' && '$LOOMY' status"
run "status: no log" sh -c "rm -f '$J' && '$LOOMY' status"
run "status: corrupted line tolerated" sh -c "printf '{pas du json\n' > '$J' && '$LOOMY' status"
rm -f "$J"

# Real delegations through the bridges and the doubles.
section "Bridges (claude and codex doubles)"
run "delegate claude explorer" "$LOOMY" delegate claude explorer "Where is VAT validated?"
has "claude result passed on" "answer from the claude double"
run "delegate codex reviewer" "$LOOMY" delegate codex reviewer "Relis le dernier commit"
has "codex result passed on" "answer from the codex double"
run "delegate codex executor (writes)" env STUB_WRITE=1 "$LOOMY" delegate codex executor "Add a file"
has "modified files flagged" "changed|fichier_doublure"
fails "unsupported claude role" 2 "$LOOMY" delegate claude executor "x"
fails "tâche manquante" 2 "$LOOMY" delegate codex reviewer
run "CLI failure logged" sh -c "STUB_FAIL=1 '$LOOMY' delegate codex reviewer 'x' || true"
starts="$(grep -c '"type":"delegation_start"' "$J")"; ends="$(grep -c '"type":"delegation",' "$J")"
if [[ "$starts" == "4" && "$ends" == "4" ]]; then ok "log: 4 starts, 4 ends"; else ko "log: $starts starts, $ends ends (4 expected)"; fi
if awk -F'"id":"' '/"type":"delegation_start"/ { split($2, a, "\""); s[a[1]]++ } /"type":"delegation",/ { split($2, a, "\""); e[a[1]]++ } END { for (i in s) if (!(i in e)) exit 1; for (i in e) if (!(i in s)) exit 1 }' "$J"
then ok "log: each start has its end (same id)"; else ko "log: mismatched ids"; fi
file_has "log: cost reported by claude" "$J" '"bridge":"claude".*"cost_usd":0.0123'
file_has "log: estimated cost for codex" "$J" '"bridge":"codex".*"cost_source":"estimate"'
file_has "log: failure recorded" "$J" '"status":"error"'
if while IFS= read -r l; do printf '%s' "$l" | grep -qE '^\{"ts":"[0-9T:-]+Z",.*\}$' || exit 1; done <"$J"; then ok "log: one JSON line per event"; else ko "log: malformed line"; fi
run "LOOMY_JOURNAL_TASKS=0 hides the task" env LOOMY_JOURNAL_TASKS=0 "$LOOMY" delegate claude explorer "SECRET-TACHE"
if grep -q "SECRET-TACHE" "$J"; then ko "task text logged despite LOOMY_JOURNAL_TASKS=0"; else ok "task text absent from the log"; fi
run "delegate codex with a French locale" env LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 "$LOOMY" delegate codex explorer "locale"
if tail -1 "$J" | grep -qE '"cost_usd":[0-9]+\.[0-9]+,'; then ok "log: cost written with a decimal point"; else ko "log: malformed cost ($(tail -1 "$J" | grep -oE '"cost_usd":[^"]*'))"; fi
n_before="$(wc -l <"$J")"
run "LOOMY_JOURNAL=0 turns the log off" env LOOMY_JOURNAL=0 "$LOOMY" delegate claude explorer "x"
[[ "$(wc -l <"$J")" == "$n_before" ]] && ok "nothing written with LOOMY_JOURNAL=0" || ko "log written despite LOOMY_JOURNAL=0"

delegation_options_tests
interrupted_delegation_tests

section "Live tracking"
run "status with delegations from both families" "$LOOMY" status
has "status: delegation total" "Delegations +[0-9]+"
has "status: failures flagged" "failed"
has "status: latest delegations" "Latest delegations"
# Running delegation: the double sleeps, the status must show it, then forget it once finished.
STUB_SLEEP=3 "$LOOMY" delegate claude architect "Tâche longue" >/dev/null 2>&1 &
bg=$!
sleep 1
run "status during a delegation" "$LOOMY" status
has "running delegation shown" "running .*architect"
wait "$bg"
run "status after the delegation" "$LOOMY" status
hasnt "nothing running anymore" "running .*architect"
# Interrupted delegation (dead process, no end event): ignored.
printf '{"ts":"2026-01-01T00:00:00Z","type":"delegation_start","id":"dmort","pid":999999,"bridge":"codex","role":"developer","model":"x","task":"interrompue"}\n' >>"$J"
run "status with an interrupted delegation" "$LOOMY" status
hasnt "interrupted delegation ignored" "interrompue"
run "status with a French locale" env LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 "$LOOMY" status
has "costs read with the decimal point" 'Delegations +[0-9]+ · \$0\.[0-9]*[1-9]'
hasnt "no awk or printf error" "division by zero|invalid number|nombre non valable"
run "status --watch starts and stops" sh -c "'$LOOMY' watch 1 >/dev/null 2>&1 & p=\$!; sleep 2; kill \$p; wait \$p; true"
run "loomy log -n 3" "$LOOMY" log -n 3
if [[ "$(wc -l <"$OUT" | tr -d ' ')" == "3" ]]; then ok "log: 3 lines"; else ko "log: $(wc -l <"$OUT") lines"; fi

section "Phases"
run "status set build" "$LOOMY" status set build
file_has "state: build phase" "$PROJ/.loomy/state" "^phase=build$"
if [[ "$(grep -c '^log=' "$PROJ/.loomy/state")" -ge 2 ]]; then ok "state: history kept"; else ko "state: history lost"; fi
fails "unknown phase refused" 2 "$LOOMY" status set nimporte
file_has "log: phase event" "$J" '"type":"phase","phase":"build"'

# ------------------------------------------------------------------ diagnostic
section "loomy doctor"
run "doctor with claude and codex" "$LOOMY" doctor
has "doctor: claude detected" "claude 2\.[0-9]"
has "doctor: codex detected" "codex 0\.[0-9]"
hasnt "doctor: no install command when everything is detected" "install.sh"
run "doctor --live (sondes)" "$LOOMY" doctor --live
fails "doctor without any AI CLI: minimum not met" 1 env LOOMY_CODEX_BIN=/inexistant PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$REPO/scripts/loomy-doctor.sh" --root "$PROJ"
has "doctor: explicit summary" "Minimum not met"
has "doctor: Claude Code install command" "curl -fsSL https://claude.ai/install.sh"
has "doctor: Codex install command" "curl -fsSL https://chatgpt.com/codex/install.sh"
run "doctor with a broken claude CLI" env STUB_BROKEN_VERSION=1 "$LOOMY" doctor

# ------------------------------------------------------------------ worktrees
section "Parallel worktrees"
git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "travail" || true
run "worktrees" "$LOOMY" worktrees demo
if [[ "$(git -C "$PROJ" worktree list | wc -l | tr -d ' ')" == "3" ]]; then ok "two worktrees created"; else ko "worktrees: $(git -C "$PROJ" worktree list | wc -l) entries"; fi
run "worktrees --help created nothing" "$LOOMY" worktrees --help
fails "task name starting with a hyphen refused" 2 "$LOOMY" worktrees -x
if [[ "$(git -C "$PROJ" worktree list | wc -l | tr -d ' ')" == "3" ]]; then ok "still only two worktrees"; else ko "worktrees created by mistake"; fi

# ------------------------------------------------------------------ existing project
section "Adopting an existing project (0.5)"
EX="$WORK/existing-app"; mkdir -p "$EX/src/auth" "$EX/tests" "$EX/.github/workflows"
cat >"$EX/package.json" <<'JSON'
{
  "name": "existing-app",
  "scripts": {
    "test": "vitest run",
    "lint": "eslint .",
    "build": "vite build"
  },
  "dependencies": {
    "react": "^19.0.0"
  },
  "devDependencies": {
    "vitest": "^3.0.0",
    "typescript": "^5.6.0"
  }
}
JSON
printf 'export function login() {\n  // TODO: rate limiting\n}\n' >"$EX/src/auth/login.ts"
printf 'export const app = 1;\n' >"$EX/src/app.tsx"
printf 'test("app", () => {});\n' >"$EX/tests/app.test.ts"
printf 'name: ci\non: push\njobs: {}\n' >"$EX/.github/workflows/ci.yml"
printf '# Existing app\n' >"$EX/README.md"
printf 'API_KEY=not-a-real-key\n' >"$EX/.env"
git -C "$EX" init -q -b main
git -C "$EX" add -A && GIT_AUTHOR_NAME=Alice GIT_AUTHOR_EMAIL=alice@example.com git -C "$EX" commit -qm "feat: first version"
printf 'export const more = 2;\n' >>"$EX/src/app.tsx"
git -C "$EX" add -A && GIT_AUTHOR_NAME=Bob GIT_AUTHOR_EMAIL=bob@example.com git -C "$EX" commit -qm "fix: more"
MAIN_BEFORE="$(git -C "$EX" rev-parse main)"
printf 'local work in progress\n' >>"$EX/README.md"
run "init on an existing project" "$LOOMY" init "$EX" --yes --no-clipboard
[[ "$(git -C "$EX" symbolic-ref --short HEAD)" == "loomy/adopt" ]] && ok "adoption: dedicated branch loomy/adopt" || ko "adoption: branch $(git -C "$EX" symbolic-ref --short HEAD)"
[[ "$(git -C "$EX" rev-parse main)" == "$MAIN_BEFORE" ]] && ok "adoption: main untouched" || ko "adoption: main moved"
git -C "$EX" diff --quiet -- README.md && ko "adoption: uncommitted work lost" || ok "adoption: uncommitted work kept"
file_has "brief: existing project" "$EX/.loomy/brief.md" "^repo: existing$"
file_has "brief: adoption branch" "$EX/.loomy/brief.md" "^adopt_branch: loomy/adopt$"
file_has "brief: base branch" "$EX/.loomy/brief.md" "^base_branch: main$"
file_has "brief: stay on the adoption branch" "$EX/.loomy/brief.md" "Work only on the \`loomy/adopt\` branch"
file_has "START.md: adoption section" "$EX/START.md" "Existing project \(adoption\)"
A="$EX/.loomy/assessment.md"
file_has "assessment: languages" "$A" "Languages: TypeScript"
file_has "assessment: frameworks" "$A" "Detected: .*react.*vitest"
file_has "assessment: test command" "$A" '`npm run test`'
file_has "assessment: lint and build commands" "$A" '`npm run build`'
file_has "assessment: CI" "$A" '\.github/workflows'
file_has "assessment: authors" "$A" "Authors: 2"
file_has "assessment: sensitive area" "$A" "src/auth/login.ts"
file_has "assessment: committed secret flagged" "$A" '`\.env`'
file_has "assessment: TODO markers" "$A" "TODO / FIXME / HACK markers: 1"
file_has "assessment: uncommitted work flagged" "$A" "uncommitted change"
file_has "assessment: high risk with a secret" "$A" "estimated risk: HIGH"
hasnt "assessment: Loomy's own files ignored" "START\.md \("
EXCI="$WORK/assessment-ci"; mkdir -p "$EXCI/tests" "$EXCI/test" "$EXCI/.github/workflows"
printf '#!/usr/bin/env bash\n' >"$EXCI/tests/run.sh"
printf '#!/usr/bin/env bash\n' >"$EXCI/test/test.sh"
cat >"$EXCI/.github/workflows/ci.yml" <<'YAML'
name: ci
jobs:
  tests:
    steps:
      - run: sudo apt-get install -y -qq expect shellcheck
      - run: bash tests/run.sh
      - run: |
          echo build
      - run: echo ${{ secrets.X }}
      - run: make test `whoami`
YAML
run "loomy assess single-line CI fixture" "$LOOMY" assess --root "$EXCI" --print
has "assessment: CI test command marked" '`bash tests/run\.sh` \(CI\)'
has "assessment: plain test script found" '`bash test/test\.sh`'
hasnt "assessment: multiline CI command skipped" '`echo build` \(CI\)'
hasnt "assessment: CI secrets skipped" 'secrets\.X'
hasnt "assessment: CI package installs skipped" 'apt-get'
hasnt "assessment: CI command with backticks skipped" 'whoami'
run "loomy assess --print" "$LOOMY" assess --root "$EX" --print
has "assess: report printed" "Assessment of the existing project"
run "loomy assess in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr "$LOOMY" assess --root "$EX" --print
has "assess: French headings" "État des lieux du projet existant"
EX2="$WORK/existing-nobranch"; mkdir -p "$EX2" && printf 'print(1)\n' >"$EX2/main.py" && git -C "$EX2" init -q -b main && git -C "$EX2" add -A && git -C "$EX2" commit -qm init
run "init --no-branch" "$LOOMY" init "$EX2" --yes --no-clipboard --no-branch
[[ "$(git -C "$EX2" symbolic-ref --short HEAD)" == "main" ]] && ok "--no-branch: stays on main" || ko "--no-branch: switched"
EX3="$WORK/existing-nogit"; mkdir -p "$EX3" && printf 'fn main() {}\n' >"$EX3/main.rs" && printf '[package]\nname = "x"\n[dependencies]\nserde = "1"\n' >"$EX3/Cargo.toml"
run "init on an existing project without Git" "$LOOMY" init "$EX3" --yes --no-clipboard
file_has "assessment without Git: Rust" "$EX3/.loomy/assessment.md" "Languages: Rust"
file_has "assessment without Git: cargo test" "$EX3/.loomy/assessment.md" '`cargo test`'
file_has "assessment without Git: no history" "$EX3/.loomy/assessment.md" "No Git history"
[[ ! -f "$PROJ/.loomy/assessment.md" ]] && ok "new project: no assessment" || ko "new project assessed"

section "Subscriptions, quotas and stats"
QD="$WORK/quota"; QC="$WORK/quota-cfg"; QX="$WORK/quota-codex"
mkdir -p "$QD/.loomy/logs" "$QC/loomy" "$QX/sessions/2026/09/28"
printf -- '---\nname: "Quota"\nai_mode: ORCHESTRATED\nai_lead: claude\nbudget: equilibre\n---\n' >"$QD/.loomy/brief.md"; printf 'phase=build\n' >"$QD/.loomy/state"
DQ="$(date -u +%Y-%m-%d)"; NQ="$(date +%s)"
cat >"$QD/.loomy/logs/events.jsonl" <<EOF
{"ts":"${DQ}T08:05:00Z","type":"delegation","id":"q1","bridge":"codex","role":"executor","family":"codex","model":"gpt-6-luna","status":"ok","duration_s":95,"tokens_in":120000,"tokens_cached":80000,"tokens_out":9000,"cost_usd":0.0215,"task":"Add tests"}
{"ts":"${DQ}T08:20:00Z","type":"delegation","id":"q2","bridge":"claude","role":"architect","family":"claude","model":"claude-opus-5-5","status":"ok","duration_s":140,"tokens_in":45000,"tokens_cached":30000,"tokens_out":6000,"cost_usd":0.31,"task":"Review design"}
{"ts":"${DQ}T08:40:00Z","type":"delegation","id":"q3","bridge":"codex","role":"reviewer","family":"codex","model":"gpt-6-sol","status":"error","duration_s":30,"tokens_in":10000,"tokens_cached":0,"tokens_out":500,"cost_usd":0.025,"task":"Review diff"}
{"ts":"${DQ}T09:00:00Z","type":"usage","tool":"claude","family":"claude","scope":"lead","agent":"","model":"claude-opus-5-5","messages":12,"tokens_in":300000,"tokens_cached":900000,"tokens_out":40000,"cost_usd":2.18}
EOF
printf '{"type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":10080,"resets_at":%s},"secondary":{"used_percent":99.0,"window_minutes":300,"resets_at":%s},"plan_type":"team","rate_limit_reached_type":null}}}\n' $(( NQ + 200000 )) $(( NQ - 60 )) >"$QX/sessions/2026/09/28/r.jsonl"
qenv() { env XDG_CONFIG_HOME="$QC" CODEX_HOME="$QX" "$@"; }
got="$(qenv bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/usage.sh"; ai_quota codex' _ "$REPO")"
[[ "$got" == "10080 12 $(( NQ + 200000 ))" ]] && ok "codex quota read from its session log (expired window ignored)" || ko "codex quota: $got"
# Claude: the status line saves the documented rate_limits field.
run "init for the status line" "$LOOMY" init "$WORK/sl-proj" --yes --no-clipboard
SLC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["statusLine"]["command"])' "$WORK/sl-proj/.claude/settings.json" 2>/dev/null)"
[[ "$SLC" == *loomy-statusline.sh* ]] && ok "status line installed in .claude/settings.json" || ko "status line missing"
mkdir -p "$WORK/sl-proj/sub"
SLIN="{\"model\":{\"display_name\":\"Opus 5.5\"},\"rate_limits\":{\"five_hour\":{\"used_percentage\":42.4,\"resets_at\":$(( NQ + 3600 ))},\"seven_day\":{\"used_percentage\":86,\"resets_at\":$(( NQ + 300000 ))}}}"
(cd "$WORK/sl-proj/sub" && printf '%s' "$SLIN" | qenv sh -c "$SLC") >"$OUT" 2>&1
has "status line: Loomy line with the quota" "Loomy( [a-z]+)? · Opus 5\.5 · 5h 42% · 7d 86%"
file_has "status line: quota saved" "$QC/loomy/claude-limits" "^seven_day_pct=86$"
echo 'echo MY-OWN-LINE' >"$QC/loomy/statusline-user"
(cd "$WORK/sl-proj" && printf '%s' "$SLIN" | qenv sh -c "$SLC") >"$OUT" 2>&1
has "status line: the user's own status line is shown" "^MY-OWN-LINE( · Loomy .*)?$"
rm -f "$QC/loomy/statusline-user"
SLE="$WORK/sl-existing"; mkdir -p "$SLE/.claude"; printf '{"statusLine":{"type":"command","command":"echo mine"}}\n' >"$SLE/.claude/settings.json"
run "init keeps an existing status line" "$LOOMY" init "$SLE" --yes --no-clipboard
file_has "existing status line kept" "$SLE/.claude/settings.json" '"command": "echo mine"'
# Subscription: quota and tokens instead of dollars.
printf 'plan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
run "status with subscriptions" qenv "$LOOMY" status --root "$QD"
has "status: Claude quota" "Claude Pro · 5 h 42 %.*week 86 %"
has "status: Codex quota" "ChatGPT Business · week 12 %"
has "status: delegations in tokens" "Delegations +3 · 190.5k tokens"
hasnt "status: no dollar amount with subscriptions" '\$[0-9]'
run "log with subscriptions" qenv "$LOOMY" log --root "$QD"
has "log: tokens instead of cost" "129.0k tk"
run "stats" qenv "$LOOMY" stats --root "$QD"
has "stats: overview" "3 · 66 % succeeded · 1 failed"
has "stats: by role" "architect +1 +2 min 20 s"
has "stats: by model with cache share" "claude-opus-5-5 +1\+12r .* 72 %"
has "stats: API value covered by the plan" "API value ≈\\\$2.54, covered by your plan"
has "stats: month value next to the plan price" "this month: API value ≈\\\$2.49 for a \\\$20/month plan"
fails "stats: invalid --since refused" 2 "$LOOMY" stats --root "$QD" --since yesterday
run "stats --days" qenv "$LOOMY" stats --root "$QD" --days 7
# API: the real cost stays.
printf 'plan_claude=api\nplan_codex=api\n' >"$QC/loomy/config"
run "status with the API" qenv "$LOOMY" status --root "$QD"
has "status API: delegation cost" 'Delegations +3 · \$0.3565'
has "status API: monthly cost" "API · cost this month: \\\$2"
hasnt "status API: no quota" "week [0-9]+ %"
printf '{"type":"event_msg","payload":{"rate_limits":{"primary":null,"secondary":null,"rate_limit_reached_type":"workspace_member_credits_depleted"}}}\n' >>"$QX/sessions/2026/09/28/r.jsonl"; touch "$QX/sessions/2026/09/28/r.jsonl"
got="$(qenv bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/usage.sh"; ai_quota codex' _ "$REPO")"
[[ "$got" == "reached workspace_member_credits_depleted" ]] && ok "codex quota: limit reached reported" || ko "codex reached: $got"
# Failover: close to the end of a subscription quota, the role goes to the other tool.
printf 'plan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
FL="$WORK/failover.log"; : >"$FL"
(cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate codex executor "Add a test") >"$OUT" 2>&1
has "failover: announced" "Codex quota at limit reached .*executor handed to Claude"
has "failover: plain answer, as from Codex" "^answer from the claude double$"
grep -q $'^claude\t-p' "$FL" && ! grep -q '^codex' "$FL" && ok "failover: Codex role run by Claude" || ko "failover: calls $(cut -c1-60 "$FL" | tr '\n' ' ')"
grep -q 'acceptEdits' "$FL" && grep -q '"sandbox":{"enabled":true' "$FL" && ok "failover: writing role with accepted edits inside Claude's sandbox" || ko "failover: write mode missing"
grep -q -- '--model	claude-haiku-5-5' "$FL" && ok "failover: model routed for that role on the Claude side" || ko "failover: model $(grep -o -- '--model	[^	]*' "$FL")"
file_has "failover: logged" "$QD/.loomy/logs/events.jsonl" '"role":"executor","family":"claude".*"sandbox":"workspace-write".*"failover_from":"codex"'
run "status after a failover" qenv "$LOOMY" status --root "$QD"
has "status: Codex roles go to Claude" "Codex's roles go to Claude until it resets"
has "status: switched delegation marked" "⇄ Add a test"
run "stats after a failover" qenv "$LOOMY" stats --root "$QD"
has "stats: switched delegations counted" "1 delegation\(s\) moved to the other tool"
: >"$FL"; printf 'quota_switch=off\nplan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
(cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate codex executor "x") >"$OUT" 2>&1
grep -q '^codex' "$FL" && ok "quota_switch off: no failover" || ko "quota_switch off ignored"
# Claude nearly exhausted: a read-only role goes to Codex, unless Codex has no room left either.
printf 'plan_claude=pro\nplan_codex=business\n' >"$QC/loomy/config"
printf 'five_hour_pct=97\nfive_hour_reset=%s\n' $(( NQ + 3600 )) >"$QC/loomy/claude-limits"
: >"$FL"; (cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate claude reviewer "Review") >"$OUT" 2>&1
grep -q '^claude' "$FL" && ok "both quotas exhausted: no ping-pong, Claude keeps the role" || ko "failover with both exhausted"
printf '{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":20.0,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' $(( NQ + 200000 )) >>"$QX/sessions/2026/09/28/r.jsonl"
: >"$FL"; (cd "$QD" && qenv STUB_LOG="$FL" "$LOOMY" delegate claude reviewer "Review") >"$OUT" 2>&1
has "failover to Codex: announced" "Claude quota at 97 % .*reviewer handed to Codex"
grep -q '^codex' "$FL" && ! grep -q '^claude' "$FL" && grep -q 'read-only' "$FL" && ok "failover to Codex: read-only role stays read-only" || ko "failover to codex: $(cut -c1-80 "$FL")"
run "start with the lead tool nearly exhausted" qenv "$LOOMY" start --root "$QD" --print
has "start: lead agent session on the other tool" "Claude Code quota at 97 %: this session runs on Codex"
has "start: Codex command for the lead agent" "codex -m gpt-6.1-sol"
rm -f "$QC/loomy/claude-limits"

fi

lead_relay_tests() {
QC="$WORK/quota-cfg"; QX="$WORK/quota-codex"
mkdir -p "$QC/loomy" "$QX/sessions/2026/09/28"
qenv() { env XDG_CONFIG_HOME="$QC" CODEX_HOME="$QX" "$@"; }
section "Lead relay (quota)"
LR="$WORK/lead-relay"; LR_BIN="$WORK/lead-relay-bin"; LR_LOG="$WORK/lead-relay.log"
mkdir -p "$LR/.loomy/logs" "$LR_BIN"
cat >"$LR/.loomy/brief.md" <<'BRIEF'
---
name: "Lead relay"
ai_mode: ORCHESTRATED
ai_lead: claude
budget: equilibre
---
BRIEF
printf 'phase=build\n' >"$LR/.loomy/state"
relay_codex_quota() {
  local pct="$1"
  printf '{"type":"event_msg","payload":{"rate_limits":{"primary":{"used_percent":%s.0,"window_minutes":10080,"resets_at":%s},"rate_limit_reached_type":null}}}\n' \
    "$pct" "$(( $(date +%s) + 200000 ))" >"$QX/sessions/2026/09/28/r.jsonl"
  rm -f "$QC/loomy/codex-limits"
}
relay_state_active() {
  printf 'master=claude\nacting=codex\nsince=%s\nreason=test relay\nresume_at=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >"$LR/.loomy/failover"
}
lead_relay_decide() {
  local dry="${1:-}" no_switch="${2:-}" requested="${3:-}"
  qenv env LOOMY_CODEX_BIN="$HERE/stubs/codex" LOOMY_NO_SWITCH="$no_switch" bash -c '
    source "$1/scripts/lib/models.sh"
    source "$1/scripts/lib/failover.sh"
    lf_decide "$2" claude "${3:-}" "${4:-}"
    [[ -n "$LF_NOTE" ]] && printf "LF_NOTE=%s\n" "$LF_NOTE"
    exit 0
  ' _ "$REPO" "$LR" "$dry" "$requested"
}
printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_codex_quota 20
rm -f "$QC/loomy/claude-limits" "$LR/.loomy/failover"
: >"$LR/.loomy/logs/events.jsonl"
got="$(lead_relay_decide)"
[[ "$got" == "claude normal" ]] && ok "lead relay: unsaturated master stays normal" || ko "lead relay: unsaturated decision was $got"
[[ ! -e "$LR/.loomy/failover" ]] && ok "lead relay: normal decision writes no state" || ko "lead relay: normal decision wrote state"

LR_RESET=$(( $(date +%s) + 3600 ))
printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$LR_RESET" >"$QC/loomy/claude-limits"
got="$(lead_relay_decide)"
[[ "$got" == "codex handover" ]] && ok "lead relay: 97% Claude hands lead to Codex" || ko "lead relay: handover decision was $got"
file_has "lead relay: state records Claude as master" "$LR/.loomy/failover" '^master=claude$'
file_has "lead relay: state records Codex as acting lead" "$LR/.loomy/failover" '^acting=codex$'
file_has "lead relay: state records Claude quota reason" "$LR/.loomy/failover" '^reason=5 h 97 %$'
file_has "lead relay: state records Claude reset time" "$LR/.loomy/failover" "^resume_at=$LR_RESET$"
file_has "lead relay: handover event is journaled" "$LR/.loomy/logs/events.jsonl" '"type":"lead_failover"'

got="$(lead_relay_decide "" "" codex)"
[[ "$got" == "codex continue" ]] && ok "lead relay: explicit acting lead keeps automatic relay" || ko "lead relay: explicit acting choice was $got"
file_has "lead relay: explicit acting choice marks state manual" "$LR/.loomy/failover" '^manual=1$'
[[ "$(grep -c '"type":"lead_failover"' "$LR/.loomy/logs/events.jsonl")" == 1 ]] \
  && ok "lead relay: explicit acting choice adds no failover event" || ko "lead relay: explicit choice duplicated failover event"
rm -f "$QC/loomy/claude-limits"
got="$(lead_relay_decide)"
[[ "$got" == "codex continue" && -f "$LR/.loomy/failover" ]] \
  && ok "lead relay: manualized Codex stays lead while Claude has room" || ko "lead relay: manualized decision was $got"
[[ "$(grep -c '"type":"lead_failover"' "$LR/.loomy/logs/events.jsonl")" == 1 ]] \
  && ok "lead relay: manualized continuation keeps one failover event" || ko "lead relay: continuation changed failover event count"
printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$LR_RESET" >"$QC/loomy/claude-limits"

rm -f "$LR/.loomy/failover"; : >"$LR/.loomy/logs/events.jsonl"
got="$(lead_relay_decide --dry)"
[[ "$got" == "codex handover" ]] && ok "lead relay: dry decision matches handover" || ko "lead relay: dry decision was $got"
[[ ! -e "$LR/.loomy/failover" ]] && ok "lead relay: dry handover writes no state" || ko "lead relay: dry handover wrote state"
[[ ! -s "$LR/.loomy/logs/events.jsonl" ]] && ok "lead relay: dry handover writes no event" || ko "lead relay: dry handover wrote an event"

rm -f "$LR/.loomy/failover"; : >"$LR/.loomy/logs/events.jsonl"
qenv env LOOMY_CODEX_BIN="$HERE/stubs/codex" bash -c '
  source "$1/scripts/lib/models.sh"
  source "$1/scripts/lib/failover.sh"
  lf_decide "$2" claude --dry >/dev/null
  lf_apply "$2"
  lf_apply "$2"
' _ "$REPO" "$LR"
[[ "$(grep -c '"type":"lead_failover"' "$LR/.loomy/logs/events.jsonl" 2>/dev/null || true)" == 1 ]] \
  && ok "lead relay: repeated apply journals one handover" || ko "lead relay: repeated apply journal count was $(grep -c '"type":"lead_failover"' "$LR/.loomy/logs/events.jsonl" 2>/dev/null || true)"
[[ -f "$LR/.loomy/failover" && "$(wc -l <"$LR/.loomy/failover" | tr -d ' ')" == 5 && ! -e "$LR/.loomy/failover.lock" ]] \
  && ok "lead relay: repeated apply keeps one state and releases the lock" || ko "lead relay: repeated apply state or lock is wrong"
got="$(lead_relay_decide)"
[[ "$got" == "codex continue" && -f "$LR/.loomy/failover" ]] \
  && ok "lead relay: active Codex relay continues while Claude is saturated" || ko "lead relay: active state decision was $got"

rm -f "$LR/.loomy/failover"; : >"$LR/.loomy/logs/events.jsonl"
mkdir "$LR/.loomy/failover.lock"
touch -t 200001010000 "$LR/.loomy/failover.lock"
qenv env LOOMY_CODEX_BIN="$HERE/stubs/codex" bash -c '
  source "$1/scripts/lib/models.sh"
  source "$1/scripts/lib/failover.sh"
  lf_decide "$2" claude --dry >/dev/null
  lf_apply "$2"
' _ "$REPO" "$LR"
[[ -f "$LR/.loomy/failover" && ! -e "$LR/.loomy/failover.lock" \
  && "$(grep -c '"type":"lead_failover"' "$LR/.loomy/logs/events.jsonl" 2>/dev/null || true)" == 1 ]] \
  && ok "lead relay: stale lock older than 30 seconds is broken" || ko "lead relay: stale lock was not recovered"

rm -f "$QC/loomy/claude-limits"
got="$(lead_relay_decide)"
[[ "$got" == "claude return" && ! -e "$LR/.loomy/failover" ]] \
  && ok "lead relay: missing Claude quota returns the lead and clears state" || ko "lead relay: quota return was $got"
file_has "lead relay: return event is journaled" "$LR/.loomy/logs/events.jsonl" '"type":"lead_return"'

printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$LR_RESET" >"$QC/loomy/claude-limits"
relay_state_active "$(( $(date +%s) - 1 ))"
: >"$LR/.loomy/logs/events.jsonl"
got="$(lead_relay_decide)"
[[ "$got" == "claude return" && ! -e "$LR/.loomy/failover" ]] \
  && ok "lead relay: expired resume time returns the lead" || ko "lead relay: expired resume decision was $got"

relay_codex_quota 90
printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
rm -f "$LR/.loomy/failover"
got="$(lead_relay_decide)"
[[ "$got" == *"claude normal"* && "$got" == *"LF_NOTE=no other tool with room left"* ]] \
  && ok "lead relay: no room on Codex leaves Claude in place" || ko "lead relay: no-room decision was $got"

printf 'plan_claude=pro\nplan_codex=api\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_codex_quota 20
rm -f "$LR/.loomy/failover"
got="$(lead_relay_decide)"
[[ "$got" == *"claude normal"* && "$got" == *"LF_NOTE=the other tool is on a pay-per-use plan"* ]] \
  && ok "lead relay: API destination keeps Claude with pay-per-use note" || ko "lead relay: API destination decision was $got"

printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$LR_RESET" >"$QC/loomy/claude-limits"
printf 'plan_claude=api\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
got="$(lead_relay_decide)"
[[ "$got" == "claude normal" ]] && ok "lead relay: Claude API plan is not relayed" || ko "lead relay: API plan decision was $got"

printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=off\n' >"$QC/loomy/config"
relay_state_active "$(( $(date +%s) + 3600 ))"
got="$(lead_relay_decide)"
[[ "$got" == "claude normal" && ! -e "$LR/.loomy/failover" ]] \
  && ok "lead relay: lead_failover off clears state and keeps Claude" || ko "lead relay: off decision was $got"
printf 'lead_failover=auto\n' >>"$QC/loomy/config"
relay_state_active "$(( $(date +%s) + 3600 ))"
got="$(lead_relay_decide "" 1)"
[[ "$got" == "claude normal" && ! -e "$LR/.loomy/failover" ]] \
  && ok "lead relay: LOOMY_NO_SWITCH clears state and keeps Claude" || ko "lead relay: no-switch decision was $got"

printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=95\nlead_failover=auto\n' >"$QC/loomy/config"
relay_codex_quota 90
got="$(lead_relay_decide)"
[[ "$got" == "codex handover" ]] && ok "lead relay: quota_room 95 admits Codex at 90%" || ko "lead relay: quota_room decision was $got"

relay_state_active "$(( $(date +%s) + 3600 ))"
lead_relay_env() {
  qenv env LOOMY_CODEX_BIN="$HERE/stubs/codex" AI_ROUTE_ENV="${1:-}" bash -c '
    source "$1/scripts/lib/models.sh"
    ai_detect_env "$2"
    printf "%s|%s|%s\n" "$AI_LEAD" "$AI_LEAD_MASTER" "$AI_ENV"
  ' _ "$REPO" "$LR"
}
got="$(lead_relay_env)"
[[ "$got" == "codex|claude|hybrid-codex" ]] && ok "lead relay: active relay sets acting lead and hybrid environment" || ko "lead relay: detected environment was $got"
got="$(lead_relay_env hybrid-claude)"
[[ "$got" == "codex|claude|hybrid-claude" ]] && ok "lead relay: AI_ROUTE_ENV override still wins" || ko "lead relay: route override was $got"

cat >"$LR_BIN/claude" <<'STUB'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  --version)
    [[ -n "${STUB_BROKEN_VERSION:-}" ]] && exit 1
    echo "2.1.300 (Claude Code)"; exit 0 ;;
esac
if [[ -n "${STUB_LOG:-}" ]]; then (IFS=$'\t'; printf 'claude\t%s\n' "$*") >>"$STUB_LOG"; fi
if [[ "${STUB_SATURATE:-1}" == "1" ]]; then
  mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/loomy"
  printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$(( $(date +%s) + 3600 ))" >"${XDG_CONFIG_HOME:-$HOME/.config}/loomy/claude-limits"
fi
exit 0
STUB
chmod +x "$LR_BIN/claude"

LR_APP_BIN="$WORK/lead-relay-app-bin"; LR_APP_OPEN_LOG="$WORK/lead-relay-app-open.log"
mkdir -p "$LR_APP_BIN"
cat >"$LR_APP_BIN/uname" <<'STUB'
#!/usr/bin/env bash
echo Darwin
STUB
cat >"$LR_APP_BIN/open" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "-Ra" ]] && exit 0
printf '%s\n' "$*" >>"$LR_APP_OPEN_LOG"
STUB
chmod +x "$LR_APP_BIN/uname" "$LR_APP_BIN/open"
printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_codex_quota 20
printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$LR_RESET" >"$QC/loomy/claude-limits"
rm -f "$LR/.loomy/failover"; : >"$LR/.loomy/logs/events.jsonl"; : >"$LR_APP_OPEN_LOG"
if qenv env PATH="$LR_BIN:$LR_APP_BIN:$HERE/stubs:/usr/bin:/bin" LR_APP_OPEN_LOG="$LR_APP_OPEN_LOG" \
  LOOMY_START_WATCH=0 LOOMY_CODEX_BIN="$HERE/stubs/codex" "$LOOMY" start --root "$LR" --app >"$OUT" 2>&1; then
  grep -q '^codex://' "$LR_APP_OPEN_LOG" 2>/dev/null && ok "start --app: opens the acting Codex app" || ko "start --app: app link $(cat "$LR_APP_OPEN_LOG" 2>/dev/null)"
  file_has "start --app: applies the lead relay state" "$LR/.loomy/failover" '^acting=codex$'
  file_has "start --app: journals the lead relay" "$LR/.loomy/logs/events.jsonl" '"type":"lead_failover"'
  has "start --app: explains the terminal-only chain" "automatic chain only runs in the terminal"
else ko "start --app: command failed"; fi

printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_codex_quota 20
rm -f "$QC/loomy/claude-limits" "$LR/.loomy/failover"
: >"$LR/.loomy/logs/events.jsonl"; : >"$LR_LOG"
if qenv env PATH="$LR_BIN:$HERE/stubs:/usr/bin:/bin" STUB_LOG="$LR_LOG" LOOMY_CODEX_BIN="$HERE/stubs/codex" \
  LOOMY_CHAIN_DELAY=0 LOOMY_START_WATCH=0 "$LOOMY" start --root "$LR" --new >"$OUT" 2>&1; then
  LR_ORDER="$(awk -F '\t' '$1 == "claude" && $2 !~ /^--version/ || $1 == "codex" && $2 !~ /^--version/ { printf "%s%s", sep, $1; sep = " " } END { print "" }' "$LR_LOG")"
  [[ "$LR_ORDER" == "claude codex" ]] && ok "start chain: Claude session hands off to Codex" || ko "start chain: session order was $LR_ORDER"
  grep -q 'You are temporarily the lead agent in place of Claude Code' "$LR_LOG" \
    && ok "start chain: Codex receives the temporary lead prompt" || ko "start chain: temporary lead prompt missing"
  has "start chain: takeover is announced" "takes over"
  file_has "start chain: Codex relay state remains active" "$LR/.loomy/failover" '^acting=codex$'
else ko "start chain: command failed"; fi

rm -f "$QC/loomy/claude-limits"; : >"$LR_LOG"
if qenv env PATH="$LR_BIN:$HERE/stubs:/usr/bin:/bin" STUB_LOG="$LR_LOG" STUB_SATURATE=0 LOOMY_CODEX_BIN="$HERE/stubs/codex" \
  LOOMY_CHAIN_DELAY=0 LOOMY_START_WATCH=0 "$LOOMY" start --root "$LR" --new >"$OUT" 2>&1; then
  grep -q 'You are the lead agent again' "$LR_LOG" \
    && ok "start chain: returning Claude receives the lead-again prompt" || ko "start chain: lead-again prompt missing"
  [[ ! -e "$LR/.loomy/failover" ]] && ok "start chain: return clears the relay state" || ko "start chain: return state remains"
else ko "start chain: return command failed"; fi

rm -f "$LR/.loomy/failover" "$QC/loomy/claude-limits"; : >"$LR_LOG"
if qenv env PATH="$LR_BIN:$HERE/stubs:/usr/bin:/bin" STUB_LOG="$LR_LOG" STUB_SATURATE=0 LOOMY_CODEX_BIN="$HERE/stubs/codex" \
  LOOMY_CHAIN_DELAY=0 LOOMY_START_WATCH=0 "$LOOMY" start --root "$LR" --new >"$OUT" 2>&1; then
  LR_COUNT="$(awk -F '\t' '$1 == "claude" && $2 !~ /^--version/ || $1 == "codex" && $2 !~ /^--version/ { n++ } END { print n + 0 }' "$LR_LOG")"
  [[ "$LR_COUNT" == "1" ]] && ok "start chain: no saturation starts one Claude session" || ko "start chain: no-saturation session count was $LR_COUNT"
  hasnt "start chain: no takeover without saturation" "takes over"
else ko "start chain: no-saturation command failed"; fi

# Alternate the two quotas: Claude saturates on every call; the Codex wrapper clears Claude's reading after each call,
# so each finished session triggers the opposite relay and exercises the six-session chain bound.
LR_BOUND_BIN="$WORK/lead-relay-bound-bin"; LR_BOUND_LOG="$WORK/lead-relay-bound.log"
mkdir -p "$LR_BOUND_BIN"; cp "$LR_BIN/claude" "$LR_BOUND_BIN/claude"
cat >"$LR_BOUND_BIN/codex" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then STUB_LOG= "${LOOMY_TEST_CODEX_STUB:?}" "$@"; exit $?; fi
if [[ -n "${STUB_LOG:-}" ]]; then (IFS=$'\t'; printf 'codex\t%s\n' "$*") >>"$STUB_LOG"; fi
rm -f "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/claude-limits"
STUB_LOG= "${LOOMY_TEST_CODEX_STUB:?}" "$@"
STUB
chmod +x "$LR_BOUND_BIN/codex"
relay_codex_quota 20
rm -f "$QC/loomy/claude-limits" "$LR/.loomy/failover"; : >"$LR_BOUND_LOG"
if qenv env PATH="$LR_BOUND_BIN:$HERE/stubs:/usr/bin:/bin" STUB_LOG="$LR_BOUND_LOG" \
  LOOMY_CODEX_BIN="$LR_BOUND_BIN/codex" LOOMY_TEST_CODEX_STUB="$HERE/stubs/codex" \
  LOOMY_CHAIN_DELAY=0 LOOMY_START_WATCH=0 "$LOOMY" start --root "$LR" --new >"$OUT" 2>&1; then
  LR_ORDER="$(awk -F '\t' '$1 == "claude" || ($1 == "codex" && $2 !~ /^--version/) { printf "%s%s", sep, $1; sep = " " } END { print "" }' "$LR_BOUND_LOG")"
  LR_COUNT="$(awk -F '\t' '$1 == "claude" || ($1 == "codex" && $2 !~ /^--version/) { n++ } END { print n + 0 }' "$LR_BOUND_LOG")"
  [[ "$LR_COUNT" -le 6 && "$LR_COUNT" == "6" && "$LR_ORDER" == "claude codex claude codex claude codex" ]] \
    && ok "start chain: alternating quota changes stop at six sessions" || ko "start chain: bound count=$LR_COUNT order=$LR_ORDER"
else ko "start chain: alternating quota command failed"; fi

LR_USER_CONFIG="$WORK/lead-relay-user-config"
fails "config rejects invalid lead_failover" 2 env XDG_CONFIG_HOME="$LR_USER_CONFIG" "$LOOMY" config set lead_failover maybe
has "config invalid lead_failover explains accepted values" '^lead_failover: auto or off$'
fails "config rejects quota_room below 1" 2 env XDG_CONFIG_HOME="$LR_USER_CONFIG" "$LOOMY" config set quota_room 0
has "config invalid quota_room explains range" '^quota_room: a percentage \(1 to 100\)$'
run "config accepts lead_failover auto" env XDG_CONFIG_HOME="$LR_USER_CONFIG" "$LOOMY" config set lead_failover auto
run "config accepts lead_failover off" env XDG_CONFIG_HOME="$LR_USER_CONFIG" "$LOOMY" config set lead_failover off
run "config accepts quota_room 1" env XDG_CONFIG_HOME="$LR_USER_CONFIG" "$LOOMY" config set quota_room 1
run "config accepts quota_room 100" env XDG_CONFIG_HOME="$LR_USER_CONFIG" "$LOOMY" config set quota_room 100

# BEGIN lead relay part B standalone coverage.
# Prompt-hook notices, session context, displays, handoff reader and inner-session banner.
relay_set_brief() {
  cat >"$LR/.loomy/brief.md" <<BRIEF
---
name: "Lead relay"
ai_mode: $2
ai_lead: $1
budget: equilibre
---
BRIEF
}
relay_active_claude() {
  printf 'master=codex\nacting=claude\nsince=%s\nreason=%s\nresume_at=%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "5 h 96 %" "$1" >"$LR/.loomy/failover"
}
relay_prompt_hook() {
  local no_switch="${1:-}"
  echo '{}' | qenv env LOOMY_LANG=en LOOMY_CODEX_BIN="$HERE/stubs/codex" LOOMY_NO_SWITCH="$no_switch" \
    bash "$REPO/scripts/loomy-context.sh" --hook prompt --root "$LR"
}
relay_record_return() {
  qenv env LOOMY_CODEX_BIN="$HERE/stubs/codex" bash -c '
    source "$1/scripts/lib/models.sh"
    source "$1/scripts/lib/failover.sh"
    lf_start "$2" codex claude "5 h 96 %" "$3"
    lf_end "$2"
  ' _ "$REPO" "$LR" "$1"
}

printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_set_brief claude ORCHESTRATED
relay_codex_quota 20
printf 'five_hour_pct=92\nfive_hour_reset=%s\n' "$(( $(date +%s) + 3600 ))" >"$QC/loomy/claude-limits"
rm -f "$LR/.loomy/failover" "$LR/.loomy/relay.notice"
relay_prompt_hook >"$OUT" 2>&1
has "prompt hook: emits UserPromptSubmit additionalContext JSON" '^\{"hookSpecificOutput":\{"hookEventName":"UserPromptSubmit","additionalContext":'
has "prompt hook: 92% notice includes HANDOFF instructions" '\[Loomy\] Claude Code quota at 92 %.*HANDOFF\.md'
has "prompt hook: near-quota notice keeps the ORCHESTRATED reminder" 'ORCHESTRATED mode: you are the orchestrator'
relay_prompt_hook >"$OUT" 2>&1
hasnt "prompt hook: immediate repeat is throttled" '\[Loomy\] Claude Code quota at'
printf 'prepare %s\n' "$(( $(date +%s) - 700 ))" >"$LR/.loomy/relay.notice"
relay_prompt_hook >"$OUT" 2>&1
has "prompt hook: notice returns after 10-minute throttle" '\[Loomy\] Claude Code quota at 92 %'

printf 'plan_claude=api\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=off\n' >"$QC/loomy/config"
printf 'five_hour_pct=80\nfive_hour_reset=%s\n' "$(( $(date +%s) + 3600 ))" >"$QC/loomy/claude-limits"
relay_codex_quota 90
rm -f "$LR/.loomy/failover"
relay_prompt_hook 1 >"$OUT" 2>&1
hasnt "prompt hook: silent with no-switch, failover off, API plan and full Codex quota" '\[Loomy\] Claude Code quota at'

printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_set_brief codex ORCHESTRATED
relay_codex_quota 20
relay_active_claude "$(( $(date +%s) - 1 ))"
rm -f "$LR/.loomy/relay.notice"
relay_prompt_hook >"$OUT" 2>&1
has "prompt hook: expired Codex reset announces lead return" '\[Loomy\] Codex has quota again and takes the lead back'
relay_codex_quota 96
relay_active_claude "$(( $(date +%s) + 3600 ))"
rm -f "$LR/.loomy/relay.notice"
relay_prompt_hook >"$OUT" 2>&1
hasnt "prompt hook: future Codex reset suppresses return notice at 96%" '\[Loomy\] Codex has quota again and takes the lead back'

relay_active_claude "$(( $(date +%s) + 3600 ))"
relay_prompt_hook >"$OUT" 2>&1
has "prompt hook: acting Claude lead retains ORCHESTRATED reminder" 'ORCHESTRATED mode: you are the orchestrator'
rm -f "$LR/.loomy/failover" "$QC/loomy/claude-limits"
relay_prompt_hook >"$OUT" 2>&1
hasnt "prompt hook: Codex lead without relay has no ORCHESTRATED reminder" 'ORCHESTRATED mode: you are the orchestrator'

printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_active_claude "$(( $(date +%s) + 3600 ))"
run "session start: active relay explains temporary Claude lead" qenv env LOOMY_NO_REPAIR=1 bash -c \
  'bash "$1/scripts/loomy-context.sh" --hook start --root "$2" </dev/null' _ "$REPO" "$LR"
has "session start: active relay names Claude in place of Codex" 'Temporary lead: Claude Code in place of Codex'
run "session start: lf_start and lf_end record return" relay_record_return "$(( $(date +%s) - 1 ))"
run "session start: Codex receives back-as-lead context" qenv env LOOMY_NO_REPAIR=1 bash -c \
  'bash "$1/scripts/loomy-context.sh" --hook start --root "$2" --tool codex </dev/null' _ "$REPO" "$LR"
has "session start: Codex sees back-as-lead line" 'Back as lead agent'
run "session start: Claude does not receive Codex back-as-lead context" qenv env LOOMY_NO_REPAIR=1 bash -c \
  'bash "$1/scripts/loomy-context.sh" --hook start --root "$2" --tool claude </dev/null' _ "$REPO" "$LR"
hasnt "session start: Claude omits Codex back-as-lead line" 'Back as lead agent'

relay_active_claude "$(( $(date +%s) + 3600 ))"
run "status: compact view shows active temporary lead" qenv env LOOMY_LANG=en bash "$REPO/scripts/loomy-status.sh" --root "$LR" --compact
has "status: Claude Code is shown in place of Codex" '⇄ Lead: Claude Code in place of Codex'
rm -f "$LR/.loomy/failover"
run "status: inactive relay has no lead line" qenv env LOOMY_LANG=en bash "$REPO/scripts/loomy-status.sh" --root "$LR" --compact
hasnt "status: no relay line without active failover" '⇄ Lead'
relay_active_claude "$(( $(date +%s) + 3600 ))"
run "status line: active relay renders acting Claude" qenv bash -c \
  'echo "{}" | env LOOMY_PROJECT_ROOT="$1" LOOMY_LANG=en bash "$2/scripts/loomy-statusline.sh"' _ "$LR" "$REPO"
has "status line: shows ⇄ claude during relay" '⇄ claude'

mkdir -p "$LR/.loomy/docs"
printf 'From: Claude\nTo: Codex\n' >"$LR/.loomy/docs/HANDOFF.md"
run "HANDOFF reader: English From/To keys render in full status" qenv env LOOMY_LANG=en bash "$REPO/scripts/loomy-status.sh" --root "$LR"
has "HANDOFF reader: English Claude → Codex" 'Claude → Codex'
printf 'De : Claude\nVers : Codex\n' >"$LR/.loomy/docs/HANDOFF.md"
run "HANDOFF reader: French De/Vers keys render in full status" qenv env LOOMY_LANG=en bash "$REPO/scripts/loomy-status.sh" --root "$LR"
has "HANDOFF reader: French Claude → Codex" 'Claude → Codex'

file_has "start: dedicated tmux agent command sets LOOMY_START_INNER=1" "$REPO/scripts/loomy-start.sh" \
  'agent=.*env LOOMY_START_INNER=1 bash.*loomy-start\.sh'
file_has "start: dedicated tmux session runs the inner agent command" "$REPO/scripts/loomy-start.sh" \
  'tmux new-session.*[$]agent; tmux kill-session'
run "start: inner print suppresses banner logo" qenv env LOOMY_START_INNER=1 COLUMNS=80 LINES=24 \
  LOOMY_CODEX_BIN="$HERE/stubs/codex" "$LOOMY" start --root "$LR" --print
hasnt "start: inner print has no banner logo line" '▀▄'
run "start: normal print renders banner logo" qenv env COLUMNS=80 LINES=24 \
  LOOMY_CODEX_BIN="$HERE/stubs/codex" "$LOOMY" start --root "$LR" --print
has "start: normal print includes banner logo line" '▀▄'
# END lead relay part B standalone coverage.

# Manual lead selection shares the quota relay state and leaves the brief untouched.
relay_set_brief claude ORCHESTRATED
printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_codex_quota 20
rm -f "$QC/loomy/claude-limits" "$LR/.loomy/failover"
: >"$LR/.loomy/logs/events.jsonl"; : >"$LR_LOG"
cp "$LR/.loomy/brief.md" "$WORK/manual-brief.before"
manual_start() {
  qenv env PATH="$LR_BIN:$HERE/stubs:/usr/bin:/bin" STUB_LOG="$LR_LOG" STUB_SATURATE=0 \
    LOOMY_CODEX_BIN="$HERE/stubs/codex" LOOMY_CHAIN_DELAY=0 LOOMY_START_WATCH=0 \
    "$LOOMY" start --root "$LR" "$@"
}
printf 'plan_claude=pro\nplan_codex=business\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
relay_codex_quota 20
printf 'five_hour_pct=97\nfive_hour_reset=%s\n' "$LR_RESET" >"$QC/loomy/claude-limits"
rm -f "$LR/.loomy/failover"; : >"$LR/.loomy/logs/events.jsonl"
got="$(lead_relay_decide)"
[[ "$got" == 'codex handover' ]] && ok "manual lead: fixture starts with automatic Codex relay" || ko "manual lead: automatic relay was $got"
run "manual lead: --lead codex pins the acting automatic relay" manual_start --lead codex --new
file_has "manual lead: pinned automatic relay is marked manual" "$LR/.loomy/failover" '^manual=1$'
[[ "$(grep -c '"type":"lead_failover"' "$LR/.loomy/logs/events.jsonl")" == 1 ]] \
  && ok "manual lead: pinning automatic relay writes no second failover" || ko "manual lead: pin duplicated failover event"
rm -f "$QC/loomy/claude-limits"
got="$(lead_relay_decide)"
[[ "$got" == 'codex continue' && -f "$LR/.loomy/failover" ]] \
  && ok "manual lead: pinned Codex stays lead while Claude has room" || ko "manual lead: pinned relay returned to Claude"
relay_codex_quota 20
rm -f "$QC/loomy/claude-limits" "$LR/.loomy/failover"
: >"$LR/.loomy/logs/events.jsonl"; : >"$LR_LOG"

run "manual lead: Codex switch overrides resume" manual_start --lead codex --resume
file_has "manual lead: marked manual in state" "$LR/.loomy/failover" '^manual=1$'
file_has "manual lead: reason is manual" "$LR/.loomy/failover" '^reason=manual$'
file_has "manual lead: manual handover journal event" "$LR/.loomy/logs/events.jsonl" '"type":"lead_failover".*"manual":true'
file_has "manual lead: Codex receives handoff and STATE prompt" "$LR_LOG" 'codex.*You are temporarily.*\(manual\).*HANDOFF.md.*STATE.md first'
if grep -q $'codex\tresume' "$LR_LOG"; then ko "manual lead: switch resumed old session"; else ok "manual lead: switch starts new session"; fi
if cmp -s "$LR/.loomy/brief.md" "$WORK/manual-brief.before"; then ok "manual lead: brief unchanged"; else ko "manual lead: brief changed"; fi
got="$(lead_relay_decide)"
[[ "$got" == 'codex continue' && -f "$LR/.loomy/failover" ]] && ok "manual lead: no automatic return when master has room" || ko "manual lead: unexpectedly returned: $got"
: >"$LR_LOG"
run "manual lead: repeating Codex starts it" manual_start --lead codex --new
[[ "$(grep -c '"type":"lead_failover"' "$LR/.loomy/logs/events.jsonl")" == 1 ]] && ok "manual lead: repeated choice writes no relay event" || ko "manual lead: duplicate relay event"
mkdir -p "$HOME/.codex/sessions"
printf '{"cwd":"%s"}\n' "$(cd "$LR" && pwd -P)" >"$HOME/.codex/sessions/manual.jsonl"
: >"$LR_LOG"
run "manual lead: same acting tool honors resume" manual_start --lead codex --resume
file_has "manual lead: repeated acting tool resumes" "$LR_LOG" '^codex.*resume[[:space:]]--last'
rm -f "$HOME/.codex/sessions/manual.jsonl"
run "manual lead: routing follows acting tool" qenv bash -c 'source "$1/scripts/lib/models.sh"; ai_detect_env "$2"; echo "$AI_LEAD|$AI_LEAD_MASTER|$AI_ENV"' _ "$REPO" "$LR"
has "manual lead: hybrid Codex routing with Claude master" '^codex\|claude\|hybrid-codex$'
run "manual lead: status displays manual relay" qenv env LOOMY_LANG=en bash "$REPO/scripts/loomy-status.sh" --root "$LR" --compact
has "manual lead: English status label" '⇄ Lead: Codex in place of Claude Code \(manual\)'
run "manual lead: French status displays manual relay" qenv env LOOMY_UI_LANG=fr bash "$REPO/scripts/loomy-status.sh" --root "$LR" --compact
has "manual lead: French status label" '⇄ Lead : Codex à la place de Claude Code \(manuel\)'
run "manual lead: live view displays manual relay" qenv env LOOMY_LANG=en bash "$REPO/scripts/loomy-tree.sh" --root "$LR" --once
has "manual lead: live view manual label" '⇄ Lead: Codex in place of Claude Code \(manual\)'
run "manual lead: session context describes manual choice" qenv env LOOMY_NO_REPAIR=1 bash -c 'bash "$1/scripts/loomy-context.sh" --root "$2" --hook start --tool codex </dev/null' _ "$REPO" "$LR"
has "manual lead: context reads handoff and shared state" 'Temporary lead: Codex.*\(manual\).*HANDOFF.md.*STATE.md first'
# Claude's prompt hook must also suppress the return notice in a manual relay.
relay_set_brief codex ORCHESTRATED
relay_active_claude "$(( $(date +%s) - 1 ))"; printf 'manual=1\n' >>"$LR/.loomy/failover"
rm -f "$LR/.loomy/relay.notice"
relay_prompt_hook >"$OUT" 2>&1
hasnt "manual lead: no in-session return notice" 'Codex has quota again and takes the lead back'
relay_set_brief claude ORCHESTRATED
relay_state_active ""; printf 'manual=1\n' >>"$LR/.loomy/failover"
: >"$LR_LOG"
run "manual lead: explicit Claude returns" manual_start --lead claude --resume
[[ ! -e "$LR/.loomy/failover" ]] && ok "manual lead: Claude return clears state" || ko "manual lead: Claude return kept state"
file_has "manual lead: explicit return journaled as manual" "$LR/.loomy/logs/events.jsonl" '"type":"lead_return".*"manual":true'
file_has "manual lead: master receives return prompt" "$LR_LOG" 'claude.*You are the lead agent again after a manual relay'
run "manual lead: switch for auto return" manual_start --lead codex --new
: >"$LR_LOG"
run "manual lead: auto returns to master" manual_start --lead auto --resume
[[ ! -e "$LR/.loomy/failover" ]] && ok "manual lead: auto clears state" || ko "manual lead: auto kept state"
file_has "manual lead: auto return gets new master prompt" "$LR_LOG" 'claude.*You are the lead agent again after a manual relay'
fails "manual lead: unknown tool exits 2" 2 manual_start --lead unknown --new
fails "manual lead: missing value exits 2" 2 manual_start --lead
fails "manual lead: uninstalled Codex exits 2" 2 qenv env PATH="$LR_BIN:/usr/bin:/bin" LOOMY_CODEX_BIN="$WORK/missing-codex" "$LOOMY" start --root "$LR" --lead codex --new
[[ ! -e "$LR/.loomy/failover" ]] && ok "manual lead: refusal writes no relay" || ko "manual lead: refusal wrote state"
cp "$LR/.loomy/logs/events.jsonl" "$WORK/manual-events.before"
run "manual lead: print previews switch" manual_start --lead codex --print
[[ ! -e "$LR/.loomy/failover" ]] && ok "manual lead: print switch writes no relay" || ko "manual lead: print switch wrote state"
if cmp -s "$LR/.loomy/logs/events.jsonl" "$WORK/manual-events.before"; then ok "manual lead: print writes no event"; else ko "manual lead: print wrote events"; fi
relay_state_active ""; printf 'manual=1\n' >>"$LR/.loomy/failover"
cp "$LR/.loomy/failover" "$WORK/manual-state.before"
cp "$LR/.loomy/logs/events.jsonl" "$WORK/manual-events.before"
run "manual lead: print stays read-only when combined with resume and tracking" manual_start --lead auto --print --resume --watch
if cmp -s "$LR/.loomy/failover" "$WORK/manual-state.before" && cmp -s "$LR/.loomy/logs/events.jsonl" "$WORK/manual-events.before"; then ok "manual lead: combined print preserves state and events"; else ko "manual lead: combined print wrote state or events"; fi
run "manual lead: print previews auto return" manual_start --lead auto --print
if cmp -s "$LR/.loomy/failover" "$WORK/manual-state.before"; then ok "manual lead: print return preserves relay"; else ko "manual lead: print return changed state"; fi
# Saturated destinations are allowed for the first launch; the normal chain then protects the acting lead.
relay_codex_quota 97
: >"$LR_LOG"
run "manual lead: saturated Codex is allowed and chains back" manual_start --lead codex --new
has "manual lead: saturation warning" 'Codex quota is saturated; manual lead allowed'
LR_ORDER="$(awk -F '\t' '$1 == "claude" || ($1 == "codex" && $2 !~ /^--version/) { printf "%s%s", sep, $1; sep = " " } END { print "" }' "$LR_LOG")"
[[ "$LR_ORDER" == 'codex claude' && ! -e "$LR/.loomy/failover" ]] && ok "manual lead: saturated acting lead hands back and clears manual" || ko "manual lead: saturated chain order=$LR_ORDER"
relay_codex_quota 20
printf 'plan_claude=pro\nplan_codex=api\nquota_switch=95\nquota_room=80\nlead_failover=auto\n' >"$QC/loomy/config"
run "manual lead: API destination allowed" manual_start --lead codex --new
has "manual lead: API warning" 'Codex is on a pay-per-use plan; manual lead allowed'
file_has "manual lead: API destination remains manual relay" "$LR/.loomy/failover" '^manual=1$'
# An explicit manual choice is independent of automatic relay preferences.
printf 'lead_failover=off\n' >>"$QC/loomy/config"
run "manual lead: disabled auto relay still preserves explicit choice" manual_start --lead codex --new
file_has "manual lead: manual relay survives lead_failover off" "$LR/.loomy/failover" '^manual=1$'
printf 'lead_failover=auto\nplan_codex=business\n' >>"$QC/loomy/config"
rm -f "$LR/.loomy/failover"; : >"$LR_APP_OPEN_LOG"
run "manual lead: app starts chosen Codex" qenv env PATH="$LR_BIN:$LR_APP_BIN:$HERE/stubs:/usr/bin:/bin" LR_APP_OPEN_LOG="$LR_APP_OPEN_LOG" LOOMY_START_WATCH=0 LOOMY_CODEX_BIN="$HERE/stubs/codex" "$LOOMY" start --root "$LR" --lead codex --app
file_has "manual lead: app link contains manual prompt" "$LR_APP_OPEN_LOG" '^codex://.*manual'
file_has "manual lead: app records manual relay" "$LR/.loomy/failover" '^manual=1$'
run "manual lead: app returns to master" qenv env PATH="$LR_BIN:$LR_APP_BIN:$HERE/stubs:/usr/bin:/bin" LR_APP_OPEN_LOG="$LR_APP_OPEN_LOG" LOOMY_START_WATCH=0 LOOMY_CODEX_BIN="$HERE/stubs/codex" "$LOOMY" start --root "$LR" --lead auto --app
[[ ! -e "$LR/.loomy/failover" ]] && ok "manual lead: app return clears state" || ko "manual lead: app return kept state"
relay_set_brief codex ORCHESTRATED
: >"$LR_LOG"
run "manual lead: reverse switch starts Claude" manual_start --lead claude --new
file_has "manual lead: reverse switch keeps Codex master" "$LR/.loomy/failover" '^master=codex$'
file_has "manual lead: reverse switch receives manual handoff prompt" "$LR_LOG" 'claude.*temporarily.*Codex.*\(manual\).*STATE.md first'
run "manual lead: reverse auto returns Codex" manual_start --lead auto --new
[[ ! -e "$LR/.loomy/failover" ]] && ok "manual lead: reverse return clears relay" || ko "manual lead: reverse return kept relay"
relay_set_brief claude ORCHESTRATED
file_has "manual lead: tracking forwards selected tool to inner session" "$REPO/scripts/loomy-start.sh" 'agent=.*lead_args'
run "manual lead: start help advertises flag" "$LOOMY" help start
has "manual lead: start help includes choices" 'loomy start --lead <codex\|claude\|auto>'
run "manual lead: global help advertises flag" "$LOOMY" help
has "manual lead: global help includes choices" '\-\-lead codex\|claude\|auto'
rm -f "$QC/loomy/claude-limits" "$LR/.loomy/failover"
}
lead_relay_tests
if [[ "${1:-}" == --section && "${2:-}" == 'Lead relay (quota)' ]]; then
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  (( FAIL == 0 )); exit $?
fi

section "Codex CLI discovery"
CA="$WORK/apps/ChatGPT.app/Contents/Resources/codex-cli"; mkdir -p "$CA/bin" "$WORK/stalebin"
printf '{ "layoutVersion": 1, "entrypoint": "bin/codex" }\n' >"$CA/codex-package.json"
printf '#!/bin/sh\necho "codex-cli 0.158.0"\n' >"$CA/bin/codex"; chmod +x "$CA/bin/codex"
printf '#!/bin/sh\nexec "%s/gone/codex" "$@"\n' "$WORK" >"$WORK/stalebin/codex"; chmod +x "$WORK/stalebin/codex"
got="$(env -u LOOMY_CODEX_BIN LOOMY_CODEX_APPS="$WORK/apps/ChatGPT.app" PATH="$WORK/stalebin:/usr/bin:/bin" bash -c 'source "$1/scripts/lib/models.sh"; ai_codex_bin' _ "$REPO")"
[[ "$got" == "$CA/bin/codex" ]] && ok "codex: stale wrapper skipped, current app layout found" || ko "codex discovery: $got"
got="$(env -u LOOMY_CODEX_BIN LOOMY_CODEX_APPS="$WORK/apps/ChatGPT.app" PATH="$WORK/stalebin:/usr/bin:/bin" bash -c 'source "$1/scripts/lib/models.sh"; ai_codex_version' _ "$REPO")"
[[ "$got" == "0.158.0" ]] && ok "codex: version read from the bundled CLI" || ko "codex version: $got"
mkdir -p "$HOME/.local/bin" && cp "$WORK/stalebin/codex" "$HOME/.local/bin/codex"
env -u LOOMY_CODEX_BIN LOOMY_CODEX_APPS="$WORK/apps/ChatGPT.app" PATH="$HOME/.local/bin:$HERE/stubs:/usr/bin:/bin" bash "$REPO/scripts/loomy-doctor.sh" --root "$PROJ" >"$OUT" 2>&1 || true
rm -f "$HOME/.local/bin/codex"
has "doctor: broken codex command flagged" "points to a Codex CLI that no longer exists"
has "doctor: readable fix" "fix: loomy doctor --fix"

section "Structured delegations"
SD="$WORK/structured"; mkdir -p "$SD"
run "init with the default delegation format" "$LOOMY" init "$SD" --yes --no-clipboard
file_has "brief: structured delegations by default" "$SD/.loomy/brief.md" "^delegation_format: structured$"
file_has "brief: instruction for the agent" "$SD/.loomy/brief.md" "Delegations in structured form"
SL="$WORK/structured.log"; : >"$SL"
(cd "$SD" && STUB_LOG="$SL" "$LOOMY" delegate codex reviewer "Review the diff") >"$OUT" 2>&1
grep -q 'STATUS: done | partial | blocked' "$SL" && ok "structured: contract added to the Codex prompt" || ko "structured: no contract in the prompt"
has "structured: fields returned" "^STATUS: partial$"
(cd "$SD" && STUB_LOG="$SL" "$LOOMY" delegate claude explorer "Map the code") >"$OUT" 2>&1
J2="$SD/.loomy/logs/events.jsonl"
file_has "structured: Codex outcome logged" "$J2" '"bridge":"codex".*"format":"structured","outcome":"partial"'
file_has "structured: Claude outcome logged" "$J2" '"bridge":"claude".*"format":"structured","outcome":"blocked"'
run "status with structured outcomes" "$LOOMY" status --root "$SD"
has "status: partial result marked" "◐ .*reviewer"
has "status: blocked result marked" "■ .*explorer"
run "log with structured outcomes" "$LOOMY" log --root "$SD"
has "log: partial result marked" "◐ reviewer"
run "stats with structured outcomes" "$LOOMY" stats --root "$SD"
has "stats: format compliance" "2 of 2 answers followed the format · 1 partial · 1 blocked"
run "context in structured mode" bash "$REPO/scripts/loomy-context.sh" --root "$SD"
has "context: structured delegations explained" "Structured delegations: write each task as GOAL"
run "generated Claude subagents carry the contract" "$LOOMY" route --root "$SD" claude-agents "$WORK/sd-agents"
file_has "subagent: answer contract" "$WORK/sd-agents/explorer.md" "^STATUS: done \| partial \| blocked$"
: >"$SL"; (cd "$SD" && LOOMY_DELEGATION_FORMAT=free STUB_LOG="$SL" "$LOOMY" delegate codex reviewer "x") >"$OUT" 2>&1
grep -q 'STATUS: done' "$SL" && ko "free format: contract still added" || ok "free format: no contract"
run "config: delegation_format" "$LOOMY" config set delegation_format free
[[ "$(bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; ai_delegation_format "$2"' _ "$REPO" "$SD")" == free ]] && ok "config overrides the project's choice" || ko "config override ignored"
fails "config: invalid delegation_format refused" 2 "$LOOMY" config set delegation_format yaml
run "config: back to the project's choice" "$LOOMY" config set delegation_format auto
[[ "$(bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; ai_delegation_format "$2"' _ "$REPO" "$QD")" == free ]] && ok "older project without the option: free text" || ko "older project: format changed"

section "Screens without leftovers"
run "doctor for the installs listing" "$LOOMY" doctor
has "doctor: installs listed under LOOMY" "not in the PATH|used by the loomy command|other install"
run "route in English" "$LOOMY" route --root "$PROJ"
hasnt "route: no French left" "sous-agent|session principale|orchestrat"
run "route markdown" "$LOOMY" route --root "$PROJ" markdown
if awk 'prev == "" && $0 == "" { bad = 1 } { prev = $0 } END { exit !bad }' "$OUT"; then ko "route markdown: double blank line"; else ok "route markdown: no double blank line"; fi
run "every command help in English" bash -c 'for c in init brief assess start effort route privacy worktrees status log feedback doctor; do "$1" "$c" --help; done' _ "$LOOMY"
hasnt "help: no French left" "[éèàù]| : "

section "Hardening"
[[ "$(bash -c 'source "$1/scripts/lib/models.sh"; loomy_slug ".."; loomy_slug "../../etc"; loomy_slug "-rf"' _ "$REPO" | tr '\n' ' ')" == "my-project etc rf " ]] && ok "slug: no dots, slashes or leading hyphen" || ko "slug: $(bash -c 'source "$1/scripts/lib/models.sh"; loomy_slug ".."; loomy_slug "../../etc"' _ "$REPO" | tr '\n' ' ')"
HB="$WORK/hostile"; mkdir -p "$HB/.loomy"; touch "$HB/START.md"
printf -- '---\nname: "evil $(touch %s/pwned) `touch %s/pwned` \033[31mRED"\nai_mode: SOLO\nai_lead: claude\nai_repo_name: ../../etc\n---\n' "$WORK" "$WORK" >"$HB/.loomy/brief.md"
run "status on a hostile brief" "$LOOMY" status --root "$HB"
[[ ! -e "$WORK/pwned" ]] && ok "hostile brief: nothing executed" || ko "hostile brief: command executed"
if grep -q $'\033\\[31m' "$OUT"; then ko "hostile brief: escape sequence reached the terminal"; else ok "hostile brief: escape sequences removed"; fi
run "context on a hostile brief" bash "$REPO/scripts/loomy-context.sh" --root "$HB"
[[ ! -e "$WORK/pwned" ]] && ok "hostile brief: context executes nothing" || ko "hostile brief: context executed a command"
mkdir -p "$WORK/clone/bin" && cp "$REPO/bin/loomy" "$WORK/clone/bin/" && cp "$REPO/VERSION" "$WORK/clone/" && ln -s "$REPO/scripts" "$WORK/clone/scripts"
PATH="$WORK/clone/bin:$PATH" "$WORK/clone/bin/loomy" uninstall >"$OUT" 2>&1
hasnt "uninstall: never suggests deleting the clone's own file" "rm .*/clone/bin/loomy"
has "uninstall: clone in the PATH" "from your PATH"
SP="$WORK/spaced repo"; mkdir -p "$SP/src dir" && printf '// TODO\n' >"$SP/src dir/a file.js" && git -C "$SP" init -q -b main && git -C "$SP" add -A && git -C "$SP" commit -qm x
run "assess with spaces in names" "$LOOMY" assess --root "$SP" --print
has "assess: file names with spaces kept whole" '`src dir/a file.js`'
if [[ -n "$TMUX_BIN" ]]; then
  tstart -s k -x 100 -y 30 -c "$PROJ" "bash"
  sleep 1; tmux -L loomy-test send-keys -t k "bash '$LOOMY'" Enter
  k=0; until tmux -L loomy-test capture-pane -t k -p | grep -q "What do you want to do"; do sleep 0.25; k=$(( k + 1 )); (( k > 80 )) && break; done
  tmux -L loomy-test send-keys -t k C-c; sleep 1
  tmux -L loomy-test send-keys -t k "stty -a | grep -oE ' -?icanon | -?echo ' | tr -d ' \n'; echo :STTY" Enter; sleep 1
  tmux -L loomy-test capture-pane -t k -p | grep -q '^icanonecho:STTY\|^echoicanon:STTY' && ok "Ctrl-C: terminal restored (echo, canonical mode)" || ko "Ctrl-C: terminal left in raw mode ($(tmux -L loomy-test capture-pane -t k -p | grep STTY | tail -1))"
  tmux -L loomy-test kill-server 2>/dev/null || true
fi

# ------------------------------------------------------------------ interface language
section "Security audit"
AR="$WORK/audit-repo"; mkdir -p "$AR" && git -C "$AR" init -q && echo x >"$AR/a.txt" && git -C "$AR" add -A && git -C "$AR" -c user.name=t -c user.email=t@t commit -qm i
fails "audit: refused outside a Git repository" 1 bash -c 'cd "$1" && "$2" audit --yes --print --no-install' _ "$WORK/pas-git-$$" "$LOOMY" 2>/dev/null || true
(cd "$AR" && "$LOOMY" audit --yes --print --no-install) >"$OUT" 2>&1
has "audit: auditor on the security role" "claude-opus|gpt-6.1-sol"
file_has "audit: mission written" "$AR/.loomy/audit.md" "^fixes: plan$"
file_has "audit: first phase" "$AR/.loomy/audit.state" "^phase=scope$"
file_has "audit: prompt names the Cloudflare skill" "$AR/.loomy/audit-prompt.txt" "security-audit skill"
file_has "audit: Sonnet 5.5 high validator in the team" "$AR/.loomy/audit-prompt.txt" "DELEGATE_CLAUDE_EFFORT=high .*loomy-delegate-claude.sh\" reviewer"
file_has "audit: explorer on a rigorous model, not a fast one" "$AR/.loomy/audit-prompt.txt" "DELEGATE_CLAUDE_MODEL=claude-sonnet-5-5 DELEGATE_CLAUDE_EFFORT=medium"
file_has "audit: fast writer drafts from validated findings only" "$AR/.loomy/audit-prompt.txt" "DELEGATE_CODEX_MODEL=gpt-6-luna .*documenter"
file_has "audit: cross review by the other family" "$AR/.loomy/audit-prompt.txt" "loomy-delegate-codex.sh\" reviewer"
[[ -z "$(git -C "$AR" status --porcelain)" ]] && ok "audit: nothing added to Git" || ko "audit: Git sees $(git -C "$AR" status --porcelain | tr '\n' ' ')"
(cd "$AR" && "$LOOMY" status) >"$OUT" 2>&1
has "audit: status shows the audit phases" "AUDIT.*step 1 of 6"
bash "$REPO/scripts/loomy-status.sh" --root "$AR" --audit set analyze >/dev/null
file_has "audit: phase recorded" "$AR/.loomy/audit.state" "^phase=analyze$"
(cd "$AR" && "$LOOMY" start) >"$OUT" 2>&1
has "audit: loomy start resumes the audit" "auditor session"
fails "audit: invalid depth" 2 "$LOOMY" audit --depth huge
# Local writer (LM Studio): only when Codex is not available and a local server answers; text only, logged.
if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  LS="$WORK/lmstudio"; mkdir -p "$LS/v1" && printf '{"data":[{"id":"text-embedding-x"},{"id":"qwen/qwen3.8-27b"}]}' >"$LS/v1/models"
  LPORT=$(( 20000 + $$ % 20000 ))
  (cd "$LS" && exec python3 -m http.server "$LPORT" --bind 127.0.0.1) >/dev/null 2>&1 &
  LPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 1 "http://127.0.0.1:$LPORT/v1/models" >/dev/null 2>&1 && break; sleep 0.3; done
  got="$(LOOMY_LOCAL_URL="http://127.0.0.1:$LPORT" bash "$REPO/scripts/loomy-local-writer.sh" --check 2>&1)"
  [[ "$got" == "qwen/qwen3.8-27b" ]] && ok "local writer: loaded chat model found, embeddings skipped" || ko "local writer check: $got"
  fails "local writer: remote address refused" 2 env LOOMY_LOCAL_URL="http://example.com:1234" bash "$REPO/scripts/loomy-local-writer.sh" --check
  LOOMY_LOCAL_URL="http://127.0.0.1:$LPORT" bash "$REPO/scripts/loomy-local-writer.sh" --root "$AR" "Draft the summary" >"$OUT" 2>&1
  has "local writer: draft returned" "answer from the claude double"
  grep -q '"bridge":"local".*"cost_usd":0' "$AR/.loomy/logs/events.jsonl" && ok "local writer: delegation logged at no cost" || ko "local writer: not logged"
  mkdir -p "$WORK/only-claude" && ln -sf "$HERE/stubs/claude" "$WORK/only-claude/claude"
  AR2="$WORK/audit-local"; mkdir -p "$AR2" && git -C "$AR2" init -q && echo x >"$AR2/a" && git -C "$AR2" add -A && git -C "$AR2" -c user.name=t -c user.email=t@t commit -qm i
  (cd "$AR2" && env -u LOOMY_CODEX_BIN LOOMY_CODEX_APPS="$WORK/no-apps" PATH="$WORK/only-claude:/usr/bin:/bin" LOOMY_LOCAL_URL="http://127.0.0.1:$LPORT" bash "$REPO/bin/loomy" audit --yes --print --no-install) >"$OUT" 2>&1
  file_has "audit without Codex: local writer used" "$AR2/.loomy/audit-prompt.txt" "loomy-local-writer.sh"
  AR3="$WORK/audit-codex"; mkdir -p "$AR3" && git -C "$AR3" init -q && echo x >"$AR3/a" && git -C "$AR3" add -A && git -C "$AR3" -c user.name=t -c user.email=t@t commit -qm i
  (cd "$AR3" && LOOMY_LOCAL_URL="http://127.0.0.1:$LPORT" "$LOOMY" audit --yes --print --no-install) >/dev/null 2>&1
  grep -q "loomy-delegate-codex.sh.* documenter" "$AR3/.loomy/audit-prompt.txt" && ! grep -q "ai-local-writer" "$AR3/.loomy/audit-prompt.txt" && ok "audit with Codex: Luna stays the writer" || ko "audit with Codex: writer not Luna"
  kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
else
  ok "local writer: skipped (curl or python3 missing)"
fi

section "Day-to-day work"
DW="$WORK/dayto"; "$LOOMY" init "$DW" --yes --no-clipboard >/dev/null 2>&1
git -C "$DW" add -A >/dev/null 2>&1; git -C "$DW" -c user.name=t -c user.email=t@t commit -qm init >/dev/null 2>&1
bash "$REPO/scripts/loomy-status.sh" --root "$DW" set "done" >/dev/null
# loomy task
(cd "$DW" && "$LOOMY" task "Add a settings page" --print) >"$OUT" 2>&1
has "task: created and prepared" "#1 · Add a settings page"
file_has "task: state" "$DW/.loomy/task.state" "^phase=plan$"
file_has "task: index" "$DW/.loomy/TASKS.md" "#1 Add a settings page"
file_has "task: prompt with its phases" "$DW/.loomy/task-prompt.txt" "--task set"
(cd "$DW" && "$LOOMY" status) >"$OUT" 2>&1
has "task: status shows the task" "TASK.*step 1 of 5"
bash "$REPO/scripts/loomy-status.sh" --root "$DW" --task set build >/dev/null
grep -q '^status: build' "$DW"/.loomy/tasks/001-*.md && ok "task: file follows the phase" || ko "task: file status not updated"
file_has "task: title kept in the state" "$DW/.loomy/task.state" "^title=Add a settings page$"
bash "$REPO/scripts/loomy-status.sh" --root "$DW" --task set "done" >/dev/null
(cd "$DW" && "$LOOMY" status) >"$OUT" 2>&1
has "task: summary once done" "Task done"
(cd "$DW" && "$LOOMY" task) >"$OUT" 2>&1
has "task: list" "#1  Add a settings page"
# loomy review
git -C "$DW" checkout -q -b feature && echo "change" >"$DW/new.txt" && git -C "$DW" add new.txt && git -C "$DW" -c user.name=t -c user.email=t@t commit -qm change
(cd "$DW" && "$LOOMY" review --print) >"$OUT" 2>&1
has "review: branch against its base" "branch feature against main"
(cd "$DW" && "$LOOMY" review --tool claude) >"$OUT" 2>&1
has "review: reviewer answer shown" "answer from the claude double"
ls "$DW"/.loomy/reviews/*.md >/dev/null 2>&1 && ok "review: saved" || ko "review: not saved"
git -C "$DW" checkout -q main
(cd "$DW" && "$LOOMY" review) >"$OUT" 2>&1
has "review: nothing to review" "Nothing to review"
# loomy report
(cd "$DW" && "$LOOMY" report --md) >"$OUT" 2>&1
has "report: delegations" "DELEGATIONS"
ls "$DW"/docs/reports/report-*.md >/dev/null 2>&1 && ok "report: Markdown file in docs/reports/" || ko "report: no Markdown file"
grep -q "$HOME" "$DW"/docs/reports/report-*.md && ko "report: local path leaked in the file" || ok "report: no local path in the file"
file_has "report: Markdown tables" "$(ls "$DW"/docs/reports/report-*.md | head -1)" "^\| Tokens \|"
(cd "$DW" && "$LOOMY" report --md reports) >/dev/null 2>&1
ls "$DW"/reports/report-*.md >/dev/null 2>&1 && ok "report: Markdown file in a chosen folder" || ko "report: chosen folder ignored"
"$LOOMY" report --all >"$OUT" 2>&1
has "report --all: projects listed" "dayto"
# loomy models
"$LOOMY" models >"$OUT" 2>&1
has "models: chains shown" "claude.mid"
got="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_MODEL_CLAUDE_MID"' _ "$REPO")"
"$LOOMY" config set chain.claude.mid "claude-sonnet-9, claude-sonnet-5-5" >/dev/null
got2="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_MODEL_CLAUDE_MID"' _ "$REPO")"
[[ "$got2" == "claude-sonnet-9" ]] && ok "models: local chain applied" || ko "models: local chain ($got2)"
"$LOOMY" models --thrifty on >/dev/null
got3="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_MODEL_CLAUDE_MID"' _ "$REPO")"
[[ "$got3" == "claude-sonnet-5-5" ]] && ok "models: low-cost mode prefers the fallback" || ko "models: low-cost mode ($got3)"
"$LOOMY" models --thrifty off >/dev/null; "$LOOMY" config set chain.claude.mid auto >/dev/null
fails "models: invalid chain refused" 2 "$LOOMY" config set chain.claude.mid "a, b, c, d"
got4="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_MODEL_CLAUDE_MID"' _ "$REPO")"
[[ "$got4" == "$got" ]] && ok "models: back to the catalog" || ko "models: not restored ($got4)"
# Project templates
printf -- '---\nname: "API test"\ngoal: "an api"\nrepo: new\ntemplate: api\n---\n' >"$WORK/tpl-answers.md"
"$LOOMY" init "$WORK/tpl-api" --answers "$WORK/tpl-answers.md" --yes --no-clipboard >/dev/null 2>&1
file_has "template: API prefills the type" "$WORK/tpl-api/.loomy/brief.md" "^type: api$"
file_has "template (before 0.10): read as the project type" "$WORK/tpl-api/.loomy/brief.md" "^traits: \"publicapi\"$"
file_has "template: starting structure for the agent" "$WORK/tpl-api/.loomy/brief.md" "OpenAPI contract first"
# 0.10 questionnaire: one project type, key characteristics (several), risk, details per type, recap and recommendations.
qa_start() { printf -- '---\nname: "%s"\ngoal: "g"\nrepo: new\n%s\n---\n' "$1" "$2" >"$WORK/qa-$1.md"; "$LOOMY" init "$WORK/qa-$1" --answers "$WORK/qa-$1.md" --yes --no-clipboard >"$WORK/qa-$1.out" 2>&1 & QA_PIDS="$QA_PIDS $!"; }
QA_PIDS=""
qa_start web 'type: web'
qa_start custom 'type: custom'
qa_start other 'type: other'
qa_start multi $'type: web\ntraits: "auth,payments,external,multitenant"\nstage: production'
qa_start data $'type: data\ntraits: "bigdata,external,personal"\ndetail1: "files,sql"\ndetail2: tb\ndetail3: "reports,dashboards"\nbudget: econome'
qa_start sens $'type: ai\nsensitive: "payments"'
qa_start legtpl $'type: web\ntemplate: landing\nsensitive: ""'
qa_start legmail $'type: other\ntemplate: emails'
qa_start legweb $'type: web\ndetail2: no\nsensitive: "auth"'
qa_start legnoacc $'type: web\ndetail2: no'
qa_start team $'type: site\nai_mode: HYBRID\nbudget: qualite'
for qa_pid in $QA_PIDS; do wait "$qa_pid"; done
qa() { cp "$WORK/qa-$1.out" "$OUT"; QB="$WORK/qa-$1/.loomy/brief.md"; }
qa web
file_has "type web: user accounts pre-checked" "$QB" '^traits: "auth"$'
file_has "type web: MEDIUM risk" "$QB" '^risk: MEDIUM$'
file_has "type web with accounts: starting structure" "$QB" "Web app with accounts"
file_has "characteristic in the brief: its check" "$QB" "the security role reviews authentication"
qa custom
file_has "custom type: nothing pre-checked" "$QB" '^traits: ""$'
file_has "custom type: LOW risk" "$QB" '^risk: LOW$'
qa other
file_has "type other (before 0.10): read as custom" "$QB" '^type: custom$'
qa multi
file_has "several characteristics kept" "$QB" '^traits: "auth,payments,external,multitenant"$'
file_has "several characteristics: HIGH risk" "$QB" '^risk: HIGH$'
file_has "former sensitive areas derived" "$QB" '^sensitive: "auth,payments"$'
qa data
file_has "data type: sources (several)" "$QB" '^detail1: "files,sql"$'
file_has "data type: volume" "$QB" '^detail2: "tb"$'
file_has "data type: deliverables (several)" "$QB" '^detail3: "reports,dashboards"$'
file_has "data type: pipeline proposed" "$QB" "ingestion → raw storage"
file_has "data type: data never whole in prompts" "$QB" "Data never goes whole into prompts"
file_has "recommendation: HIGH risk with Thrifty" "$QB" "Recommendation to offer the user \(not applied\): HIGH risk with the Thrifty profile"
file_has "recommendation: sensitive data on a local model" "$QB" "local model \(LM Studio\)"
file_has "recommendation: profile not changed" "$QB" '^budget: econome$'
has "recap: what Loomy will configure" "What Loomy will configure"
has "recap: recommendations, indicative" "Recommendations.*indicative"
qa sens
file_has "sensitive areas (before 0.10) read as characteristics" "$QB" '^traits: "payments"$'
qa legtpl
file_has "brief before 0.10: template wins over type (landing → site)" "$QB" '^type: site$'
qa legmail
file_has "brief before 0.10: emails template kept" "$QB" '^type: emails$'
qa legweb
file_has "brief before 0.10: explicit authentication kept" "$QB" '^traits: "auth"$'
file_has "brief before 0.10: accounts answer not read as a database" "$QB" '^detail2: "tbd"$'
qa legnoacc
file_has "brief before 0.10: no accounts, nothing checked" "$QB" '^traits: ""$'
qa team
file_has "earlier AI team answers kept (Customise)" "$QB" '^ai_mode: HYBRID$'
file_has "earlier profile kept" "$QB" '^budget: qualite$'

section "Automatic repair and upkeep"
# Fake installs: an npm copy of claude (method detected from its path), a fake npm and a fake official installer.
RP="$WORK/repair"; rm -rf "$RP"; mkdir -p "$RP/prefix/lib/node_modules/@anthropic-ai/claude-code" "$RP/prefix/bin" "$RP/tools" "$RP/home/.local/bin"
fake_claude() {   # fake_claude <file> <version file>
  printf '#!/bin/bash\ncase "$1" in --version) echo "$(cat %q) (Claude Code)" ;; update) [ -f %q ] && echo 2.1.400 > %q ;; esac\n' "$2" "$RP/update.ok" "$2" >"$1"; chmod +x "$1"
}
cat >"$RP/tools/npm" <<NPM
#!/bin/bash
echo "npm \$*" >>"$RP/calls"
case "\$*" in
  *"install -g"*"claude-code@latest"*) [ -f "$RP/npm.ok" ] && echo 2.1.400 >"$RP/npm.ver" ;;
  *"uninstall -g"*"claude-code"*) rm -f "$RP/prefix/bin/claude" ;;
esac
exit 0
NPM
chmod +x "$RP/tools/npm"
printf '#!/bin/bash\necho installer >>%q\nmkdir -p "$HOME/.local/bin"; echo 2.1.500 > %q\n' "$RP/calls" "$RP/native.ver" >"$RP/installer.sh"
repair_try() {   # repair_try: runs the Claude repair in the fake world; prints the final state
  HOME="$RP/home" PATH="$RP/prefix/bin:$RP/extra:$RP/tools:/usr/bin:/bin" LOOMY_REPAIR_YES=1 XDG_CONFIG_HOME="$RP/cfg" \
    LOOMY_CLAUDE_INSTALLER="bash $RP/installer.sh && cp $RP/native-claude \"\$HOME/.local/bin/claude\"" \
    bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/repair.sh"; ai_repair_tool claude >/dev/null 2>&1; ai_tool_state claude' _ "$REPO"
}
reset_world() { rm -f "$RP"/*.ok "$RP/calls" "$RP/home/.local/bin/claude"; rm -rf "$RP/extra"; echo 2.1.100 >"$RP/npm.ver"
  fake_claude "$RP/prefix/lib/node_modules/@anthropic-ai/claude-code/cli.js" "$RP/npm.ver"; ln -sf ../lib/node_modules/@anthropic-ai/claude-code/cli.js "$RP/prefix/bin/claude"
  fake_claude "$RP/native-claude" "$RP/native.ver"; }
reset_world
got="$(HOME="$RP/home" PATH="$RP/prefix/bin:/usr/bin:/bin" bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/repair.sh"; ai_tool_state claude; ai_tool_method claude "$(command -v claude)"' _ "$REPO" | tr '\n' ' ')"
[[ "$got" == "old 2.1.100 "*" npm " ]] && ok "repair: old npm copy detected" || ko "repair: detection ($got)"
touch "$RP/npm.ok"
got="$(repair_try)"
[[ "$got" == ok\ 2.1.400* ]] && ok "repair: step 1, npm update in the install's own prefix" || ko "repair step 1: $got"
grep -q "install -g --prefix .*/repair/prefix @anthropic-ai/claude-code@latest" "$RP/calls" && ok "repair: npm called with the install's prefix" || ko "repair: npm call ($(cat "$RP/calls"))"
reset_world
mkdir -p "$RP/extra"; fake_claude "$RP/extra/claude" "$RP/good.ver"; echo 2.1.450 >"$RP/good.ver"
got="$(repair_try)"
[[ "$got" == ok\ 2.1.450* ]] && ok "repair: old copy shadowing a recent one removed" || ko "repair shadow: $got"
reset_world
got="$(repair_try)"
[[ "$got" == ok\ 2.1.500* ]] && ok "repair: clean reinstall with the official installer when all else fails" || ko "repair clean reinstall: $got ($(tr '\n' ';' <"$RP/calls"))"
grep -q "uninstall -g" "$RP/calls" && grep -q installer "$RP/calls" && ok "repair: old copy removed before the reinstall" || ko "repair: order ($(tr '\n' ';' <"$RP/calls"))"
[[ -d "$RP/home/.claude" ]] && ko "repair: settings folder touched" || ok "repair: settings never touched"
# Upkeep: off in scripts and with LOOMY_NO_AUTOUPDATE; missing relays added to an older project.
rm -f "$DW/.loomy/scripts/loomy-task.sh"
(cd "$DW" && "$LOOMY" task) >/dev/null 2>&1
[[ -x "$DW/.loomy/scripts/loomy-task.sh" ]] && ok "upkeep: missing relay added to the project" || ko "upkeep: relay not added"
got="$(LOOMY_NO_AUTOUPDATE=1 bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/config.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/repair.sh"; source "$1/scripts/lib/upkeep.sh"; loomy_upkeep; echo "rc=$?"' _ "$REPO")"
[[ "$got" == "rc=0" ]] && ok "upkeep: off with LOOMY_NO_AUTOUPDATE" || ko "upkeep off: $got"

section "Announced models"
UP_CFG="$WORK/upcoming-cfg"; mkdir -p "$UP_CFG/loomy"
# A newer downloaded catalog announcing a model (the built-in list is empty while nothing is announced).
printf '%s\n' 'date=2099-01-01' 'model.claude.fast=claude-haiku-5-5, claude-haiku-4-5' 'upcoming.claude.fast=claude-haiku-9' >"$UP_CFG/loomy/catalog.conf"
upq() { XDG_CONFIG_HOME="$UP_CFG" bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_CHAIN_CLAUDE_FAST | $AI_MODEL_CLAUDE_FAST"' _ "$REPO"; }
[[ "$(upq)" == "claude-haiku-5-5 claude-haiku-4-5 | claude-haiku-5-5" ]] && ok "announced: not used before it answers" || ko "announced before: $(upq)"
XDG_CONFIG_HOME="$UP_CFG" "$LOOMY" models >"$OUT" 2>&1
has "announced: listed by loomy models" "claude-haiku-9.*not available yet"
hasnt "announced: not suggested as a new model" "✦ claude-haiku-9"
XDG_CONFIG_HOME="$UP_CFG" STUB_UNKNOWN_MODELS="claude-haiku-9" bash -c 'source "$1/scripts/lib/models.sh"; ai_model_probe claude claude-haiku-9' _ "$REPO" && ko "announced: refused model seen as available" || ok "announced: a refused model stays out"
XDG_CONFIG_HOME="$UP_CFG" bash -c 'source "$1/scripts/lib/models.sh"; ai_model_probe claude claude-haiku-9 && ai_model_mark claude-haiku-9 ok' _ "$REPO"
[[ "$(upq)" == "claude-haiku-9 claude-haiku-5-5 claude-haiku-4-5 | claude-haiku-9" ]] && ok "announced: once it answers, it heads its chain, the others as fallbacks" || ko "announced after: $(upq)"
got="$(bash -c 'source "$1/scripts/lib/models.sh"; echo "$AI_UPCOMING"' _ "$REPO")"
want="$(sed -n 's/^upcoming\.\([a-z]*\)\.\([a-z]*\)=\(.*\)$/\1:\2:\3/p' "$REPO/catalog/models.conf" | tr '\n' ' ' | sed 's/ $//')"
[[ "$want" == "$got" ]] && ok "announced: repository catalog = built-in list" || ko "announced catalog: '$got' vs '$want'"

section "Haiku 5.5 routing and long-prompt rate"
HK="$WORK/haiku-cfg"; mkdir -p "$HK/loomy"
hkq() { XDG_CONFIG_HOME="$HK" bash -c 'source "$1/scripts/lib/models.sh"; ai_resolve "$2" "$3" "$4"; echo "$R_MODEL $R_EFFORT"' _ "$REPO" "$@"; }
[[ "$(hkq executor claude equilibre)" == "claude-haiku-5-5 high" ]] && ok "haiku: full-Claude executor on Haiku 5.5 high" || ko "haiku executor: $(hkq executor claude equilibre)"
[[ "$(hkq explorer claude equilibre)" == "claude-haiku-5-5 medium" ]] && ok "haiku: Claude explorer on Haiku 5.5 medium" || ko "haiku explorer: $(hkq explorer claude equilibre)"
[[ "$(hkq executor hybrid-claude equilibre)" == "gpt-6-luna max" ]] && ok "haiku: hybrid executor stays on Luna" || ko "haiku hybrid: $(hkq executor hybrid-claude equilibre)"
[[ "$(hkq executor claude qualite)" == "claude-sonnet-5-5 high" ]] && ok "haiku: Max quality executor on Sonnet" || ko "haiku qualite: $(hkq executor claude qualite)"
echo "claude-haiku-5-5=ko" >"$HK/loomy/models.state"
[[ "$(hkq executor claude equilibre)" == "claude-sonnet-5-5 medium" ]] && ok "haiku: without Haiku 5.5 the executor goes back to Sonnet, not Haiku 4.5" || ko "haiku fallback: $(hkq executor claude equilibre)"
[[ "$(hkq explorer claude equilibre)" == "claude-haiku-4-5 medium" ]] && ok "haiku: without Haiku 5.5 the explorer falls back to Haiku 4.5" || ko "haiku explorer fallback: $(hkq explorer claude equilibre)"
# One message under 100K tokens, one over: the second one at the long-prompt rate (0.50 / 2.50).
HKP="$WORK/haiku-proj"; mkdir -p "$HKP/.loomy/logs"; HKT="$WORK/haiku.jsonl"
printf '{"type":"assistant","message":{"id":"msg_h1","model":"claude-haiku-5-5","usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1000000}}}\n' >"$HKT"
printf '{"type":"assistant","message":{"id":"msg_h2","model":"claude-haiku-5-5","usage":{"input_tokens":1000000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}\n' >>"$HKT"
bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; ai_usage_record "$2" "$3" lead' _ "$REPO" "$HKP" "$HKT"
got="$(grep -o '"cost_usd":[0-9.]*' "$HKP/.loomy/logs/events.jsonl" | sed 's/.*://' | sort | tr '\n' ' ')"
[[ "$got" == "0.500000 0.505000 " ]] && ok "haiku: long prompts priced at the long rate, the rest at the base rate" || ko "haiku long rate: $got"
file_has "haiku: model logged without the internal marker" "$HKP/.loomy/logs/events.jsonl" '"model":"claude-haiku-5-5"'
grep -q '@long' "$HKP/.loomy/logs/events.jsonl" && ko "haiku: internal marker leaked into the log" || ok "haiku: no internal marker in the log"
CL="$WORK/haiku-catalog"; mkdir -p "$CL/loomy"
printf '%s\n' 'date=2099-01-01' 'price_long.claude-haiku-5-5=200000 1 3 0.10' >"$CL/loomy/catalog.conf"
[[ "$(XDG_CONFIG_HOME="$CL" bash -c 'source "$1/scripts/lib/models.sh"; ai_price_long claude-haiku-5-5' _ "$REPO")" == "200000 1 3 0.10" ]] && ok "haiku: long-prompt rate read from the catalog" || ko "haiku catalog long rate"

section "Advisor and agent tree"
AC="$WORK/adv-cfg"; mkdir -p "$AC/loomy"
advq() { XDG_CONFIG_HOME="$AC" bash -c 'source "$1/scripts/lib/models.sh"; ai_advisor_for "$2" "$3"' _ "$REPO" "$1" "$2"; }
[[ "$(advq claude-sonnet-5-5 econome)" == "opus" ]] && ok "advisor: Opus advises the Thrifty Sonnet lead" || ko "advisor econome: $(advq claude-sonnet-5-5 econome)"
[[ -z "$(advq claude-opus-5-5 equilibre)" ]] && ok "advisor: none by default in Balanced" || ko "advisor balanced: $(advq claude-opus-5-5 equilibre)"
[[ "$(advq claude-opus-5-5 qualite)" == "opus" ]] && ok "advisor: a second Opus in Max quality" || ko "advisor quality"
[[ -z "$(advq gpt-6.1-sol econome)" ]] && ok "advisor: never for a Codex lead" || ko "advisor codex"
printf 'advisor=sonnet\n' >"$AC/loomy/config"
[[ -z "$(advq claude-opus-5-5 equilibre)" && "$(advq claude-sonnet-5-5 equilibre)" == "sonnet" ]] && ok "advisor: pairing Claude Code refuses (Sonnet advising Opus) left out" || ko "advisor pairing"
printf 'advisor=off\n' >"$AC/loomy/config"
[[ -z "$(advq claude-sonnet-5-5 econome)" ]] && ok "advisor: off when set off" || ko "advisor off"
rm -f "$AC/loomy/config"
got="$(XDG_CONFIG_HOME="$AC" bash -c 'source "$1/scripts/lib/models.sh"; ai_lead_command hybrid-claude econome' _ "$REPO")"
[[ "$got" == *"--advisor opus" ]] && ok "advisor: on the lead agent command" || ko "advisor command: $got"
fails "advisor: invalid setting refused" 2 "$LOOMY" config set advisor maybe
# Advisor consultations measured from the session transcript (advisor_message iterations).
AJ="$WORK/adv-proj"; mkdir -p "$AJ/.loomy/logs"
printf '%s\n' '{"type":"assistant","message":{"id":"msg_1","model":"claude-sonnet-5-5","usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":1000,"output_tokens":50,"iterations":[{"input_tokens":2,"output_tokens":26,"type":"message"},{"input_tokens":35648,"output_tokens":476,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"type":"advisor_message","model":"claude-opus-5-5"}]}}}' >"$AJ/t.jsonl"
bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; ai_usage_record "$2" "$2/t.jsonl" lead' _ "$REPO" "$AJ"
grep -q '"type":"advisor".*"model":"claude-opus-5-5","calls":1,"tokens_in":35648' "$AJ/.loomy/logs/events.jsonl" && ok "advisor: consultation logged with its model and tokens" || ko "advisor log: $(cat "$AJ/.loomy/logs/events.jsonl")"
# Agent tree
(cd "$DW" && "$LOOMY" tree) >"$OUT" 2>&1
has "tree: lead agent" "LEAD AGENT"
has "tree: every role with its model" "Executor.*gpt-6-luna"
has "tree: session log and status line" "session log"
TREE_OUTCOME="$WORK/tree-outcome"; mkdir -p "$TREE_OUTCOME/.loomy/logs"
printf -- '---\nai_mode: ORCHESTRATED\nai_lead: claude\nbudget: equilibre\n---\n' >"$TREE_OUTCOME/.loomy/brief.md"
printf '{"ts":"%s","type":"delegation","id":"partial","role":"reviewer","family":"codex","model":"gpt-6.1-sol","effort":"high","status":"ok","outcome":"partial","duration_s":12}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TREE_OUTCOME/.loomy/logs/events.jsonl"
COLUMNS=100 LINES=40 LOOMY_TREE=list bash "$REPO/scripts/loomy-tree.sh" --root "$TREE_OUTCOME" >"$OUT" 2>&1
has "tree: finished partial uses triangle" "△ Reviewer"
hasnt "tree: finished partial never uses running glyph" "◐ Reviewer"
bash "$REPO/scripts/loomy-status.sh" --root "$DW" --tree >"$OUT" 2>&1
has "tree: shown by the status view (key t of watch)" "AGENT TREE"
# Wide terminal: the tree is drawn as a diagram (boxes, links, routing layer, framed session log).
COLUMNS=132 LINES=64 bash "$REPO/scripts/loomy-tree.sh" --root "$DW" </dev/null >"$OUT" 2>&1
has "tree diagram: title" "LOOMY AGENT TREE"
has "tree diagram: lead agent box" "┌──.*┐"
has "tree diagram: routing layer" "LOOMY · routing"
has "tree diagram: roles side by side" "│ .*executor.*│ .*│"
has "tree diagram: back to the lead agent" "back to the lead agent"
has "tree diagram: framed session log" "┤ session log ├"
hasnt "tree diagram: no error" "syntax error|bad substitution|command not found"
hasnt "tree diagram: removed other-model list" "  [A-Z][A-Z0-9 .-]* ╌╌╌"
hasnt "tree diagram: removed other-role actions" "· (architect|debugger|security|documenter) +(designs the plan|finds the cause|checks the risks|writes the docs)"
hasnt "tree diagram: no bare role count when there is room" "\+[0-9]+ roles · loomy route"
COLUMNS=216 LINES=64 bash "$REPO/scripts/loomy-tree.sh" --root "$DW" </dev/null >"$OUT" 2>&1
hasnt "tree diagram: four role boxes at most, even in a wide window" "│ +documenter +│"
# Links aligned: every ▼ has its link right above it, in the same column (checked character by character).
if command -v python3 >/dev/null 2>&1; then
  NO_COLOR=1 COLUMNS=133 LINES=64 bash "$REPO/scripts/loomy-tree.sh" --root "$DW" </dev/null 2>/dev/null >"$OUT"
  python3 -c '
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
bad = [(i, x) for i in range(1, len(L)) for x, c in enumerate(L[i]) if c == "▼" and (x >= len(L[i - 1]) or L[i - 1][x] not in "●│┬")]
# A vertical link must meet a horizontal line on a node, never beside it.
bad += [(i, x) for i in range(len(L) - 1) for x, c in enumerate(L[i]) if c == "│" and x < len(L[i + 1]) and L[i + 1][x] == "─"]
bad += [(i, x) for i in range(1, len(L)) for x, c in enumerate(L[i]) if c == "│" and x < len(L[i - 1]) and L[i - 1][x] == "─"]

n = sum(l.count("▼") for l in L)
print(bad[:5], n) if bad or n == 0 else None
sys.exit(1 if bad or n == 0 else 0)' "$OUT" >"$WORK/align.txt" && ok "tree diagram: links aligned" || ko "tree diagram: misaligned link ($(cat "$WORK/align.txt"))"
else
  ok "tree diagram: links aligned (skipped, python3 missing)"
fi
COLUMNS=132 LINES=40 bash "$REPO/scripts/loomy-tree.sh" --root "$DW" </dev/null >"$OUT" 2>&1
has "tree auto: list when the window is too small, with a hint" "enlarge the window to 124 × 57"
hasnt "tree auto: no diagram in a small window" "LOOMY AGENT TREE"
COLUMNS=132 LINES=40 LOOMY_TREE=diagram bash "$REPO/scripts/loomy-tree.sh" --root "$DW" </dev/null >"$OUT" 2>&1
has "tree: diagram forced (tree_view diagram)" "LOOMY AGENT TREE"
COLUMNS=132 LINES=64 LOOMY_TREE=list bash "$REPO/scripts/loomy-tree.sh" --root "$DW" </dev/null >"$OUT" 2>&1
hasnt "tree: list forced (tree_view list)" "LOOMY AGENT TREE"
fails "tree_view: invalid value refused" 2 "$LOOMY" config set tree_view boxes
# Session log in watch: events arriving together scroll in one per refresh, the newest highlighted.
slq() { LOOMY_WATCH_ID="t$$" bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/sessionlog.sh"; ai_session_log "$2" 1' _ "$REPO" "$DW"; }
rm -f "${TMPDIR:-/tmp}/loomy-watch-t$$.seen"; slq >/dev/null
nowz="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","type":"delegation_start","id":"s1","pid":1,"role":"explorer","model":"m1","task":"first"}\n{"ts":"%s","type":"delegation","id":"s1","role":"explorer","model":"m1","status":"ok","duration_s":5}\n' "$nowz" "$nowz" >>"$DW/.loomy/logs/events.jsonl"
a1="$(slq)"; a2="$(slq)"
[[ "$a1" == *"start"*"first"* && "$a2" == *"done"* ]] && ok "session log: arrivals scroll in one per refresh" || ko "session log scroll: [$a1] [$a2]"
[[ "$a2" == "▸"* ]] && ok "session log: newest line highlighted" || ko "session log highlight: $a2"
rm -f "${TMPDIR:-/tmp}/loomy-watch-t$$.seen"

section "Interface language"
lang_of() {   # lang_of <environment variables…>: detected language, without LOOMY_LANG or configuration
  env -u LOOMY_LANG -u LOOMY_UI_LANG -u LC_ALL -u LC_MESSAGES -u LANG XDG_CONFIG_HOME="$WORK/cfg-lang" "$@" \
    bash -c 'source "$1/scripts/lib/i18n.sh"; echo "$LOOMY_UI_LANG"' _ "$REPO"
}
[[ "$(lang_of LANG=fr_FR.UTF-8)" == fr ]] && ok "LANG=fr_FR → French" || ko "LANG=fr_FR not detected"
[[ "$(lang_of LANG=en_US.UTF-8)" == en ]] && ok "LANG=en_US → English" || ko "LANG=en_US not detected"
[[ "$(lang_of LANG=de_DE.UTF-8)" == en ]] && ok "other language → English" || ko "de_DE should give English"
[[ "$(lang_of LC_ALL=fr_CA.UTF-8 LANG=en_US.UTF-8)" == fr ]] && ok "LC_ALL wins over LANG" || ko "LC_ALL ignored"
mkdir -p "$WORK/nouname"; printf '#!/bin/sh\necho Linux\n' >"$WORK/nouname/uname"; chmod +x "$WORK/nouname/uname"
[[ "$(lang_of LANG=C PATH="$WORK/nouname:$PATH")" == en ]] && ok "Linux without a detectable language → English" || ko "wrong Linux default"
mkdir -p "$WORK/cfg-lang/loomy"; echo "lang=fr" >"$WORK/cfg-lang/loomy/config"
[[ "$(lang_of LANG=en_US.UTF-8)" == fr ]] && ok "config lang=fr wins over the system" || ko "config lang ignored"
[[ "$(env -u LOOMY_UI_LANG LOOMY_LANG=en XDG_CONFIG_HOME="$WORK/cfg-lang" bash -c 'source "$1/scripts/lib/i18n.sh"; echo "$LOOMY_UI_LANG"' _ "$REPO")" == en ]] \
  && ok "LOOMY_LANG wins over the configuration" || ko "LOOMY_LANG ignored"
run "help in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr "$LOOMY" help
hasnt "help: no English section title left" "◇  TRACKING"
has "help: French titles" "<commande>|◇  PROJET"
run "status in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr bash "$REPO/scripts/loomy-status.sh" --root "$PROJ"
has "status: French labels" "Statut du projet"
PFR="$WORK/projet-fr"; mkdir -p "$PFR"
run "init in French" env -u LOOMY_UI_LANG LOOMY_LANG=fr "$LOOMY" init "$PFR" --yes --no-clipboard
file_has "French START.md installed" "$PFR/START.md" "BOOTSTRAP TEMPORAIRE"
file_has "French templates installed" "$PFR/.loomy/templates/AGENTS.md" "Autonomie et points d'arrêt"
file_has "French brief" "$PFR/.loomy/brief.md" "Consignes pour l'agent"
file_has "English START.md by default" "$PROJ/START.md" "TEMPORARY BOOTSTRAP"
run "compiled dictionary up to date" bash -c 'cd "$1" && tmp="$(mktemp)" && cp scripts/lib/i18n/fr.sh "$tmp" && bash tools/i18n-build.sh >/dev/null && cmp -s "$tmp" scripts/lib/i18n/fr.sh; r=$?; cp "$tmp" scripts/lib/i18n/fr.sh; rm -f "$tmp"; exit $r' _ "$REPO"
run "every interface sentence is translated" bash -c '[[ -z "$(bash "$1/tools/i18n-missing.sh")" ]]' _ "$REPO"

# ------------------------------------------------------------------ setup safeguards
section "Lead-aware delegation, project doctor, routing reminder"
SG="$WORK/garde"
run "init for the safeguards (Claude lead, ORCHESTRATED)" "$LOOMY" init "$SG" --yes --no-clipboard
SG_TPL="$WORK/_tpl-garde"; cp -R "$SG" "$SG_TPL"
fresh_init() { cp -R "$SG_TPL" "$1" && sed -i.bak "s/garde/${1##*/}/g" "$1/.loomy/brief.md" && rm -f "$1/.loomy/brief.md.bak"; }
# 1. The delegation advice depends on the lead: loomy-delegate-claude.sh is a Codex lead's bridge.
bash "$REPO/scripts/loomy-context.sh" --root "$SG" >"$OUT" 2>&1
has "context, Claude lead: native subagents" "native subagents \(\.claude/agents/<role>\.md, Agent tool"
has "context, Claude lead: only Codex goes through a bridge" "only Codex roles go through \.loomy/scripts/loomy-delegate-codex\.sh"
hasnt "context, Claude lead: no advice to use loomy-delegate-claude.sh" "loomy-delegate-claude\.sh and loomy-delegate-codex\.sh"
(cd "$SG" && bash "$REPO/scripts/loomy-delegate-claude.sh" explorer "look") >"$OUT" 2>&1
has "bridge called by a Claude lead: warning on stderr" "lead agent is Claude Code.*\.claude/agents/explorer\.md"
(cd "$SG" && LOOMY_BRIDGE_OK=1 bash "$REPO/scripts/loomy-delegate-claude.sh" explorer "look") >"$OUT" 2>&1
hasnt "bridge, LOOMY_BRIDGE_OK (audit): no warning" "lead agent is Claude Code"
SGX="$WORK/garde-codex"; fresh_init "$SGX"
sed -i.bak 's/^ai_lead: claude/ai_lead: codex/' "$SGX/.loomy/brief.md"
bash "$REPO/scripts/loomy-context.sh" --root "$SGX" >"$OUT" 2>&1
has "context, Codex lead: loomy-delegate-claude.sh kept" "loomy-delegate-claude\.sh and loomy-delegate-codex\.sh"
(cd "$SGX" && bash "$REPO/scripts/loomy-delegate-claude.sh" explorer "look") >"$OUT" 2>&1
hasnt "bridge called by a Codex lead: no warning" "lead agent is Claude Code"
for f in bootstrap/START.md fr/bootstrap/START.md templates/ORCHESTRATION.md fr/templates/ORCHESTRATION.md skills/project-bootstrap/references/orchestration.md fr/skills/project-bootstrap/references/orchestration.md; do
  grep -qE 'native subagents|sous-agents natifs' "$REPO/$f" && ok "doc advice by lead: $f" || ko "doc advice by lead: $f still gives the Codex-lead advice only"
done

# 2. doctor: a project whose bootstrap is unfinished is not "ideal". The pieces Loomy owns are removed (the partial
# setup seen on a real project: no docs, no subagents, no orchestration rule).
rm -rf "$SG/.loomy/docs" "$SG/.claude/agents"
printf '# SG\n\nRules written by the agent, without the orchestration rule.\n' >"$SG/CLAUDE.md"
run "doctor on an unfinished project" bash "$REPO/scripts/loomy-doctor.sh" --root "$SG"
has "doctor: PROJECT section" "PROJECT"
has "doctor: bootstrap unfinished" "bootstrap unfinished.*START\.md still pending"
has "doctor: .loomy/docs/ missing" "\.loomy/docs/ folder missing"
has "doctor: subagents missing, with the fix" "subagents missing in \.claude/agents/.*architect"
has "doctor: subagent fix command" "fix: \.loomy/scripts/loomy-route\.sh claude-agents"
hasnt "doctor: not ideal with a gap" "Ideal setup"
has "doctor: gaps listed in the summary" "for the ideal: .*bootstrap finished"
has "doctor: orchestration rule missing" "orchestration rule missing"
run "doctor --fix completes the project" bash "$REPO/scripts/loomy-doctor.sh" --root "$SG" --fix
has "doctor --fix: project completed" "project completed"
[[ -f "$SG/.loomy/docs/AI_MODEL_ROUTING.md" && -f "$SG/.claude/agents/architect.md" ]] && grep -q 'loomy:orchestration:start' "$SG/CLAUDE.md" \
  && ok "doctor --fix: docs, subagents and rule back" || ko "doctor --fix: project not completed"
# The bootstrap finishes: no more gap, except the hook added since (the project's settings.json is rebuilt on update).
bash "$REPO/scripts/loomy-status.sh" --root "$SG" set "done" >/dev/null; rm -f "$SG/START.md"; mkdir -p "$SG/.loomy/docs"
bash "$REPO/scripts/loomy-route.sh" --root "$SG" claude-agents >/dev/null 2>&1
run "doctor on a finished project" bash "$REPO/scripts/loomy-doctor.sh" --root "$SG"
hasnt "doctor: no bootstrap gap once finished" "bootstrap unfinished|\.loomy/docs/ folder missing|subagents missing"
has "doctor: subagents present" "Claude subagents"
has "doctor: hooks present" "Claude Code hooks"
python3 - "$SG/.claude/settings.json" <<'PY' 2>/dev/null
import json, sys
p = sys.argv[1]; d = json.load(open(p))
d["hooks"].pop("UserPromptSubmit", None)
json.dump(d, open(p, "w"))
PY
run "doctor with an older settings.json" bash "$REPO/scripts/loomy-doctor.sh" --root "$SG"
has "doctor: missing prompt hook, with the fix" "hooks missing in \.claude/settings\.json.*prompt"
rm -f "$SG/.claude/agents/explorer.md"
run "doctor with a missing subagent" bash "$REPO/scripts/loomy-doctor.sh" --root "$SG"
has "doctor: names the missing subagent" "subagents missing in \.claude/agents/.*explorer"
# Not a Loomy project: no PROJECT section.
NP="$WORK/pas-loomy"; mkdir -p "$NP"; git -C "$NP" init -q 2>/dev/null
run "doctor outside a Loomy project" bash "$REPO/scripts/loomy-doctor.sh" --root "$NP"
hasnt "doctor outside a project: no PROJECT section" "◇  PROJECT"

# SessionStart: an abandoned bootstrap is said in one line, not presented as waiting for a go-ahead.
SA="$WORK/garde-abandon"; fresh_init "$SA"
bash "$REPO/scripts/loomy-status.sh" --root "$SA" set approve >/dev/null
bash "$REPO/scripts/loomy-context.sh" --root "$SA" >"$OUT" 2>&1
has "start context: fresh bootstrap resumes normally" "Bootstrap in progress, phase 5 of 10"
hasnt "start context: fresh bootstrap is not abandoned" "Bootstrap abandoned"
sed -i.bak 's/^updated=.*/updated=2000-01-01 10:00/' "$SA/.loomy/state"
bash "$REPO/scripts/loomy-context.sh" --root "$SA" >"$OUT" 2>&1
has "start context: abandoned bootstrap" "Bootstrap abandoned: stopped at phase 5 of 10 \(Approval\) since 2000-01-01 10:00"
hasnt "start context: no more 'waits for your go-ahead'" "waits for your go-ahead"

# 3. UserPromptSubmit: light routing reminder, ORCHESTRATED projects only.
PH="bash $REPO/scripts/loomy-context.sh --hook prompt"
echo '{"prompt":"hello"}' | CLAUDE_PROJECT_DIR="$SA" $PH >"$OUT" 2>&1
has "prompt hook: unfinished setup said first" '"additionalContext":"\[Loomy\] The Loomy setup of this project is not finished.*ORCHESTRATED mode'
sed -i.bak 's/^ai_mode: ORCHESTRATED/ai_mode: SOLO/' "$SA/.loomy/brief.md"
echo '{}' | CLAUDE_PROJECT_DIR="$SA" $PH >"$OUT" 2>&1
has "prompt hook: unfinished setup said in SOLO mode too" "setup of this project is not finished"
sed -i.bak 's/^ai_mode: SOLO/ai_mode: ORCHESTRATED/' "$SA/.loomy/brief.md"
mv "$SA/START.md" "$SA/START.keep"; rm -f "$SGX/START.md"
echo '{"prompt":"hello"}' | CLAUDE_PROJECT_DIR="$SA" $PH >"$OUT" 2>&1
has "prompt hook: reminder as additionalContext" '"hookEventName":"UserPromptSubmit","additionalContext":"\[Loomy\] ORCHESTRATED mode: you are the orchestrator'
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'loomy-route.sh' in d['hookSpecificOutput']['additionalContext']" "$OUT" 2>/dev/null \
  && ok "prompt hook: valid JSON" || ko "prompt hook: invalid JSON: $(cat "$OUT")"
echo '{}' | LOOMY_PROJECT_ROOT="$SA" LOOMY_UI_LANG=fr $PH >"$OUT" 2>&1
has "prompt hook: French" "Mode ORCHESTRATED : tu es l'orchestrateur"
echo '{}' | LOOMY_DELEGATION=1 CLAUDE_PROJECT_DIR="$SA" $PH >"$OUT" 2>&1
[[ ! -s "$OUT" ]] && ok "prompt hook: silent in a bridge session" || ko "prompt hook: not silent in a bridge session"
echo '{}' | CLAUDE_PROJECT_DIR="$NP" $PH >"$OUT" 2>&1
[[ ! -s "$OUT" ]] && ok "prompt hook: silent outside a Loomy project" || ko "prompt hook: not silent outside a project"
sed -i.bak 's/^ai_mode: ORCHESTRATED/ai_mode: SOLO/' "$SA/.loomy/brief.md"
echo '{}' | CLAUDE_PROJECT_DIR="$SA" $PH >"$OUT" 2>&1
[[ ! -s "$OUT" ]] && ok "prompt hook: silent when the project isn't ORCHESTRATED" || ko "prompt hook: not silent in SOLO mode"
echo '{}' | CLAUDE_PROJECT_DIR="$SGX" $PH >"$OUT" 2>&1
[[ ! -s "$OUT" ]] && ok "prompt hook: silent with a Codex lead" || ko "prompt hook: not silent with a Codex lead"
# Light: every prompt pays for it (about 20 ms measured; 10 runs under 3 s leaves a wide margin).
t0=$SECONDS; for _ in 1 2 3 4 5 6 7 8 9 10; do echo '{}' | CLAUDE_PROJECT_DIR="$SG" $PH >/dev/null 2>&1; done
(( SECONDS - t0 < 3 )) && ok "prompt hook: light (10 runs in $(( SECONDS - t0 )) s)" || ko "prompt hook: too slow ($(( SECONDS - t0 )) s for 10 runs)"
# Project integrity: init leaves a complete setup; a .ai/ project (before 0.9) is migrated; the repair is idempotent.
SI="$WORK/integrite"; fresh_init "$SI"
[[ -f "$SI/.loomy/docs/AI_WORKFLOW.md" && -f "$SI/.loomy/docs/AI_ORCHESTRATION.md" && -f "$SI/.loomy/docs/AI_MODEL_ROUTING.md" ]] \
  && ok "init: routing documents created by Loomy" || ko "init: routing documents missing"
[[ -f "$SI/.claude/agents/architect.md" ]] && ok "init: role subagents created by Loomy" || ko "init: subagents missing"
for f in templates/CLAUDE.md templates/AGENTS.md fr/templates/CLAUDE.md fr/templates/AGENTS.md; do
  grep -q 'loomy:orchestration:start' "$REPO/$f" && ok "template carries the orchestration rule: $f" || ko "orchestration rule missing from $f"
done
# The agent writes CLAUDE.md without the rule (what happened on a real project): the next start puts it back.
printf '# SI\n\nProject rules.\n' >"$SI/CLAUDE.md"
bash "$REPO/scripts/loomy-context.sh" --root "$SI" >/dev/null 2>&1
grep -q 'Every request in this project' "$SI/CLAUDE.md" && ok "repair: orchestration rule added to CLAUDE.md" || ko "repair: orchestration rule not added"
[[ "$(sed -n 1p "$SI/CLAUDE.md")" == "# SI" ]] && grep -q 'Project rules.' "$SI/CLAUDE.md" && ok "repair: the agent's text kept" || ko "repair: CLAUDE.md damaged"
[[ ! -e "$SI/.ai" ]] && ok "init: no .ai/ folder" || ko "init: .ai/ still created"
mv "$SI/.loomy/docs" "$SI/.ai"; echo "See .ai/AI_WORKFLOW.md and docs/.ai/x." >>"$SI/CLAUDE.md"
echo "custom" >"$SI/.claude/agents/explorer.md"
bash "$REPO/scripts/loomy-context.sh" --root "$SI" >"$OUT" 2>&1
[[ -d "$SI/.loomy/docs" && ! -e "$SI/.ai" ]] && ok "migration: .ai/ moved to .loomy/docs/" || ko "migration: .ai/ not moved"
grep -q 'See .loomy/docs/AI_WORKFLOW.md and docs/.ai/x.' "$SI/CLAUDE.md" && ok "migration: references updated, other paths kept" || ko "migration: references: $(grep 'See ' "$SI/CLAUDE.md")"
has "migration: said in the start context" "Loomy has just completed this project's setup files: .*\.ai/ → \.loomy/docs/"
[[ "$(cat "$SI/.claude/agents/explorer.md")" == custom ]] && ok "repair: customised subagent kept" || ko "repair: subagent overwritten"
# A subagent written by an older routing (model and effort lines only) follows the current one; a hand-set model stays.
cur="$(sed -n 's/^model: //p' "$SI/.claude/agents/documenter.md")"
sed -i.bak -e 's/^model: .*/model: claude-sonnet-5/' -e 's/^effort: .*/effort: max/' "$SI/.claude/agents/documenter.md"
sed -i.bak 's/^model: .*/model: opus/' "$SI/.claude/agents/architect.md"; rm -f "$SI"/.claude/agents/*.bak
bash "$REPO/scripts/loomy-context.sh" --root "$SI" >"$OUT" 2>&1
[[ "$(sed -n 's/^model: //p' "$SI/.claude/agents/documenter.md")" == "$cur" ]] && ! grep -q '^effort: max' "$SI/.claude/agents/documenter.md" && ok "repair: untouched subagent moved to the current routing" || ko "repair: subagent not refreshed ($(grep -E '^(model|effort):' "$SI/.claude/agents/documenter.md" | tr '\n' ' '))"
grep -q '^model: opus$' "$SI/.claude/agents/architect.md" && ok "repair: hand-set subagent model kept" || ko "repair: hand-set model overwritten"
[[ "$(cat "$SI/.claude/agents/explorer.md")" == custom ]] && ok "repair: customised subagent still kept" || ko "repair: customised subagent overwritten later"
cp "$SI/CLAUDE.md" "$WORK/claude-avant.md"
bash "$REPO/scripts/loomy-context.sh" --root "$SI" >"$OUT" 2>&1
cmp -s "$SI/CLAUDE.md" "$WORK/claude-avant.md" && ok "repair: idempotent" || ko "repair: CLAUDE.md changed on a second run"
hasnt "repair: nothing to say the second time" "Loomy has just completed"
[[ "$(grep -c 'loomy:orchestration:start' "$SI/CLAUDE.md")" == 1 ]] && ok "repair: a single managed block" || ko "repair: block duplicated"
LOOMY_NO_REPAIR=1 bash "$REPO/scripts/loomy-context.sh" --root "$SI" >/dev/null 2>&1; ok "repair: LOOMY_NO_REPAIR accepted"

# Scripts renamed loomy-* (0.10): a project with the old relays and hooks is migrated, the old relays removed.
SR="$WORK/renommage"; fresh_init "$SR"
[[ -x "$SR/.loomy/scripts/loomy-route.sh" && ! -e "$SR/.loomy/scripts/ai-route.sh" ]] && ok "new project: loomy-* relays only" || ko "new project: relays $(ls "$SR/.loomy/scripts" | head -3 | tr '\n' ' ')"
for f in "$SR"/.loomy/scripts/loomy-*.sh; do n="$(basename "$f")"; o="ai-${n#loomy-}"
  case "$n" in loomy-delegate-codex.sh) o=delegate-to-codex.sh ;; loomy-delegate-claude.sh) o=delegate-to-claude.sh ;; esac
  sed "s/$n/$o/g" "$f" >"$SR/.loomy/scripts/$o"; chmod +x "$SR/.loomy/scripts/$o"; rm -f "$f"; done
sed -i.bak 's/loomy-context\.sh/ai-context.sh/g; s/loomy-statusline\.sh/ai-statusline.sh/g' "$SR/.claude/settings.json"
printf '# SR\n\nRoute with .loomy/scripts/ai-route.sh; Codex through .loomy/scripts/delegate-to-codex.sh or delegate-to-<tool>.sh. Keep my-ai-route.sh.\n' >"$SR/CLAUDE.md"
echo "local work" >"$SR/.loomy/scripts/ai-mine.sh"
printf '#!/usr/bin/env bash\n# Loomy relay: runs ai-log.sh from the installed Loomy (see _loomy.sh).\necho customised\n' >"$SR/.loomy/scripts/ai-log.sh"
bash "$REPO/scripts/loomy-context.sh" --root "$SR" >"$OUT" 2>&1
has "rename: said in the start context" "Loomy has just completed this project's setup files: .*scripts → loomy-\*"
[[ -x "$SR/.loomy/scripts/loomy-route.sh" && ! -e "$SR/.loomy/scripts/ai-route.sh" && ! -e "$SR/.loomy/scripts/delegate-to-codex.sh" ]] && ok "rename: new relays added, old relays removed" || ko "rename: relays $(ls "$SR/.loomy/scripts" | tr '\n' ' ')"
[[ -f "$SR/.loomy/scripts/ai-mine.sh" ]] && ok "rename: a script of the project with an old-looking name is kept" || ko "rename: project script removed"
[[ -f "$SR/.loomy/scripts/ai-log.sh" ]] && ok "rename: a customised relay is kept" || ko "rename: customised relay removed"
grep -q 'loomy-context.sh." --hook start' "$SR/.claude/settings.json" && ! grep -q 'ai-context.sh' "$SR/.claude/settings.json" && ok "rename: hooks rewritten" || ko "rename: hooks: $(grep -o 'scripts/[a-z-]*' "$SR/.claude/settings.json" | sort -u | tr '\n' ' ')"
printf 'Other: vendor/ai-review.sh and .loomy/scripts/ai-review.sh.bak stay.\n' >>"$SR/CLAUDE.md"; rm -f "$SR/.loomy/scripts/loomy-route.sh"
bash "$REPO/scripts/loomy-context.sh" --root "$SR" >/dev/null 2>&1
grep -q 'Other: vendor/ai-review.sh and .loomy/scripts/ai-review.sh.bak stay.' "$SR/CLAUDE.md" && ok "rename: other paths and suffixes untouched" || ko "rename: $(grep 'Other:' "$SR/CLAUDE.md")"
grep -q 'Route with .loomy/scripts/loomy-route.sh; Codex through .loomy/scripts/loomy-delegate-codex.sh or loomy-delegate-<tool>.sh. Keep my-ai-route.sh.' "$SR/CLAUDE.md" && ok "rename: references updated, other names kept" || ko "rename: $(grep 'Route with' "$SR/CLAUDE.md")"
cp "$SR/CLAUDE.md" "$WORK/sr-avant.md"; bash "$SR/.loomy/scripts/loomy-context.sh" --root "$SR" >"$OUT" 2>&1
cmp -s "$SR/CLAUDE.md" "$WORK/sr-avant.md" && ok "rename: idempotent" || ko "rename: CLAUDE.md changed again"
hasnt "rename: nothing to say the second time" "scripts → loomy-"
others=""; for f in "$REPO"/scripts/*.sh; do case "${f##*/}" in loomy-*) ;; *) others="$others ${f##*/}" ;; esac; done
[[ -z "$others" ]] && ok "every script is named loomy-*" || ko "scripts not named loomy-*:$others"

# Shared memory (.loomy/memory/): results of the delegations, work state, given back at the start of every session.
SM="$WORK/memoire"; fresh_init "$SM"
printf '# Work state\n\n## Done\n- importer written\n\n## In progress\n\n## Decisions\n- DuckDB on Parquet\n' >"$SM/.loomy/memory/STATE.md.new"
[[ -f "$SM/.loomy/memory/STATE.md" ]] && ok "memory: STATE.md created at init" || ko "memory: STATE.md missing"
grep -qxF '.loomy/memory/' "$SM/.gitignore" && ok "memory: shared state and delegation results kept out of Git" || ko "memory: .gitignore $(cat "$SM/.gitignore" | tr '\n' ' ')"
(cd "$SM" && bash "$SM/.loomy/scripts/loomy-delegate-codex.sh" executor "Write the importer") >/dev/null 2>&1
MF="$(ls "$SM"/.loomy/memory/delegations/*-executor-*.md 2>/dev/null | head -1)"
[[ -n "$MF" ]] && grep -q 'Write the importer' "$MF" && grep -q 'SUMMARY: answer from the codex double' "$MF" && ok "memory: Codex bridge result saved with its task" || ko "memory: bridge result not saved ($(ls "$SM/.loomy/memory/delegations" 2>&1))"
printf '%s\n' '{"type":"user","message":{"role":"user","content":"Map the CSV schemas"}}' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"STATUS: done\nSUMMARY: three CSV files, one key\nNEXT: load them"}]}}' >"$WORK/sub.jsonl"
printf '{"agent_id":"a1","agent_type":"explorer","agent_transcript_path":"%s","transcript_path":"%s"}' "$WORK/sub.jsonl" "$WORK/sub.jsonl" \
  | CLAUDE_PROJECT_DIR="$SM" bash "$SM/.loomy/scripts/loomy-context.sh" --hook subagent >/dev/null 2>&1
MS="$(ls "$SM"/.loomy/memory/delegations/*-explorer-*.md 2>/dev/null | head -1)"
[[ -n "$MS" ]] && grep -q 'Map the CSV schemas' "$MS" && grep -q 'three CSV files, one key' "$MS" && ok "memory: native subagent result saved from its transcript" || ko "memory: subagent result not saved"
[[ -f "$SM/.loomy/memory/STATE.md" ]] && ok "memory: STATE.md present" || ko "memory: STATE.md lost"
mv "$SM/.loomy/memory/STATE.md.new" "$SM/.loomy/memory/STATE.md"; touch -t 202601010000 "$SM/.loomy/memory/STATE.md"
bash "$SM/.loomy/scripts/loomy-context.sh" --root "$SM" >"$OUT" 2>&1
has "memory: work state given at session start" "Work state \(.loomy/memory/STATE.md"
has "memory: decisions in the context" "DuckDB on Parquet"
hasnt "memory: empty sections left out" "## In progress"
has "memory: latest results in short" "explorer · subagent · ok · .*three CSV files, one key · next: load them"
has "memory: Codex result in short" "executor · .* · ok · .*answer from the codex double · next: finish it"
# Cost: the block is bounded, absent when a session is resumed, and results already taken into STATE.md are not repeated.
python3 - "$OUT" <<'PY2' && ok "memory: block bounded (under 3,000 characters)" || ko "memory: block too large"
import sys, re
t = open(sys.argv[1], encoding="utf-8").read()
i = t.find("Work state (.loomy"); j = t.find("\n- ", t.find("Latest delegation results") + 5)
sys.exit(0 if 0 <= i and len(t[i:j if j > 0 else None]) < 3000 else 1)
PY2
echo '{"session_id":"r1","source":"resume"}' | bash "$SM/.loomy/scripts/loomy-context.sh" --root "$SM" --hook start --tool claude >"$OUT" 2>&1
hasnt "memory: nothing added when a session is resumed" "Work state \(.loomy|Latest delegation results"
touch "$SM/.loomy/memory/STATE.md"
bash "$SM/.loomy/scripts/loomy-context.sh" --root "$SM" >"$OUT" 2>&1
hasnt "memory: results already in STATE.md not repeated" "Latest delegation results"
has "memory: work state still given" "DuckDB on Parquet"
"$LOOMY" config set memory off >/dev/null 2>&1; bash "$SM/.loomy/scripts/loomy-context.sh" --root "$SM" >"$OUT" 2>&1; "$LOOMY" config set memory on >/dev/null 2>&1
hasnt "memory: memory off, nothing given" "Work state \(.loomy"
echo '{"session_id":"s1","source":"startup"}' | bash "$SM/.loomy/scripts/loomy-context.sh" --root "$SM" --hook start --tool claude >/dev/null 2>&1
echo '{"session_id":"s2","source":"startup"}' | bash "$SM/.loomy/scripts/loomy-context.sh" --root "$SM" --hook start --tool codex >"$OUT" 2>&1
has "memory: switching tool, picks up from the memory" "previous session ran in Claude Code"
echo '{"session_id":"s3","source":"compact"}' | bash "$SM/.loomy/scripts/loomy-context.sh" --root "$SM" --hook start --tool codex >"$OUT" 2>&1
has "memory: given back after a compaction" "DuckDB on Parquet"
hasnt "memory: same tool, no switch notice" "previous session ran in"
run "loomy memory" bash -c "cd '$SM' && '$LOOMY' memory"
has "loomy memory: work state and results" "SHARED MEMORY"
has "loomy memory: result listed" "three CSV files"
run "loomy memory show" bash -c "cd '$SM' && '$LOOMY' memory show"
has "loomy memory show: full text of the latest" "Map the CSV schemas"
for i in 1 2 3; do LOOMY_MEMORY_KEEP=2 bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/memory.sh"; loomy_memory_save "$2" "p$3" reviewer m ok task result; [ "$3" = 3 ] && sleep 1' _ "$REPO" "$SM" "$i"; done
[[ "$(ls "$SM/.loomy/memory/delegations" | wc -l | tr -d ' ')" == 2 ]] && ok "memory: oldest results pruned" || ko "memory: pruning ($(ls "$SM/.loomy/memory/delegations" | wc -l))"
# Robustness (cross review): odd roles, invalid retention, symbolic links, lowercase fields, ranks, sessions by tool.
mem() { bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/memory.sh"; shift; "$@"' _ "$REPO" "$@"; }
LOOMY_MEMORY_KEEP=abc mem loomy_memory_save "$SM" i1 "my/role x" m ok "task" $'summary: lower case\nchecks: passed\nnext: go on'
[[ $? -eq 0 ]] && ok "memory: invalid retention value does not stop the caller" || ko "memory: save failed"
mem loomy_memory_digest "$SM" 1 >"$OUT" 2>&1
has "memory: odd role saved under a clean name" "my-role-x"
has "memory: lowercase fields read, next one not swallowed" ": lower case · next: go on"
mkdir -p "$WORK/ailleurs"; for i in 1 2 3; do echo x >"$WORK/ailleurs/$i.md"; done
SL="$WORK/memlien"; mkdir -p "$SL/.loomy/memory"; ln -s "$WORK/ailleurs" "$SL/.loomy/memory/delegations"
LOOMY_MEMORY_KEEP=1 mem loomy_memory_save "$SL" i2 role m ok task result
[[ "$(ls "$WORK/ailleurs" | wc -l | tr -d ' ')" == 3 ]] && ok "memory: never writes or prunes through a symbolic link" || ko "memory: files touched through the link"
(cd "$SM" && "$LOOMY" memory show 999) >"$OUT" 2>&1
has "loomy memory show: out of range refused" "choose N from 1 to"
SW="$WORK/memoutil"; fresh_init "$SW"; JW="$SW/.loomy/logs/events.jsonl"; mkdir -p "$(dirname "$JW")"
printf '%s\n' '{"ts":"2026-10-01T08:00:00Z","type":"session","event":"start","tool":"claude"}' "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"type\":\"session\",\"event\":\"start\",\"tool\":\"codex\",\"pid\":1}" >>"$JW"
echo '{"source":"startup"}' | bash "$SW/.loomy/scripts/loomy-context.sh" --root "$SW" --hook start --tool codex >"$OUT" 2>&1
has "memory: Codex after Claude (launcher + hook events), switch seen" "previous session ran in Claude Code"
printf '%s\n' '{"ts":"2026-10-01T08:00:00Z","type":"session","event":"start","tool":"claude"}' '{"ts":"2026-10-02T09:00:00Z","type":"session","event":"start","tool":"codex","pid":2}' >"$JW"
echo '{"source":"startup"}' | bash "$SW/.loomy/scripts/loomy-context.sh" --root "$SW" --hook start --tool codex >"$OUT" 2>&1
hasnt "memory: a later Codex session, no switch notice" "previous session ran in"
bash "$SW/.loomy/scripts/loomy-context.sh" --root "$SW" >"$OUT" 2>&1
hasnt "memory: no switch notice outside the start hook" "previous session ran in"
grep -q 'loomy/memory/STATE.md' "$SM/CLAUDE.md" 2>/dev/null || grep -q 'loomy/memory/STATE.md' "$REPO/templates/CLAUDE.md" && ok "memory: the lead agent is told to keep STATE.md" || ko "memory: no instruction for STATE.md"

# Launch: status line segment, reminder when tracking isn't open, shell hook, opening in the desktop app.
SL2="$WORK/lancement"; fresh_init "$SL2"
printf '{"ts":"2026-10-06T10:00:00Z","type":"delegation_start","id":"d1","pid":%s,"role":"executor"}\n{"ts":"2026-10-06T10:00:00Z","type":"delegation_start","id":"d2","pid":999999,"role":"explorer"}\n' "$$" >>"$SL2/.loomy/logs/events.jsonl"
echo '{"model":{"display_name":"Opus 5.5"}}' | LOOMY_PROJECT_ROOT="$SL2" bash "$SL2/.loomy/scripts/loomy-statusline.sh" >"$OUT" 2>&1
has "status line: phase and running delegations" "^Loomy discover · ⟳ 1 · Opus 5.5"
mkdir -p "$XDG_CONFIG_HOME/loomy"; echo 'echo MY-LINE' >"$XDG_CONFIG_HOME/loomy/statusline-user"
echo '{}' | LOOMY_PROJECT_ROOT="$SL2" bash "$SL2/.loomy/scripts/loomy-statusline.sh" >"$OUT" 2>&1; rm -f "$XDG_CONFIG_HOME/loomy/statusline-user"
has "status line: Loomy segment after the user's own line" "^MY-LINE · Loomy discover · ⟳ 1$"
echo '{"source":"startup"}' | bash "$SL2/.loomy/scripts/loomy-context.sh" --root "$SL2" --hook start >"$OUT" 2>&1
has "start: reminder when live tracking isn't open" "Live tracking is not open for this project"
echo '{"source":"resume"}' | bash "$SL2/.loomy/scripts/loomy-context.sh" --root "$SL2" --hook start >"$OUT" 2>&1
hasnt "start: no reminder when a session is resumed" "Live tracking is not open"
echo '{"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1}}}' | LC_ALL=fr_FR.UTF-8 LOOMY_PROJECT_ROOT="$SL2" bash "$SL2/.loomy/scripts/loomy-statusline.sh" >"$OUT" 2>&1
has "status line: decimal quota read whatever the locale" "5h 13%"
mkdir -p "$XDG_CONFIG_HOME/loomy"; echo 'sleep 5; echo SLOW' >"$XDG_CONFIG_HOME/loomy/statusline-user"
t0=$SECONDS; echo '{}' | LOOMY_PROJECT_ROOT="$SL2" bash "$SL2/.loomy/scripts/loomy-statusline.sh" >"$OUT" 2>&1; rm -f "$XDG_CONFIG_HOME/loomy/statusline-user"
(( SECONDS - t0 < 4 )) && ok "status line: a slow user line doesn't block it" || ko "status line: blocked $(( SECONDS - t0 )) s"
RCB="$WORK/zshrc-broken"; printf 'export A=1\n# >>> loomy shell hook (loomy shell-hook remove to take it out) >>>\nexport KEEP=1\n' >"$RCB"
LOOMY_SHELL_RC="$RCB" "$LOOMY" shell-hook remove >/dev/null 2>&1
grep -q 'export KEEP=1' "$RCB" && ok "shell hook: end marker missing, nothing cut" || ko "shell hook: rc file cut"
RCF="$WORK/zshrc-test"; printf 'export A=1\n' >"$RCF"
LOOMY_SHELL_RC="$RCF" "$LOOMY" shell-hook install >"$OUT" 2>&1
grep -q '^function claude {' "$RCF" && grep -q 'export A=1' "$RCF" && ok "shell hook: installed, the file kept" || ko "shell hook: install ($(cat "$RCF"))"
LOOMY_SHELL_RC="$RCF" "$LOOMY" shell-hook install >/dev/null 2>&1
[[ "$(grep -c 'loomy shell hook (loomy' "$RCF")" == 1 ]] && ok "shell hook: installed once" || ko "shell hook: duplicated"
HB="$(sed -n '/^function _loomy_lead/,/^# <<< loomy shell hook/p' "$RCF")"
printf '#!/bin/sh\necho loomy-called "$@"\n' >"$WORK/stubbin-loomy"; mkdir -p "$WORK/hookbin"; cp "$WORK/stubbin-loomy" "$WORK/hookbin/loomy"; chmod +x "$WORK/hookbin/loomy"
printf '#!/bin/sh\necho real-claude "$@"\n' >"$WORK/hookbin/claude"; chmod +x "$WORK/hookbin/claude"
got1="$(cd "$SL2" && PATH="$WORK/hookbin:$PATH" bash -c "$HB"$'\n''claude')"
got2="$(cd "$SL2" && PATH="$WORK/hookbin:$PATH" bash -c "$HB"$'\n''claude --version')"
got3="$(cd "$WORK" && PATH="$WORK/hookbin:$PATH" bash -c "$HB"$'\n''claude')"
[[ "$got1" == "loomy-called start" && "$got2" == "real-claude --version" && "$got3" == "real-claude" ]] && ok "shell hook: claude alone in a project goes through loomy start, anything else unchanged" || ko "shell hook: '$got1' '$got2' '$got3'"
LOOMY_SHELL_RC="$RCF" "$LOOMY" shell-hook remove >/dev/null 2>&1
! grep -q 'function claude' "$RCF" && grep -q 'export A=1' "$RCF" && ok "shell hook: removed, the file kept" || ko "shell hook: remove ($(cat "$RCF"))"
if [[ "$(uname -s)" == Darwin ]]; then
  mkdir -p "$WORK/openbin"; printf '#!/bin/sh\n[ "$1" = "-Ra" ] && exit 0\necho "$@" >>"%s"\n' "$WORK/open.log" >"$WORK/openbin/open"; chmod +x "$WORK/openbin/open"
  (cd "$SL2" && PATH="$WORK/openbin:$PATH" bash "$SL2/.loomy/scripts/loomy-start.sh" --app) >"$OUT" 2>&1
  grep -q '^claude://code/new?folder=.*lancement&q=' "$WORK/open.log" 2>/dev/null && ok "start --app: Claude app opened on the project folder with the prompt" || ko "start --app: $(cat "$WORK/open.log" 2>&1)"
  has "start --app: model and effort to pick" "pick model claude-"
fi

# Official skills: chosen from the brief, installed (analysed) at init, suggested by task, out of Git, lock, sync, updates.
skf() { bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/config.sh"; source "$1/scripts/lib/journal.sh"; source "$1/scripts/lib/skills.sh"; shift; "$@"' _ "$REPO" "$@"; }
grep -v '^#' "$REPO/catalog/skills.conf" | grep -v '^date=' | awk -F'|' 'NF != 8 || $4 !~ /^[0-9a-f]{40}$/ || ($2 != "anthropic" && $2 != "openai") { bad = 1 } END { exit bad }' \
  && ok "skills catalog: well formed, official sources only, pinned commits" || ko "skills catalog: malformed line"
printf -- '---\nname: "SK"\nrepo: new\ntype: web\ntraits: "auth,payments"\ndetail1: vercel\n---\n' >"$WORK/sk-answers.md"
SKP="$WORK/skills-web"; "$LOOMY" init "$SKP" --answers "$WORK/sk-answers.md" --yes --no-clipboard >"$OUT" 2>&1
cp -R "$SKP" "$WORK/_tpl-skills"
[[ "$(skf skills_auto_for "$SKP" | tr '\n' ' ')" == "webapp-testing frontend-design security-best-practices security-threat-model vercel-deploy " ]] \
  && ok "skills: chosen from type, characteristics and hosting" || ko "skills auto: $(skf skills_auto_for "$SKP" | tr '\n' ' ')"
has "init: official skills step" "Official skills"
[[ -f "$SKP/.claude/skills/webapp-testing/SKILL.md" && -f "$SKP/.agents/skills/webapp-testing/SKILL.md" ]] && ok "skills: installed for Claude and Codex (orchestrated)" || ko "skills: not installed"
grep -q '^webapp-testing|anthropic|skills/webapp-testing|[0-9a-f]\{40\}|Apache-2.0|' "$SKP/.loomy/skills.lock" && ok "skills: lock with source, commit and licence" || ko "skills lock: $(cat "$SKP/.loomy/skills.lock" 2>&1)"
grep -q 'webapp-testing|.*1 script(s) · network no · deletes files no · runs commands yes' "$SKP/.loomy/skills.lock" && ok "skills: analysed before installation" || ko "skills: analysis missing"
grep -qxF '/.claude/skills/webapp-testing/' "$SKP/.gitignore" && ok "skills: folders kept out of Git (licences)" || ko "skills: not in .gitignore"
grep -q '"type":"skill","event":"added","name":"webapp-testing"' "$SKP/.loomy/logs/events.jsonl" && ok "skills: each installation logged (watch, tree)" || ko "skills: not logged"
bash "$SKP/.loomy/scripts/loomy-context.sh" --root "$SKP" >"$OUT" 2>&1
has "skills: named in the session context" "Official skills installed .*webapp-testing"
(cd "$SKP" && "$LOOMY" skills) >"$OUT" 2>&1
has "loomy skills: list with the reason" "webapp-testing .*project web"
(cd "$SKP" && "$LOOMY" skills suggest "fix the failing GitHub Actions checks") >"$OUT" 2>&1
has "loomy skills suggest: from the task text" "^gh-fix-ci"
(cd "$SKP" && "$LOOMY" task "Add end-to-end tests of sign-in with Playwright" --print) >"$OUT" 2>&1
has "loomy task: skill added for the task, announced" "Skill added.*playwright"
grep -q 'Official skills added for this task.*playwright' "$SKP/.loomy/task-prompt.txt" && ok "loomy task: the lead agent is told" || ko "loomy task: prompt without the skill"
skf skills_install "$SKP" sentry "test" >/dev/null 2>&1; [[ ! -d "$SKP/.claude/skills/sentry" ]] && ok "skills: one asking for secrets is not installed on its own" || ko "skills: secrets skill installed"
(cd "$SKP" && "$LOOMY" skills add sentry) >"$OUT" 2>&1; [[ -d "$SKP/.claude/skills/sentry" ]] && ok "skills: added by the user on request" || ko "skills add: $(cat "$OUT")"
rm -rf "$SKP/.claude/skills/frontend-design" "$SKP/.agents/skills/frontend-design"
(cd "$SKP" && "$LOOMY" skills sync) >/dev/null 2>&1; [[ -f "$SKP/.claude/skills/frontend-design/SKILL.md" ]] && ok "skills sync: missing ones installed again from the lock" || ko "skills sync"
sed -i.bak 's/^\(vercel-deploy|openai|[^|]*|\)[0-9a-f]*/\1aaaaaaa/' "$SKP/.loomy/skills.lock"
[[ "$(skf skills_updates "$SKP")" == vercel-deploy\ aaaaaaa→* ]] && ok "skills: updates detected against the catalog" || ko "skills updates: $(skf skills_updates "$SKP")"
(cd "$SKP" && "$LOOMY" skills remove sentry) >/dev/null 2>&1; [[ ! -d "$SKP/.claude/skills/sentry" ]] && ! grep -q '^sentry|' "$SKP/.loomy/skills.lock" && ok "skills remove" || ko "skills remove"
# Safety (cross review): names never paths, symbolic links refused, whole-word keywords, proprietary only on request.
mkdir -p "$WORK/victime"; echo keep >"$WORK/victime/f"
(cd "$SKP" && "$LOOMY" skills remove ../../victime) >/dev/null 2>&1; [[ -f "$WORK/victime/f" ]] && ok "skills remove: a path is refused" || ko "skills remove deleted outside the project"
SKL="$WORK/skills-lien"; cp -R "$WORK/_tpl-skills" "$SKL"
rm -rf "$SKL/.claude/skills"; mkdir -p "$WORK/dehors"; ln -s "$WORK/dehors" "$SKL/.claude/skills"
skf skills_install "$SKL" frontend-design "test" force >/dev/null 2>&1; [[ -z "$(ls "$WORK/dehors")" ]] && ok "skills: never written through a symbolic link" || ko "skills: written through a link"
[[ -z "$(skf skills_suggest "$WORK/aucun" "Fix the build and improve precision of the crossword solver" 3 2>/dev/null)" ]] && ok "skills suggest: whole words only (build, precision, crossword)" || ko "skills suggest: $(skf skills_suggest "$SKP" "Fix the build and improve precision of the crossword solver" 3)"
skf skills_install "$SKP" xlsx "auto" >/dev/null 2>&1; [[ ! -d "$SKP/.claude/skills/xlsx" ]] && ok "skills: proprietary licence never installed on its own" || ko "skills: proprietary installed"
(cd "$SKP" && "$LOOMY" skills add xlsx) >/dev/null 2>&1; [[ -d "$SKP/.claude/skills/xlsx" && ! -d "$SKP/.agents/skills/xlsx" ]] && ok "skills: proprietary on request, for Claude only" || ko "skills: proprietary add"
"$LOOMY" config set skills off >/dev/null 2>&1
SKO="$WORK/skills-off"; "$LOOMY" init "$SKO" --answers "$WORK/sk-answers.md" --yes --no-clipboard >/dev/null 2>&1
[[ ! -d "$SKO/.claude/skills" ]] && ok "skills off: nothing installed" || ko "skills off: installed anyway"
"$LOOMY" config set skills auto >/dev/null 2>&1

# Tester feedback: follow-up (list, fixed notice), maintainer triage, mark and close; nothing posted without approval.
FBD="$WORK/fb"; mkdir -p "$FBD"; FBL="$WORK/gh-calls.log"; : >"$FBL"
printf '%s\n' '12|OPEN|feedback,fixed-in:0.1.0|Feedback: watch is slow' '13|OPEN|feedback,triaged|Feedback: an idea' '14|CLOSED||Feedback: old one' >"$FBD/list.txt"
GH_STUB_ISSUES="$FBD/list.txt" bash "$REPO/scripts/loomy-feedback.sh" list >"$OUT" 2>&1
has "feedback list: fixed, with the version" "#12 .*watch is slow · fixed in 0.1.0 .*you have it"
has "feedback list: being handled" "#13 .*an idea · being handled"
has "feedback list: closed" "#14 .*closed"
rm -f "$XDG_CONFIG_HOME/loomy/feedback-seen" "$XDG_CONFIG_HOME/loomy/feedback-fixed"
GH_STUB_ISSUES="$FBD/list.txt" bash "$REPO/scripts/loomy-feedback.sh" --check-fixed >/dev/null 2>&1
grep -q '#12 watch is slow' "$XDG_CONFIG_HOME/loomy/feedback-fixed" 2>/dev/null && ok "feedback: fixed in the installed version, noted for the next launch" || ko "feedback: fixed notice missing"
GH_STUB_ISSUES="$FBD/list.txt" bash "$REPO/scripts/loomy-feedback.sh" --check-fixed >/dev/null 2>&1; rm -f "$XDG_CONFIG_HOME/loomy/feedback-fixed"
GH_STUB_ISSUES="$FBD/list.txt" bash "$REPO/scripts/loomy-feedback.sh" --check-fixed >/dev/null 2>&1
[[ ! -s "$XDG_CONFIG_HOME/loomy/feedback-fixed" ]] && ok "feedback: each fix announced once" || ko "feedback: announced again"
GH_STUB_PUSH=false bash "$REPO/scripts/loomy-feedback.sh" triage >"$OUT" 2>&1
has "feedback triage: maintainers only" "Maintainers only"
printf '21\tFeedback: watch freezes\twatch freezes after a while\n22\tFeedback: tree too wide\tthe tree overflows\n' >"$FBD/triage.txt"
STUB_LOG="$FBL" GH_STUB_ISSUES="$FBD/triage.txt" LOOMY_TRIAGE_AI=none bash "$REPO/scripts/loomy-feedback.sh" triage >"$OUT" 2>&1
has "feedback triage: issues counted" "2 open, not triaged"
has "feedback triage: report written" "triage-[0-9-]*\.md"
grep -qE 'issue (comment|edit|close)' "$FBL" && ko "feedback triage: posted without approval" || ok "feedback triage: nothing posted without approval"
# In a terminal, each reply waits for a choice: here "Skip", then "Stop" (the issue rows don't take the keyboard).
if command -v expect >/dev/null 2>&1; then
  cat >"$WORK/triage.exp" <<EXP
set timeout 20
spawn env GH_STUB_ISSUES=$FBD/triage.txt LOOMY_TRIAGE_AI=none STUB_LOG=$FBL bash $REPO/scripts/loomy-feedback.sh triage
expect "What to do with #21" ; expect "⏎ confirm" ; send "\033\[B" ; after 150 ; send "\033\[B" ; after 150 ; send "\033\[B" ; after 150 ; send "\r"
expect "What to do with #22" ; expect "⏎ confirm" ; send "\033\[B" ; after 150 ; send "\033\[B" ; after 150 ; send "\033\[B" ; after 150 ; send "\033\[B" ; after 150 ; send "\r"
expect eof
EXP
  : >"$FBL"; expect "$WORK/triage.exp" >"$OUT" 2>&1
  has "feedback triage: asks for each issue in a terminal" "What to do with #22"
  grep -qE 'issue	(comment|edit)' "$FBL" && ko "feedback triage: posted although skipped" || ok "feedback triage: skipped and stopped, nothing posted"
fi
STUB_LOG="$FBL" bash "$REPO/scripts/loomy-feedback.sh" mark 21 0.12.1 >"$OUT" 2>&1
grep -q 'issue	edit	21	.*fixed-in:0.12.1' "$FBL" && ok "feedback mark: label fixed-in:<version>" || ko "feedback mark: $(tail -2 "$FBL")"
printf '21|OPEN|fixed-in:0.12.1|Feedback: watch freezes\n' >"$FBD/close.txt"
STUB_LOG="$FBL" GH_STUB_ISSUES="$FBD/close.txt" bash "$REPO/scripts/loomy-feedback.sh" close 0.12.1 >"$OUT" 2>&1
grep -q 'issue	close' "$FBL" && ko "feedback close: closed without approval" || ok "feedback close: asks first"
STUB_LOG="$FBL" GH_STUB_ISSUES="$FBD/close.txt" LOOMY_FEEDBACK_YES=1 bash "$REPO/scripts/loomy-feedback.sh" close 0.12.1 >"$OUT" 2>&1
grep -q 'issue	close	21	.*Fixed in Loomy 0.12.1' "$FBL" && ok "feedback close: commented and closed once approved" || ko "feedback close: $(tail -2 "$FBL")"
grep -q 'loomy feedback --print' "$REPO/templates/CLAUDE.md" && ok "feedback: the lead agent prepares Loomy feedback, never sends it" || ko "feedback: no instruction for the lead agent"

# Logo cursor: the README's profile (lit, fading, off over 1.1 s), independent of the seconds.
got="$(TERM=xterm-256color LOOMY_FORCE_COLOR=1 bash -c 'source "$1/scripts/lib/ui.sh"; for ms in 0 300 400 550 700 800 1099 1100 1650; do _ui_cursor_level $ms; printf "%s " "$UI_CL"; done' _ "$REPO")"
[[ "$got" == "0 0 0 2 4 5 5 0 2 " ]] && ok "logo cursor: lit, progressive fade, off, every 1.1 s" || ko "logo cursor levels: $got"

# Installed in a new project, completed (once) in an existing one, user hooks kept.
file_has "UserPromptSubmit hook installed in a new project" "$SGX/.claude/settings.json" '"UserPromptSubmit"'
SU="$WORK/garde-update"; mkdir -p "$SU/.claude"
printf '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"echo perso"}]}]}}\n' >"$SU/.claude/settings.json"
"$LOOMY" init "$SU" --yes --no-clipboard >/dev/null 2>&1
python3 - "$SU/.claude/settings.json" <<'PY' 2>/dev/null
import json, sys
p = sys.argv[1]; d = json.load(open(p))
# Back to what 0.8.4 installed: no prompt hook of Loomy's, the user's own one stays.
d["hooks"]["UserPromptSubmit"] = [g for g in d["hooks"]["UserPromptSubmit"] if "loomy-context.sh" not in json.dumps(g)]
json.dump(d, open(p, "w"))
PY
run "init --update on a project with older hooks" "$LOOMY" init "$SU" --update
run "second init --update" "$LOOMY" init "$SU" --update
python3 - "$SU/.claude/settings.json" <<'PY' >"$OUT" 2>&1 && ok "update: prompt hook added once, user hook kept" || ko "update: hooks wrong: $(cat "$OUT")"
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h["command"] for g in d["hooks"]["UserPromptSubmit"] for h in g["hooks"]]
assert cmds.count("echo perso") == 1, cmds
assert sum("--hook prompt" in c for c in cmds) == 1, cmds
assert sum("--hook start" in json.dumps(g) for g in d["hooks"]["SessionStart"]) == 1
PY

# ------------------------------------------------------------------ install.sh
section "install.sh"
PREFIX="$WORK/prefix"
run "install.sh into a prefix" env LOOMY_PREFIX="$PREFIX" sh "$REPO/install.sh"
run "installed loomy works" "$PREFIX/bin/loomy" version
run "install.sh --uninstall" env LOOMY_PREFIX="$PREFIX" sh "$REPO/install.sh" --uninstall
[[ ! -e "$PREFIX/bin/loomy" ]] && ok "command removed" || ko "command still present"

# ------------------------------------------------------------------ bilan
_sec_close
if [[ "$TEST_TIMES" == 1 ]]; then
  printf '\n\033[1mSlowest sections (s)\033[0m\n'; printf '%s' "$SEC_TIMES" | sort -rn | head -15 | sed 's/^/  /'
fi
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
