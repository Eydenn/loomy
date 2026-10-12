# Release Priorities

## P1: Native Codex Agents Missing From Watch

Reported and reproduced on 2026-10-12 with Loomy 0.16.1 and Codex CLI
0.162.0-alpha.17.2. Implemented on `fix/codex-native-watch` for the next
maintenance release; not installed or released by this change.

### Observed Behavior

A Codex lead launched three native agents using `spawn_agent` / collaboration:
two writers with distinct ownership and one independent reviewer. Their local
rollouts recorded separate agent identities, parent-thread identities, models,
efforts, `task_started` and `task_complete` events, and ongoing activity. The
lead process remained alive. None of the three native agents appeared in
`loomy watch` because their lifecycle events were absent from the project's
`.loomy/logs/events.jsonl`.

This is an instrumentation gap, not evidence that the agents stopped working.
The existing journal producers cover Loomy delegation bridges and Claude's
native-agent hooks, but not this native Codex execution path.

### Reproduction

1. Start an existing Loomy project with a Codex lead and Codex-only routing.
2. Open `loomy watch` on the same project.
3. Have the lead spawn three native Codex agents with distinct tasks.
4. Verify their activity in their local Codex rollouts and the lead's agent
   status result.
5. Compare the watch display and the project's journal: the native agents
   are missing although the lead session and bridge delegations are visible.

### Correction Scope

- Track native Codex agents as well as bridge-launched agents, without requiring
  the user to change their delegation workflow or restart running agents.
- Display the actual model, effort, task identity, running/waiting/finished
  state where observable, elapsed time, and last observed activity.
- Handle repeated turns of the same agent: finishing one turn must not imply
  that its entire assignment is accepted, and a new turn must be observable.
- Preserve independent review as a separate activity, including partial or
  blocked results. A terminal event is not a linguistic or release approval.
- Do not invent completion percentages from elapsed time. If advancement is
  unknown, show observed activity or an explicit unknown state.
- Keep ingestion local, incremental, bounded and token-free. Avoid scanning
  all conversation history on each refresh. Do not copy raw prompts, tool
  arguments, transcripts or credentials into the project's journal.
- Preserve private journal permissions, reject symlink targets, isolate projects
  and parent sessions, and stop reporting active work after an observed end or
  a verified owner-process exit. Missing evidence must not mean success.
- Avoid double counting lifecycle events, usage and costs between the native
  path and bridge path; unknown usage must remain unknown.

### Acceptance Tests

- Three native agents appear simultaneously in both tree and list views.
- Completion, abort, partial result, subsequent turn and owner-process exit
  update correctly; final summaries do not automatically pass review gates.
- Restarting watch/backfilling a running session preserves identities and
  produces no duplicate agents or usage records.
- Unrelated projects/sessions are excluded; malformed, truncated, unavailable
  and growing rollout files are handled without hanging watch.
- Claude-native and Codex-bridge tracking continue to pass their existing tests.
- Private data and journal symlink protections are regression-tested.
- Verify terminal rendering on the Mac and measure polling overhead before
  release. The existing full Loomy release gates remain required.

### Separate Coordination Finding

The same project's task remained at `phase=plan` while writers were editing
files. This is independently stale orchestrator-maintained phase metadata.
Do not conflate it with the missing native-agent lifecycle events. Clarify and
test the phase-update contract: the lead must update build/verify transitions,
and watch must not imply that an old phase is a current observation.

Status: implementation and independent scoped review completed. The targeted
suite passed 67 checks, including actual watch refresh, privacy, large backlogs,
repeated turns and journal-generation restoration. Full repository and remote
CI gates are recorded in the delivery report; this is not a package release.

## Follow-Up: Linked Worktree Install Classification

The full-suite installation check exposed a pre-existing worktree limitation:
`bin/loomy` tests whether `.git` is a directory when classifying a Git install.
A linked worktree has a `.git` file and is classified as manual instead. The
current native-agent change does not alter this independent behavior.

Validate the native-agent candidate in an ordinary local Git clone with
byte-identical source files; do not suppress the installation assertion.
A future focused fix should recognize valid linked Git worktrees and retain
the npm, bun, Homebrew and genuinely manual installation classifications.
