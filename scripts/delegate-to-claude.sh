#!/usr/bin/env bash
# Hands a role to the Claude Code CLI (claude -p). Bash 3.2 compatible.
# Used by a Codex lead agent in hybrid mode: Claude inspects and reports, its editing tools disabled.
# Roles that write (executor, developer, documenter) only come here when the Codex quota is nearly exhausted
# (LOOMY_FAILOVER_FROM=codex): edits accepted, commands only inside Claude Code's sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/usage.sh
source "$SCRIPT_DIR/lib/usage.sh"

ROLE="${1:-}"
TASK="${2:-}"

if [[ -z "$ROLE" || -z "$TASK" ]]; then
  t "Usage: %s <architect|debugger|security|reviewer|explorer> \"task\"" "$0" >&2; echo >&2
  t "Old names accepted: architecture, debug, review, research." >&2; echo >&2
  t "Possible overrides: DELEGATE_CLAUDE_MODEL, DELEGATE_CLAUDE_EFFORT, DELEGATE_CLAUDE_MAX_TURNS, AI_ROUTE_PROFILE" >&2; echo >&2
  exit 2
fi

case "$ROLE" in
  review) ROLE="reviewer" ;; research) ROLE="explorer" ;; debug) ROLE="debugger" ;; architecture) ROLE="architect" ;;
esac

if ! command -v claude >/dev/null 2>&1; then
  t "Error: the Claude Code CLI ('claude') is not in the PATH. Run loomy doctor." >&2; echo >&2
  exit 127
fi

case "$ROLE" in
  reviewer)
    ROLE_GUIDANCE="$(t "Act as a senior, independent code reviewer. Inspect the repository or the diff the task is about. Only report concrete defects: regressions, missing tests, dangerous assumptions or needless complexity. Don't modify any file. Give concise findings, ranked by severity, with file references and evidence.")" ;;
  architect)
    ROLE_GUIDANCE="$(t "Act as an independent software architect. Critique the proposed or current architecture against the task and the repository's constraints: key trade-offs, coupling, maintainability, scaling and simpler alternatives. Don't modify any file. Give concise, justified recommendations.")" ;;
  debugger)
    ROLE_GUIDANCE="$(t "Act as an independent debugging specialist. Examine the evidence available in the repository and the logs. Identify the likely causes, rank the hypotheses and propose the smallest, most discriminating checks or fixes. Don't modify any file. Avoid lists of speculative fixes.")" ;;
  security)
    ROLE_GUIDANCE="$(t "Act as an independent security reviewer. Only inspect the scope the task is about. Identify concrete security weaknesses with their exploitation context, evidence, affected files and recommended fix. Don't modify any file. Separate confirmed issues from hypotheses.")" ;;
  executor|developer|documenter)
    if [[ "${LOOMY_FAILOVER_FROM:-}" != "codex" ]]; then
      t "Error: unsupported role '%s'. Roles that write go through Codex (delegate-to-codex.sh) or a native subagent." "$ROLE" >&2; echo >&2; exit 2
    fi
    case "$ROLE" in
      executor) ROLE_GUIDANCE="$(t "You are the Executor. Do exactly the bounded task below, within the given scope. Follow the repository's conventions, add or update tests for the changed behaviour, run the relevant checks, then stop. Don't refactor anything outside the scope. If the task turns out to be ambiguous, cross-cutting or risky, stop without modifying any file and explain why it must be escalated.")" ;;
      developer) ROLE_GUIDANCE="$(t "You are the Developer. Implement the feature or fix below within the given scope, following the repository's conventions, with tests. Run the relevant checks and give the exact commands and their results. Stop and report if the change becomes cross-cutting or risky.")" ;;
      *) ROLE_GUIDANCE="$(t "You are the Documenter. Only update the documentation the task points to. Be accurate: check every statement against the code. Don't modify source code.")" ;;
    esac ;;
  explorer)
    ROLE_GUIDANCE="$(t "Act as a focused technical researcher. Only study the question asked, favour reference evidence available in the environment, and give concise findings, uncertainties and the recommended action. Don't modify any file.")" ;;
  *)
    t "Error: unsupported role '%s'. Roles that write go through Codex (delegate-to-codex.sh) or a native subagent." "$ROLE" >&2; echo >&2
    exit 2 ;;
