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
LOOMY_PHASE_COUNT=10
LOOMY_PHASE_MODE="project"
# Audit (loomy audit): a mission on an existing codebase, with its own phases and state (.loomy/audit.state),
# never mixed with the project's bootstrap.
LOOMY_AUDIT_PHASES="scope analyze validate report plan fix"
# Task (loomy task): a named piece of work after the bootstrap, its own state (.loomy/task.state).
LOOMY_TASK_PHASES="plan approve build verify commit"

# loomy_phases_mode <project|audit>: which list the helpers below work on.
loomy_phases_mode() {
  if [[ "$1" == "audit" ]]; then LOOMY_PHASE_MODE="audit"; LOOMY_PHASES="$LOOMY_AUDIT_PHASES"; LOOMY_PHASE_COUNT=6
  elif [[ "$1" == "task" ]]; then LOOMY_PHASE_MODE="task"; LOOMY_PHASES="$LOOMY_TASK_PHASES"; LOOMY_PHASE_COUNT=5
  else LOOMY_PHASE_MODE="project"; LOOMY_PHASES="brief discover interview propose approve build verify document commit retire"; LOOMY_PHASE_COUNT=10; fi
}

loomy_phase_label() {
  case "$1" in
    brief) t "Brief"; echo ;; discover) t "Discovery"; echo ;; interview) t "Interview"; echo ;;
    propose) t "Proposal"; echo ;; approve) t "Approval"; echo ;; build) t "Build"; echo ;;
    verify) t "Verification"; echo ;; document) t "Documentation"; echo ;; commit) t "Commit"; echo ;;
    retire) t "Wrap-up"; echo ;; done) t "Done"; echo ;;
    scope) t "Scope"; echo ;; analyze) t "Analysis"; echo ;; validate) t "Validation of findings"; echo ;;
    report) t "Report"; echo ;; fix) t "Fixes"; echo ;;
    plan) if [[ "$LOOMY_PHASE_MODE" == "task" ]]; then t "Plan"; echo; else t "Fix plan"; echo; fi ;; "") t "Not started"; echo ;; *) echo "$1" ;;
  esac
}

# loomy_phase_agent <phase> : ce que fait l'orchestrateur pendant cette phase.
loomy_phase_agent() {
  if [[ "$LOOMY_PHASE_MODE" == "task" ]]; then
    case "$1" in
      plan) t "The lead agent reads the code involved and writes the plan in the task file."; echo ;;
      approve) t "The lead agent waits for your go-ahead on the plan."; echo ;;
      build) t "The lead agent does the task and delegates to the roles; the progress is ticked in the task file."; echo ;;
      verify) t "Tests and a cross review of the changes (loomy review)."; echo ;;
      commit) t "Commit of the task, once you agree."; echo ;;
      done) t "Task finished: duration, delegations and cost below."; echo ;;
      *) t "No phase recorded yet."; echo ;;
    esac
    return 0
  fi
  case "$1" in
    brief) t "The questionnaire is filled in; the lead agent hasn't started yet."; echo ;;
    discover) t "The lead agent reads the brief and explores the project folder."; echo ;;
    interview) t "The lead agent asks the questions the brief still lacks."; echo ;;
    propose) t "The lead agent presents the stack, the repository layout and the plan."; echo ;;
    approve) t "The lead agent waits for your go-ahead before creating anything."; echo ;;
    build) t "The lead agent sets up the project and delegates to dedicated roles."; echo ;;
    verify) t "Tests, cross review and security checks of the delivered work."; echo ;;
    document) t "Writing PROJECT.md, ARCHITECTURE.md and the .loomy/docs/ rules."; echo ;;
    commit) t "Initial commit, if you allowed it in the questionnaire."; echo ;;
    retire) t "START.md is archived or deleted: the bootstrap is ending."; echo ;;
    scope) t "The auditor confirms with you what is audited, how deep, and what is out of scope."; echo ;;
    analyze) t "The auditor runs the security-audit workflow on the code, without changing anything."; echo ;;
    validate) t "Each finding is checked independently: proof in the code, false positives removed."; echo ;;
    report) t "Writing the report: findings by severity, evidence (file:line), impact."; echo ;;
    plan) t "Prioritised fixes and optimisations, with effort and risk for each."; echo ;;
    fix) t "Approved fixes on a dedicated branch, checked and reviewed; the main branch stays untouched."; echo ;;
    done)
      if [[ "$LOOMY_PHASE_MODE" == "audit" ]]; then t "Audit finished: the report and the fix plan are in the audit folder."; echo
      else t "The project is set up; the lead agent now follows AGENTS.md and CLAUDE.md."; echo; fi ;;
    *) t "No phase recorded yet."; echo ;;
  esac
}

