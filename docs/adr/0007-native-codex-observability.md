# ADR-0007: Observe Native Codex Agents Locally

Status: Accepted (2026-10-12); repository delivery gates recorded separately.

## Context

The Loomy delegation bridges emit lifecycle events, and Claude's native agents
have lifecycle hooks. Native Codex agents run through a separate path. A live
Codex parent can therefore have active children that `loomy watch` cannot see.
The parent's continued existence is not proof that every child is still working.

## Decision

- Add a local Perl collector to the existing watcher, with a one-shot entry
  point for snapshot commands. No new service, runtime dependency or model call.
- Scope rollout metadata by project and parent session, and use native thread
  and turn identities rather than collapsing all workers into one role.
- Persist private incremental cursors and deduplication keys. Read bounded
  chunks, retry incomplete records, and tolerate unrecognized records.
- On journal replacement or truncation, rehydrate only currently active turns
  into the new journal generation, preserving delegation identities and source
  timestamps. Do not replay historical completions or invent fresh activity.
- Export only necessary identity, model, effort, timestamp and lifecycle fields.
  Never export raw conversations or tool arguments; measured usage must not be
  invented or counted again through another path.
- Recover the root session's model and effort from observed turn contexts,
  not its planned routing. Keep source identity separate from catch-up status;
  clear invalidated evidence and recover revision ordering after checkpoint loss.
- Record the owner process explicitly, not as an individual agent PID.
- Track new turns, termination and observed activity. A turn completion without
  an explicit recognized result is unknown, not approved work. Partial/blocked
  results remain distinct, and no elapsed-time-derived percentage is displayed.
- Keep phases as lead-maintained metadata. Do not infer build/verify phases from
  a tool name or silently rewrite an orchestrator's task state.

## Consequences And Limits

- Tracking depends on observable local Codex rollout records and a correlated
  Loomy owner session. If the records are unavailable or ambiguous, the collector
  must not guess ownership or claim success.
- This is a versioned-file adapter, not a public Codex API guarantee. Fixtures
  describe the observed protocol; new CLI formats need verification.
- Discovery runs at most once every five seconds across today's and the six
  preceding UTC date directories, plus tomorrow for local-time directory dates.
  It considers up to 128 recent rollout names per directory (at most 4,096
  directory entries) and reads at most 32 uncached metadata records per pass.
  Metadata must fit in the first 64 KiB. Already discovered files remain tailed;
  older undiscovered sessions and formats outside these bounds are not promised.
- Lifecycle polling runs once per second in the existing watcher process.
  Journal replay and lifecycle reads each have a 2 MiB budget per pass, with up to
  256 KiB per child and rotating read order. Root context discovery shares that
  lifecycle budget with a 128 KiB incremental head and at most 128 KiB recent
  tail per root; tail positions cannot be replaced by older head observations.
  Initial catch-up may take several
  passes. Oversized records are skipped, not treated as valid completion;
  missing evidence stays unknown. Locks never wait on a concurrent journal writer.
- Parent-session correlation must be unambiguous. If a Loomy opening lacks an
  explicit session ID, the adapter checks local metadata/start evidence in a
  bounded time window; ambiguous matches are left untracked, not guessed.
- A Git push of this correction does not upgrade an existing Homebrew install
  or restart a watcher already running the installed version.

## Verification

- The isolated targeted suite passed 67 checks on the Mac, including three
  agents in list/tree/diagram/status, real watch PTY refresh, new turns,
  interruption after drained backlog, nine-child budget fairness, journal
  rotation/truncation/restoration, deduplication, privacy and unknown costs.
- 100 unchanged in-process polls took 0.233 seconds on the local Mac in the
  parent run. This is a small-fixture idle measurement, not a guarantee for a
  huge history or a different machine.
- Full repository and remote CI results are recorded in the delivery report;
  the targeted suite does not replace them. This adapter cannot certify an
  agent's linguistic correctness or approve a product release.

## Alternatives Considered

- Require all Codex agents to use Loomy's bridges: changes the user's workflow
  and does not represent already running native work.
- Copy or repeatedly scan all conversation history: unnecessary privacy,
  latency and resource cost.
- Derive completion from elapsed time or the parent PID: falsely labels
  waiting, aborted or missing native work as progress.
- Use an external monitoring/model service: unnecessary for deterministic
  local lifecycle evidence.
