# ADR-0011 — One live collector per project

Status: Accepted (2026-11-12).

## Context

Native Codex and Claude tracking reads provider files and writes checkpoints, cursors and journal events. Until 0.17.9 every `loomy watch`, one-shot `status`/`tree` and direct adapter call collected on its own, serialized only by short per-index locks. Several views on one project (and sibling Git worktrees sharing one store) repeated the work, raced on cursors and could not say who was authoritative. Fencing was impossible: nothing identified the writer.

## Decision

- One owner per canonical project store, enforced by a non-blocking kernel lock on `.loomy/logs/collector.lock` with a content-free record beside it. The store is resolved once by `runtime-paths.pl`, so every worktree layout shares one lock and one source-root set.
- Only a command lifetime elects: the watch once, a one-shot view or direct adapter, reducer or migration call transiently. Everything else is a follower: no election side effects, no writes, stored checkpoints and journal only. Inspection commands (`log`, plain `doctor`, resume) never elect.
- The guard is checked at every storage boundary and fences on replaced lock, record or directory, fork and release. Drain is bounded: the owner finishes its current batch, flushes, then releases last; the controller exits in seconds even if the disk stalls. No stealing, no PID signalling, no timeout takeover.
- The decision is visible and short: footer notes lead with the action, `loomy doctor` carries the facts (build, pid, boot, birth, epoch).

## Consequences

- One live collector per project, a followers' view equal to the owner's, and measurable one-shot savings.
- Older builds cannot be fenced: a newer lock does not constrain code that ignores it. Adoption therefore needs explicit quiescence: close older watches with `q`, switch, reopen. Supported pairs are tested under quiescence (0.17.9 -> 0.17.10 -> 0.17.9); an old watch beside a new one is documented as unsupported, not prevented.
- The protocol number in the record is separate from the version string, so a later implementation can refuse or follow by protocol, not by version text.
- Out of scope: a daemon, authentication of same-user processes, network filesystems, and hook cost accounting.

- Clone-shipped runtime state tracked in the Git index is refused (by filesystem identity, failing closed). The gate is a leak barrier at the shared append and journal lock (and the preparation), not only an election check: every journal writer and every election passes it, so a tracked `.loomy/logs` never receives private events that a later `git commit -a` would publish. Only a positive verdict is cached in the project: `.loomy/logs/gate-v1` holds a sha256 of the index stat, the Git directory and the identity of `.loomy` and `.loomy/logs` (never for an index changed in the last 2 s, a not-yet-existing logs directory or an invalid Git directory). A tracked verdict is only memoized 2 s in the process and an unanswered or erroring Git is a refusal remembered 30 s by an empty marker file outside the project (per-user cache directory, named by the sha256 of the project root): a tracked or refused logs directory therefore never receives a file, and a shipped `gate-v1` is never rewritten. The barrier also covers the elected native collectors (asked at each poll, before any lock or journal byte), the non-blocking journal lock, the direct adapter and reducer command lines, and the label store `display-context-v1.jsonl`. An owner asks again at each poll (stats only on a cache hit), so a file that becomes tracked mid-watch stops the writes at the next poll. The remedy is `git rm --cached -f -- <path>` for a path that can be shown and `loomy doctor --fix` otherwise: it removes from the index only the entries the gate reported, through `git update-index --force-remove -z --stdin` with literal pathspecs.
- Known limits: only the innermost repository is checked; an index of about 1.5 million entries or more cannot be read within the 2 s bound ("Storage not verified"); residuals: an answer that needed Git is memoized 2 s per process, so an owner can write for up to 2 s after a file becomes tracked, and the refusal marker delays recovery by up to 30 s; a same-user process that ignores the gate is out of scope.

## Alternatives considered

- Hold both legacy adapter locks for a whole watch: fences one historical baseline only, adds lock-order and fairness problems and cannot certify older builds.
- A background service: contradicts the no-daemon, no-dependency stance (ADR-0001).
- PID files or timeouts: reuse and stopped processes make them unsafe; the kernel lock releases on any exit.
- Letting every view poll: the 0.17.9 behaviour this replaces.
