#!/usr/bin/env bash
# Feedback on Loomy: prepares a GitHub issue with the useful, anonymised context. Bash 3.2 compatible.
#   loomy-feedback.sh ["message"]   describe the problem or idea; preview, then sent only after confirmation
#   loomy-feedback.sh --print       only prints the issue text (nothing is sent)
#   loomy-feedback.sh --root <dir>  project whose state to attach (default: current folder, if it is a Loomy project)
#   loomy-feedback.sh list          your feedback and where it stands (received, being handled, fixed in X.Y.Z)
#   loomy-feedback.sh triage        maintainer: open feedback grouped by cause, priority and reply proposed; each reply
#                                   posted only after your approval
#   loomy-feedback.sh mark <n> <v>  maintainer: feedback #n fixed in version v (label fixed-in:v)
#   loomy-feedback.sh close <v>     maintainer: comments and closes the feedback fixed in v, after your approval
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
ROOT=""; MSG=""; PRINT=0; SUB=""
SUB_ARGS=()
case "${1:-}" in list|triage|mark|close|--check-fixed) SUB="$1"; shift; SUB_ARGS=("$@"); set -- ;; esac
LOOMY_V="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "?")"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --print) PRINT=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//; s/loomy-feedback.sh/loomy feedback/' | i18n_lines; exit 0 ;;
    *) MSG="${MSG:+$MSG }$1" ;;
  esac
  shift
done
[[ -z "$ROOT" ]] && ROOT="$(ai_project_root 2>/dev/null || pwd)"

