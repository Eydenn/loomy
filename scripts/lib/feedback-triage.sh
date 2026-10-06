#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by loomy-feedback.sh
# Maintainer triage of the testers' feedback (loomy feedback triage): the open feedback issues not triaged yet are
# grouped by cause, given a priority, labels and a proposed reply by a fast model (GPT-6-Luna through Codex, or Claude
# Haiku; LOOMY_TRIAGE_AI=none: no model, one group per issue), written to a Markdown report, then reviewed one by
# one: nothing is posted to GitHub without the maintainer's approval. Bash 3.2.

# _fb_ai <prompt file> <output file>: runs the fast model available, unable to act (Codex read-only sandbox, Claude
# without tools); false when none answered.
_fb_ai() {
  local codex claude
  case "${LOOMY_TRIAGE_AI:-auto}" in none) return 1 ;; esac
  codex="$(ai_codex_bin 2>/dev/null || true)"
  if [[ -n "$codex" && "${LOOMY_TRIAGE_AI:-auto}" != claude ]]; then
    LOOMY_DELEGATION=1 "$codex" exec -m "${AI_MODEL_CODEX_FAST:-gpt-6-luna}" -c model_reasoning_effort=medium -s read-only \
      --skip-git-repo-check --ephemeral -o "$2" "$(cat "$1")" </dev/null >/dev/null 2>&1 && [[ -s "$2" ]] && return 0
  fi
  claude="$(command -v claude 2>/dev/null || true)"
  if [[ -n "$claude" ]]; then
    # No tool at all (the issues are untrusted text): it can only write the proposal.
    LOOMY_DELEGATION=1 "$claude" -p --model "${AI_MODEL_CLAUDE_FAST:-claude-haiku-4-5}" --tools "" --strict-mcp-config "$(cat "$1")" </dev/null >"$2" 2>/dev/null && [[ -s "$2" ]] && return 0
  fi
  return 1
}

