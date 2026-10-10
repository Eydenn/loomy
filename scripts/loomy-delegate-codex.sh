#!/usr/bin/env bash
# Hands a role to the Codex CLI (codex exec). Bash 3.2 compatible.
# Used by a Claude Code lead agent in hybrid mode, or by a Codex lead agent to run a role on its routed model.
#   Roles that write (executor, developer, documenter): workspace-write sandbox, changes land in the working tree.
#   Read-only roles (reviewer, explorer, debugger, architect, security): read-only sandbox, findings only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/memory.sh
source "$SCRIPT_DIR/lib/memory.sh"
# shellcheck source=lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"

ROLE="${1:-}"; [[ $# -gt 0 ]] && shift
ai_delegate_opts codex "$@" || exit 2
shift "$O_SHIFT"
TASK="${1:-}"

if [[ "$ROLE" == "-h" || "$ROLE" == "--help" || -z "$ROLE" || -z "$TASK" ]]; then
  t "Usage: %s <executor|developer|documenter|reviewer|explorer|debugger|architect|security> [options] \"task\"" "$0" >&2; echo >&2
  t "Options: --model <id>, --effort <low|medium|high|xhigh|max>, --write | --read-only (override the role's sandbox), --why \"reason\"; they win over the environment variables." >&2; echo >&2
  t "Possible overrides: DELEGATE_CODEX_MODEL, DELEGATE_CODEX_EFFORT, AI_ROUTE_PROFILE (econome|equilibre|qualite)" >&2; echo >&2
  exit 2
fi

case "$ROLE" in
  review) ROLE="reviewer" ;; research) ROLE="explorer" ;; debug) ROLE="debugger" ;;
  architecture) ROLE="architect" ;; exec|implement) ROLE="executor" ;;
esac

case "$ROLE" in
  executor)
    GUIDANCE="$(t "You are the Executor. Do exactly the bounded task below, within the given scope. Follow the repository's conventions, add or update tests for the changed behaviour, run the relevant checks, then stop. Don't refactor anything outside the scope. If the task turns out to be ambiguous, cross-cutting or risky, stop without modifying any file and explain why it must be escalated.")" ;;
  developer)
    GUIDANCE="$(t "You are the Developer. Implement the feature or fix below within the given scope, following the repository's conventions, with tests. Run the relevant checks and give the exact commands and their results. Stop and report if the change becomes cross-cutting or risky.")" ;;
  documenter)
    GUIDANCE="$(t "You are the Documenter. Only update the documentation the task points to. Be accurate: check every statement against the code. Don't modify source code.")" ;;
  reviewer)
    GUIDANCE="$(t "You are an independent Reviewer. Review the diff or files given in the task. Only report concrete defects: regressions, missed edge cases, security issues, missing tests, needless complexity, each with severity, file reference and evidence. Don't modify any file. \"No findings\" is a valid answer.")" ;;
  explorer)
    GUIDANCE="$(t "You are the Explorer. Only answer the question asked, with short facts and path:line references. Don't propose rewrites. Don't modify any file.")" ;;
  debugger)
    GUIDANCE="$(t "You are the Debugger. Examine the evidence, rank the cause hypotheses, and propose the smallest, most discriminating checks or fixes. Don't modify any file.")" ;;
  architect)
    GUIDANCE="$(t "You are the Architect. Critique the design against the task and the repository's constraints: trade-offs, coupling, simpler alternatives. Don't modify any file.")" ;;
  security)
    GUIDANCE="$(t "You are the Security reviewer. Only inspect the given scope. Report concrete weaknesses with their exploitability, evidence and fix, separating confirmed issues from hypotheses. Don't modify any file.")" ;;
  *) t "Error: unsupported role '%s'." "$ROLE" >&2; echo >&2; exit 2 ;;
esac

