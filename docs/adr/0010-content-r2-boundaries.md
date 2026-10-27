# ADR-0010 — Content release 2 boundaries

Status: accepted contract (2026-10-27); implementation and release evidence pending.

Release 1 separates structural journal events, authorized display labels and
optional private results. Release 2 must apply that boundary to checkpoints,
exports and incidental buffers without losing source cursors, accounting,
recognizable tasks or the caller's complete successful result. T0 fixes the
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

`export_policy_snapshot(root, mode)` defaults to `structural`, independently of
an existing compatibility policy. Its shell entry point is
`loomy_content_export_policy_snapshot ROOT [structural|legacy-excerpts]`.
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
without mutation and never copied verbatim into that namespace. T1 implements
the file transactions; T0 supplies the pure `checkpoint_schema()`,
`project_checkpoint(state, context)` and `validate_checkpoint(state, context)`
contracts. The context requires an existing project ID and explicit approved
source/workspace roots. Unknown object domains and serialized nested keys are
rejected or omitted by the closed projection, never admitted by a generic
recursive scalar rule. Validation cannot itself admit a writer or create files.
The current `usage.idx` is TSV, not a native v2 JSON checkpoint: its separate
logical row is `{source_locator, line_offset}`. The smooth display cursor's
logical record is `{shown}`. `checkpoint_schema()` describes these separately;
`project_checkpoint` handles native JSON state only. T1 owns preserving or
adopting the concrete usage/cursor formats without losing consumption offsets.
The pure helpers validate the expanded logical state against the 32 MiB legacy
read ceiling. A successful validation is not proof of the serialized core and
shard byte limits; T1 enforces those limits at its serializer/transaction boundary.

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
  T1 must preserve its meaning when adopting paired `role`/`agent_type` fields.
- Codex `owner_leads` values are closed `{lead, session}` records, not scalars.
  Retain `projected_metadata=2`, `v2_window`, the stat `probe_sig` tuple and the
  bounded array of task-start epoch values (`starts`) emitted by the collectors.
- Serialized emitted/checkpoint signatures are projected into their reviewed
  structural domains and deterministically hashed. Text-bearing map keys,
  unknown nested objects, raw carry buffers and encoded source JSON cannot
  bypass the boundary. Restart/replay stability and one usage count remain T1
  transaction acceptance criteria.

`checkpoint_signature(key, value, context)` validates the closed serialized
domain before reusing R1's structural signature canonicalizer, including its
empty optional identity/model and generic-role semantics. The stored Claude call
retains its separate agent-type value. Adopted signatures match existing R1
replay/emit signatures; a raw signature body is never saved as the new digest.

Approved local paths are typed source/workspace locators under the supplied
roots, kept only in private 0700 directories and 0600 local checkpoint files.
The pure helper checks lexical containment; its caller must supply validated
roots, and T1 separately enforces filesystem ownership, type, no-follow and race
checks. Missing sources keep their locator/cursor identity without being opened.
They are excluded from export and sync; this permission does not cover changed
file lists, task titles or arbitrary paths. Opaque IDs are optional only after
the paired Mac and native Linux performance gate. T1 must freeze its numerical
warm regression threshold before measuring; cold p95 remains at most 80 ms.
New core size is at most 2 MiB; at most 64 shards, each at most 256 KiB and
16 MiB combined; legacy reads are at most 32 MiB. A failed gate is reported,
never solved by dropping its workload or weakening a schema silently.

## Collector admission and restriction lifetime

`collector_admission_contract()` fixes the future
`Loomy::CollectorContent::admit(request, lock_attestation)` API, implemented in
T1's `collector-content.pl` and bound centrally by T6. Its closed request fields
are `protocol_version=1`, `project_id`, `requester_pid`, `requester_birth`,
`policy_generation`, `journal_enabled`, `tasks_restricted`. A verified
MAINFIRST-LOCK attestation adds `collector_pid`, `collector_birth`,
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

## Named residual: R2-D1 execution scratch

