# ADR-0010 — Content release 2 boundaries

Status: accepted contract (2026-10-27); implementation and release evidence pending.
Execution-scratch acceptance and shared-reader ownership refined on 2026-11-10.

Release 1 separates structural journal events, authorized display labels and
optional private results. Release 2 must apply that boundary to checkpoints,
exports and incidental buffers without losing source cursors, accounting,
recognizable tasks or the caller's complete successful result. This record fixes the
shared contracts; it does not enable the later checkpoint or execution writers.

## Read-only identity, policy and export

`Loomy::ContentPolicy::policy_snapshot(root)` reads the existing project identity
and policy without calling the identity-creating `_context` path. The shell
entry point is `loomy_content_policy_snapshot ROOT`; it prints canonical JSON
without initializing the interactive UI. The snapshot reports `identity_state`
(`present`, `missing`, `invalid`) and `policy_state` (`project`, `default`,
`invalid`) with the effective policy fields. Missing or unsafe identity supplies
no invented project ID and closes grants. Reads never create a directory, lock,
identity or policy, chmod an existing object, repair, migrate or quarantine it.
Unsafe symlinks, FIFOs, hardlinks, ownership, permissions and races fail closed.
Registered shared worktree identities retain the existing registration check.

`policy_snapshot` is the single public noncreating policy/identity reader.
The live collector ownership work (ADR-0011) reuses it rather than introducing a
second public reader. A later extraction of `_dir` and `_shared_owner` into
`runtime-paths.pl` may rebuild `_snapshot_context` on those shared primitives;
it must preserve this read-only contract.

`export_policy_snapshot(root, mode)` defaults to `structural`, independently of
an existing compatibility policy. Its shell entry point is
`loomy_content_export_policy_snapshot ROOT [structural|legacy-excerpts]`.
Export refuses unless `identity_state` is `present`, including in structural
mode: missing or invalid identity must never produce unsalted digests.
Exporters pass that snapshot to
`project_with_policy(policy, event)`, not the project-policy shortcut
`project_event`. Explicit `legacy-excerpts` can consume only an existing valid
grant for that project. A flag, restored brief, provider result, bound environment
or missing identity cannot create a grant. A caller needing new consent must use
the existing human-origin confirmation path before exporting; this read-only
API never prompts or saves consent. The five already bounded legacy fields
remain the entire compatibility domain. `LOOMY_JOURNAL_TASKS=0` wins over grants
and compatibility selection; it never changes the saved policy generation.

## Recursive checkpoint boundary

The v2 container and source/cursor identity remain. New generations belong under
`.loomy/logs/structural-v1/`; historical checkpoints, backups and shards are read
without mutation and never copied verbatim into that namespace. A later step implements
the file transactions; this record supplies the pure `checkpoint_schema()`,
`project_checkpoint(state, context)` and `validate_checkpoint(state, context)`
contracts. The context requires an existing project ID and explicit approved
source/workspace roots. Unknown object domains and serialized nested keys are
rejected or omitted by the closed projection, never admitted by a generic
recursive scalar rule. Validation cannot itself admit a writer or create files.
The current `usage.idx` is TSV, not a native v2 JSON checkpoint: its separate
logical row is `{source_locator, line_offset}`. The smooth display cursor's
logical record is `{shown}`. `checkpoint_schema()` describes these separately;
`project_checkpoint` handles native JSON state only. a later step owns preserving or
adopting the concrete usage/cursor formats without losing consumption offsets.
The pure helpers validate the expanded logical state against the 32 MiB legacy
read ceiling. A successful validation is not proof of the serialized core and
shard byte limits; a later step enforces those limits at its serializer/transaction boundary.

Preserve the real constructors' identities, counters, timestamps, topology,
dedup maps, consumption offsets, inode/stat probes, windows and signature tuples.
In particular:

- `label_ref` retains the six scoped fields `version`, `project_id`, `target_kind`,
  `target_id`, `attempt_id`, `label_id`; `label_refs` is a closed object containing only
  `slug`, `nickname`, `role`, each with that same scoped reference.
  Lifecycle event nulls retain R1's unknown-value meaning and confer no reference
  or grant authority; every non-null reference must satisfy the closed scope.