# Codex quota nearly exhausted, Claude available with room left: the role goes to Claude, on the model the routing
# gives that role on the Claude side (once: a delegation that already switched never switches back).
if [[ -z "${LOOMY_FAILOVER_FROM:-}" && "$(ai_switch_family codex)" == "claude" ]]; then
  t "loomy-delegate-codex: Codex quota at %s (threshold %s %%): %s handed to Claude until it resets." "$(ai_quota_state codex)" "$(ai_switch_threshold)" "$ROLE" >&2; echo >&2
  # Options that mean the same on the Claude side travel along (not --model: a Codex id).
  FWD=()
  [[ -n "$O_EFFORT" ]] && FWD+=(--effort "$O_EFFORT")
  [[ "$O_SANDBOX" == "write" ]] && FWD+=(--write)
  [[ "$O_SANDBOX" == "read" ]] && FWD+=(--read-only)
  [[ -n "$O_WHY" ]] && FWD+=(--why "$O_WHY")
  LOOMY_REQUESTED_MODEL="${O_MODEL:-${DELEGATE_CODEX_MODEL:-}}" LOOMY_FAILOVER_FROM=codex exec bash "$SCRIPT_DIR/loomy-delegate-claude.sh" "$ROLE" ${FWD[@]+"${FWD[@]}"} "$TASK"
fi
FAILOVER_JSON=""; [[ -n "${LOOMY_FAILOVER_FROM:-}" ]] && FAILOVER_JSON=",\"failover_from\":\"$LOOMY_FAILOVER_FROM\""

CODEX="$(ai_codex_bin)" || { t "Error: Codex CLI not found (PATH, Codex.app or ChatGPT.app). Run loomy doctor." >&2; echo >&2; exit 127; }

ROOT="$(ai_project_root)"
ai_detect_env "$ROOT"
ai_route "$ROLE" codex "$AI_PROFILE"
MODEL="${O_MODEL:-${DELEGATE_CODEX_MODEL:-$R_MODEL}}"
EFFORT="${O_EFFORT:-${DELEGATE_CODEX_EFFORT:-$R_EFFORT}}"

SANDBOX="read-only"
if ai_role_writes "$ROLE"; then SANDBOX="workspace-write"; fi
case "$O_SANDBOX" in write) SANDBOX="workspace-write" ;; read) SANDBOX="read-only" ;; esac
REQUESTED=0
[[ -n "$O_MODEL$O_EFFORT$O_SANDBOX$O_WHY${DELEGATE_CODEX_MODEL:-}${DELEGATE_CODEX_EFFORT:-}${LOOMY_REQUESTED_MODEL:-}" ]] && REQUESTED=1
OFF_ROUTING="$(ai_delegate_off_routing "$ROLE" codex "$MODEL" "$EFFORT" "$SANDBOX" "${LOOMY_FAILOVER_FROM:-}")"
WHY_JSON=",\"requested_model\":$(ai_json_str "${LOOMY_REQUESTED_MODEL:-}"),\"requested\":$([[ $REQUESTED == 1 ]] && echo true || echo false),\"off_routing\":\"$OFF_ROUTING\",\"why\":$(ai_json_str "$(ai_task_excerpt "$O_WHY")")"
# The sandbox asked for differs from the role's default: the prompt must not contradict it.
if [[ "$SANDBOX" == "workspace-write" ]] && ! ai_role_writes "$ROLE"; then
  GUIDANCE="$GUIDANCE $(t "For this task you may create or modify the files it asks for, within its scope.")"
elif [[ "$SANDBOX" == "read-only" ]] && ai_role_writes "$ROLE"; then
  GUIDANCE="$GUIDANCE $(t "For this task the sandbox is read-only: don't modify any file.")"
fi

PROMPT="$GUIDANCE

$(t "Task handed over by the lead agent:")
$TASK

$(t "You are a specialist. Don't take over the project. Give the lead agent a concise result: what you did or found, the files involved, the checks run and their results, the open risks. Reply in English.")"

# Structured delegations: the answer comes back as fixed fields the lead agent (and this bridge) can check.
DFORMAT="$(ai_delegation_format "$ROOT")"
[[ "$DFORMAT" == "structured" ]] && PROMPT="$PROMPT

$(ai_result_contract)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/delegate-codex.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

