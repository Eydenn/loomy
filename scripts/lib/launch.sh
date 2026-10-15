#!/usr/bin/env bash
# Single process boundary for provider CLIs. Sourced, Bash 3.2 compatible.
# shellcheck disable=SC2034  # exported launch contract
# shellcheck source=models.sh
declare -F ai_codex_bin >/dev/null || source "${BASH_SOURCE[0]%/*}/models.sh"

# Tests must explicitly trust the resolved stub directory, including app-bundled binaries.
_loomy_cli_test_guard() {
  [[ "${LOOMY_TEST_GUARD:-}" == 1 ]] || return 0
  local name="$1" binary message stubs
  binary="$(command -v "${2:-$1}" 2>/dev/null || true)"
  if [[ -n "$binary" ]]; then
    binary="$(_ai_realpath "$binary")"
    binary="$(cd "$(dirname "$binary")" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "${binary##*/}")" || binary=""
  fi
  # LOOMY_TEST_STUBS is a colon-separated list of trusted stub directories (tests append their own).
  stubs="${LOOMY_TEST_STUBS:-}"
  if [[ -n "$binary" ]]; then
    local dir old_ifs="$IFS"; IFS=:
    for dir in $stubs; do
      [[ -n "$dir" ]] || continue
      if [[ "$binary" == "$dir/"* ]]; then IFS="$old_ifs"; return 0; fi
    done
    IFS="$old_ifs"
  fi
  message="loomy: test guard: refusing to launch real $name (${binary:-not found})"
  printf '%s\n' "$message" >&2
  if [[ -n "${LOOMY_TEST_GUARD_LOG:-}" ]]; then printf '%s\n' "$message" >>"$LOOMY_TEST_GUARD_LOG"; fi
  return 97
}


loomy_cli_resolve() {
  LOOMY_CLI_BIN=""
  case "$1" in
    claude|local) LOOMY_CLI_BIN="$(command -v claude 2>/dev/null || true)" ;;
    codex) LOOMY_CLI_BIN="$(ai_codex_bin 2>/dev/null || true)" ;;
    *) return 2 ;;
  esac
  [[ -z "${LOOMY_CLI_META_BIN:-}" ]] || LOOMY_CLI_BIN="$LOOMY_CLI_META_BIN"
  [[ -n "$LOOMY_CLI_BIN" && -x "$LOOMY_CLI_BIN" ]] || return 127
}
_loomy_cli_check() {
  local tool="$1" role="$2" model="$3" valid tier chain
  # Guard before all quota/cache work, even when resolution would otherwise fail.
  loomy_cli_resolve "$tool" || { _loomy_cli_test_guard "$tool" || return $?; return 127; }
  _loomy_cli_test_guard "$tool" "$LOOMY_CLI_BIN" || return $?
  [[ "$tool" != local ]] || return 0
  declare -F ai_provider_saturated >/dev/null || source "${BASH_SOURCE[0]%/*}/usage.sh"
  if [[ "${LOOMY_CLI_PROBE:-0}" == 1 ]]; then
    if ai_provider_saturated "$tool"; then LOOMY_CLI_RESUME_AT="$(ai_provider_reset "$tool")"; return 75; fi
    return 0
  fi
  valid=0
  for tier in TOP MID FAST; do
    _ai_ascii_upper "$tool"; eval "chain=\"\$AI_VALIDATED_${_AI_ASCII_UPPER}_${tier}\""
    case " $chain " in *" $model "*) [[ -z "$model" ]] || valid=1 ;; esac
  done
  # The documented Claude aliases (--model opus|sonnet|haiku) are resolved by Claude Code itself.
  if [[ "$tool" == claude ]]; then case "$model" in opus|sonnet|haiku) valid=1 ;; esac; fi
  (( valid )) || return 2
  if [[ "${LOOMY_CLI_MANAGED:-0}" == 1 && "${LOOMY_CLI_BRIDGE_CHECKED:-0}" != 1 ]]; then
    ai_delegate_provider_guard "$tool"
  elif ai_provider_saturated "$tool" || ! ai_model_usable "$model" "$tool"; then
    LOOMY_CLI_RESUME_AT="$(ai_provider_reset "$tool")"
    return 75
  fi
  [[ -n "$role" ]]
}

# Every launch caller shares the same actionable validation/pause diagnostic.
loomy_cli_check_message() {
  case "$1" in
    75)
      t "paused until %s (both providers saturated)" "${LOOMY_CLI_RESUME_AT:-$(ai_provider_reset "$2")}" >&2; echo >&2 ;;
    2) t "model not validated: %s" "$3" >&2; echo >&2 ;;
  esac
  return 0
}
loomy_cli_check() {
  local rc=0
  _loomy_cli_check "$@" || rc=$?
  (( rc == 0 )) || loomy_cli_check_message "$rc" "$1" "$3"
  return "$rc"
}