- Claude built-in/custom `agent_type` is a validated token of at most 40 ASCII
  characters. A legacy Claude call's `role` slot carries that same agent-type
  domain; it must not be degraded to `unknown` by the generic Loomy-role enum.
  a later step must preserve its meaning when adopting paired `role`/`agent_type` fields.
- Codex `owner_leads` values are closed `{lead, session}` records, not scalars.
  Retain `projected_metadata=2`, `v2_window`, the stat `probe_sig` tuple and the
  bounded array of task-start epoch values (`starts`) emitted by the collectors.
- Serialized emitted/checkpoint signatures are projected into their reviewed
  structural domains and deterministically hashed. Text-bearing map keys,
  unknown nested objects, raw carry buffers and encoded source JSON cannot
  bypass the boundary. Restart/replay stability and one usage count remain a later step
  transaction acceptance criteria.

`checkpoint_signature(key, value, context)` validates the closed serialized
domain before reusing R1's structural signature canonicalizer, including its
empty optional identity/model and generic-role semantics. The stored Claude call
retains its separate agent-type value. Adopted signatures match existing R1
replay/emit signatures; a raw signature body is never saved as the new digest.

Approved local paths are typed source/workspace locators under the supplied
roots, kept only in private 0700 directories and 0600 local checkpoint files.
The pure helper checks lexical containment; its caller must supply validated
roots, and a later step separately enforces filesystem ownership, type, no-follow and race
checks. Missing sources keep their locator/cursor identity without being opened.
They are excluded from export and sync; this permission does not cover changed
file lists, task titles or arbitrary paths. Opaque IDs are optional only after
the paired Mac and native Linux performance gate. a later step must freeze its numerical
warm regression threshold before measuring; cold p95 remains at most 80 ms.
New core size is at most 2 MiB; at most 64 shards, each at most 256 KiB and
16 MiB combined; legacy reads are at most 32 MiB. A failed gate is reported,
never solved by dropping its workload or weakening a schema silently.

## Collector admission and restriction lifetime

`collector_admission_contract()` fixes the future
`Loomy::CollectorContent::admit(request, lock_attestation)` API, implemented in
the later collector-content module and bound centrally. Its closed request fields
are `protocol_version=1`, `project_id`, `requester_pid`, `requester_birth`,
`policy_generation`, `journal_enabled`, `tasks_restricted`. A verified
collector ownership attestation adds `collector_pid`, `collector_birth`,
`state=new|live|quiescent|unknown` and
`owner_scope=requester|owned-descendant|other|unknown` to the identity and
restriction tuple. An arbitrary caller hash or environment flag is not an
attestation. The descriptor fixes the closed result fields and finite reasons.
Admission is `admitted`, `refused` or `hold`: missing, unverified or unsupported
ownership evidence holds; mismatched identity/ownership or incompatible live
writers refuse; compatible owned collectors or verified new/quiescent ownership
can admit. A descriptor alone implements none of those checks. New owned
descendants inherit restrictions and each writer
rechecks policy before effects. Incompatible reuse is refused before provider
launch, append or cursor acknowledgement. An unknown/preprotocol collector needs
verified LOCK quiescence or a hold, with a visible reason.

`TASKS=0` restricts its requesting process and owned descendants. It is not a
durable project-global veto, a grant mutation, permission to kill another watch,
a new daemon or a promise that a later separately granted collector will never
reread provider transcripts. Project-wide revocation uses the existing privacy
controls. No safe concurrent mixed-writer guarantee is made without LOCK.

## Named residual: execution scratch

The lead selected option 2 on 2026-10-27: preserve today's complete output on
success only, including arbitrarily large output, and preserve failure, exit 75,
handover and accounting behavior. Progressive delivery on a late failure was
rejected. Provider replay was not established. The same answer prefix can end
with success or failure; withholding it until that status needs proportional
storage. An unlinked regular file still counts as disk storage.

The single new raw-storage residual is **execution scratch**. The binding
acceptance checklist records required contracts, not completed bridge checks:

