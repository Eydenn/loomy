#!/usr/bin/env bash
# shellcheck disable=SC2016  # programs and fixtures expand in child shells
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d /tmp/loomy-launch.XXXXXX)"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
unset LOOMY_DELEGATION LOOMY_CLI_MANAGED LOOMY_CLI_ID LOOMY_CLI_BRIDGE_CHECKED LOOMY_PARENT_SESSION AI_ROUTE_ENV
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex"
export LOOMY_CODEX_BIN="$LOOMY_TEST_STUBS/codex" LOOMY_CODEX_APPS="$WORK/no-apps"
export LOOMY_PROJECT_ROOT="$WORK/project" LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1 NO_COLOR=1 LOOMY_LANG=en LOOMY_UI_LANG=en
mkdir -p "$HOME" "$XDG_CONFIG_HOME/loomy" "$CODEX_HOME/sessions" "$WORK/project/.loomy"
printf 'plan_claude=pro\nplan_codex=business\n' >"$XDG_CONFIG_HOME/loomy/config"
cd "$WORK/project"
# shellcheck source=../scripts/lib/launch.sh
source "$REPO/scripts/lib/launch.sh"
# shellcheck source=../scripts/lib/journal.sh
source "$REPO/scripts/lib/journal.sh"
# shellcheck source=../scripts/lib/usage.sh
source "$REPO/scripts/lib/usage.sh"
ROOT="$WORK/project"
PASS=0
check() { "$@"; PASS=$((PASS+1)); printf 'ok %s\n' "$*"; }
expect_rc() { local want="$1" rc=0; shift; "$@" >"$WORK/output" 2>&1 || rc=$?; [[ "$rc" == "$want" ]]; }
# A deliberately untrusted executable is refused before it can leave evidence.
printf '#!/bin/bash\ntouch "%s"\n' "$WORK/executed" >"$WORK/real"
chmod +x "$WORK/real"
check expect_rc 97 env LOOMY_CODEX_BIN="$WORK/real" bash -c 'source "$1/scripts/lib/launch.sh"; loomy_cli_run codex reviewer gpt-6.1-sol -- exec' _ "$REPO"
check test ! -e "$WORK/executed"
check grep -q 'refusing to launch real codex' "$LOOMY_TEST_GUARD_LOG"
: >"$LOOMY_TEST_GUARD_LOG" # The refusal above is the expected assertion, not a leak.
check expect_rc 2 loomy_cli_run codex reviewer gpt-9-unknown -- exec
check expect_rc 2 loomy_cli_run codex reviewer gpt-6.1-sol -- exec -m gpt-9-unknown
check expect_rc 2 loomy_cli_meta codex exec
ai_provider_refusal codex 'rate limit retry_after: 600'
check expect_rc 75 loomy_cli_run codex reviewer gpt-6.1-sol -- exec
# Metadata never consults quota and never journals model activity.
check loomy_cli_meta codex --version
check test ! -e "$ROOT/.loomy/logs/events.jsonl"
rm "$XDG_CONFIG_HOME/loomy/codex-availability"
export LOOMY_PARENT_ID=lead-a LOOMY_ATTEMPT=attempt-a
check loomy_cli_run codex reviewer gpt-6.1-sol -- exec -m gpt-6.1-sol --ephemeral --json -o "$WORK/answer" OK
check perl -MJSON::PP -e 'open my $f,"<",shift or die $!;my @e=map {decode_json($_)} <$f>;my @s=grep {$_->{type} eq "delegation_start"} @e;my @n=grep {$_->{type} eq "delegation"} @e;die unless @s==1 && @n==1;for (@s,@n) {die unless $_->{parent_id} eq "lead-a" && $_->{attempt_id} eq "attempt-a"}' "$ROOT/.loomy/logs/events.jsonl"
# Lead hooks remain enabled, and redirected stdin reaches the provider transport.
check bash -c 'source "$1/scripts/lib/launch.sh"; printf "lead-input\n" | LOOMY_DELEGATION=1 LOOMY_CLI_META_BIN="$LOOMY_TEST_STUBS/launch-env" loomy_cli_run claude lead claude-opus-5-5 -- --model claude-opus-5-5 >"$2"; grep -qx "delegation=" "$2" && grep -qx "input=lead-input" "$2"' _ "$REPO" "$WORK/lead-env"
# Detached API retains an owned lifecycle until the foreground child has finished.
check loomy_cli_spawn claude reviewer claude-sonnet-5-5 -- -p OK --output-format json --model claude-sonnet-5-5
wait "$LOOMY_CLI_PID"
# Replay a provider stream through a trusted stub fixture (no real provider process).
export LOOMY_PARENT_ID=bridge-a LOOMY_ATTEMPT=attempt-stream
check bash -c 'source "$1/scripts/lib/launch.sh"; _loomy_cli_stream "$2" "$LOOMY_PARENT_ID" "$LOOMY_ATTEMPT" /bin/cat "$1/tests/fixtures/bridge-codex.jsonl"' _ "$REPO" "$ROOT/.loomy/logs/events.jsonl"
check perl -MJSON::PP -e 'open my $f,"<",shift or die;my %links;while (<$f>) {my $e=decode_json($_);next unless $e->{type} eq "bridge_link" && ($e->{attempt_id}//"") eq "attempt-stream";die unless $e->{parent_delegation} eq "bridge-a";$links{$e->{session}}=$e->{parent_session}}die unless keys(%links)==3 && $links{"native-child-a"} eq "bridge-exec-a" && $links{"native-grandchild-a"} eq "native-child-a"' "$ROOT/.loomy/logs/events.jsonl"
# The supplied Claude UUID identifies its transcript without a cwd/role heuristic.
LOOMY_PARENT_ID=bridge-claude LOOMY_ATTEMPT=attempt-claude LOOMY_CLI_SESSION_ID=bridge-claude-a loomy_cli_run claude reviewer claude-sonnet-5-5 -- -p OK --output-format json --model claude-sonnet-5-5 --session-id bridge-claude-a >"$WORK/claude"
check perl -MJSON::PP -e 'open my $j,"<",shift or die;my @links=grep {$_->{type} eq "bridge_link" && ($_->{session}//"") eq "bridge-claude-a"} map {decode_json($_)} <$j>;die unless @links==1 && $links[0]{parent_delegation} eq "bridge-claude";open my $f,"<",shift or die;my $m=decode_json(<$f>);die unless $m->{sessionId} eq $links[0]{session}' "$ROOT/.loomy/logs/events.jsonl" "$REPO/tests/fixtures/bridge-claude.jsonl"
# Same-role bridges retain explicit, distinct parents and attempts.
(LOOMY_PARENT_ID=bridge-one LOOMY_ATTEMPT=attempt-one loomy_cli_run claude reviewer claude-sonnet-5-5 -- -p OK --output-format json --model claude-sonnet-5-5) >"$WORK/one" & one=$!
(LOOMY_PARENT_ID=bridge-two LOOMY_ATTEMPT=attempt-two loomy_cli_run claude reviewer claude-sonnet-5-5 -- -p OK --output-format json --model claude-sonnet-5-5) >"$WORK/two" & two=$!
wait "$one"; wait "$two"
check perl -MJSON::PP -e 'open my $f,"<",shift or die;my %e;while (<$f>) {my $e=decode_json($_);next unless $e->{type} eq "delegation_start" && ($e->{parent_id}//"") =~ /^bridge-(one|two)$/;die unless $e->{attempt_id} eq "attempt-$1";$e{$e->{parent_id}}=$e->{id}}die unless keys(%e)==2 && $e{"bridge-one"} ne $e{"bridge-two"}' "$ROOT/.loomy/logs/events.jsonl"
check perl "$REPO/tests/fixtures/bridge-links.pl" "$REPO" "$ROOT"
# Local user models use Claude only as transport, with no cloud availability/catalog gate.
ai_provider_refusal claude 'usage limit reached'
check loomy_cli_run local documenter user/local-model -- -p OK --model user/local-model
check perl -MJSON::PP -e 'my @e=map {decode_json($_)} <>; die unless grep {$_->{type} eq "delegation_start" && $_->{family} eq "local" && $_->{model} eq "user/local-model"} @e; die unless grep {$_->{type} eq "delegation" && $_->{family} eq "local" && $_->{status} eq "ok"} @e' "$ROOT/.loomy/logs/events.jsonl"
rm "$XDG_CONFIG_HOME/loomy/claude-availability"
check expect_rc 97 env PATH="$WORK:$PATH" LOOMY_TEST_GUARD_LOG="$WORK/local-refusal" bash -c 'source "$1/scripts/lib/launch.sh"; LOOMY_CLI_META_BIN="$2" loomy_cli_run local documenter user/model -- -p OK' _ "$REPO" "$WORK/real"
check test ! -e "$WORK/executed"
# Config cap and the prompt reminder use the same user setting.
check bash "$REPO/bin/loomy" config get max_parallel
check bash -c 'source "$1/scripts/lib/config.sh"; test "$(loomy_config_get max_parallel)" = 4' _ "$REPO"
check bash "$REPO/bin/loomy" config set max_parallel 6
check expect_rc 2 bash "$REPO/bin/loomy" config set max_parallel 0
printf '%s\n' '---' 'ai_mode: ORCHESTRATED' 'ai_lead: claude' '---' >"$ROOT/.loomy/brief.md"
check bash -c 'printf "{}" | bash "$1/scripts/loomy-context.sh" --root "$2" --hook prompt >"$2/reminder"; grep -q "max_parallel=6" "$2/reminder" && grep -q "launch them together" "$2/reminder"' _ "$REPO" "$ROOT"
check bash "$REPO/bin/loomy" config set max_parallel auto
# Final terminal provider message wins over nonfatal retry noise.
printf '%s\n' '{"type":"error","message":"Reconnecting 429 rate limit"}' '{"type":"turn.failed","error":{"message":"invalid model"}}' >"$WORK/error"
ai_delegate_error codex "$WORK/error" 1
check test "$(ai_model_error_class "$AI_ERROR_TEXT")" = model
printf 'usage limit reached\n' >"$WORK/error"
ai_delegate_error codex "$WORK/error" 1
check test "$(ai_model_error_class "$AI_ERROR_TEXT")" = saturated
# Relative and dated reset forms from provider stderr.
rm -f "$XDG_CONFIG_HOME/loomy/codex-availability"
now="$(date +%s)"; ai_provider_refusal codex 'try again in 2 days 3 hours'
reset="$(ai_provider_reset codex)"; check test "$reset" -ge "$((now+183600))"
rm "$XDG_CONFIG_HOME/loomy/codex-availability"
ai_provider_refusal codex 'try again at Oct 20'
check test "$(ai_provider_reset codex)" -gt "$now"
rm "$XDG_CONFIG_HOME/loomy/codex-availability"
ai_provider_refusal codex 'try again at 2099-10-20T15:30:00+02:00'
check test "$(ai_provider_reset codex)" = "$(perl -MTime::Local -e 'print timegm(0,30,13,20,9,2099)')"
rm "$XDG_CONFIG_HOME/loomy/codex-availability"
# Probe mode is bounded, journal-less, and never poisons model availability.
export STUB_SLEEP=3 LOOMY_MODEL_PROBE_TIMEOUT=1
check expect_rc 1 ai_model_probe codex gpt-6.1-sol
check test "$AI_PROBE_STATUS" = 124
check expect_rc 1 ai_model_probe claude claude-sonnet-5-5
check test "$AI_PROBE_STATUS" = 124
check test ! -f "$XDG_CONFIG_HOME/loomy/models.state"
# Doctor must warn on a used model timeout, without setting the blocking verdict.
printf '%s\n' '---' 'name: timeout fixture' 'ai_mode: ORCHESTRATED' 'ai_lead: codex' 'budget: equilibre' '---' >"$ROOT/.loomy/brief.md"
check expect_rc 0 bash "$REPO/scripts/loomy-doctor.sh" --root "$ROOT" --live --compact
unset STUB_SLEEP LOOMY_MODEL_PROBE_TIMEOUT
# Every caller gets a clear shared validation/pause message; local caches remain advisory.
check expect_rc 2 loomy_cli_check codex lead gpt-9-unknown
check grep -q 'model not validated: gpt-9-unknown' "$WORK/output"
printf '{"models":[{"slug":"foreign-model"}]}\n' >"$CODEX_HOME/models_cache.json"
check expect_rc 0 loomy_cli_check codex lead gpt-6.1-sol
check grep -q "gpt-6.1-sol missing from Codex's local catalog" "$WORK/output"
rm "$CODEX_HOME/models_cache.json"
ai_provider_refusal codex 'rate limit retry_after: 600'
ai_provider_refusal claude 'usage limit retry_after: 600'
check expect_rc 75 loomy_cli_check codex lead gpt-6.1-sol
check grep -q 'paused until .* (both providers saturated)' "$WORK/output"
check expect_rc 75 env LOOMY_CLI_PROBE=1 bash -c 'source "$1/scripts/lib/launch.sh"; loomy_cli_check codex probe ""' _ "$REPO"
check bash -c 'source "$1/scripts/lib/models.sh"; AI_UPCOMING="codex:gpt-announced claude:claude-announced"; export STUB_LOG="$2"; ai_upcoming_probe_daily; wait; test ! -s "$2"' _ "$REPO" "$WORK/upcoming-calls"
rm "$XDG_CONFIG_HOME/loomy/codex-availability" "$XDG_CONFIG_HOME/loomy/claude-availability"
check bash -c 'source "$1/scripts/lib/launch.sh"; test "$(loomy_cli_open_note 97 "loomy: test guard: refusing to launch real open")" = "loomy: test guard: refusing to launch real open"; test "$(loomy_cli_open_note 1 "Desktop apps: macOS only / opening in the terminal")" = "Desktop apps: macOS only"; test -z "$(loomy_cli_open_note 1 stale-warning)"' _ "$REPO"
# Explicit provider names survive misleading installation paths.
check bash -c 'source "$1/scripts/lib/repair.sh"; source "$1/scripts/lib/models.sh"; test "$(ai_tool_version_of codex "$LOOMY_TEST_STUBS/codex")" = 0.160.0; _ai_probe_run codex exec -m gpt-6.1-sol --ephemeral -o "$2" "Reply exactly: OK"; grep -q OK "$2"' _ "$REPO" "$WORK/probe-answer"
# A detached runner, rather than its caller, owns the journal lifetime on Bash 3.2.
check bash -c 'set -e; source "$1/scripts/lib/launch.sh"; export ROOT="$2/pid-project" STUB_SLEEP=2; mkdir -p "$ROOT/.loomy"; loomy_cli_spawn claude reviewer claude-sonnet-5-5 -- -p OK --output-format json >"$2/pid-output"; perl -MJSON::PP -e '\''my ($p,$caller)=@ARGV; open my $f,"<",$p or die; my ($e)=grep {$_->{type} eq "delegation_start"} map {decode_json($_)} <$f>; die unless $e->{pid}>1 && $e->{pid}!=$caller && kill(0,$e->{pid});'\'' "$ROOT/.loomy/logs/events.jsonl" "$$"; wait "$LOOMY_CLI_PID"' _ "$REPO" "$WORK"
check bash "$REPO/tests/fixtures/guard-poll.sh" "$REPO" "$WORK"
# Source static scan: literal commands, variable binaries and generated launcher arrays.
printf 'Launch functional assertions: %s passed\n' "$PASS"
files=()
while IFS= read -r file; do files+=("$file"); done < <(find "$REPO/scripts" "$REPO/bin" -type f \( -name '*.sh' -o -name loomy \))
check perl -e '
  my @files=@ARGV; my @bad;
  for my $f (@files) {
    next if $f =~ m{scripts/lib/launch\.sh$};
    next if $f =~ m{scripts/loomy-shell-hook\.sh$}; # Generated user-command passthrough only.
    open my $h,"<",$f or die $!; my $n=0;
    while (<$h>) {++$n; next if /^\s*#/;
      push @bad,"$f:$n:$_" if /(?:^\s*|[;|&]\s*)(?:exec\s+|command\s+)?(?:claude|codex)\s+(?:-p|--version|update|login|exec|--model|\"\$@\")/
        || /(?:^|\s)\"\$(?:CODEX|codex|claude|binary|first|1)\"\s+(?:exec|--version|update|-p)/
        || /ui_(?:exec|external)\s+\"\$\{AGENT_CMD\[@\]\}/;
    }
  }
  die join("",@bad) if @bad;
' ${files[@]+"${files[@]}"}
printf 'Launch assertions: %s passed\n' "$PASS"