esac

# Claude quota nearly exhausted, Codex available with room left: the role goes to Codex (read-only sandbox for these
# roles), on the model the routing gives it on the Codex side. Once only: a delegation that already switched stays.
if [[ -z "${LOOMY_FAILOVER_FROM:-}" && "$(ai_switch_family claude)" == "codex" ]]; then
  t "delegate-to-claude: Claude quota at %s (threshold %s %%): %s handed to Codex until it resets." "$(ai_quota_state claude)" "$(ai_switch_threshold)" "$ROLE" >&2; echo >&2
  LOOMY_FAILOVER_FROM=claude exec bash "$SCRIPT_DIR/delegate-to-codex.sh" "$ROLE" "$TASK"
fi
WRITES=0; ai_role_writes "$ROLE" && WRITES=1
SANDBOX="read-only"; (( WRITES )) && SANDBOX="workspace-write"
FAILOVER_JSON=""; [[ -n "${LOOMY_FAILOVER_FROM:-}" ]] && FAILOVER_JSON=",\"failover_from\":\"$LOOMY_FAILOVER_FROM\""

ROOT="$(ai_project_root)"
ai_detect_env "$ROOT"
ai_route "$ROLE" claude "$AI_PROFILE"
# Deliberately not CLAUDE_MODEL/CLAUDE_EFFORT: Claude Code exports CLAUDE_EFFORT in its own sessions.
MODEL="${DELEGATE_CLAUDE_MODEL:-$R_MODEL}"
EFFORT="${DELEGATE_CLAUDE_EFFORT:-$R_EFFORT}"
MAX_TURNS="${DELEGATE_CLAUDE_MAX_TURNS:-${CLAUDE_MAX_TURNS:-8}}"

PROMPT="$ROLE_GUIDANCE

$(t "Task handed over by the lead agent:")
$TASK

$( (( WRITES )) && t "You are a specialist. Don't take over the project. Give the lead agent a concise result: what you did or found, the files involved, the checks run and their results, the open risks. Reply in English." || t "You are a specialist. Don't take over the project. Don't modify any file in the repository. Give your result only to the lead agent. Reply in English.")"

# Structured delegations: the answer comes back as fixed fields the lead agent (and this bridge) can check.
DFORMAT="$(ai_delegation_format "$ROOT")"
[[ "$DFORMAT" == "structured" ]] && PROMPT="$PROMPT

$(ai_result_contract)"

run_claude() {
  if (( WRITES )); then
    # Like Codex's workspace-write sandbox: file edits accepted in the project, shell commands only inside Claude
    # Code's sandbox (filesystem limited to the project, no network); anything else is refused, never asked.
    LOOMY_DELEGATION=1 claude -p "$PROMPT" --output-format json --max-turns "$MAX_TURNS" \
      --model "$1" --effort "$EFFORT" --permission-mode acceptEdits \
      --settings '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'
  else
    LOOMY_DELEGATION=1 claude -p "$PROMPT" --output-format json --max-turns "$MAX_TURNS" \
      --model "$1" --effort "$EFFORT" \
      --disallowedTools "Edit,Write,NotebookEdit"
  fi
}
BEFORE=""
if (( WRITES )) && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then BEFORE="$(git -C "$ROOT" status --porcelain)"; fi

t "delegate-to-claude: role=%s model=%s effort=%s max_turns=%s profile=%s" "$ROLE" "$MODEL" "$EFFORT" "$MAX_TURNS" "$AI_PROFILE" >&2; echo >&2

DELEG_ID="$(ai_delegation_id)"
ai_journal_start "$ROOT" "$DELEG_ID" claude "$ROLE" claude "$MODEL" "$EFFORT" "$SANDBOX" "$TASK"
STARTED="$(date +%s)"
set +e
OUT="$(run_claude "$MODEL")"
STATUS=$?
set -e

# Old Claude Code versions refuse recent model ids: try again with the family alias.
if grep -q 'does not support this model' <<<"$OUT"; then
  ALIAS="$(ai_claude_alias "$MODEL")"
  t "delegate-to-claude: this Claude Code version doesn't know %s, trying again with '%s' (run 'claude update')." "$MODEL" "$ALIAS" >&2; echo >&2
  set +e
  OUT="$(run_claude "$ALIAS")"
  STATUS=$?
  set -e