| Item | Required contract |
| --- | --- |
| 1 | Validated per-user base, trusted parents and canonical location; exclusive random directory; fail closed. |
| 2 | Lifetime `flock(LOCK_EX)`; verified owner metadata and nonblocking lock before stale reaping. |
| 3 | Mandatory pipes for content-bearing values; no content here-strings or here-docs; shell-local, non-exported `TMPDIR`. |
| 4 | Ignore PIPE/XFSZ; clean up for EXIT, INT, TERM, HUP, QUIT, ALRM, USR1 and USR2; no provider `exec` from the trap owner. |
| 5 | Loomy-owned stdout writer checks every write and final close. |
| 6 | Bridges set `ulimit -c 0`; disclose OS persistence limits and the macOS temporary-directory rationale. |
| 7 | Structural export requires `identity_state=present`; no unsalted digests. |

The scratch lifecycle must satisfy the following details:

- **Base selection:** an inherited `TMPDIR` is usable only if it is an existing
  directory owned by the current user, mode 0700, whose canonical realpath is
  outside the project root and every synced/exported location. An unsafe
  inherited value fails the delegation; it is not a request to try another
  location. With no inherited value, macOS resolves the base with
  `getconf DARWIN_USER_TEMP_DIR`; command failure fails the delegation. Linux
  selects `$XDG_RUNTIME_DIR` only if user-owned and 0700, otherwise the
  lstat-verified user-owned 0700 `/tmp/loomy-<uid>`. This is the only specified
  Linux alternative; shared `/tmp` itself is never a scratch base. Linux runtime
  directories are commonly tmpfs: RAM use and possible swap remain a stated
  trade-off, not a disk-free or persistence-free guarantee.
- **Parent and realpath checks:** validate the selected base's directory type,
  owner, mode and canonical location, and validate the parent chain before use.
  Parents must be trusted user/root-owned directories without unsafe writable
  components; the root-owned sticky `/tmp` parent is allowed only above a
  verified private user-owned 0700 base. Resolve system path aliases safely;
  reject unsafe links, containment in the project or any synced/exported
  location, and replacement races. Do not accept an unresolved or unverifiable
  parent or canonical path. A failed validation, creation or later safety check
  fails closed without falling back to a weaker directory, using the seeded
  diagnostic `Execution scratch could not be created safely; delegation not started.`
- **Private creation:** create one random per-delegation directory with an
  exclusive 0700 `mkdir`; `EEXIST` or any failed check fails the delegation.
  Files are 0600 from creation, regardless of the caller's umask. No-follow,
  type, owner, link and replacement checks apply to creation, access and cleanup;
  a name prefix is never ownership proof. A missing or replaced scratch file
  fails the delegation, never becoming an empty successful result.
- **Liveness and reaping:** the owner holds `flock(LOCK_EX)` on a verified lock
  file inside its directory for its whole lifetime. Protected metadata inside
  that directory records uid, PID, process start time (birth), boot ID and host.
  The next bridge start may delete stale scratch only after obtaining
  `LOCK_EX|LOCK_NB` on the verified lock and validating that metadata and the end
  of the recorded owner's lifetime. PID existence alone is insufficient: PID
  reuse, another host or a different process namespace must not misidentify an
  owner. Live owners are skipped; unverifiable lock/metadata, host, boot or
  process-birth evidence is skipped and reported, never guessed dead.
- **Signals and handover:** ignore PIPE and XFSZ so writes fail with EPIPE or
  EFBIG and enter an explicit failure path. Trap EXIT, INT, TERM, HUP, QUIT,
  ALRM, USR1 and USR2. Signal cleanup stops and reaps owned children before
  removing owned scratch, and remains idempotent with normal/error EXIT.
  SIGQUIT must take this cleanup path. Never `exec` the provider from the
  trap-owning shell: a successful `exec` bypasses Bash's EXIT trap. An ordinary
  `exit 75` runs EXIT cleanup before returning the paused status. Handover must
  complete that same cleanup before transferring control; a bridge-to-bridge
  `exec` handover must run it explicitly because `exec` will not run EXIT.
  Preserve exactly-once lifecycle/accounting and the existing 75/handover
  result; any resumed/replacement attempt creates its
  own scratch directory. SIGKILL cannot be trapped: stale reaping is recovery,
  not immediate deletion after abrupt kill or power loss.