# ---------------------------------------------------------------- follow-up and triage (gh)
# Feedback issues: title "Feedback: …" (any author), label "feedback" when the maintainer has set it.
FB_JQ='.[] | "\(.number)|\(.state)|\([.labels[].name] | join(","))|\(.title)"'
need_gh() {
  command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && return 0
  ui_err "$(t "GitHub CLI not ready")" "$(t "gh auth login, then try again")"; exit 1
}
fixed_of() { printf '%s' "$1" | tr ',' '\n' | sed -n 's/^fixed-in://p' | head -1; }
is_maintainer() { [[ "$(gh api "repos/$REPO" --jq .permissions.push 2>/dev/null)" == "true" ]]; }
if [[ -n "$SUB" ]]; then
  case "$SUB" in
    list)
      need_gh
      rows="$(gh issue list -R "$REPO" --author @me --state all --search "Feedback in:title" --limit 50 --json number,title,state,labels --jq "$FB_JQ" 2>/dev/null || true)"
      ui_section "$(t "YOUR FEEDBACK")" "$REPO"
      if [[ -z "$rows" ]]; then ui_kv "$(t "Feedback")" "${C_DIM}$(t "none yet: loomy feedback \"…\"")${C_RESET}"
      else
        while IFS='|' read -r n st labels title; do
          [[ -n "$n" ]] || continue
          v="$(fixed_of "$labels")"
          if [[ -n "$v" ]]; then s="${C_GREEN}$(t "fixed in %s" "$v")${C_RESET}"; ai_version_ge "$LOOMY_V" "$v" 2>/dev/null && s="$s ${C_DIM}($(t "you have it"))${C_RESET}" || s="$s ${C_DIM}(loomy update)${C_RESET}"
          elif [[ "$st" == CLOSED ]]; then s="${C_DIM}$(t "closed")${C_RESET}"
          elif [[ ",$labels," == *",triaged,"* ]]; then s="${C_YELLOW}$(t "being handled")${C_RESET}"
          else s="$(t "received")"; fi
          ui_kv "#$n" "${title#Feedback: } · $s"
        done <<<"$rows"
      fi
      ui_rail_end "https://github.com/$REPO/issues" ;;
    --check-fixed)
      # At launch (once a day, in the background): the user's feedback fixed in the installed version, not yet announced.
      command -v gh >/dev/null 2>&1 || exit 0
      cfg="${XDG_CONFIG_HOME:-$HOME/.config}/loomy"; seen="$(cat "$cfg/feedback-seen" 2>/dev/null || true)"; out=""
      rows="$(gh issue list -R "$REPO" --author @me --state all --search "Feedback in:title label:fixed-in" --limit 30 --json number,title,state,labels --jq "$FB_JQ" 2>/dev/null || true)"
      while IFS='|' read -r n _ labels title; do
        [[ -n "$n" ]] || continue
        v="$(fixed_of "$labels")"; [[ -n "$v" ]] || continue
        case " $seen " in *" $n "*) continue ;; esac
        ai_version_ge "$LOOMY_V" "$v" 2>/dev/null || continue
        out="${out:+$out · }#$n ${title#Feedback: }"; seen="$seen $n"
      done <<<"$rows"
      mkdir -p "$cfg" && printf '%s\n' "$seen" >"$cfg/feedback-seen"
      [[ -n "$out" ]] && printf '%s\n' "$out" >"$cfg/feedback-fixed"
      exit 0 ;;
    mark)
      need_gh; is_maintainer || { ui_err "$(t "Maintainers only")" "$REPO"; exit 1; }
      n="${SUB_ARGS[0]:-}"; v="${SUB_ARGS[1]:-}"; [[ "$n" =~ ^[0-9]+$ && "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { t "Usage: loomy feedback mark <number> <version>" >&2; echo >&2; exit 2; }
      gh label create "fixed-in:$v" -R "$REPO" --color 0E8A16 --description "Fixed in Loomy $v" >/dev/null 2>&1 || true
      if gh issue edit "$n" -R "$REPO" --add-label "fixed-in:$v" >/dev/null 2>&1; then ui_ok "$(t "Feedback #%s marked fixed in %s" "$n" "$v")" "$(t "closed with loomy feedback close %s at release" "$v")"
      else ui_err "$(t "Not marked")" "#$n"; exit 1; fi ;;
    close)
      need_gh; is_maintainer || { ui_err "$(t "Maintainers only")" "$REPO"; exit 1; }
      v="${SUB_ARGS[0]:-}"; [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { t "Usage: loomy feedback close <version>" >&2; echo >&2; exit 2; }
      rows="$(gh issue list -R "$REPO" --state open --label "fixed-in:$v" --limit 100 --json number,title,state,labels --jq "$FB_JQ" 2>/dev/null || true)"
      [[ -n "$rows" ]] || { ui_ok "$(t "Nothing to close for %s" "$v")" ""; exit 0; }
      ui_section "$(t "FEEDBACK FIXED IN %s" "$v")"
      while IFS='|' read -r n _ _ title; do [[ -n "$n" ]] && ui_kv "#$n" "$title"; done <<<"$rows"
      msg="$(t "Fixed in Loomy %s, thanks for the feedback! Update with: loomy update" "$v")"
      ui_rail "   ${C_DIM}$(t "comment: %s" "$msg")${C_RESET}"
      # Posted only after an explicit yes (LOOMY_FEEDBACK_YES=1: already approved, for scripts).
      if [[ "${LOOMY_FEEDBACK_YES:-}" != 1 ]]; then
        ui_is_interactive || { ui_end "$(t "nothing was posted (run it in a terminal to approve)")"; exit 0; }
        UI_LABEL="$(t "Close")"; ui_choose "$(t "Comment and close these issues?")" 1 "$(t "Yes, comment and close")" "$(t "No")"
        [[ "${UI_INDEX:-1}" == 0 ]] || { ui_end "$(t "nothing was posted")"; exit 0; }
      fi
      while IFS='|' read -r n _ _ _; do
        [[ -n "$n" ]] || continue
        gh issue close "$n" -R "$REPO" --comment "$msg" >/dev/null 2>&1 && ui_ok "$(t "Closed")" "#$n" || ui_warn "$(t "Not closed")" "#$n"
      done <<<"$rows"
      ui_end "" ;;
    triage)
      need_gh; is_maintainer || { ui_err "$(t "Maintainers only")" "$REPO"; exit 1; }
      # shellcheck source=lib/feedback-triage.sh
      source "$SCRIPT_DIR/lib/feedback-triage.sh"
      fb_triage ;;
  esac
  exit 0
fi
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
      echo "<details><summary>$(t "Latest log events (without task text)")</summary>"
      echo
      echo '```'
      # ROOT points here to a copy of the log whose task text was emptied (see below).
      NO_COLOR=1 bash "$SCRIPT_DIR/loomy-log.sh" --root "$ROOT" -n 15 2>/dev/null || true
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
    lbl=(); gh label list -R "$REPO" --limit 100 2>/dev/null | cut -f1 | grep -qx feedback && lbl=(--label feedback)
    if url="$(gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" ${lbl[@]+"${lbl[@]}"} 2>&1)"; then ui_ok "$(t "Issue created")" "$url"
    else ui_warn "$(t "Issue not created")" "$(printf '%s' "$url" | tail -1)"; fi ;;
  web) gh issue create --repo "$REPO" --title "$TITLE" --body-file "$BODY_FILE" --web >/dev/null 2>&1 && ui_ok "$(t "Form opened in the browser")" ;;
  copy) if ui_copy "$(cat "$BODY_FILE")"; then ui_ok "$(t "Text copied")" "$(t "title: %s" "$TITLE")"; else ui_warn "$(t "Clipboard unavailable")" "loomy feedback --print"; fi ;;
  *) ui_end "$(t "nothing was sent")"; rm -f "$BODY_FILE"; exit 0 ;;
esac
rm -f "$BODY_FILE"
ui_end "$(t "thanks! feedback tracking: %s" "https://github.com/$REPO/issues")"