# loomy_phase_you <phase>: what the user must do (shown as "Your turn: …").
loomy_phase_you() {
  if [[ "$LOOMY_PHASE_MODE" == "task" ]]; then
    case "$1" in
      plan) t "nothing for now; keep the session open."; echo ;;
      approve) t "approve the plan or ask for changes in its session."; echo ;;
      build) t "follow the delegations here; the agent will ask you if a choice comes up."; echo ;;
      verify) t "look at the review findings it reports."; echo ;;
      commit) t "check the proposed commit (git log, git show)."; echo ;;
      done) t "start the next one with loomy task \"…\"."; echo ;;
      *) t "open the task session with loomy task --resume."; echo ;;
    esac
    return 0
  fi
  case "$1" in
    ""|brief) t "start the lead agent with loomy start."; echo ;;
    discover) t "nothing for now; keep the session open."; echo ;;
    interview) t "answer its questions in its session."; echo ;;
    propose) t "read the proposal, ask your questions."; echo ;;
    approve) t "approve the proposal or ask for changes in its session."; echo ;;
    build) t "follow the delegations here; the agent will ask you if a choice comes up."; echo ;;
    verify) t "look at the review findings it reports."; echo ;;
    document) t "review PROJECT.md and ARCHITECTURE.md when it points you to them."; echo ;;
    commit) t "check the proposed commit (git log, git show)."; echo ;;
    retire) t "nothing; the bootstrap is almost over."; echo ;;
    scope) t "confirm or adjust the audit scope in its session."; echo ;;
    analyze|validate) t "nothing for now; keep the session open."; echo ;;
    report) t "read the report when it points you to it."; echo ;;
    plan) t "choose which fixes to apply, or stop at the report."; echo ;;
    fix) t "review the fix branch before merging it yourself."; echo ;;
    done)
      if [[ "$LOOMY_PHASE_MODE" == "audit" ]]; then t "read the report; merge the fix branch if you are satisfied."; echo
      else t "ask the lead agent for your changes (loomy start opens its session)."; echo; fi ;;
    *) t "loomy start to open the lead agent session."; echo ;;
  esac
}

# loomy_phase_index <phase>: rank of the phase (1 to count), 0 when unknown, count + 1 when finished.
loomy_phase_index() {
  local p i=0
  [[ "$1" == "done" ]] && { echo $(( LOOMY_PHASE_COUNT + 1 )); return 0; }
  for p in $LOOMY_PHASES; do i=$(( i + 1 )); [[ "$p" == "$1" ]] && { echo "$i"; return 0; }; done
  echo 0
}

# loomy_you_now <phase> <session state>: instruction for the user, adapted to the lead agent session.
# As long as no session is open, the only useful thing is to open it (or reopen it).
loomy_you_now() {
  case "$1" in done) loomy_phase_you "$1"; return 0 ;; esac
  case "$2" in
    open*) loomy_phase_you "$1" ;;
    closed*)
      if [[ "$LOOMY_PHASE_MODE" == "audit" ]]; then t "reopen the audit session with loomy audit --resume; it will resume at this phase."; echo
      elif [[ "$LOOMY_PHASE_MODE" == "task" ]]; then t "reopen the task session with loomy task --resume; it will resume at this phase."; echo
      else t "reopen the lead agent session with loomy start; it will resume at this phase."; echo; fi ;;
    *)
      if [[ "$LOOMY_PHASE_MODE" == "audit" ]]; then t "open the audit session with loomy audit --resume."; echo
      elif [[ "$LOOMY_PHASE_MODE" == "task" ]]; then t "open the task session with loomy task --resume."; echo
      else t "open the lead agent session with loomy start."; echo; fi ;;
  esac
}