BEFORE=""
if [[ "$SANDBOX" == "workspace-write" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BEFORE="$(git -C "$ROOT" status --porcelain)"
fi

{ t "loomy-delegate-codex: role=%s model=%s effort=%s sandbox=%s profile=%s" "$ROLE" "$MODEL" "$EFFORT" "$SANDBOX" "$AI_PROFILE"; ai_delegate_banner_extra "$REQUESTED" "${O_WHY:-${LOOMY_REQUESTED_MODEL:-}}" "$OFF_ROUTING"; echo; } >&2

DELEG_ID="$(ai_delegation_id)"
STARTED="$(date +%s)"
START_MODEL="$MODEL"
CHILD_PID=""
FINAL_WRITTEN=0
delegate_start_exists() {
  ai_journal_all "$ROOT" | grep -F "\"type\":\"delegation_start\",\"id\":\"$DELEG_ID\"" >/dev/null
}
delegate_final_exists() {
  ai_journal_all "$ROOT" | grep -F "\"type\":\"delegation\",\"id\":\"$DELEG_ID\"" >/dev/null
}
delegate_stop_child() {
  local attempts=0
  [[ -n "$CHILD_PID" ]] || return 0
  kill -TERM -- "-$CHILD_PID" 2>/dev/null || true
  while kill -0 -- "-$CHILD_PID" 2>/dev/null && (( attempts < 5 )); do
    sleep 1
    attempts=$(( attempts + 1 ))
  done
  if kill -0 -- "-$CHILD_PID" 2>/dev/null; then kill -KILL -- "-$CHILD_PID" 2>/dev/null || true; fi
  wait "$CHILD_PID" 2>/dev/null || true
  CHILD_PID=""
}
delegate_finish() {
  local signal="$1" exit_code="$2" duration
  trap '' INT TERM HUP
  trap - EXIT
  delegate_stop_child
  if (( ! FINAL_WRITTEN )) && delegate_start_exists && ! delegate_final_exists; then
    duration=$(( $(date +%s) - STARTED )); (( duration >= 0 )) || duration=0
    ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"$DELEG_ID\",\"bridge\":\"codex\",\"role\":\"$ROLE\",\"family\":\"codex\",\"model\":\"$START_MODEL\",\"effort\":\"$EFFORT\",\"profile\":\"$AI_PROFILE\",\"sandbox\":\"$SANDBOX\",\"status\":\"interrupted\",\"outcome\":\"interrupted\",\"signal\":\"$signal\",\"duration_s\":$duration,\"tokens_in\":0,\"tokens_cached\":0,\"tokens_out\":0,\"cost_usd\":0,\"cost_source\":\"estimate\",\"files_changed\":0$FAILOVER_JSON$WHY_JSON,\"task\":$(ai_json_str "$(ai_task_excerpt "$TASK")")"
    FINAL_WRITTEN=1
  fi
  rm -rf "$TMP"
  exit "$exit_code"
}
trap 'delegate_finish INT 130' INT
trap 'delegate_finish TERM 143' TERM
trap 'delegate_finish HUP 129' HUP
trap 'delegate_finish EXIT "$?"' EXIT
ai_delegate_journal_start "$ROOT" "$DELEG_ID" codex "$ROLE" codex "$MODEL" "$EFFORT" "$SANDBOX" "$TASK" "$REQUESTED" "$OFF_ROUTING" "$O_WHY"
run_codex() {
  LOOMY_DELEGATION=1 exec perl -e 'setpgrp(0, 0); getpgrp(0) == $$ or die "setpgrp: $!"; exec @ARGV or die "exec: $!"' \
    "$CODEX" exec -m "$1" -c "model_reasoning_effort=$EFFORT" -s "$SANDBOX" -C "$ROOT" \
    --skip-git-repo-check --ephemeral --json -o "$TMP/last.txt" "$PROMPT" </dev/null >"$TMP/log.txt" 2>&1
}
set +e
run_codex "$MODEL" &
CHILD_PID=$!
wait "$CHILD_PID"; STATUS=$?
CHILD_PID=""
set -e
# Model refused (doesn't exist or no access for this account): recorded for this machine, then fallback to the next in its chain.
while (( STATUS != 0 )) && grep -qiE "model.*(not found|does not exist|not supported|unavailable|not available)|unknown model|model_not_found" "$TMP/log.txt"; do
  ai_model_mark "$MODEL" ko
  NEXT="$(ai_model_next codex "$MODEL")"
  [[ -n "$NEXT" ]] || break
  t "loomy-delegate-codex: %s unavailable for this account, falling back to %s (remembered for next time)." "$MODEL" "$NEXT" >&2; echo >&2
  MODEL="$NEXT"
  set +e
  run_codex "$MODEL" &
  CHILD_PID=$!
  wait "$CHILD_PID"; STATUS=$?
  CHILD_PID=""
  set -e
done
DURATION=$(( $(date +%s) - STARTED ))

# Usage reported by the "turn.completed" events of codex exec --json.
read -r T_IN T_CACHED T_OUT < <(grep '"turn.completed"' "$TMP/log.txt" | awk '
  { if (match($0, /"input_tokens":[0-9]+/)) i += substr($0, RSTART+15, RLENGTH-15)
    if (match($0, /"cached_input_tokens":[0-9]+/)) c += substr($0, RSTART+22, RLENGTH-22)
    if (match($0, /"output_tokens":[0-9]+/)) o += substr($0, RSTART+16, RLENGTH-16) }
  END { printf "%d %d %d\n", i, c, o }')
COST="$(ai_cost_estimate "$MODEL" "$(( T_IN - T_CACHED ))" "$T_CACHED" "$T_OUT")"

CHANGED=0
if [[ $STATUS -eq 0 && "$SANDBOX" == "workspace-write" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  AFTER="$(git -C "$ROOT" status --porcelain)"
  CHANGED="$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -c '^> ' || true)"
fi

RESULT="ok"; [[ $STATUS -ne 0 ]] && RESULT="error"
FORMAT_JSON=""
if [[ "$DFORMAT" == "structured" && "$RESULT" == "ok" ]]; then
  OUTCOME="$(ai_result_outcome "$(cat "$TMP/last.txt" 2>/dev/null)")"
  FORMAT_JSON=",\"format\":\"structured\",\"outcome\":\"${OUTCOME:-unformatted}\""
fi
ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"$DELEG_ID\",\"bridge\":\"codex\",\"role\":\"$ROLE\",\"family\":\"codex\",\"model\":\"$MODEL\",\"effort\":\"$EFFORT\",\"profile\":\"$AI_PROFILE\",\"sandbox\":\"$SANDBOX\",\"status\":\"$RESULT\",\"duration_s\":$DURATION,\"tokens_in\":$T_IN,\"tokens_cached\":$T_CACHED,\"tokens_out\":$T_OUT,\"cost_usd\":${COST:-0},\"cost_source\":\"estimate\",\"files_changed\":$CHANGED$FAILOVER_JSON$FORMAT_JSON$WHY_JSON,\"task\":$(ai_json_str "$(ai_task_excerpt "$TASK")")"
FINAL_WRITTEN=1
# Shared memory: the task and the full result, for the next sessions and the other tool.
loomy_memory_save "$ROOT" "$DELEG_ID" "$ROLE" "$MODEL" "$RESULT" "$TASK" "$(cat "$TMP/last.txt" 2>/dev/null || true)"

if [[ $STATUS -ne 0 ]]; then
  t "loomy-delegate-codex: codex exec failed (code %s). Last log lines:" "$STATUS" >&2; echo >&2
  tail -20 "$TMP/log.txt" >&2
  exit "$STATUS"
fi

cat "$TMP/last.txt"
echo

if [[ "$SANDBOX" == "workspace-write" ]] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ "$CHANGED" != "0" ]]; then
    t "loomy-delegate-codex: the working tree changed — review with 'git diff' before accepting:" >&2; echo >&2
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed -n 's/^> /  /p' >&2 || true
  else
    t "loomy-delegate-codex: no file modified." >&2; echo >&2
  fi
fi
t "loomy-delegate-codex: %ss · input tokens %s (%s cached), output %s · estimated cost \$%s" "$DURATION" "$T_IN" "$T_CACHED" "$T_OUT" "${COST:-?}" >&2; echo >&2