fb_triage() {
  local tmp json n title body grp pri labels reply rows report i=0 total ans
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loomy-triage.XXXXXX")" || return 1
  json="$tmp/issues.tsv"
  # number <TAB> title <TAB> feedback text (the part the tester wrote, without the attached context), one line each.
  gh issue list -R "$REPO" --state open --search "Feedback in:title -label:triaged" --limit 100 --json number,title,body \
    --jq '.[] | "\(.number)\t\(.title)\t\(.body | split("\n## ")[0] | gsub("[\t\r\n]+"; " ") | .[0:600])"' >"$json" 2>/dev/null || true
  total="$(grep -c . "$json" 2>/dev/null || true)"
  ui_section "$(t "FEEDBACK TRIAGE")" "$REPO · $(t "%s open, not triaged" "${total:-0}")"
  if [[ "${total:-0}" == 0 ]]; then ui_ok "$(t "Nothing to triage")" ""; rm -rf "$tmp"; return 0; fi

  # Proposal: the model groups by cause and drafts; without a model, one group per issue and a neutral reply.
  {
    echo "GOAL: Triage user feedback issues of Loomy, a CLI that sets up and orchestrates AI coding agents (Claude Code, Codex)."
    echo "OUTPUT: one line per issue, same order, nothing else: number|group|priority|labels|reply"
    echo "- group: a short name of the underlying cause (2 to 5 words); issues with the same cause share the same group name."
    echo "- priority: P1 (blocks work, data or security), P2 (annoying, workaround exists), P3 (idea, polish)."
    echo "- labels: comma separated among bug, enhancement, documentation, question."
    echo "- reply: 1 to 3 sentences to the tester, in the language of the issue, thanking them, saying what is understood and what happens next; no promise of a date. No | character."
    echo "ISSUES (number TAB title TAB text):"
    cat "$json"
  } >"$tmp/prompt.txt"
  ui_info "$(t "grouping by cause and drafting replies (fast model)…")"
  if ! _fb_ai "$tmp/prompt.txt" "$tmp/proposal.txt"; then
    ui_info "$(t "no model available: one group per issue, neutral reply")"
    while IFS=$'\t' read -r n title _; do
      printf '%s|%s|P2|%s|%s\n' "$n" "${title#Feedback: }" "question" "$(t "Thanks for this feedback! It is noted and will be looked at; we'll update this issue.")"
    done <"$json" >"$tmp/proposal.txt"
  fi
  # Report, grouped by cause then priority (kept for the maintainer, outside any project).
  report="$(mktemp -d "${TMPDIR:-/tmp}/loomy-triage.XXXXXX")/triage-$(date +%Y%m%d-%H%M%S).md"
  {
    echo "# Loomy feedback triage — $(date '+%Y-%m-%d %H:%M')"
    echo
    grep -E '^[0-9]+\|' "$tmp/proposal.txt" | sort -t'|' -k2,2 -k3,3 | awk -F'|' '
      $2 != g { g = $2; print ""; print "## " g; print "" }
      { printf "- #%s · %s · %s — %s\n", $1, $3, $4, $5 }'
  } >"$report"
  ui_kv "$(t "Report")" "$report"
  grep -E '^[0-9]+\|' "$tmp/proposal.txt" | sort -t'|' -k2,2 | awk -F'|' '$2 != g { g = $2; c[g] = 0; order[++n] = g } { c[$2]++ } END { for (i = 1; i <= n; i++) printf "%s|%d\n", order[i], c[order[i]] }' \
    | while IFS='|' read -r grp n; do ui_kv "$grp" "$(t "%s issue(s)" "$n")"; done
  if ! ui_is_interactive; then ui_end "$(t "nothing was posted (run it in a terminal to review each reply)")"; rm -rf "$tmp"; return 0; fi

  # One by one: post (reply + labels + triaged), labels only, edit the reply, skip, stop.
  gh label create triaged -R "$REPO" --color C5DEF5 --description "Seen by the maintainer" >/dev/null 2>&1 || true
  rows="$(grep -E '^[0-9]+\|' "$tmp/proposal.txt" | sort -t'|' -k3,3)"
  while IFS='|' read -r n grp pri labels reply <&3; do
    [[ "$n" =~ ^[0-9]+$ ]] || continue
    # Only the issues fetched above (a number made up by the model is ignored); labels limited to the known ones.
    awk -F'\t' -v n="$n" '$1 == n { f = 1 } END { exit !f }' "$json" || continue
    [[ "$pri" =~ ^P[123]$ ]] || pri="P2"
    labels="$(printf '%s' "$labels" | tr ',' '\n' | tr -d ' ' | grep -xE 'bug|enhancement|documentation|question' | paste -sd ',' -)"
    i=$(( i + 1 ))
    title="$(awk -F'\t' -v n="$n" '$1 == n { print $2 }' "$json")"
    ui_section "#$n · $pri · $grp" "$i/$total"
    ui_kv "$(t "Feedback")" "${title#Feedback: }"
    ui_kv "$(t "Labels")" "$labels"
    ui_kv "$(t "Reply")" "$reply"
    UI_LABEL="#$n"
    UI_DESCS=("$(t "Posts this reply, adds the labels, the priority and triaged.")" "$(t "Labels, priority and triaged only, no reply.")" "$(t "Write your own reply, then post it.")" "$(t "Leaves this issue as it is.")" "$(t "Ends the triage here.")")
    ui_choose "$(t "What to do with #%s?" "$n")" 0 "$(t "Post the reply")" "$(t "Labels only")" "$(t "Edit the reply")" "$(t "Skip")" "$(t "Stop")"
    ans="${UI_INDEX:-3}"
    if [[ "$ans" == 2 ]]; then
      ui_input "$(t "Your reply")" "$reply"; reply="$UI_VALUE"; ans=0
    fi
    case "$ans" in
      0|1)
        gh label create "$pri" -R "$REPO" --color FBCA04 >/dev/null 2>&1 || true
        gh issue edit "$n" -R "$REPO" --add-label "triaged,$pri${labels:+,$labels}" >/dev/null 2>&1 || ui_warn "$(t "Labels not set")" "#$n"
        if [[ "$ans" == 0 && -n "$reply" ]]; then
          gh issue comment "$n" -R "$REPO" --body "$reply" >/dev/null 2>&1 && ui_ok "$(t "Reply posted")" "#$n" || ui_warn "$(t "Reply not posted")" "#$n"
        else ui_ok "$(t "Triaged")" "#$n"; fi ;;
      4) break ;;
      *) ui_info "$(t "issue #%s skipped" "$n")" ;;
    esac
  done 3<<<"$rows"
  rm -rf "$tmp"
  ui_end "$(t "fix, then: loomy feedback mark <n> <version>; at release: loomy feedback close <version>")"
}
