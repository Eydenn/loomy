#!/usr/bin/env bash
# Security audit of an existing codebase: a mission, not a project. Bash 3.2 compatible.
#   ai-audit.sh                  asks the scope, depth and fix policy, then opens the auditor session
#   ai-audit.sh --resume         reopens the auditor session at the phase where the audit stopped
#   ai-audit.sh --print          prepares everything and shows the command instead of opening the session
#   ai-audit.sh --yes            no questions: whole repository, standard depth, report and fix plan only
#   --scope <text> --depth quick|standard|deep --fixes report|plan|branch --tool claude|codex --no-install
# Phases: scope, analysis, validation of findings, report, fix plan, fixes (on a branch, only when allowed).
# Uses Cloudflare's official security-audit skill (https://github.com/cloudflare/security-audit-skill, MIT).
# The report stays out of Git (.loomy/audits/): it can describe exploitable weaknesses.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/phases.sh
source "$SCRIPT_DIR/lib/phases.sh"
loomy_phases_mode audit

ROOT=""; RESUME=0; PRINT=0; YES=0; SCOPE=""; DEPTH=""; FIXES=""; TOOL=""; INSTALL=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --resume) RESUME=1 ;;
    --print) PRINT=1 ;;
    --yes|-y) YES=1 ;;
    --scope) SCOPE="${2:-}"; shift ;;
    --depth) DEPTH="${2:-}"; shift ;;
    --fixes) FIXES="${2:-}"; shift ;;
    --tool) TOOL="${2:-}"; shift ;;
    --no-install) INSTALL=0 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//; s/ai-audit.sh/loomy audit/' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy audit --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
case "$DEPTH" in ""|quick|standard|deep) ;; *) t "%s: quick, standard or deep" "--depth" >&2; echo >&2; exit 2 ;; esac
case "$FIXES" in ""|report|plan|branch) ;; *) t "%s: report, plan or branch" "--fixes" >&2; echo >&2; exit 2 ;; esac
case "$TOOL" in ""|claude|codex) ;; *) t "%s: claude or codex" "--tool" >&2; echo >&2; exit 2 ;; esac

[[ -n "$ROOT" ]] || ROOT="$(ai_project_root)"
ROOT="$(cd "$ROOT" 2>/dev/null && pwd -P)" || { t "Error: folder not found: %s" "$ROOT" >&2; echo >&2; exit 1; }
top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$top" ]]; then
  t "loomy audit works on a Git repository (the fixes go on a branch): run it inside one, or git init first." >&2; echo >&2; exit 1
fi
ROOT="$(cd "$top" && pwd -P)"
BRIEF_A="$ROOT/.loomy/audit.md"; STATE_A="$ROOT/.loomy/audit.state"
brief_a() { _ai_brief_get "$BRIEF_A" "$1"; }

ui_clear
ui_banner "$(t "Security audit")" "${C_RESET}${C_TITLE}$(basename "$ROOT")${C_RESET}${C_DIM} · ${ROOT/#$HOME/~}"

# ---------------------------------------------------------------- audit in progress
cur="$(sed -n 's/^phase=//p' "$STATE_A" 2>/dev/null | head -1 || true)"
if (( ! RESUME )) && [[ -n "$cur" && "$cur" != "done" ]] && [[ -f "$BRIEF_A" ]]; then
  if (( YES )) || ! ui_is_interactive; then RESUME=1
  else
    UI_DESCS=("$(t "Reopens the auditor session at this phase, with the same scope.")" "$(t "Asks the questions again; the previous report stays in its folder.")" "$(t "Opens nothing.")")
    ui_choose "$(t "An audit is in progress (%s). What now?" "$(loomy_phase_label "$cur")")" 0 "$(t "Resume it")" "$(t "Start a new audit")" "$(t "Cancel")"
    case "$UI_INDEX" in 0) RESUME=1 ;; 2) UI_NO_DUMP=1; _ui_restore; exit 0 ;; esac
  fi
fi
if (( RESUME )) && [[ ! -f "$BRIEF_A" ]]; then
  t "No audit to resume here: run loomy audit." >&2; echo >&2; exit 1
fi

