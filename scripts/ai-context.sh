#!/usr/bin/env bash
# Resume context for the lead agent, at session start. Bash 3.2 compatible.
#   ai-context.sh               prints the context (Codex reads it at session start, see AGENTS.md)
#   ai-context.sh --hook start  Claude Code SessionStart hook: records the session opening, then prints the context
#   ai-context.sh --hook end    Claude Code SessionEnd hook: records the closing; in private repository mode, backs up the AI files
#   ai-context.sh --hook stop     Claude Code Stop hook: real cost of the lead agent's turn ("usage" log entry)
#   ai-context.sh --hook subagent  SubagentStop hook: real cost of a native subagent
#   --tool codex                 same hooks for Codex (.codex/hooks.json)
# Never blocks a session: if anything goes wrong, it stays silent.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
# shellcheck source=lib/privacy.sh
source "$SCRIPT_DIR/lib/privacy.sh"

HOOK=""; ROOT=""; TOOL="claude"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hook) HOOK="${2:-}"; shift ;;
    --root) ROOT="${2:-}"; shift ;;
    --tool) TOOL="${2:-claude}"; shift ;;
    -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' | i18n_lines; exit 0 ;;
  esac
  shift
done
# Script copied into <project>/.loomy/scripts: the project is two folders up.
if [[ -z "$ROOT" && "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"; fi
ROOT="$(cd "${ROOT:-$(ai_project_root)}" 2>/dev/null && pwd -P)" || exit 0
[[ -f "$ROOT/.loomy/brief.md" ]] || exit 0

# ---------------------------------------------------------------- hooks: session opening and closing
if [[ -n "$HOOK" ]]; then
  input=""; [[ -t 0 ]] || input="$(cat 2>/dev/null || true)"
  # Session started by a Loomy bridge (claude -p): already logged as a delegation, cost included.
  [[ -n "${LOOMY_DELEGATION:-}" ]] && exit 0
  # End of a lead agent turn, end of a native subagent: real cost read from the transcript, nothing to print.
  if [[ "$HOOK" == "stop" || "$HOOK" == "subagent" ]]; then
    jget() { printf '%s' "$input" | sed -n "s/.*\"$1\" *: *\"\([^\"]*\)\".*/\1/p" | head -1; }
    if [[ "$HOOK" == "stop" ]]; then ai_usage_record "$ROOT" "$(jget transcript_path)" lead
    else ai_usage_record "$ROOT" "$(jget agent_transcript_path)" subagent "$(jget agent_type)"; fi
    exit 0
  fi
  sid="$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p' | head -1)"
  src="$(printf '%s' "$input" | sed -n 's/.*"source" *: *"\([^"]*\)".*/\1/p' | head -1)"
  # Agent process (ancestor of the hook): its presence tells whether the session is still open.
  pid=$PPID; p=$PPID; i=0
  while (( i < 6 )) && [[ -n "$p" && "$p" != "1" ]]; do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in *"$TOOL"*) pid=$p; break ;; esac
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; i=$(( i + 1 ))
  done
  case "$HOOK" in
    start)
      ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"$TOOL\",\"session\":$(ai_json_str "$sid"),\"source\":$(ai_json_str "$src"),\"pid\":$pid" ;;
    end)
      ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"end\",\"tool\":\"$TOOL\",\"session\":$(ai_json_str "$sid"),\"pid\":$pid"
      # Very short end-of-session budget: the backup runs in the background.
      if [[ "$(privacy_mode "$ROOT")" == "private" ]] && privacy_companion_ready "$ROOT"; then
        nohup bash "$SCRIPT_DIR/ai-privacy.sh" --root "$ROOT" sync --quiet >/dev/null 2>&1 &
      fi
      exit 0 ;;
  esac
fi

# ---------------------------------------------------------------- contexte
brief() { _ai_brief_get "$ROOT/.loomy/brief.md" "$1"; }
PHASE="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
UPDATED="$(sed -n 's/^updated=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
[[ -z "$PHASE" && ! -f "$ROOT/START.md" ]] && PHASE="done"
[[ -z "$PHASE" ]] && PHASE="brief"
idx="$(loomy_phase_index "$PHASE")"

t "[Loomy] Resume context for project \"%s\"%s." "$(brief name)" "$( [[ -n "$(brief slug)" ]] && echo " ($(brief slug))")"; echo
if [[ "$PHASE" == "done" ]]; then
  t "- Bootstrap finished: START.md no longer has authority. Follow AGENTS.md and CLAUDE.md; you remain the lead agent."; echo
else
  t "- Bootstrap in progress, phase %s of 10: %s%s. %s" "$idx" "$(loomy_phase_label "$PHASE")" "${UPDATED:+ ($(t "since %s" "$UPDATED"))}" "$(loomy_phase_agent "$PHASE")"; echo
  t "- Resume START.md from this phase. Record every phase change, before any other action: .loomy/scripts/ai-status.sh set <phase>."; echo
  t "- What the user needs to do now: %s" "$(loomy_phase_you "$PHASE")"; echo
fi
k_phase="$(sed -n 's/^phase=//p' "$ROOT/.loomy/task.state" 2>/dev/null | head -1 || true)"
if [[ -n "$k_phase" && "$k_phase" != "done" ]]; then
  t "- Current task #%s (%s), phase %s: plan and progress in %s. Continue it and record its phases with .loomy/scripts/ai-status.sh --task set <phase>." "$(sed -n 's/^id=//p' "$ROOT/.loomy/task.state" | head -1)" "$(sed -n 's/^title=//p' "$ROOT/.loomy/task.state" | head -1)" "$k_phase" "$(sed -n 's/^file=//p' "$ROOT/.loomy/task.state" | head -1)"; echo
fi
a_phase="$(sed -n 's/^phase=//p' "$ROOT/.loomy/audit.state" 2>/dev/null | head -1 || true)"
if [[ -n "$a_phase" && "$a_phase" != "done" ]]; then
  t "- A security audit is in progress (loomy audit, phase %s): its mission is in .loomy/audit.md; if the user is working on it, continue it and record its phases with .loomy/scripts/ai-status.sh --audit set <phase>." "$a_phase"; echo
fi
# The advice depends on the lead: delegate-to-claude.sh is the bridge of a Codex lead (claude -p, headless: a shell
# command that isn't pre-approved is refused). A Claude lead runs its Claude roles as native subagents instead.
if [[ "$(brief ai_lead)" == "claude" ]]; then
  t "- Brief (.loomy/brief.md): mode %s, lead %s, profile %s, risk %s. Role routing: .loomy/scripts/ai-route.sh; delegations: Claude roles are your native subagents (.claude/agents/<role>.md, Agent tool, in the foreground), not delegate-to-claude.sh (a headless claude -p refuses every shell command that isn't pre-approved); only Codex roles go through .loomy/scripts/delegate-to-codex.sh." "$(brief ai_mode)" "$(brief ai_lead)" "$(brief budget)" "$(brief risk)"; echo
else
  t "- Brief (.loomy/brief.md): mode %s, lead %s, profile %s, risk %s. Role routing: .loomy/scripts/ai-route.sh; delegations: .loomy/scripts/delegate-to-claude.sh and delegate-to-codex.sh." "$(brief ai_mode)" "$(brief ai_lead)" "$(brief budget)" "$(brief risk)"; echo
fi
J="$(ai_journal_file "$ROOT")"
if [[ -s "$J" ]] && grep -q '"type":"delegation",' "$J" 2>/dev/null; then
  last="$(grep '"type":"delegation",' "$J" | tail -3 | sed -n 's/.*"role":"\([^"]*\)".*"model":"\([^"]*\)".*"status":"\([^"]*\)".*/\1 (\2, \3)/p' | paste -sd ',' - | sed 's/,/, /g')"
  [[ -n "$last" ]] && { t "- Latest delegations: %s." "$last"; echo; }
fi
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  br="$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || t "detached")"
  dirty="$(git -C "$ROOT" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  t "- Git: branch %s, %s modified file(s) not committed." "$br" "$dirty"; echo
fi
case "$(privacy_mode "$ROOT")" in
  local) t "- Local AI files: never version AGENTS.md, CLAUDE.md, .ai/, .claude/, .codex/, .loomy/ or START.md (never git add -f)."; echo ;;
  private) t "- AI files in a separate private repository: don't version them in the project repository; back them up at the end of each step with .loomy/scripts/ai-privacy.sh sync."; echo ;;
esac
t "- Delegations: always run the bridges in the foreground and wait for them to finish (in the background they stop if the session closes). Announce each one in one line before (role, model, task, rough duration) and after (result, duration)."; echo
if [[ "$(ai_delegation_format "$ROOT")" == "structured" ]]; then
  t "- Structured delegations: write each task as GOAL / SCOPE / FILES / ACCEPTANCE; results come back as STATUS / SUMMARY / FINDINGS / FILES / CHECKS / RISKS / NEXT (see .ai/AI_ORCHESTRATION.md). Act on STATUS: partial or blocked means the task is not done."; echo
fi
t "- Phase change: announce it on one line \"Phase n/10 · Name\", then what you are doing and what you expect from the user."; echo
t "- To start: tell the user, in one or two sentences, where the project stands and what you propose to do now."; echo
exit 0