- **Storage and checked delivery:** raw provider output/events and the error/
  result material needed for existing delivery stay inside that directory.
  Provider stdout passes through a Loomy-owned writer that checks every write,
  including short writes, and the final close. Any short/failed write or failed
  close fails the delegation even if the provider reports success. There is
  **no size cap**: complete arbitrary-size successful output remains disk-bound
  as today. Disk-full, parser/storage errors and cleanup failures are explicit
  failure paths; never silently truncate, return a partial result as complete
  or start a paid retry to compensate. Never copy scratch into another
  incidental spool, structural store, diagnostic, receipt, sync or export.
  Independently authorized bounded private-result retention remains its own
  R1 workflow, not an incidental scratch copy.
- **Content transport:** pipes are mandatory for every content-bearing value;
  content-bearing Bash here-strings and here-docs are forbidden. a later step adds a
  static bridge check for this rule. Internal formatter/matcher values travel
  through stdin, never external process argv. The only listed exceptions are
  the owned execution scratch above, separately authorized bounded R1 private
  results, and the existing public task/provider argv protocols, which remain
  separately disclosed. These exceptions do not authorize incidental spools or
  content here-strings/here-docs. The bridge shell sets a shell-local,
  non-exported `TMPDIR=<owned scratch dir>`, removing any inherited export
  attribute, so any Bash-created temporary file stays inside the owned directory
  and is reaped with it. No OS/process secrecy or support for unverified new
  CLI flags follows.
- **OS persistence limits:** bridges set `ulimit -c 0` before provider launch.
  Swap, hibernation and OS crash reporters are out of scope. The macOS per-user
  temporary directory's exclusion from Time Machine is a reason for selecting
  it, not a secure-erasure guarantee. Unlink does not securely erase filesystem
  or OS copies.

A later step implements the hardened scratch lifecycle in the bridges and verifies their
framing, successful-result bytes, errors, signals, exactly-once 75/handover and
usage. This record does not install a scratch allocator or change live bridges. Before that
release, the CHANGELOG and privacy status line must disclose this residual using
the seeded EN/FR text. The current R1 status continues to report pending repair
until the later implementation and integration are complete.

Streaming transport targets are 64 KiB per read/chunk and a separate 64 KiB
error-classification window. Optional private capture retains at most the
authorized record limit (no more than 1 MiB) plus one byte as an oversize sentinel;
an oversize capture is unavailable, never a truncated saved result. Metadata
parser state needs separate explicit bounds in a later step. These bounds do not cap
successful caller output or execution scratch. Synthetic framing probes cover
empty, 1 MiB and 64 MiB output, late status and the Bash 3.2 110,592-byte
here-string/pipe descriptor comparison. Stub evidence does not prove a real
provider accepts FIFO output or avoids persistent transcript/session files.
Real-provider-created-file feasibility is **NOT RUN / NOT VERIFIED** here and
remains a release gate unless separately accepted by the lead.

## Typed skills and handoff

`skills_auto_for_values type traits detail1` matches the existing catalog in
memory. `skills_auto_for root` remains a wrapper with the existing `traits` to
`sensitive` fallback. Task suggestions and matcher inputs use stdin pipes to
external matchers, preserving recommendations and literal text without synthetic
brief files, content-bearing here-strings or `awk -v` text arguments. a later step adopts
the typed API in setup; it does not need to own the skills library.

Known gap assigned to a later step: `skills.lock` still receives a task title in its
`reason` field (`skills.sh:274`, `loomy-task.sh:126`). That step replaces the raw title
with the reason code `task:<id>`; this record neither fixes nor accepts the current write.

Later steps reuse the reserved EN/FR seed block and add exact `EN<TAB>FR` keys; the
final step adopts the standalone contract suite in the full runner, wires collector
admission and updates release/privacy disclosures. Passing the contract suite is contract evidence, not proof
that unimplemented checkpoint, provider, collector or scratch writers are safe.
