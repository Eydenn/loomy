#!/usr/bin/env bash
# Feedback on Loomy: prepares a GitHub issue with the useful, anonymised context. Bash 3.2 compatible.
#   ai-feedback.sh ["message"]   describe the problem or idea; preview, then sent only after confirmation
#   ai-feedback.sh --print       only prints the issue text (nothing is sent)
#   ai-feedback.sh --root <dir>  project whose state to attach (default: current folder, if it is a Loomy project)
# Attached: versions (Loomy, system, bash, git, Claude Code, Codex, gh), and for a project: type, stage, AI mode,
# profile, phase and latest log events WITHOUT the task text. Never: name, goal, paths, code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"

REPO="${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}"
ROOT=""; MSG=""; PRINT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --print) PRINT=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//; s/ai-feedback.sh/loomy feedback/' | i18n_lines; exit 0 ;;
    *) MSG="${MSG:+$MSG }$1" ;;
  esac
  shift
done
[[ -z "$ROOT" ]] && ROOT="$(ai_project_root 2>/dev/null || pwd)"
IN_PROJECT=0; [[ -f "$ROOT/.loomy/brief.md" ]] && IN_PROJECT=1

ver() { "$@" 2>/dev/null | head -1 | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 || true; }
LOOMY_V="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "?")"

body() {
  echo "## $(t "Feedback")"
  echo
  echo "${MSG:-_($(t "to be completed"))_}"
  echo
  echo "## $(t "Context (attached by loomy feedback, anonymized)")"
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Loomy | $LOOMY_V |"
  echo "| $(t "System") | $(uname -s) $(uname -r) $(uname -m) |"
  echo "| bash | ${BASH_VERSION%%(*} |"
  echo "| git | $(ver git --version) |"
  echo "| Claude Code | $(ver claude --version || true) |"
  echo "| Codex | $(ver "$(ai_codex_bin 2>/dev/null || echo codex)" --version || true) |"
  echo "| gh | $(ver gh --version) |"
  echo "| Terminal | ${TERM_PROGRAM:-?} · TERM=${TERM:-?}$( [[ -n "${TMUX:-}" ]] && echo " · tmux") |"
  if (( IN_PROJECT )); then
    local b="$ROOT/.loomy/brief.md" phase
    phase="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
    echo "| $(t "Project") | $(_ai_brief_get "$b" type) · $(_ai_brief_get "$b" stage) · $(_ai_brief_get "$b" ai_mode) · lead $(_ai_brief_get "$b" ai_lead) · $(t "profile") $(_ai_brief_get "$b" budget) · $(t "ai_files") $(_ai_brief_get "$b" ai_files) |"
    echo "| $(t "Project's Loomy") | $(cat "$ROOT/.loomy/VERSION" 2>/dev/null || echo "?") · phase ${phase:-?} |"
    local j; j="$(ai_journal_file "$ROOT")"
    if [[ -s "$j" ]]; then
      echo
      echo "<details><summary>$(t "Latest journal events (without task text)")</summary>"
      echo
      echo '```'
      # ROOT points here to a copy of the log whose task text was emptied (see below).
      NO_COLOR=1 bash "$SCRIPT_DIR/ai-log.sh" --root "$ROOT" -n 15 2>/dev/null || true
      echo '```'
      echo
      echo "</details>"
    fi
  fi
}

# Log: ai-log reads the file itself; we give it a copy without the task text.
if (( IN_PROJECT )) && [[ -s "$(ai_journal_file "$ROOT")" ]]; then
  SAFE="$(mktemp -d)"; mkdir -p "$SAFE/.loomy/logs"
  cp "$ROOT/.loomy/brief.md" "$SAFE/.loomy/brief.md"
  sed -E 's/"task":"([^"\\]|\\.)*"/"task":""/' "$(ai_journal_file "$ROOT")" >"$SAFE/.loomy/logs/events.jsonl"
  cp "$ROOT/.loomy/state" "$SAFE/.loomy/state" 2>/dev/null || true
  cp "$ROOT/.loomy/VERSION" "$SAFE/.loomy/VERSION" 2>/dev/null || true
  trap 'rm -rf "$SAFE"' EXIT
  ROOT="$SAFE"
fi

if (( PRINT )) || ! ui_is_interactive; then body; exit 0; fi

ui_clear
ui_banner "$(t "Feedback on Loomy")" "$(t "GitHub issue on %s · nothing is sent without your approval" "$REPO")"
if [[ -z "$MSG" ]]; then
  ui_print "${C_RAIL}│${C_RESET}"
  UI_LABEL="$(t "Feedback")"; UI_HINT="$(t "A bug, an annoyance, an idea: what happened, and what you expected.")"
  ui_input "$(t "Your feedback, in one or two sentences")" "" "$(t "E.g.: loomy watch doesn't see my Codex session")"
  MSG="$UI_VALUE"
  [[ -n "$MSG" ]] || { ui_end "$(t "nothing to send")"; exit 0; }
fi
TITLE="$(t "Feedback:") $(printf '%s' "$MSG" | cut -c1-70)"
BODY_FILE="$(mktemp)"; body >"$BODY_FILE"
ui_section "$(t "PREVIEW")" "$(t "issue text")"
while IFS= read -r l; do ui_rail "${C_DIM}${l}${C_RESET}"; done <"$BODY_FILE"
ui_print "${C_RAIL}│${C_RESET}"
opts=(); UI_DESCS=(); codes=()
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  opts+=("$(t "Create the issue now")"); codes+=(create); UI_DESCS+=("$(t "gh issue create on %s, with this title and text." "$REPO")")
  opts+=("$(t "Open it in the browser")"); codes+=(web); UI_DESCS+=("$(t "Prefilled GitHub form: you review and submit it yourself.")")
fi
opts+=("$(t "Copy the text")"); codes+=(copy); UI_DESCS+=("$(t "To the clipboard, to paste wherever you want.")")
opts+=("$(t "Cancel")"); codes+=(cancel); UI_DESCS+=("$(t "Nothing is sent.")")
UI_LABEL="$(t "Sending")"
ui_choose "$(t "What to do with this feedback?")" 0 "${opts[@]}"
case "${codes[$UI_INDEX]}" in
  create)
    if url="$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" 2>&1)"; then ui_ok "$(t "Issue created")" "$url"
    else ui_warn "$(t "Issue not created")" "$(printf '%s' "$url" | tail -1)"; fi ;;
  web) gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" --web >/dev/null 2>&1 && ui_ok "$(t "Form opened in the browser")" ;;
  copy) if ui_copy "$(cat "$BODY_FILE")"; then ui_ok "$(t "Text copied")" "$(t "title: %s" "$TITLE")"; else ui_warn "$(t "Clipboard unavailable")" "loomy feedback --print"; fi ;;
  *) ui_end "$(t "nothing was sent")"; rm -f "$BODY_FILE"; exit 0 ;;
esac
rm -f "$BODY_FILE"
ui_end "$(t "thanks! feedback tracking: %s" "https://github.com/$REPO/issues")"