The lead selected option 2 on 2026-10-27: preserve today's complete output on
success only, including arbitrarily large output, and preserve failure, exit 75,
handover and accounting behavior. Progressive delivery on a late failure was
rejected. Provider replay was not established. The same answer prefix can end
with success or failure; withholding it until that status needs proportional
storage. An unlinked regular file still counts as disk storage.

The single new raw-storage residual is **execution scratch**, with this contract:

- One private, exclusively created, no-follow directory per running delegation
  under the per-user runtime temporary directory, outside the project and all
  synced/exported locations. Directories are 0700 and files 0600 from creation,
  even with a permissive caller umask. Type, owner, link and replacement checks
  apply to creation, access and cleanup; a name prefix is not ownership proof.
- Raw provider output/events and the error/result material needed to preserve
  existing delivery stay inside that directory. Never copy them to another
  incidental spool, structural store, diagnostic, receipt, sync or export.
  Independently authorized bounded private-result retention remains its own R1
  workflow and is not an incidental scratch copy.
- Remove owned scratch on normal and error EXIT and on INT, TERM and HUP after
  stopping/reaping owned children. SIGKILL cannot be trapped: the next bridge
  start reaps stale directories only after verifying a dead owner PID and safe
  owned metadata. Live or unverifiable owners are never guessed dead. Do not
  claim that abrupt kill or power loss removes bytes immediately, or that unlink
  securely erases filesystem/OS backups.
- There is **no size cap**: complete arbitrary-size successful output remains
  disk-bound as today. Disk-full, failed writes and cleanup failures are explicit
  failure paths; never silently truncate output, return a partial result as
  complete or start a paid retry to compensate for a parser/storage failure.
- Replace content-bearing Bash here-strings with pipes where feasible. Internal
  formatter/matcher values travel through stdin, not external process argv.
  The existing public task/provider argv protocols remain separately disclosed;
  no claim of OS/process secrecy or support for unverified new CLI flags follows.

T2 implements the hardened scratch lifecycle in the bridges and verifies their
framing, successful-result bytes, errors, signals, exactly-once 75/handover and
usage. T0 does not install a scratch allocator or change live bridges. Before R2
release, the CHANGELOG and privacy status line must disclose this residual using
the seeded EN/FR text. The current R1 status continues to report pending repair
until the later implementation and integration are complete.

Streaming transport targets are 64 KiB per read/chunk and a separate 64 KiB
error-classification window. Optional private capture retains at most the
authorized record limit (no more than 1 MiB) plus one byte as an oversize sentinel;
an oversize capture is unavailable, never a truncated saved result. Metadata
parser state needs separate explicit bounds in T2. These bounds do not cap
successful caller output or execution scratch. Synthetic framing probes cover
empty, 1 MiB and 64 MiB output, late status and the Bash 3.2 110,592-byte
here-string/pipe descriptor comparison. Stub evidence does not prove a real
provider accepts FIFO output or avoids persistent transcript/session files.
Real-provider-created-file feasibility is **NOT RUN / NOT VERIFIED** in T0 and
remains a T2/release gate unless separately accepted by the lead.

## Typed skills and handoff

`skills_auto_for_values type traits detail1` matches the existing catalog in
memory. `skills_auto_for root` remains a wrapper with the existing `traits` to
`sensitive` fallback. Task suggestions and matcher inputs use stdin pipes to
external matchers, preserving recommendations and literal text without synthetic
brief files, content-bearing here-strings or `awk -v` text arguments. T3 adopts
the typed API in setup; it does not need to own the skills library.

T1–T5 reuse the contiguous `# R2-T0` EN/FR seed block and send additional exact
`EN<TAB>FR` keys to T6. T6 adopts the new standalone contract suite in the full
runner, wires collector admission, updates release/privacy disclosures and
assembles cross-lane write manifests. Passing T0 is contract evidence, not proof
that unimplemented checkpoint, provider, collector or scratch writers are safe.