# Preserve specific opener refusals in watch's footer without stale route warnings.
loomy_cli_open_note() {
  local rc="$1" output="$2" platform
  platform="$(t 'Desktop apps: macOS only')"
  if [[ "$output" == *"$platform"* ]]; then printf '%s' "$platform"
  elif (( rc == 3 || rc == 97 )); then printf '%s\n' "$output" | sed '/^[[:space:]]*$/d' | tail -1
  fi
  return 0
}
loomy_cli_meta() (
  case "${2:-}" in --version|update|login|auth) ;; *) return 2 ;; esac
  loomy_cli_resolve "$1" || { _loomy_cli_test_guard "$1" || return $?; return 127; }
  _loomy_cli_test_guard "$1" "$LOOMY_CLI_BIN" || return $?
  shift
  "$LOOMY_CLI_BIN" "$@"
)
loomy_cli_links() {
  printf ',"parent_id":%s,"parent_delegation":%s,"parent_session":%s,"parent_agent_id":%s,"attempt_id":%s' \
    "$(ai_json_str "${LOOMY_EVENT_PARENT_ID-${LOOMY_PARENT_ID:-}}")" "$(ai_json_str "${LOOMY_EVENT_PARENT_ID-${LOOMY_PARENT_ID:-}}")" \
    "$(ai_json_str "${LOOMY_PARENT_SESSION:-}")" "$(ai_json_str "${LOOMY_PARENT_AGENT:-}")" "$(ai_json_str "${LOOMY_ATTEMPT:-}")"
}
loomy_cli_end() { ai_journal_write "$1" "$2$(loomy_cli_links)"; }
loomy_cli_bridge_start() {
  local req=false; [[ "${10}" == "1" ]] && req=true
  loomy_cli_end "$1" "\"type\":\"delegation_start\",\"id\":\"$2\",\"pid\":$$,\"bridge\":\"$3\",\"role\":\"$4\",\"family\":\"$5\",\"model\":\"$6\",\"effort\":\"$7\",\"sandbox\":\"$8\",\"requested\":$req,\"requested_model\":$(ai_json_str "${LOOMY_REQUESTED_MODEL:-}"),\"off_routing\":\"${11}\",\"why\":$(ai_json_str "$(ai_task_excerpt "${12}")"),\"task\":$(ai_json_str "$(ai_task_excerpt "$9")")"
}
# Explicit provider IDs only; never pair sessions by cwd, role or clock proximity.
loomy_cli_link() {
  local root="$1" tool="$2" sid="$3" parent="${4:-${LOOMY_PARENT_ID:-}}"
  [[ "$sid" =~ ^[A-Za-z0-9_.:-]{1,100}$ && -n "$parent" ]] || return 0
  ai_journal_write "$root" "\"type\":\"bridge_link\",\"schema\":2,\"tool\":$(ai_json_str "$tool"),\"session\":$(ai_json_str "$sid"),\"session_key\":$(ai_json_str "$tool:$sid"),\"parent_delegation\":$(ai_json_str "$parent"),\"attempt_id\":$(ai_json_str "${LOOMY_ATTEMPT:-}"),\"evidence\":\"launch-session-id\""
}
# Stream is relayed unchanged to the private bridge output; only structural IDs enter the journal.
_loomy_cli_stream() {
  exec perl -MJSON::PP -MPOSIX=strftime -MFcntl=O_RDWR,O_CREAT,O_WRONLY,O_APPEND,O_NOFOLLOW -e '
    my ($file,$parent,$attempt)=splice @ARGV,0,3; my ($sid,%seen); $|=1;
    setpgrp(0,0); my $pid=open my $provider,"-|"; defined($pid) or die $!;
    if (!$pid) {delete @ENV{qw(LOOMY_CLI_MANAGED LOOMY_CLI_BRIDGE_CHECKED LOOMY_CLI_ID LOOMY_CLI_SESSION_ID LOOMY_EVENT_PARENT_ID LOOMY_CLI_DETACHED)}; exec @ARGV or die $!}
    sub emit_link {
      my ($id,$ancestor)=@_; return unless defined($id) && !ref($id) && $id =~ /\A[A-Za-z0-9_.:-]{1,100}\z/;
      return if $seen{$id}++; return unless length($file);
      (my $lockfile=$file)=~s{/[^/]+$}{/events.lock};
      sysopen my $lock,$lockfile,O_RDWR|O_CREAT|O_NOFOLLOW,0600 or return; flock $lock,2 or return;
      sysopen my $f,$file,O_WRONLY|O_APPEND|O_NOFOLLOW or return;
      my $row=JSON::PP->new->canonical->encode({schema=>2,tool=>"codex",session=>$id,session_key=>"codex:$id",parent_delegation=>$parent,attempt_id=>$attempt,parent_session=>$ancestor//"",evidence=>"exec-json"}); print $f "{\"ts\":".encode_json(strftime("%Y-%m-%dT%H:%M:%SZ",gmtime)).",\"type\":\"bridge_link\",".substr($row,1)."\n";
    }
    while (<$provider>) { print; my $e=eval {decode_json($_)}; next unless ref($e) eq "HASH";
      if (($e->{type}//"") eq "thread.started") { $sid=$e->{thread_id}; emit_link($sid,"") }
      my $item=$e->{item}; next unless ref($item) eq "HASH" && ($item->{type}//"") eq "collab_tool_call";
      next unless ($item->{tool}//"") eq "spawn_agent" && ref($item->{receiver_thread_ids}) eq "ARRAY";
      emit_link($_,$item->{sender_thread_id}//$sid) for @{$item->{receiver_thread_ids}};
    }
    close $provider; exit (($? & 127) ? 128+($? & 127) : $? >> 8);
  ' "$@"
}
loomy_cli_run() (
  local tool="$1" role="$2" model="$3" rc=0 root id body started child="" stream_file=""
  shift 3; [[ "${1:-}" == -- ]] || return 2; shift
  loomy_cli_check "$tool" "$role" "$model" || return $?
  if [[ "${LOOMY_CLI_PROBE:-0}" != 1 ]]; then
    local arg pending=0 found=0 desktop=0
    for arg in "$@"; do
      if (( pending )); then [[ "$arg" == "$model" ]] || return 2; found=1; pending=0; continue; fi
      case "$arg" in
        --desktop) [[ "$tool" != claude ]] || desktop=1 ;;
        -m|--model) pending=1 ;;
        --model=*) [[ "${arg#--model=}" == "$model" ]] || return 2; found=1 ;;
        model=*) return 2 ;; # Config must not override the checked model flag.
      esac
    done
    (( pending == 0 )) || return 2
    # Desktop hands over an existing session and rejects model/effort flags.
    if (( ! found && ! desktop )); then
      if [[ "$tool" == claude || "$tool" == local ]]; then set -- "$@" --model "$model"; else set -- "$@" -m "$model"; fi
    fi
  fi
  declare -F ai_journal_write >/dev/null || source "${BASH_SOURCE[0]%/*}/journal.sh"
  root="${ROOT:-$(ai_project_root)}"; id="${LOOMY_CLI_ID:-$(perl -e 'printf "d%d-%d-%06x",time,$$,rand(2**24)')}"
  if [[ "$role" == lead ]]; then unset LOOMY_DELEGATION; else export LOOMY_DELEGATION=1; fi
  export LOOMY_PARENT_ID="${LOOMY_PARENT_ID:-$id}" LOOMY_ATTEMPT="${LOOMY_ATTEMPT:-$id}"
  started="$(date +%s)"
  body="\"id\":$(ai_json_str "$id"),\"bridge\":$(ai_json_str "$tool"),\"family\":$(ai_json_str "$tool"),\"role\":$(ai_json_str "$role"),\"model\":$(ai_json_str "$model"),\"effort\":$(ai_json_str "${EFFORT:-${LOOMY_CLI_EFFORT:-}}")"
  # A lead session is not a delegation: it keeps its ids for child links but never counts as one in the journal.
  local journal_ends=1
  [[ "${LOOMY_CLI_MANAGED:-0}" != 1 && "${LOOMY_CLI_PROBE:-0}" != 1 && "$role" != lead ]] || journal_ends=0
  _loomy_cli_finish() {
    local status="$1"
    trap - EXIT INT TERM HUP
    if [[ -n "$child" ]]; then
      local tries=0
      kill -TERM -- "-$child" 2>/dev/null || kill -TERM "$child" 2>/dev/null || true
      while kill -0 -- "-$child" 2>/dev/null && (( tries < 5 )); do sleep 1; tries=$((tries+1)); done
      kill -KILL -- "-$child" 2>/dev/null || true
      wait "$child" 2>/dev/null || true
    fi
    if (( journal_ends )); then
      local result=ok; (( status == 0 )) || result=error
      (( status < 128 )) || result=interrupted
      # A local model costs nothing and never touches files: keep the usual cost fields so status and stats count it.
      local extra=""; [[ "$tool" != local ]] || extra=',"profile":"-","sandbox":"text-only","tokens_in":0,"tokens_out":0,"cost_usd":0,"cost_source":"local","files_changed":0'
      loomy_cli_end "$root" "\"type\":\"delegation\",$body,\"status\":\"$result\",\"duration_s\":$(( $(date +%s)-started ))$extra"
    fi
    exit "$status"
  }
  trap '_loomy_cli_finish "$?"' EXIT
  trap '_loomy_cli_finish 130' INT
  trap '_loomy_cli_finish 143' TERM
  if [[ "${LOOMY_CLI_DETACHED:-0}" == 1 ]]; then trap '' HUP; else trap '_loomy_cli_finish 129' HUP; fi
  if [[ "${LOOMY_CLI_PROBE:-0}" == 1 ]]; then
    local seconds="${LOOMY_MODEL_PROBE_TIMEOUT:-10}"
    [[ "$seconds" =~ ^[1-9][0-9]*$ ]] || seconds=10
    perl -e '
      my $seconds=shift; my $pid=fork(); defined $pid or die $!;
      if (!$pid) {setpgrp(0,0); exec @ARGV or die $!}
      $SIG{ALRM}=sub {kill "KILL",-$pid; kill "KILL",$pid; waitpid($pid,0); exit 124};
      alarm $seconds; waitpid($pid,0); alarm 0; exit (($? & 127) ? 128+($? & 127) : $? >> 8);
    ' "$seconds" "$LOOMY_CLI_BIN" "$@" || rc=$?
  else
    # The bridge owns this group too; its signal handler can terminate the whole tree.
    [[ -z "${LOOMY_CLI_SESSION_ID:-}" ]] || loomy_cli_link "$root" "$tool" "$LOOMY_CLI_SESSION_ID"
    if [[ "$tool" == codex && " $* " == *" --json "* ]]; then
      if ai_journal_enabled "$root" && ai_journal_prepare "$root"; then stream_file="$(ai_journal_file "$root")"; fi
      _loomy_cli_stream "$stream_file" "$LOOMY_PARENT_ID" "$LOOMY_ATTEMPT" "$LOOMY_CLI_BIN" "$@" &
    elif [[ "$role" == lead && -t 0 && " $* " != *" --desktop "* ]]; then
      # Interactive leads keep the terminal foreground group and project hooks.
      "$LOOMY_CLI_BIN" "$@" || rc=$?
      return "$rc"
    else
      perl -e 'setpgrp(0,0); delete @ENV{qw(LOOMY_CLI_MANAGED LOOMY_CLI_BRIDGE_CHECKED LOOMY_CLI_ID LOOMY_CLI_SESSION_ID LOOMY_EVENT_PARENT_ID LOOMY_CLI_DETACHED)}; exec @ARGV or die $!' "$LOOMY_CLI_BIN" "$@" <&0 &
    fi
    child=$!
    # $! is the actual owned child on Bash 3.2 too; $$ identifies the caller of this subshell.
    if (( journal_ends )); then loomy_cli_end "$root" "\"type\":\"delegation_start\",$body,\"pid\":$child"; fi
    wait "$child" || rc=$?; child=""
  fi
  return "$rc"
)
# Replace the bridge worker, keeping its PID as the process-group owner.
loomy_cli_bridge_exec() {
  loomy_cli_check "$1" "$2" "$3" || return $?
  export ROOT EFFORT
  LOOMY_CLI_BRIDGE_CHECKED=1 exec perl -e 'setpgrp(0,0); exec @ARGV or die $!' \
    bash -c 'source "$1"; shift; loomy_cli_run "$@"' _ "${BASH_SOURCE[0]}" "$@"
}
# Child runner owns both events; caller receives a PID, never a premature success end.
loomy_cli_spawn() {
  loomy_cli_check "$1" "$2" "$3" || return $?
  LOOMY_CLI_DETACHED=1 loomy_cli_run "$@" </dev/null &
  LOOMY_CLI_PID=$!
  # Catch an immediate desktop handover refusal; later exits are journaled by the runner.
  sleep 0.2
  kill -0 "$LOOMY_CLI_PID" 2>/dev/null || wait "$LOOMY_CLI_PID"
}

# App/window openers are launchers, not provider model processes. Never prefix a CLI binary.
loomy_cli_app() (
  local tool="$1" launcher="$2" binary rc=0; shift 2
  case "$tool:$launcher" in claude:open|codex:open|claude:osascript|codex:osascript) ;; *) return 2 ;; esac
  binary="$(type -P "$launcher")" || return 127
  _loomy_cli_test_guard "$launcher" "$binary" || return $?
  "$binary" "$@" || rc=$?
  declare -F ai_journal_write >/dev/null || source "${BASH_SOURCE[0]%/*}/journal.sh"
  ai_journal_write "${ROOT:-$(ai_project_root)}" "\"type\":\"app_open\",\"tool\":$(ai_json_str "$tool"),\"launcher\":$(ai_json_str "$launcher"),\"exit_code\":$rc"
  return "$rc"
)
