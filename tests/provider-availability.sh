#!/usr/bin/env bash
# shellcheck disable=SC2016  # Single-quoted programs expand in the child Bash.
# Provider availability regressions, isolated from real accounts and without network/tokens.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d "/tmp/loomy-provider-tests.XXXXXX")"
# shellcheck source=lib/guard.sh
source "$REPO/tests/lib/guard.sh"
for v in $(env | sed -nE 's/^((LOOMY|AI|DELEGATE|STUB)_[A-Z0-9_]*|CLAUDE_PROJECT_DIR|CODEX_HOME)=.*/\1/p'); do case "$v" in LOOMY_TEST_GUARD|LOOMY_TEST_STUBS|LOOMY_TEST_GUARD_LOG) continue ;; esac; unset "$v"; done
mkdir -p "$WORK/bin" "$WORK/tmp" "$WORK/home" "$WORK/config/loomy" "$WORK/project/.loomy" "$WORK/codex/sessions"
export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" CODEX_HOME="$WORK/codex" TMPDIR="$WORK/tmp"
export PATH="$WORK/bin:$HERE/stubs:/usr/bin:/bin:/usr/sbin:/sbin" LOOMY_CODEX_BIN="$HERE/stubs/codex"
export LOOMY_HOME="$REPO" LOOMY_LANG=en NO_COLOR=1 LOOMY_CATALOG_CHECK=0 LOOMY_NO_AUTOUPDATE=1 LOOMY_START_WATCH=0
export TZ=UTC
export STUB_LOG="$WORK/calls" STUB_NOW=1791885600
cat >"$WORK/bin/date" <<'DATE'
#!/usr/bin/env bash
if [[ "$*" == '+%s' ]]; then echo "$STUB_NOW"; else exec /bin/date "$@"; fi
DATE
chmod +x "$WORK/bin/date"
cd "$WORK/project" || exit 1
PASS=0; FAIL=0; OUT="$WORK/out"
ok() { PASS=$(( PASS + 1 )); printf '  ✓ %s\n' "$1"; }
ko() { FAIL=$(( FAIL + 1 )); printf '  ✗ %s\n' "$1"; tail -12 "$OUT"; }
run() { local d="$1"; shift; if "$@" >"$OUT" 2>&1; then ok "$d"; else ko "$d (code $?)"; fi; }
fails() { local d="$1" want="$2"; shift 2; "$@" >"$OUT" 2>&1; local got=$?; if [[ "$got" == "$want" ]]; then ok "$d"; else ko "$d (code $got, expected $want)"; fi; }
has() { if grep -qE -- "$2" "$OUT"; then ok "$1"; else ko "$1"; fi; }
file_has() { if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else ko "$1"; fi; }
no_ko() { ! grep -q '=ko' "$XDG_CONFIG_HOME/loomy/models.state" 2>/dev/null; }
reset_case() {
  rm -f "$XDG_CONFIG_HOME"/loomy/* "$WORK/project/.loomy/logs/events.jsonl" "$CODEX_HOME/sessions/quota.jsonl"
  printf 'plan_claude=pro\nplan_codex=business\n' >"$XDG_CONFIG_HOME/loomy/config"
  : >"$STUB_LOG"
  unset STUB_CODEX_CREDITS_DEPLETED STUB_CODEX_ERROR STUB_CODEX_ERROR_EXIT STUB_CLAUDE_ERROR STUB_UNKNOWN_MODELS STUB_FAIL STUB_CODEX_TEXT STUB_CODEX_NONFATAL STUB_CLAUDE_TEXT STUB_CLAUDE_RESULT_ERROR STUB_CLAUDE_ERROR_EXIT STUB_WRITE STUB_SLEEP LOOMY_MODEL_PROBE_TIMEOUT
}
bridge() { bash "$REPO/scripts/loomy-delegate-$1.sh" reviewer "bounded review"; }
journal="$WORK/project/.loomy/logs/events.jsonl"

reset_case
export STUB_CODEX_CREDITS_DEPLETED=1
run 'credits depleted hands role to Claude' bridge codex
run 'credits never writes ko' no_ko
file_has 'one Codex call only' "$STUB_LOG" '^codex.*-m.gpt-6.1-sol'
file_has 'Claude gets the routed model' "$STUB_LOG" '--model.claude-sonnet-5-5'
file_has 'handover has a terminal event' "$journal" '"status":"handed_over"'
file_has 'successful other provider has failover metadata' "$journal" '"status":"ok".*"failover_from":"codex"'
run 'same-second handover has distinct lifecycle IDs' bash -c '[[ $(sed -n "s/.*\"id\":\"\([^\"]*\).*/\1/p" "$1" | sort -u | wc -l | tr -d " ") == 2 ]]' _ "$journal"

reset_case
export STUB_CODEX_CREDITS_DEPLETED=1 STUB_CLAUDE_ERROR='rate_limit_error: usage limit reached retry_after: 600'
fails 'two real refusals pause after one handover' 75 bridge codex
has 'pause is explicit' 'PAUSED: provider claude'
run 'neither provider poisons model cache' no_ko
file_has 'pause carries outcome and expected reset' "$journal" '"status":"paused","outcome":"waiting_for_reset","resume_at":1791885900'
run 'exactly two calls, no same-provider retry' bash -c '[[ $(grep -Ec "^(codex.*exec|claude.*-p)" "$STUB_LOG") == 2 ]]'

reset_case
export STUB_CLAUDE_ERROR='usage limit reached'
run 'Claude refusal hands role to Codex' bridge claude
run 'Claude quota refusal never writes ko' no_ko
file_has 'reverse failover uses Codex current model' "$STUB_LOG" '^codex.*-m.gpt-6.1-sol'

reset_case
printf 'five_hour_pct=100\nfive_hour_reset=1791886500\n' >"$XDG_CONFIG_HOME/loomy/claude-limits"
printf '%s\n' '{"rate_limits":{"primary":{"window_minutes":300,"used_percent":100,"resets_at":1791886200},"secondary":{"window_minutes":10080,"used_percent":100,"resets_at":1791886800}}}' >"$CODEX_HOME/sessions/quota.jsonl"
fails 'both quota readings pause before any CLI call' 75 bridge codex
file_has 'resume waits for all blocked windows of earliest provider' "$journal" '"resume_at":1791886500'
run 'preflight pause makes zero calls' test ! -s "$STUB_LOG"
run 'doctor reports providers despite compact output' bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact
has 'doctor names paused Codex and Claude' 'Provider codex: PAUSED'
has 'doctor includes expected reset' 'until .*epoch 1791886800'

reset_case
export STUB_UNKNOWN_MODELS='gpt-6.1-sol'
run 'unknown Codex model crosses provider' bridge codex
file_has 'only unknown model receives timestamped ko' "$XDG_CONFIG_HOME/loomy/models.state" '^gpt-6.1-sol=ko:1791885600$'
run 'ko blocks until hour boundary' bash -c 'source "$1/scripts/lib/models.sh"; ! ai_model_usable gpt-6.1-sol codex' _ "$REPO"
export STUB_NOW=1791889200
run 'hour boundary drops ko at load' bash -c 'source "$1/scripts/lib/models.sh"; ai_model_usable gpt-6.1-sol codex' _ "$REPO"
run 'expiry at load is read-only' test ! -e "$XDG_CONFIG_HOME/loomy/models.state.reprobe"
unset STUB_UNKNOWN_MODELS
run 'non-live doctor makes no model calls' bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact
run 'non-live doctor kept model state' bash -c 'grep -q "=ko:" "$1"' _ "$XDG_CONFIG_HOME/loomy/models.state"
run 'live doctor probes current chains' bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact --live
file_has 'successful probe records ok' "$XDG_CONFIG_HOME/loomy/models.state" '^gpt-6.1-sol=ok$'

reset_case
printf 'claude-sonnet-5-5=ko:%s\n' "$STUB_NOW" >"$XDG_CONFIG_HOME/loomy/models.state"
printf '%s\n' '---' 'name: provider tests' 'ai_mode: ORCHESTRATED' 'ai_lead: codex' '---' >"$WORK/project/.loomy/brief.md"
run 'session entry point reprobes fresh ko' bash "$REPO/scripts/loomy-start.sh" --root "$WORK/project" --new --lead codex --no-watch
rm -f "$WORK/project/.loomy/brief.md"
attempt=0
until grep -q '^claude-sonnet-5-5=ok$' "$XDG_CONFIG_HOME/loomy/models.state" || (( attempt >= 5 )); do attempt=$(( attempt+1 )); sleep 0.1; done
file_has 'session start clears fresh refusal after success' "$XDG_CONFIG_HOME/loomy/models.state" '^claude-sonnet-5-5=ok$'

reset_case
export STUB_UNKNOWN_MODELS='claude-sonnet-5-5'
run 'unknown Claude model crosses provider' bridge claude
file_has 'Claude rejection gets timestamped ko' "$XDG_CONFIG_HOME/loomy/models.state" '^claude-sonnet-5-5=ko:[0-9]+$'
run 'doctor prominently reports unavailable model' bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact
has 'doctor unavailable provider/model' 'Provider model unavailable: claude-sonnet-5-5'

reset_case
export STUB_CODEX_ERROR='network connection failed'
fails 'transport failures remain errors' 1 bridge codex
run 'network failure never marks ko' no_ko
run 'transport failure never retries' bash -c '[[ $(grep -Ec "^(codex.*exec|claude.*-p)" "$STUB_LOG") == 1 ]]'

reset_case
export STUB_CODEX_CREDITS_DEPLETED=1
run 'doctor live tolerates provider refusal without ko' bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact --live
has 'doctor live warns handover provider' 'Provider codex: HANDOVER to claude'
[[ $(grep -c 'Provider codex:' "$OUT") == 1 ]] && ok 'doctor shows one verdict per provider' || ko 'doctor repeats provider verdict'
run 'doctor live quota does not write ko' no_ko

reset_case
run 'chains contain only validated current models' bash -c '
source "$1/scripts/lib/models.sh"
[[ "$AI_CHAIN_CODEX_TOP|$AI_CHAIN_CODEX_MID|$AI_CHAIN_CODEX_FAST|$AI_CHAIN_CLAUDE_TOP|$AI_CHAIN_CLAUDE_MID|$AI_CHAIN_CLAUDE_FAST" == "gpt-6.1-sol|gpt-6.1-sol|gpt-6-luna|claude-opus-5-5|claude-sonnet-5-5|claude-haiku-5-5" ]]
' _ "$REPO"
run 'published chains match validated set' bash -c '[[ $(sed -n "s/^model\.[^=]*=//p" "$1/catalog/models.conf" | paste -sd "|" -) == "claude-opus-5-5|claude-sonnet-5-5|claude-haiku-5-5|gpt-6.1-sol|gpt-6.1-sol|gpt-6-luna" ]]' _ "$REPO"
reset_case
printf 'chain.codex.top=gpt-6-astra, gpt-6-sol\nchain.claude.fast=claude-haiku-4-5\n' >>"$XDG_CONFIG_HOME/loomy/config"
run 'obsolete local chains cannot restore retired fallbacks' bash -c 'source "$1/scripts/lib/models.sh"; [[ "$AI_CHAIN_CODEX_TOP|$AI_CHAIN_CLAUDE_FAST" == "gpt-6.1-sol|claude-haiku-5-5" ]]' _ "$REPO"

reset_case
printf '%s\n' '{"rate_limits":{"primary":{"window_minutes":300,"used_percent":100,"resets_at":1791889500},"rate_limit_reached_type":"primary"}}' >"$CODEX_HOME/sessions/quota.jsonl"
export STUB_NOW=1791889500
run 'quota reached stops blocking at its reset' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ! ai_provider_saturated codex' _ "$REPO"
run 'delegation can retry after reset' bridge codex

reset_case
export STUB_CODEX_ERROR='unknown model: credits depleted retry_after: 60'
run 'quota takes precedence over mixed model wording' bridge codex
run 'mixed error does not write ko' no_ko
file_has 'explicit Retry-After controls provider state' "$XDG_CONFIG_HOME/loomy/codex-availability" '^resume_at=1791889560$'

reset_case
export STUB_CODEX_ERROR='workspace_member_credits_depleted resets_at: 1791890500'
run 'provider epoch reset is preserved' bridge codex
file_has 'structured epoch stored' "$XDG_CONFIG_HOME/loomy/codex-availability" '^resume_at=1791890500$'

reset_case
export STUB_CODEX_CREDITS_DEPLETED=1
run 'writer failover preserves permission and explicit effort' bash "$REPO/scripts/loomy-delegate-codex.sh" developer --write --effort high --why 'quota test' 'bounded implementation'
file_has 'destination accepts scoped edits' "$STUB_LOG" '--permission-mode.acceptEdits'
file_has 'destination retains requested effort' "$STUB_LOG" '--effort.high'

reset_case
export STUB_CODEX_ERROR='not have access to repository'
fails 'repository access error is not a model refusal' 1 bridge codex
run 'repository access failure never marks ko' no_ko

reset_case
printf 'five_hour_pct=100\nfive_hour_reset=1791890500\n' >"$XDG_CONFIG_HOME/loomy/claude-limits"
export STUB_CODEX_CREDITS_DEPLETED=1
fails 'pause persists full task for orchestrator resume' 75 bash "$REPO/scripts/loomy-delegate-codex.sh" reviewer 'Full paused task with options and instructions for later resumption'
run 'resume task kept in existing delegation memory' bash -c 'grep -ql "Full paused task with options and instructions for later resumption" "$PWD"/.loomy/memory/delegations/*.md'

reset_case
export STUB_CODEX_ERROR='{"type":"turn.failed","error":{"message":"workspace_member_credits_depleted"}}' STUB_CODEX_ERROR_EXIT=0
run 'structured refusal still switches when CLI exits zero' bridge codex
run 'zero-exit refusal does not poison model state' no_ko

reset_case
run 'doctor warns prominently on replaced chain head' env COLUMNS=200 AI_MODEL_CODEX_TOP=gpt-6-luna bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact
has 'doctor identifies downgraded provider' 'Provider codex: DOWNGRADED'

reset_case
run 'refused head never selects a sibling even in a custom chain' bash -c '
source "$1/scripts/lib/models.sh"
AI_CHAIN_CODEX_TOP="gpt-6.1-sol gpt-6-luna"
ai_model_mark gpt-6.1-sol ko
[[ "$(ai_model_pick codex top)" == gpt-6.1-sol && -z "$(ai_model_next codex gpt-6.1-sol)" ]]
' _ "$REPO"

reset_case
printf 'claude-sonnet-5-5=ko:%s\n' "$STUB_NOW" >"$XDG_CONFIG_HOME/loomy/models.state"
run 'start help has no provider side effects' bash "$REPO/scripts/loomy-start.sh" --help
run 'help made no CLI call' test ! -s "$STUB_LOG"


# V1: successful agent text and transient stream errors are never refusals.
for prose in 'rate limit' 'unknown model' 'Credit balance is too low'; do
  reset_case
  export STUB_CODEX_TEXT="Review quotes: $prose"
  run "Codex success quoting $prose stays successful" bridge codex
  run 'successful quotation never poisons model state' no_ko
  run 'successful quotation never blocks provider' test ! -e "$XDG_CONFIG_HOME/loomy/codex-availability"
  run 'successful quotation made one model call' bash -c '[[ $(grep -Ec "^(codex.*exec|claude.*-p)" "$STUB_LOG") == 1 ]]'
done
reset_case
export STUB_CODEX_NONFATAL='Reconnecting... rate limit'
run 'nonfatal stream error before turn.completed is successful' bridge codex
run 'nonfatal stream error never blocks provider' test ! -e "$XDG_CONFIG_HOME/loomy/codex-availability"
reset_case
export STUB_CLAUDE_TEXT='Review quotes unknown model and rate limit'
run 'Claude successful result quoting errors stays successful' bridge claude
run 'Claude quotation never poisons cache' no_ko
run 'Claude quotation never blocks provider' test ! -e "$XDG_CONFIG_HOME/loomy/claude-availability"
reset_case
export STUB_CLAUDE_RESULT_ERROR='Credit balance is too low' STUB_CLAUDE_ERROR_EXIT=0
run 'Claude is_error result at exit zero hands over' bridge claude
file_has 'Claude failed result has handover event' "$journal" '"status":"handed_over"'
reset_case
export STUB_CODEX_ERROR='{"type":"item.completed","item":{"type":"agent_message","text":"rate limit unknown model"}}' STUB_CODEX_ERROR_EXIT=1
fails 'failed process cannot classify agent prose as refusal' 1 bridge codex
run 'failed agent prose never poisons cache' no_ko
run 'failed agent prose never blocks provider' test ! -e "$XDG_CONFIG_HOME/loomy/codex-availability"

# V5/V11: Claude wording, parsed deadlines and monotonic saved resets.
reset_case
run 'Claude session/weekly/credit texts saturate the provider' bash -c '
source "$1/scripts/lib/models.sh"; shift
for s in "$@"; do [[ $(ai_model_error_class "$s") == saturated ]] || exit 1; done' _ "$REPO" "You've hit your session limit · resets 3pm" "5-hour limit reached ∙ resets 3pm" "Weekly limit reached ∙ resets Oct 20" "Credit balance is too low"
run 'Claude hour reset is parsed' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ai_provider_refusal claude "5-hour limit reached ∙ resets 3pm"; [[ $(ai_provider_reset claude) == $(perl -MTime::Local -e '\''@t=localtime($ARGV[0]); print timelocal(0,0,15,$t[3],$t[4],$t[5])'\'' "$STUB_NOW") ]]' _ "$REPO"
reset_case
run 'Claude date reset is parsed' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ai_provider_refusal claude "Weekly limit reached ∙ resets Oct 20"; [[ $(ai_provider_reset claude) == 1792454400 ]]' _ "$REPO"
reset_case
run 'relative reset seconds are parsed' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ai_provider_refusal codex "rate limit resets_in_seconds: 60"; [[ $(ai_provider_reset codex) == $(( STUB_NOW+60 )) ]]' _ "$REPO"
reset_case
run 'epoch suffix is parsed' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ai_provider_refusal codex "rate limit |1791990000"; [[ $(ai_provider_reset codex) == 1791990000 ]]' _ "$REPO"
run 'short epoch cannot shorten saved refusal' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ai_provider_refusal codex "rate limit resets_at: 1791890000"; [[ $(ai_provider_reset codex) == 1791990000 ]]' _ "$REPO"
run 'short relative reset cannot shorten saved refusal' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ai_provider_refusal codex "rate limit retry_after: 1"; [[ $(ai_provider_reset codex) == 1791990000 ]]' _ "$REPO"
reset_case
run 'unparsable reset uses five-minute estimate' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ai_provider_refusal claude "Credit balance is too low"; [[ $(ai_provider_reset claude) == $(( STUB_NOW+300 )) ]]' _ "$REPO"

# V6: read-only doctor, current chains and bounded model calls.
reset_case
printf 'gpt-6-astra=ko:%s\ngpt-6.1-sol=ko:%s\n' "$STUB_NOW" "$STUB_NOW" >"$XDG_CONFIG_HOME/loomy/models.state"
cp "$XDG_CONFIG_HOME/loomy/models.state" "$WORK/before-state"
run 'ordinary doctor is read-only for rejected models' bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact
run 'ordinary doctor preserves models.state bytes' cmp "$WORK/before-state" "$XDG_CONFIG_HOME/loomy/models.state"
run 'ordinary doctor calls no provider models' bash -c '! grep -Eq "^(codex.*exec|claude.*-p)" "$STUB_LOG"'
run 'reprobe accepts current chain models only' bash -c 'source "$1/scripts/lib/models.sh"; ai_models_reprobe' _ "$REPO"
run 'retired Astra was never called' bash -c '! grep -q -- "-m.gpt-6-astra" "$STUB_LOG"'
file_has 'retired rejection remains untouched' "$XDG_CONFIG_HOME/loomy/models.state" '^gpt-6-astra=ko:'
reset_case
export LOOMY_MODEL_PROBE_TIMEOUT=1 STUB_SLEEP=10
SECONDS=0
fails 'hung Codex probe is bounded' 1 bash -c 'source "$1/scripts/lib/models.sh"; ai_model_probe codex gpt-6.1-sol' _ "$REPO"
(( SECONDS < 5 )) && ok 'probe timeout kills process group promptly' || ko 'probe timeout took too long'
fails 'hung Claude probe is bounded' 1 bash -c 'source "$1/scripts/lib/models.sh"; ai_model_probe claude claude-sonnet-5-5' _ "$REPO"
run 'timeouts never poison cache' no_ko

# V7: both providers at 95-99 percent can still serve, stale reached can refresh.
reset_case
printf 'five_hour_pct=97\nfive_hour_reset=%s\n' $(( STUB_NOW+3600 )) >"$XDG_CONFIG_HOME/loomy/claude-limits"
printf '{"rate_limits":{"primary":{"window_minutes":300,"used_percent":99.6,"resets_at":%s}}}\n' $(( STUB_NOW+3600 )) >"$CODEX_HOME/sessions/quota.jsonl"
run '95-99 percent readings still permit a real Codex attempt' bridge codex
run '95-99 percent readings still permit a real Claude attempt' bridge claude
run 'both near quota providers stay available' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; ! ai_provider_saturated codex && ! ai_provider_saturated claude' _ "$REPO"
reset_case
printf '{"rate_limits":{"rate_limit_reached_type":"primary"}}\n' >"$CODEX_HOME/sessions/quota.jsonl"
run 'stale reached without reset permits a fresh attempt' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/usage.sh"; STUB_NOW=$(( $(stat -c %Y "$2" 2>/dev/null || stat -f %m "$2")+301 )); export STUB_NOW; ! ai_provider_saturated codex' _ "$REPO" "$CODEX_HOME/sessions/quota.jsonl"
reset_case
run 'unknown chain model is explicitly refused' bash -c '"$1/bin/loomy" config set chain.codex.top gpt-9-test; [[ $? == 2 ]]' _ "$REPO"
run 'validated local chain is accepted' "$REPO/bin/loomy" config set chain.codex.top gpt-6.1-sol
fails 'retired thrifty option is explicitly refused' 2 "$REPO/bin/loomy" models --thrifty on
has 'retired thrifty option explains current routing' 'retired.*validated'

# V11/V8: partial writes survive terminal availability events and are visible apart from errors.
reset_case
git init -q "$WORK/project"
printf '.loomy/\n' >"$WORK/project/.gitignore"
export STUB_CODEX_ERROR='rate limit retry_after: 60' STUB_WRITE=1
run 'partial writer refusal hands over' bash "$REPO/scripts/loomy-delegate-codex.sh" developer --write 'bounded implementation'
file_has 'handover records partial changed files' "$journal" '"status":"handed_over".*"files_changed":1,"changed_files":\["partial.txt"\]'
run 'handover display is distinct from failed' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; ai_journal_display_events "$2"' _ "$REPO" "$journal"
has 'timeline names handover' 'handed over'
run 'stats counts handover separately' bash "$REPO/scripts/loomy-stats.sh" --root "$WORK/project"
has 'stats handover is not a failure' '0 paused.*1 handed over'
rm -f "$WORK/project/partial.txt"
reset_case
printf 'five_hour_pct=100\nfive_hour_reset=%s\n' $(( STUB_NOW+3600 )) >"$XDG_CONFIG_HOME/loomy/claude-limits"
export STUB_CODEX_ERROR='rate limit retry_after: 60' STUB_WRITE=1
fails 'partial writer refusal pauses when other is blocked' 75 bash "$REPO/scripts/loomy-delegate-codex.sh" developer --write --effort high --why 'writer pause' 'bounded implementation'
file_has 'pause records partial changed files' "$journal" '"status":"paused".*"files_changed":1,"changed_files":\["partial.txt"\]'
run 'pause memory contains exact role/options to relaunch' bash -c 'grep -q "Resume:.*developer.*--effort high.*--write.*--why.*writer" "$PWD"/.loomy/memory/delegations/*.md'
run 'display formatter shows paused without failure' bash -c 'source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/journal.sh"; ai_journal_display_events "$2"' _ "$REPO" "$journal"
has 'display formatter includes pause deadline' 'paused.*until [0-9]{2}:[0-9]{2}'
printf '%s\n' '---' 'name: availability view' 'ai_mode: ORCHESTRATED' 'ai_lead: codex' '---' >"$WORK/project/.loomy/brief.md"
run 'watch displays explicit paused deadline' bash "$REPO/scripts/loomy-tree.sh" --root "$WORK/project" --once
has 'watch paused until HH:MM' 'paused until [0-9]{2}:[0-9]{2}'
run 'stats counts pause separately' bash "$REPO/scripts/loomy-stats.sh" --root "$WORK/project"
has 'stats paused separate from failures' '1 paused.*0 handed over'
run 'status counts pause separately' bash "$REPO/scripts/loomy-status.sh" --root "$WORK/project"
has 'status paused separate from failures' '1 paused.*0 handed over'
run 'report counts pause separately' bash "$REPO/scripts/loomy-report.sh" --root "$WORK/project"
has 'report pause is not an error' '0 failed.*1 paused.*0 handed over'
reset_case
run 'watch identifies downgraded chain prominently' env COLUMNS=200 AI_MODEL_CODEX_TOP=gpt-6-luna bash "$REPO/scripts/loomy-tree.sh" --root "$WORK/project" --once
has 'watch downgraded chain head' 'codex.top: DOWNGRADED.*gpt-6.1-sol.*gpt-6-luna'


reset_case
export STUB_CLAUDE_RESULT_ERROR='This CLI does not support this model'
run 'old Claude CLI refusal crosses provider without an alias retry' bridge claude
file_has 'old Claude CLI refusal is model class' "$XDG_CONFIG_HOME/loomy/models.state" '^claude-sonnet-5-5=ko:'
run 'old Claude CLI made no alias call' bash -c '! grep -Eq -- "--model.(opus|sonnet|haiku)([[:space:]]|$)" "$STUB_LOG"'
reset_case
printf 'existing partial work\n' >"$WORK/project/partial.txt"
printf 'five_hour_pct=100\nfive_hour_reset=%s\n' $(( STUB_NOW+3600 )) >"$XDG_CONFIG_HOME/loomy/claude-limits"
export STUB_CODEX_ERROR='rate limit' STUB_WRITE=1
fails 'writer refusal detects a write to an already dirty file' 75 bash "$REPO/scripts/loomy-delegate-codex.sh" developer --write 'bounded implementation'
file_has 'already dirty file is retained in paused event' "$journal" '"status":"paused".*"files_changed":1,"changed_files":\["partial.txt"\]'
reset_case
printf '{"rate_limits":{"primary":{"window_minutes":300,"used_percent":100,"resets_at":%s}}}\n' $(( STUB_NOW+3600 )) >"$CODEX_HOME/sessions/quota.jsonl"
run 'ordinary doctor can read a quota without updating its cache' bash "$REPO/scripts/loomy-doctor.sh" --root "$WORK/project" --compact
run 'ordinary doctor created no quota cache' test ! -e "$XDG_CONFIG_HOME/loomy/codex-limits"

reset_case
printf 'claude-sonnet-5-5=ko:%s\n' "$STUB_NOW" >"$XDG_CONFIG_HOME/loomy/models.state"
run 'start print makes no model calls' bash "$REPO/scripts/loomy-start.sh" --root "$WORK/project" --print
run 'start print left providers untouched' bash -c '! grep -Eq "^(codex.*exec|claude.*-p)" "$STUB_LOG"'

reset_case
export STUB_CODEX_ERROR='rate limit' STUB_CLAUDE_ERROR='rate limit'
fails 'writer paused after a handover keeps a valid resumption bridge' 75 bash "$REPO/scripts/loomy-delegate-codex.sh" developer --write --model gpt-6.1-sol --effort high 'bounded implementation'
run 'resumption returns to original bridge with original model and permissions' bash -c 'grep -q "Resume:.*loomy-delegate-codex.sh developer.*--model gpt-6.1-sol.*--write" "$PWD"/.loomy/memory/delegations/*.md'

printf '\nProvider availability: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