# ---------------------------------------------------------------- mission
had_loomy=0; [[ -d "$ROOT/.loomy" ]] && had_loomy=1
exclude_add() {   # exclude_add <path>: kept out of Git on this machine only (.git/info/exclude)
  local ex; ex="$(git -C "$ROOT" rev-parse --git-path info/exclude 2>/dev/null)"; [[ "$ex" == /* ]] || ex="$ROOT/$ex"
  mkdir -p "$(dirname "$ex")"
  grep -qxF "$1" "$ex" 2>/dev/null || printf '%s\n' "$1" >>"$ex"
}

if (( ! RESUME )); then
  if (( YES )) || ! ui_is_interactive; then
    SCOPE="${SCOPE:-$(t "whole repository")}"; DEPTH="${DEPTH:-standard}"; FIXES="${FIXES:-plan}"
  else
    if [[ -z "$SCOPE" ]]; then
      UI_LABEL="$(t "Scope")"; UI_HINT="$(t "What to audit: the whole repository, or folders, services, features (comma separated).")"
      ui_input "$(t "Audit scope")" "$(t "whole repository")"; SCOPE="$UI_VALUE"
    fi
    if [[ -z "$DEPTH" ]]; then
      UI_LABEL="$(t "Depth")"
      UI_DESCS=("$(t "Entry points, authentication, secrets and the riskiest areas. Fastest and cheapest.")" \
        "$(t "The whole scope, with independent validation of every finding. Recommended.")" \
        "$(t "Standard, plus dependencies, configuration, infrastructure files and secrets in the Git history.")")
      ui_choose "$(t "How deep?")" 1 "$(t "Quick")" "$(t "Standard (recommended)")" "$(t "Deep")"
      case "$UI_INDEX" in 0) DEPTH=quick ;; 2) DEPTH=deep ;; *) DEPTH=standard ;; esac
    fi
    if [[ -z "$FIXES" ]]; then
      UI_LABEL="$(t "Fixes")"
      UI_DESCS=("$(t "Only the report: nothing is planned or changed.")" \
        "$(t "The report and a prioritised fix plan; no code is changed.")" \
        "$(t "Report, plan, then the fixes you approve, on a loomy/audit-fixes branch; your branches stay untouched, nothing is pushed.")")
      ui_choose "$(t "What should the audit deliver?")" 1 "$(t "Report only")" "$(t "Report and fix plan (recommended)")" "$(t "Report, plan and fixes on a branch")"
      case "$UI_INDEX" in 0) FIXES=report ;; 2) FIXES=branch ;; *) FIXES=plan ;; esac
    fi
  fi
  DATE="$(date +%Y-%m-%d)"; DIR=".loomy/audits/$DATE-security"
  n=2; while [[ -e "$ROOT/$DIR" ]]; do DIR=".loomy/audits/$DATE-security-$n"; n=$(( n + 1 )); done
  mkdir -p "$ROOT/$DIR" "$ROOT/.loomy/logs"
  # Outside Git: Loomy's folder when the repository had none, and the reports always (they can describe weaknesses).
  (( had_loomy )) || exclude_add "/.loomy/"
  exclude_add "/.loomy/audits/"
  exclude_add "/.loomy/audit.state"
  {
    echo "---"
    echo "kind: security"
    echo "date: $DATE"
    echo "scope: $(printf '%s' "$SCOPE" | tr '\n' ' ')"
    echo "depth: $DEPTH"
    echo "fixes: $FIXES"
    echo "report_dir: $DIR"
    echo "---"
    echo ""
    echo "# Loomy security audit"
    echo ""
    echo "Mission for the auditor started by loomy audit. Deliverables in $DIR, kept out of Git."
  } >"$BRIEF_A"
  bash "$SCRIPT_DIR/ai-status.sh" --root "$ROOT" --audit set scope >/dev/null
  cur="scope"
fi
SCOPE="$(brief_a scope)"; DEPTH="$(brief_a depth)"; FIXES="$(brief_a fixes)"; DIR="$(brief_a report_dir)"

# ---------------------------------------------------------------- auditor: tool, model
# The security role: Opus 5.5 on the Claude side, Astra on the Codex side (effort from the project's profile).
if [[ -z "$TOOL" ]]; then
  TOOL="$(_ai_brief_get "$ROOT/.loomy/brief.md" ai_lead 2>/dev/null || true)"
  case "$TOOL" in claude) ai_has_claude || TOOL="" ;; codex) ai_has_codex || TOOL="" ;; *) TOOL="" ;; esac
  [[ -n "$TOOL" ]] || { ai_has_claude && TOOL=claude; } || { ai_has_codex && TOOL=codex; } || TOOL=claude
fi
PROFILE="$(_ai_brief_get "$ROOT/.loomy/brief.md" budget 2>/dev/null || true)"; PROFILE="${PROFILE:-equilibre}"
ai_route security "$TOOL" "$PROFILE"
MODEL="$R_MODEL"; EFFORT="$R_EFFORT"
OTHER="codex"; [[ "$TOOL" == "codex" ]] && OTHER="claude"
tool_label="Claude Code"; [[ "$TOOL" == "codex" ]] && tool_label="Codex"

# ---------------------------------------------------------------- Cloudflare security-audit skill
skill_found() {
  local d
  for d in "$ROOT/.claude/skills" "$ROOT/.agents/skills" "$HOME/.claude/skills" "$HOME/.agents/skills" "${CODEX_HOME:-$HOME/.codex}/skills"; do
    [[ -f "$d/security-audit/SKILL.md" ]] && return 0
  done
  return 1
}
SKILL_NOTE=""
if skill_found; then SKILL_NOTE="$(t "security-audit skill found")"
elif (( INSTALL )) && (( ! RESUME )); then
  go=1
  if ! (( YES )) && ui_is_interactive; then
    UI_DESCS=("$(t "npx skills add, from github.com/cloudflare/security-audit-skill (MIT), for this repository only, kept out of Git.")" "$(t "The auditor follows Loomy's summary of the workflow instead (less thorough).")")
    ui_choose "$(t "Install Cloudflare's security-audit skill for this repository?")" 0 "$(t "Yes, install it (recommended)")" "$(t "No")"
    [[ "$UI_INDEX" == "0" ]] || go=0
  fi
  if (( go )) && command -v npx >/dev/null 2>&1; then
    had_c=0; [[ -d "$ROOT/.claude/skills" ]] && had_c=1
    had_a=0; [[ -d "$ROOT/.agents/skills" ]] && had_a=1
    ui_info "$(t "installing the security-audit skill (npx skills add)…")"
    (cd "$ROOT" && npx -y skills add https://github.com/cloudflare/security-audit-skill --skill security-audit -y) >"$ROOT/.loomy/logs/skill-install.log" 2>&1 || true
    (( had_c )) || [[ ! -d "$ROOT/.claude/skills" ]] || exclude_add "/.claude/skills/"
    (( had_a )) || [[ ! -d "$ROOT/.agents/skills" ]] || exclude_add "/.agents/skills/"
    [[ -d "$ROOT/.claude/skills/security-audit" ]] && exclude_add "/.claude/skills/security-audit/"
    [[ -d "$ROOT/.agents/skills/security-audit" ]] && exclude_add "/.agents/skills/security-audit/"
    if skill_found; then SKILL_NOTE="$(t "security-audit skill installed for this repository")"
    else SKILL_NOTE="$(t "skill not installed: the auditor follows Loomy's summary of the workflow")"; fi
  elif (( go )); then SKILL_NOTE="$(t "npx missing: the auditor follows Loomy's summary of the workflow")"
  else SKILL_NOTE="$(t "skill not installed: the auditor follows Loomy's summary of the workflow")"; fi
else SKILL_NOTE="$(t "skill not installed: the auditor follows Loomy's summary of the workflow")"; fi

# ---------------------------------------------------------------- auditor prompt (English: agent-facing)
STATUS_CMD="bash \"$SCRIPT_DIR/ai-status.sh\" --root \"$ROOT\" --audit set"
case "$DEPTH" in
  quick) depth_txt="quick: entry points, authentication and authorisation, secrets, input handling, and the riskiest areas" ;;
  deep) depth_txt="deep: the whole scope, plus dependencies (known vulnerabilities), configuration and infrastructure files, CI, and secrets in the Git history" ;;
  *) depth_txt="standard: the whole scope, every finding validated independently" ;;
esac
case "$FIXES" in
  report) fix_txt="report only: skip the fix plan and the fixes (phases plan and fix)." ;;
  branch) fix_txt="report, fix plan, then the fixes the user approves, on a branch loomy/audit-fixes created from the current branch; never touch other branches, never push, never merge." ;;
  *) fix_txt="report and fix plan; change no code (skip the fix phase)." ;;
esac
lang_txt="English"; [[ "$(ui_lang)" == "fr" ]] && lang_txt="French"
if (( RESUME )); then
  PROMPT="Resume the Loomy security audit of this repository where it stopped: phase \"$cur\". Reread .loomy/audit.md and the files already in $DIR, summarise where the audit stands in two sentences, then continue with the same rules: record each phase change with: $STATUS_CMD <phase>."
else
  PROMPT="You are the security auditor of this repository. This is a Loomy audit mission, not a project bootstrap: ignore START.md if there is one.
Mission (.loomy/audit.md): scope: $SCOPE. Depth: $depth_txt. Deliverables: $fix_txt
Write every deliverable in $DIR (kept out of Git: it can describe exploitable weaknesses; never commit or paste it elsewhere). Write them in $lang_txt.
Record each phase change before acting, with: $STATUS_CMD <phase>   and announce it on one line: \"Audit n/6 · Name\".
1. scope: restate the scope, depth, exclusions and deliverables; ask the user to confirm or adjust, and wait.
2. analyze: use Cloudflare's official security-audit skill and follow its workflow (if it is not available, follow $SCRIPT_DIR/../external-skills/security-audit.md and a threat-model-first review). Read-only: change no project file.
3. validate: confirm every finding with evidence in the code (file:line, reachable path, preconditions, realistic impact); drop false positives and keep them in a separate list. For an independent check of a serious finding you may ask the other tool: bash \"$SCRIPT_DIR/delegate-to-$OTHER.sh\" reviewer \"<finding and evidence>\".
4. report: write $DIR/REPORT.md: summary, scope and method, findings by severity (Critical, High, Medium, Low, Info) each with evidence, impact and recommendation, discarded false positives, limits of the audit.
5. plan: write $DIR/FIX_PLAN.md: fixes and hardening or optimisation items, prioritised (severity, effort, risk, suggested order). Point the user to both files and ask which items to apply.
6. fix: only when the deliverables include fixes and the user approved items: branch loomy/audit-fixes, one commit per fix with a test when possible, re-check each fixed finding, then ask for a cross review.
Finish with: $STATUS_CMD done, and a five-line summary (findings by severity, where the files are, what the user should do next)."
fi

if [[ "$TOOL" == "claude" ]]; then AGENT_CMD=(claude --model "$MODEL" --effort "$EFFORT" "$PROMPT")
else CODEX="$(ai_codex_bin 2>/dev/null || echo codex)"; AGENT_CMD=("$CODEX" -m "$MODEL" -c "model_reasoning_effort=$EFFORT" "$PROMPT"); fi

ui_section "AUDIT"
ui_kv "$(t "Scope")" "$SCOPE"
ui_kv "$(t "Depth")" "$DEPTH"
ui_kv "$(t "Deliverables")" "$FIXES · ${DIR} ${C_DIM}($(t "kept out of Git"))${C_RESET}"
ui_kv "$(t "Auditor")" "$tool_label · $MODEL ($EFFORT)"
ui_kv "Skill" "$SKILL_NOTE"
ui_kv "$(t "Phase")" "$(loomy_phase_label "$cur") ${C_DIM}($(t "step %s of %s" "$(loomy_phase_index "$cur")" "$LOOMY_PHASE_COUNT"))${C_RESET}"

if (( PRINT )) || ! ui_is_interactive; then
  ui_rail ""
  ui_rail "$(t "Open the auditor session in this folder:")"
  ui_rail "   ${C_BOLD}$(printf '%q ' "${AGENT_CMD[@]:0:${#AGENT_CMD[@]}-1}")\"<prompt>\"${C_RESET}"
  printf '%s\n' "$PROMPT" >"$ROOT/.loomy/audit-prompt.txt"
  ui_rail "   ${C_DIM}$(t "prompt saved in %s" ".loomy/audit-prompt.txt")${C_RESET}"
  ui_end "$(t "live tracking: loomy watch")"
  exit 0
fi

ui_end "$(t "opening %s…" "$tool_label") · $(t "live tracking in another terminal: loomy watch")"
cd "$ROOT" || exit 1
# Session tracking: Loomy's Claude hooks record it in a Loomy project; otherwise it is recorded here (exec keeps the pid).
if [[ "$TOOL" == "codex" ]] || ! grep -qs "ai-context.sh" "$ROOT/.claude/settings.json"; then
  ai_journal_write "$ROOT" "\"type\":\"session\",\"event\":\"start\",\"tool\":\"$TOOL\",\"pid\":$$"
fi
ui_exec "${AGENT_CMD[@]}"