fi

# Model refused (doesn't exist or no access for this account): recorded for this machine, then fallback to the next
# model of its chain in the catalog (not everyone has access to the latest models).
while grep -qiE "may not exist|not have access|model.*not (found|available)|invalid model|not_found_error" <<<"$OUT"; do
  ai_model_mark "$MODEL" ko
  NEXT="$(ai_model_next claude "$MODEL")"
  [[ -n "$NEXT" ]] || break
  t "delegate-to-claude: %s unavailable for this account, falling back to %s (remembered for next time)." "$MODEL" "$NEXT" >&2; echo >&2
  MODEL="$NEXT"
  set +e
  OUT="$(run_claude "$MODEL")"
  STATUS=$?
  set -e
done

DURATION=$(( $(date +%s) - STARTED ))
# Cost and tokens reported by the JSON output of claude -p.
T_IN="$(ai_json_num "$OUT" input_tokens)"
T_CACHED="$(ai_json_num "$OUT" cache_read_input_tokens)"
T_CWRITE="$(ai_json_num "$OUT" cache_creation_input_tokens)"
T_OUT="$(ai_json_num "$OUT" output_tokens)"
COST="$(ai_json_num "$OUT" total_cost_usd)"
RESULT="ok"
if [[ $STATUS -ne 0 ]] || grep -q '"is_error":true' <<<"$OUT"; then RESULT="error"; fi
FORMAT_JSON=""
if [[ "$DFORMAT" == "structured" && "$RESULT" == "ok" ]]; then
  ANSWER="$OUT"; command -v python3 >/dev/null 2>&1 && ANSWER="$(python3 -c 'import json, sys; print(json.loads(sys.stdin.read()).get("result", ""))' <<<"$OUT" 2>/dev/null || printf '%s' "$OUT")"
  OUTCOME="$(ai_result_outcome "$ANSWER")"
  FORMAT_JSON=",\"format\":\"structured\",\"outcome\":\"${OUTCOME:-unformatted}\""
fi
CHANGED=0; AFTER=""
if (( WRITES )) && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  AFTER="$(git -C "$ROOT" status --porcelain)"
  CHANGED="$(diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | grep -c '^>' || true)"
fi
ai_journal_write "$ROOT" "\"type\":\"delegation\",\"id\":\"$DELEG_ID\",\"bridge\":\"claude\",\"role\":\"$ROLE\",\"family\":\"claude\",\"model\":\"$MODEL\",\"effort\":\"$EFFORT\",\"profile\":\"$AI_PROFILE\",\"sandbox\":\"$SANDBOX\",\"status\":\"$RESULT\",\"duration_s\":$DURATION,\"tokens_in\":$(( T_IN + T_CACHED + T_CWRITE )),\"tokens_cached\":$T_CACHED,\"tokens_out\":$T_OUT,\"cost_usd\":$COST,\"cost_source\":\"reported\",\"files_changed\":$CHANGED$FAILOVER_JSON$FORMAT_JSON,\"task\":$(ai_json_str "$(ai_task_excerpt "$TASK")")"
t "delegate-to-claude: %ss · input tokens %s (%s cached), output %s · cost \$%s" "$DURATION" "$(( T_IN + T_CACHED + T_CWRITE ))" "$T_CACHED" "$T_OUT" "$(awk -v c="$COST" 'BEGIN { printf "%.4f", c }')" >&2; echo >&2

# Handed over by the Codex bridge: its caller expects Codex's plain answer, not Claude's JSON.
if [[ "${LOOMY_FAILOVER_FROM:-}" == "codex" ]] && command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json, sys; print(json.loads(sys.stdin.read()).get("result", ""))' <<<"$OUT" 2>/dev/null || printf '%s\n' "$OUT"
else
  printf '%s\n' "$OUT"
fi
if (( WRITES )); then
  if [[ "$CHANGED" != "0" ]]; then
    t "delegate-to-claude: the working tree changed — review with 'git diff' before accepting:" >&2; echo >&2
    diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER") | sed -n 's/^> /  /p' >&2 || true
  else t "delegate-to-claude: no file modified." >&2; echo >&2; fi
fi
exit "$STATUS"
