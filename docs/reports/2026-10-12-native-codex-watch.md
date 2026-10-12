# Native Codex Watch Delivery

Date: 2026-10-12. Source branch: `fix/codex-native-watch`, based on `4e0ebbf`.
This prepares a maintenance correction; it does not release or install Loomy.

## Implemented

- Local bounded ingestion of native Codex lifecycle records, scoped to project
  and parent session, alongside existing Claude hooks and delegation bridges.
- Distinct agent/turn identities, actual model/effort, observed activity and
  terminal outcomes in watch, status, tree and statistics.
- Restart deduplication, oversized-record progress, fair child read budgets,
  interruption only after fresh EOF evidence, and active-only restoration after
  journal rotation or truncation with original identities and timestamps.
- Private checkpoints/journals, nonblocking locks, symlink rejection, task-text
  switches, no conversation/tool-argument export, and explicit unknown native
  usage rather than invented measurements.

## Verified Locally

- Independent security/reliability review: all reproduced P2 findings fixed;
  no remaining P1/P2 found in the scoped final review.
- `bash tests/codex-native.sh`: 67 checks passed in the parent run, including
  real watch PTY refresh, rotation, repeated turns, privacy and malformed input.
- `bash tests/run.sh -v`: 1,421 passed, zero failed on the Mac.
- The full gate ran in an ordinary isolated local Git clone containing
  byte-identical candidate source. A linked-worktree run encountered the
  pre-existing install-classification assertion documented in `docs/BACKLOG.md`;
  no assertion was suppressed or changed. Code hashes matched before/after.
- Perl syntax, Bash syntax, ShellCheck, translation coverage and
  `git diff --check` passed.
- 100 unchanged in-process polls took 0.233 seconds on a small local fixture.
  This is not a large-history or cross-machine performance guarantee.
- `npm pack --dry-run --json`: native Perl library included; private runtime
  artifacts excluded. Public agent templates are expected package content.

## Not Verified Or Not Performed

- No Homebrew/package release, version bump, tag or installed-watcher upgrade.
- No claim of support for arbitrary future Codex formats or undiscovered old
  sessions outside the bounded discovery horizon; see ADR-0007.
- No automated inference of product phases, completion percentages or review
  approval. Phases remain lead-maintained metadata.
- GitHub CI runs on the pushed PR head and is a separate remote check, not
  implied by the local results above. Its actual result is reported with delivery.
- Linguistic accuracy of another project's agent output is outside this change.
