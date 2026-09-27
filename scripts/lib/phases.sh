#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Loomy bootstrap phases: label, what the agent does, what the user must do.
# Single source for loomy status, loomy watch and loomy start. To be sourced. Bash 3.2 compatible.

# Translated strings (t): the language layer is loaded if the script hasn't done it already (hooks, context).
if ! declare -F t >/dev/null 2>&1; then
  # shellcheck source=i18n.sh
  source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
fi

LOOMY_PHASES="brief discover interview propose approve build verify document commit retire"

loomy_phase_label() {
  case "$1" in
    brief) t "Brief"; echo ;; discover) t "Discovery"; echo ;; interview) t "Interview"; echo ;;
    propose) t "Proposal"; echo ;; approve) t "Approval"; echo ;; build) t "Build"; echo ;;
    verify) t "Verification"; echo ;; document) t "Documentation"; echo ;; commit) t "Commit"; echo ;;
    retire) t "Wrap-up"; echo ;; done) t "Done"; echo ;; "") t "Not started"; echo ;; *) echo "$1" ;;
  esac
}

# loomy_phase_agent <phase> : ce que fait l'orchestrateur pendant cette phase.
loomy_phase_agent() {
  case "$1" in
    brief) t "The questionnaire is filled in; the lead agent hasn't started yet."; echo ;;
    discover) t "The lead agent reads the brief and explores the project folder."; echo ;;
    interview) t "The lead agent asks the questions the brief still lacks."; echo ;;
    propose) t "The lead agent presents the stack, the repository layout and the plan."; echo ;;
    approve) t "The lead agent waits for your go-ahead before creating anything."; echo ;;
    build) t "The lead agent sets up the project and delegates to dedicated roles."; echo ;;
    verify) t "Tests, cross review and security checks of the delivered work."; echo ;;
    document) t "Writing PROJECT.md, ARCHITECTURE.md and the .ai/ rules."; echo ;;
    commit) t "Initial commit, if you allowed it in the questionnaire."; echo ;;
    retire) t "START.md is archived or deleted: the bootstrap is ending."; echo ;;
    done) t "The project is set up; the lead agent now follows AGENTS.md and CLAUDE.md."; echo ;;
    *) t "No phase recorded yet."; echo ;;
  esac
}

# loomy_phase_you <phase>: what the user must do (shown as "Your turn: …").
loomy_phase_you() {
  case "$1" in
    ""|brief) t "start the lead agent with loomy start."; echo ;;
    discover) t "nothing for now; keep its session open."; echo ;;
    interview) t "answer its questions in its session."; echo ;;
    propose) t "read the proposal, ask your questions."; echo ;;
    approve) t "approve the proposal or ask for changes in its session."; echo ;;
    build) t "follow the delegations here; the agent will ask you if a choice comes up."; echo ;;
    verify) t "look at the review findings it reports."; echo ;;
    document) t "review PROJECT.md and ARCHITECTURE.md when it points you to them."; echo ;;
    commit) t "check the proposed commit (git log, git show)."; echo ;;
    retire) t "nothing; the bootstrap is almost over."; echo ;;
    done) t "ask the lead agent for your changes (loomy start opens its session)."; echo ;;
    *) t "loomy start to open the lead agent session."; echo ;;
  esac
}

# loomy_phase_index <phase>: rank of the phase (1 to 10), 0 when unknown, 11 when finished.
loomy_phase_index() {
  local p i=0
  [[ "$1" == "done" ]] && { echo 11; return 0; }
  for p in $LOOMY_PHASES; do i=$(( i + 1 )); [[ "$p" == "$1" ]] && { echo "$i"; return 0; }; done
  echo 0
}

# loomy_you_now <phase> <session state>: instruction for the user, adapted to the lead agent session.
# As long as no session is open, the only useful thing is to open it (or reopen it).
loomy_you_now() {
  case "$1" in done) loomy_phase_you "$1"; return 0 ;; esac
  case "$2" in
    open*) loomy_phase_you "$1" ;;
    closed*) t "reopen the lead agent session with loomy start; it will resume at this phase."; echo ;;
    *) t "open the lead agent session with loomy start."; echo ;;
  esac
}
