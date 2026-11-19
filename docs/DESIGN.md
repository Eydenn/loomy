# Design notes

Loomy separates the temporary bootstrap behaviour from the repository's permanent instructions.

The decisions behind the main choices are recorded in [`docs/adr/`](adr/README.md).

- `START.md`: temporary setup and orchestration contract, copied to a project's root by `loomy init` from the template `bootstrap/START.md` (`fr/bootstrap/START.md` in French).
- `templates/AGENTS.md`: compact project rules for Codex.
- `templates/CLAUDE.md`: compact compatibility layer for Claude Code.
- `skills/project-bootstrap/`: reusable workflow, with progressively loaded references. Only data projects load `references/data.md`: figures require executed, versioned code and cited outputs/snapshots, temporal validation uses a held-out period split by time, and an independent routed agent validates results (another role/model of the same family in SOLO). Agents see schemas, statistics and anonymised samples, never the full data set. For `type: data`, project repair keeps one compact Data results bullet in the managed blocks of both `AGENTS.md` and `CLAUDE.md`, in every solo/hybrid setup, pointing to `.loomy/skills/project-bootstrap/references/data.md`. Repair adds or removes that bullet when the type changes; it never installs the bootstrap skill in native skill folders. The wizard shows the data rule in its recap and keeps the binding brief bullet, without listing it as an unapplied recommendation.
- `external-skills/`: integrations that must stay current with their original source.
- `fr/`: French copies of the agent-facing documents above, installed when French is detected.
- `scripts/`: deterministic setup tools.
- `scripts/loomy-init-wizard.sh`: terminal questionnaire that collects the easy, high-impact answers before spending a single token. It writes `.loomy/brief.md`, which the agent treats as an interview already held. `loomy-status.sh` makes the bootstrap phases and the delegation activity visible.
- `scripts/lib/models.sh` and `loomy-route.sh`: the lead agent and roles routing engine. It is the single source of truth for each role's model and effort in each environment. Its rationale is in `docs/MODEL_CATALOG.md`. `catalog/models.conf` holds the model chains, prices and route rebalancing as data; a `price_long.<model>=<prompt tokens> <input> <output> <cache-read>` line gives the dearer rate of a request whose whole prompt exceeds that size (Claude Haiku 5.5 above 100K tokens), applied to the entire request by `ai_price_long` and the usage counter (`@long` in `scripts/lib/journal.sh`).
- `loomy-doctor.sh`: checks that the machine can really run the routed models before spending tokens on the bootstrap.

- `bin/loomy`: single entry point, installed by npm, bun, Homebrew or `install.sh`. It calls the scripts above on the current project.
- `scripts/lib/i18n.sh` and `scripts/lib/i18n/fr.tsv`: interface language. Strings are English in the code (`t "English sentence"`); the French dictionary is compiled into a `case` function by `tools/i18n-build.sh`, fast even in bash 3.2. `tools/i18n-missing.sh` lists what isn't translated yet.
- `scripts/lib/journal.sh`: local activity log (`.loomy/logs/events.jsonl`). Bridges record delegation starts (pid) and completions (same id), with routing facts such as `requested` and `off_routing`. Every append path applies the per-event content allowlist; task text and override explanations are absent by default. Native Claude subagents record starts from `PreToolUse` and matching completions from `SubagentStop`, with the actual model from usage when available; their completion events refer to usage costs rather than counting them twice. Session and request events delimit the live recap; dead processes become interrupted roles in the live view. See [Per-store content policy](#per-store-content-policy).
- The integrated tree journal reads a bounded 400-record JSON tail, keeps task identity and the latest useful observed activity per active native turn, and honors tool/PID/session closure and explicit reopening. Received responses remain distinct from unconfirmed endings and approval; display labels are resolved at read time without rewriting the raw journal.
- `scripts/lib/hooks.pl`: the single hook-registration engine for `.claude/settings.json` and `.codex/hooks.json`. It holds the exact catalog of current and historical Loomy hook forms (shell form; a native form is reserved and never written), classifies each event (`shell`, `native`, `mixed`, `custom`, `missing`, `invalid`, `ambiguous`), and applies a deterministic transform: missing bindings added, recognized historical shell bindings converted, custom entries (user hooks, matchers, status line), their values and the file mode kept. A changed file is re-serialized with the 0.17.8 encoding (sorted keys, 2-space indent); an unchanged file is never rewritten. Writes are no-follow, locked, revalidated and atomic, preserve mode and group, and are refused for invalid, unsafe, unsupported-number or concurrently changed files. The status line is chained through a bounded wrapper (nesting marker, own process group). `scripts/lib/hooks.sh` is its shell adapter, used during installation and project repair (`init`/`--update` write both providers; automatic repair and `loomy hooks` act only inside a Loomy project and on the providers it uses).
- `scripts/loomy-hooks.sh`: `loomy hooks status|repair [--shell]`. Read-only status, scoped repair and the shell-form rollback before an older Loomy; prints only catalog event names, counts and fixed codes, never user commands. Native registration is deliberately unavailable in this release.
- `scripts/lib/runtime-paths.pl`: the single resolver of a project's runtime storage. It maps any spelling of a root (symlinks, registered Git worktrees, whole-`.loomy` or logs-only shared layouts) to one canonical store and a pinned context (`root`, `logs`, inode identities) without creating anything, and holds the shared no-follow, mode, owner and hardlink checks. It also exposes the read-only identity and policy readers CONTENT uses.
- `scripts/lib/collector-owner.pl`: the live collector election (ADR-0011). `try_acquire` takes a non-blocking kernel lock on `.loomy/logs/collector.lock` and publishes a content-free record; the returned guard authenticates writes (`assert_owner`, `assert_owner_quick`), carries the shared source-root set and its revision, supports `begin_drain` and a last-place `release`, and is fenced when the lock, record or directory is replaced, after fork or after release. Only a command lifetime elects (the watch once, a one-shot view or direct adapter/reducer/migration call transiently); a loser gets a reason (busy, draining, unsafe or incompatible runtime) and mutates nothing. `inspect` is the read-only view used by doctor and the footer.
- Follower path: a non-owner never polls. `Loomy::LiveState::follower_read` peeks both native checkpoints without locking (`checkpoint_peek`, `stat_evidence`), reads the journal, and reduces with the owner's last valid snapshot, so leases and agents match the owner's view; an unsupported checkpoint format is preserved and reported, not repaired. The watch promotes a follower when the owner releases. Entry points: `loomy-status.sh` (watch, status), `loomy-tree.sh`, the adapters' and the reducer's command lines (`bare_election`), `project.sh` migration; `log`, plain `doctor` and resume never elect.
- `scripts/lib/codex-native.pl`: local native Codex rollout adapter, loaded in the watch sampler and called once for snapshots. Project/parent ownership, per-turn lifecycle, observed root model/effort and last-observed activity feed the existing journal. Private cursors and recoverable context revisions support bounded head/tail reading, invalidation and deduplication; source freshness is separate from model identity. Native owner PIDs are explicit, conversations/tool arguments are not exported, usage is unknown, and distinct native identities remain separate tree nodes. See ADR-0007 for limits; phases are still lead-maintained.
- `scripts/lib/claude-native.pl`: Claude CLI/Code-tab hooks and bounded incremental transcript tails feed the shared `live-state.pl` projection. Agent calls and transcript agent IDs are aliased within each session, including stops preceding returns; asynchronous launch returns never finish a child. Explicit transcript stop/error metadata fills missing hooks, with unknown usage and a 120-second source-presence lease. Separate Claude/Codex leads remain visible together. Emitted journal events use the content allowlist; native checkpoints can still contain paths and content-bearing legacy state and have a separate storage boundary. Warm watch polls signatures every 200 ms. Source replay does not add costs. Atomic v2 checkpoint recovery, progressive reconstruction and bounded history are verified by the fixtures below.
- `scripts/lib/failover.sh`: temporary lead relay. The brief's lead (the master) never changes; the state is `.loomy/failover` (`master`, `acting`, `since`, `reason`, `resume_at`, optional `manual=1`). `lf_decide` returns the lead tool and a kind (`normal`, `handover`, `continue`, `return`) from the quotas (`quota_switch`, `quota_room`, `lead_failover`, `LOOMY_NO_SWITCH`), `lf_apply` records it and journals `lead_failover` / `lead_return`. `loomy start --lead codex|claude` explicitly selects a temporary lead; manual relays persist when the master has room, but automatic relay can return to the master if the acting lead saturates and the master has room. `--lead auto` or `--lead <master>` explicitly returns to the brief's lead; manual relays are shown as `(manual)`. The chain loop of `loomy-start.sh` (6 sessions at most, `LOOMY_CHAIN_DELAY` seconds to cancel) starts the next session; `loomy-context.sh` prints the prepare and return notices (prompt hook, at most every 10 minutes, Claude Code only) and the start context lines; `loomy-status.sh` and `loomy-statusline.sh` show it (⇄). See ADR-0006.
- `scripts/lib/config.sh`: user preferences (`~/.config/loomy/config`): Claude and Codex plans, to compare the API value consumed with the subscription price, language, screen mode, pinned models.
- `scripts/lib/phases.sh`: the ten bootstrap phases, each with what the lead agent does and what the user must do. Single source for `loomy status`, `loomy watch` and `loomy start`.
- `scripts/loomy-start.sh` (`loomy start`): opens or resumes the lead agent session. It finds the folder's previous session on the machine (Claude stores its conversations per folder, Codex records each session's folder) and picks the prompt from the phase.
- `scripts/loomy-install-project.sh` (`loomy init`): on a project already set up, offers to resume, update (`--update`, brief, phase and log kept) or reset (`--reset`).
- `scripts/loomy-privacy.sh` and `scripts/lib/privacy.sh` (`loomy privacy`): AI files visibility. Local mode: exclusion in `.git/info/exclude`, specific to the copy and invisible in the repository. Private mode: a second Git repository (`.loomy/ai.git`) whose working tree is the project itself and which only tracks the AI files; no copy, `sync` replays the changes on top of another machine's before pushing.
- `scripts/loomy-context.sh`: resume context (phase, expectations, delegations, Git, AI files). Installed by `loomy init` as Claude Code `SessionStart` and `SessionEnd` hooks (`.claude/settings.json`) and Codex hooks (`.codex/hooks.json`, same format), merged with an existing file. Codex only runs a project's hooks once the folder is trusted and the hooks approved (it asks on first launch); the Codex hook command walks up from the session folder to the Loomy project. Claude's prompt hook records request identity and time; a bounded excerpt requires the project's explicit `legacy-excerpts` grant. Native subagent hooks log their lifecycle, while `Stop` and `SubagentStop` collect usage. Session openings and closings go to the log; `loomy start` also records Codex sessions, whose process keeps its pid after `exec`.
- `scripts/loomy-home.sh`: `loomy` without argument, the home screen leading to the next action.
- `scripts/lib/usage.sh`, `scripts/loomy-statusline.sh` and `scripts/loomy-stats.sh` (`loomy stats`): subscription quotas and usage figures. Codex quotas come from the `rate_limits` events in its session logs (end of the latest log, cached in `~/.config/loomy/codex-limits`); Claude quotas from the documented `rate_limits` field of the status line input, saved to `~/.config/loomy/claude-limits` by the project status line (which then runs the user's own status line, remembered by `loomy init` in `~/.config/loomy/statusline-user`). With a subscription, status and log show quota shares and tokens; with the API, costs.
- `scripts/loomy-delegate-codex.sh`, `scripts/loomy-delegate-claude.sh` and `ai_delegate_*` in `scripts/lib/models.sh`: delegation overrides (`--model`, `--effort`, `--write`, `--read-only`, `--why`) precede the task text and take precedence over model/effort environment variables. Bridges also accept `--task-label` as an explicit display title, saved only with the project's `explicit-lead` source grant. Codex sandbox overrides also adjust the task guidance. Claude refuses `--write` outside a quota failover; during that relay, writes use `acceptEdits` with sandboxing. Requested overrides and differences from routing (tool, model, effort, sandbox) are journaled and shown in the banner; explanations enter the journal only in bounded compatibility mode. A quota failover itself is not a tool-routing difference.
- Structured delegations (`ai_delegation_format`, `ai_result_contract`, `ai_result_outcome`, `ai_result_json` in `scripts/lib/models.sh`): when the brief (or `loomy config`) asks for them, the bridges append a fixed answer contract to their prompt and record whether the answer followed it (`format`, `outcome` in the log); generated Claude subagents carry the same contract. TRIED follows empty/none FINDINGS only, with at most 8 attack/result bullets; required for reviewer/security and optional otherwise. The shared rule also reaches free-form review prompts and managed lead instructions for native subagents. Session-start context repeats the rule only when the current tool's managed block is absent or lacks the current rule, using the project's document language to check it. The lead treats a review with no findings and no TRIED as partial; outcome parsing stays backward compatible and records the reported STATUS. Successful structured bridge answers from reviewer/security with a recognized outcome and empty/none FINDINGS but no TRIED evidence also carry `review:"incomplete"`; an empty/none TRIED section supplies no evidence. The classifier accepts common English and French empty markers, case-insensitive field labels, surrounding whitespace and Markdown-bold field labels; any nonempty finding line prevents the flag. Review metadata is best-effort: a Perl failure discards it while preserving the reported outcome and terminal journal event. Stats and status count these flags, and the readable log labels each flagged result, including cached watch views. Old journals without the flag remain unclassified; no outcome is rewritten. Old untouched generated Claude roles are upgraded through project repair; custom roles and orchestration documents stay intact.
- `scripts/loomy-assess.sh` (`loomy assess`): assessment of an existing project, without AI, written to `.loomy/assessment.md`. `loomy init` runs it on an existing project, after switching a Git repository with a history to a dedicated `loomy/adopt` branch (the base branch is remembered in `branch.loomy/adopt.loomy-base`); START.md's "Existing project" section turns it into an adoption plan.
- Project technical name (`slug` in the brief, `loomy_slug`): a single source for the created folder, the GitHub repository (`repo_name`) and the private AI files repository (`ai_repo_name`).
- `bootstrap/START.md`: the setup contract template. Only the copy shipped with Loomy lives here, so that Loomy's own repository never looks like an unfinished setup. It defines nine ordered phases (discovery, adaptive interview, proposal with explicit approval, build, verification, documentation and memory, security, Git checkpoint, retirement of the file), an "Existing project (adoption)" section, token and context discipline rules, and the order of authority once the setup is over. `loomy init` (`scripts/loomy-install-project.sh`) copies it to the project root, from `fr/bootstrap/` when the interface language is French; `--reset` copies it again. The file is retired in the last phase (`loomy-status.sh set done`) and has no authority afterwards.
- `scripts/lib/project.sh`: integrity of a Loomy project. `loomy_project_repair` runs at each `loomy` command that opens a project (`bin/loomy`) and at each Claude Code session start (`scripts/loomy-context.sh`), also from `loomy init` and `loomy doctor`. It migrates `.ai/` to `.loomy/docs/`, adds the relays under the `loomy-*` names, rewrites the old script names in hooks and agent files and removes the unmodified old relays (script rename migration), creates the missing routing documents in `.loomy/docs/`, adds the missing role subagents of a Claude lead in `.claude/agents/`, creates `.loomy/memory/STATE.md` (migrating existing states with a missing `## Dead ends` section; context readers only migrate existing files) and git-ignores `.loomy/memory/`, and keeps the managed orchestration block (between Loomy's markers) current in `AGENTS.md` and `CLAUDE.md`. Existing files are never overwritten except that block and the subagents that are untouched: same text as generated apart from the `model:` and `effort:` lines, and a model Loomy routes. Those follow the routing; a hand-set model or any other change is kept. `loomy_relays_sync` (`scripts/lib/upkeep.sh`) adds the relays that a project created by an older Loomy lacks in `.loomy/scripts/`.
- `scripts/lib/upkeep.sh` and `scripts/lib/repair.sh`: upkeep at launch. Before the commands that open a session or a project, `loomy_upkeep` updates the model catalog silently, probes announced models once a day, compares the latest published Loomy release (cache `~/.config/loomy/loomy.remote`, refreshed in the background at most once a day; the tag comes from the public GitHub API with `curl`, `gh` only as a fallback) and checks Claude Code and Codex against the minimum version of the routed models. When something needs updating it asks once, does everything in one go and the command goes on (`LOOMY_NO_AUTOUPDATE=1` or `loomy config set auto_update no` turn it off). `repair.sh` brings the CLI that the PATH runs to a working version, whatever the install method (npm, Homebrew, native installer, desktop app), by escalating steps each checked in turn: update in place, reinstall with the same method, removal of an older copy that shadows a good one, clean reinstall with the official installer. Each step is logged in `~/.config/loomy/logs/repair-<tool>.log`; settings, logins and conversations are never touched.
- `scripts/lib/skills.sh`, `scripts/loomy-skills.sh` (`loomy skills`) and `catalog/skills.conf`: official agent skills only, from `github.com/anthropics/skills` and `github.com/openai/skills`. The catalog has one line per skill (name, source, path, pinned commit, licence, auto condition, keywords, summary), read line by line and refreshed with `loomy update --catalog` when newer. Skills are chosen from the brief at init (`skills_auto_for`) and suggested from the words of each task (`skills_suggest`, used by `loomy task`); the policy is `loomy config set skills auto|ask|off`. Before installation each skill is fetched at its pinned commit and analysed (`skills_analyse`: scripts, network, deletions, commands run, credentials asked). The fetch goes through a tarball cache in `~/.cache/loomy/skills` whose archives are checked (readable, no link, no absolute or `..` path). Skills that ask for credentials or have a proprietary licence are installed only on request (`loomy skills add`), the proprietary ones for Claude only. Installed folders (`.claude/skills`, `.agents/skills`) are git-ignored; the versioned `.loomy/skills.lock` records source, path, commit, licence, date, reason and analysis, and `loomy skills sync` restores missing folders at the locked commit on another clone. Writes refuse symbolic links, and the lock is rewritten under a lock directory. Each addition or removal goes to the log.
- `scripts/lib/memory.sh` and `scripts/loomy-memory.sh` (`loomy memory`): shared memory in `.loomy/memory/`. `STATE.md` is the work state kept by the lead agent (done, in progress, decisions, dead ends, next), with a target of 40 physical lines. Evidence-backed rejected approaches are appended oldest first under `## Dead ends`: `- <approach> — <why it died> (<evidence path or ref>) · do not retry without a new reason`. Entries use one physical line; indented continuations are tolerated, kept with their bullet during archiving, and joined for display. Other free text stays in STATE and is ignored by the dead-end context. When over budget, the oldest dead ends move to `DEAD-ENDS.md`, always keeping the latest three in STATE; other state content is preserved, even if STATE remains over budget (the lead must condense it). Readers (`loomy_memory_state`, the context hook and `loomy memory`) only migrate or archive an existing STATE, never create one. Migration and archiving preserve the state timestamp, so unincorporated delegation results are not hidden. Both files are never versioned in the project repository and may be kept in the private repository in private mode. New automatic delegation records are structural receipts; full tasks/results require the separate private-results grant described below. Older `delegations/` files remain separately readable through `loomy memory show legacy [N]` and are not rewritten or pruned by the new store. At session start (and after a compaction) `scripts/loomy-context.sh` injects `STATE.md` and a digest of authorized results or receipt facts, as data to check rather than instructions; both tool families see up to three recent dead ends first (one line each, 320 characters at most, inside the 40-line context budget), falling back to the latest archived entries when STATE has no dead-end bullets, and a pointer to the full ledger and archive. The reminder to check before proposing and state a new reason before retrying appears only when the current tool's complete managed block lacks the current Dead ends rule, checked in the project's document language; the ledger data stays in context regardless. `loomy config set memory off` disables context injection, not automatic capture. `loomy memory` shows state and digests; `loomy memory show [N]` resolves an available authorized result or displays its receipt and the unavailable-result fact.
- `scripts/loomy-feedback.sh` (`loomy feedback`) and `scripts/lib/feedback-triage.sh`: tester feedback. `loomy feedback` builds an issue from allowlisted environment/project facts and the latest 15 structurally projected events, without copying the brief or journal into staging. Automatic context excludes labels, excerpts and private results; it is not an anonymity guarantee. The user's feedback text remains the explicit issue body. Sending still requires confirmation; `--print` only prints it. `list` shows the tester's feedback and its state, and the launch says once when one is fixed in the installed version. For the maintainer, `triage` groups the open untriaged issues by cause, with a priority and a proposed reply, written by a fast model that cannot act (Codex read-only sandbox, or Claude without any tool, since issues are untrusted text; `LOOMY_TRIAGE_AI=none` skips the model), into a Markdown report; each reply and label is then posted only after the maintainer's choice. `mark` and `close` label a feedback `fixed-in:<version>` and close it at release after approval.
- `scripts/loomy-shell-hook.sh` (`loomy shell-hook`): opt-in `claude` and `codex` shell functions, added to `~/.zshrc` or `~/.bashrc` between Loomy's markers (never installed silently, a backup is kept, removable). Typed alone in a Loomy project whose lead tool it is, the command goes through `loomy start`; with arguments, in another folder, for the other tool, inside a delegation or with `LOOMY_SHELL_HOOK=0`, the real command runs unchanged.
- `scripts/loomy-status.sh` and `scripts/loomy-tree.sh`: session and live rendering. `loomy watch` defaults to the tree, with a live list in compact side panes; `a` selects the live list with running roles first and finished roles from the current lead session. A persistent sampler checks journal/state changes every 250 ms; queued timer tuples are coalesced up to the first key, retaining dirty state and key order, and quit runs before expensive rendering. The incremental reducer reads complete appended events and detects rotation or truncation. Timers redraw every second while running. `v` switches diagram/list or request/model grouping; `o` opens the acting orchestrator in an available desktop app or a separate terminal window with tracking. Rows use observed models/efforts, updated from usage or native session contexts, and show elapsed time, tasks, outcomes and requested/off-routing markers. `t` switches tree/status; `l` opens the journal. `loomy tree --once` prints the live view. The regular diagram uses adaptive padded boxes, two fixed title rows and clipped canvas slots (`tree_view`, `scripts/lib/canvas.sh`) without changing box heights for long labels.
- `scripts/loomy-statusline.sh`: Claude Code status line segment. Besides saving quotas, it shows the bootstrap phase while setup is unfinished and the number of running delegations whose process is alive; it appends the segment to the user's own status line (run with a 2 second limit) or shows a short Loomy line. It never fails.
- `tests/run.sh`: end-to-end test suite, without network or token (`claude` and `codex` doubles in `tests/stubs/`). `--section 'Native Codex'` runs the native rollout regressions alone; their fixture clock is saved at seed so appends and snapshots survive UTC midnight. `LOOMY_TEST_NATIVE_PTY=0` explicitly skips its terminal test in a restricted sandbox; the default Mac run keeps that test enabled.

**Test hermeticity.** Every suite sources `tests/lib/guard.sh`: `XDG_STATE_HOME`, temporary files and tmux sockets stay inside its disposable work directory, desktop launchers are stubs, and AI launch sites reject binaries outside the declared stub directory under `LOOMY_TEST_GUARD=1`. Exit cleanup reports and stops leaked processes before removing the work directory; the main suite also checks remaining sessions and guard violations.

**Core test selection.** `LOOMY_TEST_CORE=shell|next` defaults to shell. The guard's private `BASH_ENV` hook selects CLI and executable relay calls without changing assertions. `next` uses `LOOMY_TEST_NEXT_ROOT` (default `tests/next/compat`): executable `bin/loomy` plus matching `scripts/loomy-*.sh` wrappers. An unavailable CLI prints a named suite SKIP; a missing relay fails without fallback. `$WORK/core-entrypoints.tsv` records selector, logical entrypoint and selected path without arguments, then disappears on cleanup. This is dispatch accounting, not Rust-hit proof; sourced libraries remain implementation tests. Native dispatch wrappers must supply actual Rust-hit evidence. `--section 'Core seam'` checks selection with synthetic wrappers and the existing process gate.

The design deliberately avoids preloading every specialised role or a large security workflow into every session.

- `tools/capture-watch.sh`: regenerates the animated README live-view SVG with `tools/capture-watch.sh <en|fr> <out.svg>`, using an isolated disposable project, CLI test stubs and synthetic journal events with live local processes; renders 24 frames through `scripts/loomy-tree.sh --once`, converts them with `tools/ansi2svg.py`, and checks the heading, local-path exclusion and size below 300 KB.

## Per-store content policy

Observability and memory have separate storage contracts. `scripts/lib/content-policy.pl`
validates the project-local policy in `.loomy/logs/content-policy.conf`; missing or
invalid grants fall back to structural journal writes, no automatic labels and no
private-result capture. Existing installations use these defaults for future writes.
The policy is a closed schema, with atomic updates and a monotonic `policy_generation`.

The stable local project identity lives in `.loomy/project-id`. Moving or renaming
the project with its `.loomy` directory preserves label and memory references.
Validated worktrees sharing `.loomy` or its logs share the owner's identity, grants
and first-use acknowledgement; an unrelated clone does not inherit those grants.
The identifier is a namespace, not a confidentiality mechanism.

| Store | Content contract |
| --- | --- |
| `.loomy/logs/events.jsonl` and fresh rotation snapshots | Allowlisted identities, lifecycle/routing facts, timestamps, usage, counts, outcomes and scoped references. Every writer uses the same per-event projector. Structural writes omit prompt/task/result text, explanations, file lists and relative working-directory labels. Nested checkpoint evidence becomes a structural signature. New events carry `content_policy` and `policy_generation`. |
| `.loomy/logs/display-context-v1.jsonl` | Separately granted display text, scoped by project, target and attempt. Each label is sanitized to one line and truncated at a whole-grapheme boundary to at most 96 graphemes and 384 UTF-8 bytes; each Codex component is at most 40 validated ASCII characters. The store has a 1 MiB hard cap; overflow refuses the save and preserves the previous label. |
| `.loomy/memory/receipts-v1/` | Closed structural delegation receipts: identity/attempt, role/model/effort/sandbox, status/outcome, times, reset time, changed-file count, review metadata and optional task/label/result references. Receipts never contain the full task, answer, summary, file paths or a shell resume command. |
| `.loomy/memory/private-results-v1/` | Full task/result bodies and validated resume descriptors only after the separate human grant. Hard maxima: 200 records, 1 MiB per record and 16 MiB total, with a 30-day age policy for unpinned records. Retention runs on saves, protects active/paused references within their pin lifetimes, and refuses capture visibly when protected records fill the cap or a body is too large. Turning capture off preserves previously authorized bodies. |
| Authored task, review, audit and continuity documents | Explicit work artifacts retain their intended prose and existing authority. Automatic-store restrictions do not turn them into metadata stubs or authorize scanning their bodies into diagnostics. |

New policy, label, receipt and private-result files use 0600 from creation, with
0700 store directories, no-follow opens and locked writes. These creation permissions
do not harden or remove older sensitive copies; new-store retention does not migrate
or purge legacy delegation results.
Policy/identity files, journals, labels, receipts and private results are excluded
from both project and companion-repository tracking; private mode still synchronizes
the approved authored AI documents. `loomy privacy inventory` reports metadata,
with paths, host scope and Git-history checks available only through explicit options;
it does not inspect content, purge files or rewrite history.

`journal_content=legacy-excerpts` is a separate, explicit project compatibility
choice. It can retain only five bounded top-level fields where the event supports
them: `task` (200 characters), `excerpt` (60), `why` (200), `nickname` (40) and
`cwd_relative` (256, project-relative). It never enables full results or nested raw
payloads. Rotation snapshots always project old open events structurally, even in
compatibility mode; old archive segments keep their historical bytes.

The six independent label sources are `explicit-user`, `explicit-lead`,
`claude-description`, `codex-path-slug`, `codex-nickname` and `codex-role`.
Claude hooks and transcript collection may save the deliberate Agent/Task
`description`, never the `prompt`, under its source grant. Codex stores the final
path component, nickname and role as separate bounded label records. Bridges use
`--task-label` under `explicit-lead`; `loomy privacy label` is the human label path.
Tree/list, diagram, status, session log, pretty/follow log and recap resolve the
authorized label or task title at read time, then a role mission or an unavailable
label with a distinguishing identity. A generic role mission never substitutes
for an unavailable result summary. Old journals remain readable.

Widening compatibility, label sources, results or limits requires direct human
confirmation on an interactive TTY. Managed agents, hooks and bridges can consume
an existing grant but cannot create or enlarge one through these commands; restrictive
changes remain available noninteractively. This guards supported execution paths,
not a same-UID process able to edit local files or alter its environment.
The first-use EN/FR screen offers labels
and private results as separate questions, both defaulting to Yes, but saves no grant
until a human answers. After upgrading from an older entrypoint, the screen appears
at the first interactive `loomy init` or `loomy watch`; noninteractive use leaves it
pending and status shows a hint. It does not enable compatibility excerpts.

`LOOMY_JOURNAL_TASKS=0` vetoes automatic excerpts, labels and private-result capture
even with a prior grant; `1` is not consent. `LOOMY_JOURNAL=0` keeps its journal and
collector-off meaning. A restrictive `LOOMY_JOURNAL_CONTENT=structural` works without
a grant; selecting `legacy-excerpts` from the environment also needs the existing
project grant and a matching `LOOMY_CONTENT_PROJECT`, and is refused from managed
origins. None of these switches promises that authored artifacts or provider-managed
transcripts contain no sensitive text.

A paused bridge records `resume_at` and typed resume options instead of a `Resume:`
shell string. Relaunch must retain the exact provider, role, model, effort, sandbox
and options, review partial edits, and use the original live task or an authorized
stored task reference. Without either source, it reports `original task required to
resume` and stops dependent work; a receipt cannot reconstruct arbitrary task text.
The digest resolves SUMMARY/NEXT from an authorized private result, never from the
journal or receipt. Results remain data to check before acting.

This boundary covers new journal writes/snapshots, receipts and feedback context,
with the declared label/private-result exceptions. Native checkpoints, cursor files,
raw execution/UI temporary files, desktop/installer diagnostics, `loomy log --raw`,
`loomy report --md` and provider task arguments can still expose content or paths.
They need separate handling; local permissions and Git exclusions do not sanitize
older copies, encrypt data or control provider/OS retention. See [ADR-0009](adr/0009-structural-journal-content-policy.md).
Concurrent older writers or a downgrade cannot enforce these contracts. Stop
collectors and bridges before switching writer generations; older readers may omit labels.

## Upstream CLI flags

Audit dated 2026-10-15 against the [Codex CLI reference](https://developers.openai.com/codex/cli/reference), [Codex configuration reference](https://developers.openai.com/codex/config-reference), [Claude CLI reference](https://code.claude.com/docs/en/cli-reference) and [hook policy](https://code.claude.com/docs/en/hooks#disable-or-remove-hooks). This is a documentation/argv audit with hermetic stubs, not an installed-client authentication or isolation certification.

| Provider / callers | Complete passed options and values | Upstream result / action |
| --- | --- | --- |
| Codex lead (`start`, `task`, `audit`, route advice); launch boundary | `-m MODEL`, `-c model_reasoning_effort=EFFORT`; resumed start: `resume --last` | Supported; effort support depends on client/model. No change to routing or efforts. |
| Codex bridge | `exec -m MODEL -c model_reasoning_effort=EFFORT -s read-only\|workspace-write -C ROOT --skip-git-repo-check --ephemeral --json -o FILE` | Supported; `-s` is sandbox, not approval policy. |
| Codex doctor/models probe; feedback triage | `exec -m MODEL -c model_reasoning_effort=low\|medium -s read-only --skip-git-repo-check --ephemeral -o FILE` | Supported. Probe runs only when requested; this audit never runs a real probe. |
| Codex route `codex-profiles` (printed advice only) | Before 0.134: `--profile ai-ROLE` with `[profiles.ai-ROLE]`; 0.134+ or unknown version: explicit `-m MODEL -c model_reasoning_effort=EFFORT` | Legacy sections removed in 0.134.0; version read through `loomy_cli_meta codex --version`. Unknown/failed detection gets an explicit note and per-call advice. No user config writes. Current `--profile` uses separate files; Loomy does not generate them. |
| Claude lead (`start`, `task`, `audit`, route advice); launch boundary | `--model MODEL --effort EFFORT`, optional `--advisor MODEL`; resumed start: `--continue` | Supported; effort/advisor availability depends on client/model. |
| Claude Desktop handover | `--desktop --resume SESSION_ID` | Requires 2.1.285+ (existing version gate). Desktop rejects model flags; the launch boundary now omits its automatic `--model` addition for this handover. |
| Claude bridge, compatibility `off` mode | `-p PROMPT --session-id UUID --output-format json --max-turns N --model MODEL --effort EFFORT`; read: `--disallowedTools Edit,Write,NotebookEdit`; quota-write: `--permission-mode acceptEdits --settings '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'` | Supported; base argv unchanged. Unresolved headless permission requests remain denied. Project MCP/hooks can load without a trust prompt in this mode. |
| Claude bridge, internal `bare` candidate | Base bridge options plus `--bare` | Documented minimal discovery mode; auth/config/isolation effects must be tested on the installed version before rollout. |
| Claude bridge, default `strict` mode | Base bridge options plus `--strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources ''`; `--settings` adds `"disableAllHooks":true` (merged with sandbox settings for quota-write) | Explicit empty MCP set and per-run hook denial; no inherited user/project/local settings. Auth store stays in place. Managed policy may still require MCP/hooks; this is not certified plugin/config isolation. |
| Claude doctor/models probe | `-p PROMPT --output-format json --max-turns 1 --model MODEL --effort low --tools '' --strict-mcp-config` | Supported; no tools. Probe changes are outside the bridge isolation switch. |
| Claude local writer / feedback triage | `-p --model MODEL --tools '' --strict-mcp-config PROMPT` | Supported; no tools. Local writer also uses a disposable `CLAUDE_CONFIG_DIR` and the local API endpoint. That empty user directory is precedent, not proof that project hooks are disabled; bridge strict uses explicit hook denial without replacing the subscription auth store. |
| Both providers, metadata / repair | `--version`; Claude repair: `update` | Through `loomy_cli_meta`; no model call. Its allowlisted `login`/`auth` subcommands have no current caller. |

Loomy passes neither `--full-auto` nor `--approve-for-me`, and sets no Codex `approval_policy` or `-a` option. Upstream's removal of `--full-auto` therefore requires no launch replacement. Current approval values are `on-request`, `never`, or granular config; `untrusted` is unsupported and `on-failure` deprecated. Inherited user policy is unchanged. `--approve-for-me` conflicts with an explicit `-s` sandbox and must not be substituted blindly. Claude's newer `--permission-prompts none` is not added to the unchanged default bridge.

`LOOMY_CLAUDE_ISOLATION=off|bare|strict` is internal; unset means `strict`, invalid values fail before launch. Real test on Claude Code 2.1.296 with subscription auth (2026-10-15, trap project with a project MCP server and a project hook): `off` started both; `bare` failed with "Not logged in" (subscription auth unavailable), so it stays an unused candidate; `strict` answered with neither started, in read and write modes. `off` remains available for diagnosis. No mode falls back to another on failure.

StatusLine freshness remains event-driven. Upstream's optional `refreshInterval` (at least one second) is **not implemented by Loomy**: no timer registration, user statusLine rewrite, or provider refresh call is added. Idle silence is not a fresh quota zero.



## Live performance and resilient watch

The sampler and timer coalescer live for the watch lifetime. Watch-owned snapshots
skip source collection. Native tree/list ownership and fitted-row inputs are indexed
on deltas; warm timers update elapsed text without decoding unchanged wire rows or
spawning row helpers. Duration-width transitions still refit the original row inputs.
Captured lines are joined once per frame, avoiding repeated multibyte concatenation.
An active agent's rows fitted for the live block are replayed in the recap rather than
refitted; timer frames redraw both through the same fitted-row inputs.
The viewport reuses them rather than splitting the entire frame again;
state counts are reused until the projection sequence changes. Config/brief/models
are loaded at startup or when their signatures change, not on native timer frames.
Status/log bodies are reused for unchanged timer frames. Legacy hook-only rendering
still parses history on changed frames and needs further integration before claiming
that every view is history-free. Codex discovery caches every date directory, queues
new/replaced metadata only, and prioritizes changed directories over initial backlog.
Known eligible old files remain signature-polled for resumed appends. Pending bootstrap
inventory is shown in the footer. Quota source discovery has a separate 15-second cache,
including negative results; warm calls stat only the selected file, then read a bounded tail.

`tests/s5-w6.sh` asserts a warm reducer and Bash frame under 150 ms with 50,000
historical events and 100 active agents, using 10,000 source files and four leads.
Cold reconstruction is measured separately. The 2026-10-13 sandbox run measured
9.1 s cold inventory/reconstruction, 1.5 ms maximum warm reduction and 41 ms
new old-date source discovery. Bash builtin stage timers measured the same fixture
before/after the native cache (milliseconds, warm frames):

| Stage | Tree before / after | List before / after |
| --- | ---: | ---: |
| State counts | 15 / 1 | 13 / <1 |
| Header | 1 / <1 | 1 / <1 |
| Row rendering | 549 / 36 | 743 / 53 |
| Viewport | 129 / 6 | 248 / 9 |
| Chrome | 1 / 1 | 2 / 2 |
| Paint | 14 / 14 | 15 / 14 |

The frame fixture now budgets states, rendering, viewport and painting together
under 150 ms (five trials each: maximum 71 ms tree, 89 ms list, including timing
helper overhead). Cached and rebuilt frames are compared byte-for-byte across EN/FR,
tree/list, terminal sizes, duration boundaries and identity updates; warm timers
assert zero wire decodes and survive a PATH without external executables.
Changed native layouts now index ownership through collision-checked Bash 3.2
identifier buckets and reuse decoded agent columns for hierarchy, routing and rows.
Newest-start selection runs only when active rows cannot fit, with its sorted list
bounded to the visible budget. On the same 50,000-event fixture, five complete changed
frames (states, rebuild, viewport and paint) measured maxima of 152.415 ms tree and
182.912 ms list, below the new 200 ms changed-frame budget (previous rebuild stage:
304/350 ms). A comparison against the batch-5 renderer produced byte-identical output
for 48 EN/FR, tree/list, width and height combinations; ownership tests cover bucket
collisions, unrelated groups and UTF-8 labels. These
are fixture results; validation remains incomplete because hook-only diagram, changed status
and journal views still invoke the legacy full scripts (`loomy-status.sh` watch
branches), including history parsing and sourcing. Preserving their output requires
extracting those renderers and their historical summaries into a persistent read
side, beyond this isolated cache change. `watch-idle.exp` asserts total watch
CPU below 3% over 60 seconds (Bash and all child processes) on an idle empty project.
The populated-envelope CPU and real Mac checks remain release gates.

`tests/replay-soak.sh` sources the shared test guard and runs watch in an expect PTY
with a private tmux socket. Forty accelerated bursts over at least 120 seconds replay
Claude CLI/app async Agent/notification and ignored Bash notification envelopes,
Codex spawned-agent rollouts and explicitly nested bridge events. Tree/list launches
and endings have a strict 1-second maximum with no retry, plus duplicate/phantom,
crash, q and process/socket cleanup checks. Missing expect/tmux or explicit sandbox
PTY disablement prints a named SKIP. Linux CI installs both and enables PTY tests.
The replay and 60-second CPU fixtures were not executed in the sandbox.

Adapter/reducer exceptions and Bash ERR are isolated from the terminal controller.
Only UTC timestamps, stages and allowlisted error kinds are persisted, never exception
text or provider content. `.loomy/logs/watch-errors.log` is no-follow, 0600 and bounded
to 64 KiB under a lock, respecting `LOOMY_JOURNAL=0`. A footer warning stays visible
and q remains available; fatal external signals and user exits retain normal cleanup.
Doctor shows the last three validated diagnostics and warns about source-home
symlinks, journals above 8 MiB, checkpoints above 2 MiB and oversized source shards.

## Native watch labels and stale sessions

A session group heading reads `<tool> <surface> <id> · <cwd> · live` with the observed session state, or `<tool> <surface> <id>`
with `stale` and the age since its last evidence; lease and launcher evidence stay in the wire rows, never in the heading.
A group is stale when it has no live launcher and no source activity for 120 s. A stale group with nothing running is shown
only in the recap, where the heading is repeated marked `recap` (a live group repeats the same way below the scroll line);
a stale group with no agent is not shown. The reducer ends a pre-schema bridge turn as `interrupted` when its recorded
launcher PID is gone, when it has none and its session is not live, or when it is over a day old outside a live session.
The routing legend is `LOOMY · <family>: <short model>, ...` (family once, `claude-`/`gpt-` removed, an alias such as
`sonnet` folded into `sonnet-5-5`) and exists only for live groups. A finished turn reads `✓ done`, `△ partial`, `■ blocked`,
`✗ failed` or `⊘ interrupted`: the glyph follows the outcome and an unknown outcome adds no word. `tests/watch-real-data.sh`
A Claude child with no evidence for longer than its 15 minute lease is projected as `lost` (`! lost`, clock = time since its
last evidence), is never counted as running and collapses into the recap like other finished rows; a silent child inside its
lease stays running. A granted Claude Agent/Task description is resolved from the separate label store; without an available
authorized label, the view uses a role mission or an unavailable-label identity rather than copying the prompt.
The live block of a live group shows running agents first (newest first), then agents that ended within the last 30 minutes
(newest first); everything older and every lost agent folds into one line `+N earlier · M lost` and is listed only in the
recap, which is ordered newest first (the fold forces the recap pass). The list view and the compact modes keep their
`+N finished` summary. `tests/watch-real-data.sh` covers these cases with structural fixtures.

## Checkpoint and journal policy

Native checkpoints use version 2, with a 2 MiB snapshot and content-addressed source
inventory shards of at most 256 KiB each (16 MiB total). Finished detail expires after
seven days; the recap retains at most 1,000 turns, and the reducer at most 32 per agent.
Codex keeps at most 8,000 recent event keys plus current retained turn identities.
Pruning keeps source offsets and replay fences; unfinished work is never discarded to
meet a size limit. Overflow pauses persistence explicitly. Valid v1 checkpoints are
read completely up to 32 MiB and migrated by project repair or the next collector poll.

The persistent adapters cache state and signatures; unchanged polls neither decode nor
rewrite checkpoints. Stable per-checkpoint locks protect 0600 temporary-file, sync and
rename writes, retaining the last valid backup. Large source shards save only when their
content changes. Journal append/flush precedes checkpoint replacement; recovery first
replays the saved journal suffix, following archive successor links across rotations.
Codex journal records carry source inode/offset evidence; Claude records carry semantic
checkpoint signatures. A damaged checkpoint recovers from a valid backup; if neither
copy is valid, both are preserved as private `.invalid-<device>-<inode>` files.
Collectors reconstruct journal state progressively (2 MiB per poll), crossing archived
segments before reading sources; Codex restores source inode/offset evidence and Claude
restores semantic signatures. Overflow still pauses explicitly. Read-only collection
recovers interrupted rotations but leaves monthly rotation to journal writes.
Consumed offsets never skip hooks appended concurrently during source collection.

Leak barrier (`scripts/lib/journal-gate.pl`, ADR-0011): every writer in `.loomy/logs` (hook appends, preparation, the non-blocking lock, native collector polls, the direct adapter and reducer command lines, the label store, the small log writers) asks it first. A positive answer is cached in `gate-v1` as a sha256 key; a tracked answer (keyed like the ok cache) and a refusal (30 s) are cached in the per-user cache directory outside the project, else memoized 2 s in the process, so nothing is ever written into a tracked or refused directory. A watch owner asks at each poll (stats only on a cache hit); residual: an answer that needed Git can stay 2 s stale. Owner-record writes and elections ask it too (a refusal fences the owner; `release` skips the record), the policy writers (`_context` create) refuse before creating anything, and the policy reader treats a policy file in a refused logs directory as absent. Cache files: one marker per root and kind (`t-`, `r-`, `o-` for an aliased worktree's ok verdict), temp file plus rename, no-follow non-blocking reads, a group/world writable base unused; anything but exactly `<root>/.loomy/logs` is refused.

All journal writers and rotation share `events.lock`. Rotation runs monthly or at 8 MiB,
keeps immutable inode-named archive segments and carries structural snapshots of every
open session/agent, tagged `snapshot`, without copying usage or terminal events. A private
rotation marker recovers the archive/snapshot rename gap after a crash. Readers seek
before decoding, consume at most 2 MiB per poll and retry partial lines; malformed or
oversized records are skipped. Display tails are bounded to 8 MiB and 64 KiB per line.
The reducer rejects invalid fields, orphan activity, backward terminals and timestamps
more than five minutes ahead of the observation clock. Historical reconstruction and
rotation are cold-path work; the warm-frame budget does not measure those operations.

Claude child liveness uses its own 15-minute source lease; newer lead/sibling activity
never fabricates a terminal. Ordinary source timestamps/mtime stay in memory rather
than changing activity signatures. Historical lead replay prefilters unrelated tool
results before JSON decoding and caps each lead window at 1.5 MiB within the 2 MiB
shared source budget (one-shot compile/projection CPU headroom); failed polls retain discovery state and back off five
seconds. `tests/live-growth.sh` covers these fixes, 50,000-event idle growth,
65,000-key migration, pruning, crash recovery across multiple rotations, corruption,
shards, private modes and idempotent repair. It is registered in `tests/run.sh` with the launch, resume,
availability, live and watch-exit suites.
**Desktop resume and session-only routing.** `scripts/lib/resume.pl` reuses native metadata/slug helpers read-only: Codex date directories are inspected newest first, at most 256 KiB of metadata per candidate, stopping at the first matching project/subfolder lead; Claude transcript filenames identify the newest root session. Live Claude cwd ownership or a fresh transcript with a live journal owner prevents desktop handover. `loomy-start.sh` uses the shared `launch.sh` check/run/spawn/meta API. Terminal `--lead <tool> --only` owns `.loomy/session-only-<pid>-<birth-time>`; routing validates the owner's birth identity and ancestry, and start removes only its own marker on exit. Desktop-only overrides are refused until a session-owned lifetime is available. The brief remains unchanged.
## Parallel requests and coherence

- Project repair is limited to project/session opening commands (`home`, `start`, `resume`, `init`, `install`, `task`, `tasks`, `audit`, `review`) and Claude session start; read-only `status`, `watch` and `route` do not repair a project.
- Managed orchestration and templates split requests into disjoint subtasks, launch native roles of the lead family together and use bridges only across families. Background bridges are all awaited before integration; review, security and documentation then run together with disjoint scopes. Routed efforts remain unchanged. `max_parallel` defaults to 4; `loomy config set max_parallel N` accepts 1–999 (`auto` restores 4). The prompt reminder includes the configured cap.
- `loomy worktrees <task> [base] --count N` creates numbered branches `loomy/<task>/<n>` and paths `<repo>-<task>-<n>`; the legacy family pair remains the default. Worktrees link to the main project's `.loomy` (or, when the AI files are versioned and each worktree checks out its own `.loomy`, to its `.loomy/logs`), so every bridge writes into the same watch journal. Preflight rejects existing branches/paths and a tracked `.loomy` (a tracked `.loomy/logs` when the AI files are versioned) at the base before creating any worktree.
- `loomy stats` counts completed requests from Claude request/lead-stop evidence and Codex lead rollout user turns/terminal events (one user record per turn, no prompt output). Incomplete requests are excluded. Parallelism = summed worker durations / the union of their active intervals; 1x is sequential, 2x is two fully overlapping workers. These lifecycle measurements are independent of native usage/cost, which remain unknown. Rollout discovery is read-only, scans the local session history only when stats is requested, and accepts project subfolders and worktrees sharing `.loomy`.
- Row allocation reserves state/outcome and elapsed, shrinking task, then model, then effort bar; extremely narrow rows wrap identity. The dictionary test builds in its private work directory and never rewrites a tracked file; translation discovery handles both shell quote styles.
### Git chokepoint

- A repository's config and hooks are untrusted input. Every Git spawn of Loomy goes through `loomy_git` (read-only probes: `core.fsmonitor=false`, `core.hooksPath=/dev/null`, `log.showSignature=false`, `--no-pager`, `GIT_NO_LAZY_FETCH=1` (effective from git 2.44), `--no-optional-locks` (git 2.15); inherited `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, `GIT_CONFIG_*`, `GIT_EXEC_PATH`, `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_PAGER` and object-store variables are removed for the call) or `loomy_git_user` (commits, branches, checkouts and worktrees created for the user: their hooks keep running, only fsmonitor is hardened; lazy fetch stays on because partial clones need it), both defined in `scripts/lib/models.sh` as env-prefixed `command git` (no extra process). The Perl spawners (`runtime-paths.pl`, `watch-health.pl`, `tracked-fix.pl`, `loomy-privacy.sh` metadata) harden their own spawn and are allow-listed. The residual risk is a `filter.<name>.clean|process` or a signature program in the project's own `.git/config` running on a stat-dirty file during `status`/`diff`: that file cannot arrive with a plain clone (Git never transfers `.git/config`), so it needs the user's own repository to be altered. `tests/git-chokepoint.sh` fails on any other raw `git` in `bin/` or `scripts/` and checks that a marker-writing `core.fsmonitor`, hooks and a promisor remote run nothing.

### Private history companion

- `.loomy/ai.git` (the separate private repository of the AI files) is trusted by provenance, never by location: a plain clone can ship one. Loomy records the real path and device/inode of every companion it creates, restores or the user adopts in `~/.config/loomy/companions` (outside the project). `privacy_companion_ready` also refuses a symlink, a foreign owner and any entry tracked by the project index (`ls-files -z -- :(icase).loomy/ai.git`). Every automatic caller (`SessionEnd` sync, `loomy status`, `doctor`, session context, `privacy sync`) goes through it and, for a present but unverified companion, shows `Private history not verified · run loomy privacy adopt` and spawns no git against it.
- `loomy privacy adopt` audits the config with `git config --no-includes --file` against an allow-list (core basics, `status.showUntrackedFiles`, remote url/pushurl/fetch/push/tagopt with https, ssh, file, local or scp-like URLs, `branch.*`, `user.*`), refuses any other key, shipped hooks, `commondir`, `gitdir`, alternates, grafts and `info/attributes`, then records it. Trust is re-audited on every `ready` (verdict cached in `~/.cache/loomy/companion-verdicts`, keyed on the stat of every file the audit reads), a record is `nonce`-bound (nonce file inside the companion) and digests every remote url/pushurl; tracked, changed or failing companions lose the record and need `adopt`, which prints the URLs, asks on a terminal and refuses a pushurl different from url and local remotes (local remotes are allowed only when set through `privacy private --remote` or `restore`). Legacy `remotes/`/`branches/` files, several url values, a pushurl differing from the url, other remotes and unusual remote names are refused; `file` is allowed only from configured url/pushurl values, never from resolving the remote name. The record helpers live in `scripts/lib/companion.pl` (flock, temp file + rename, 0600/0700, exact field compare). `ai_git` always passes `core.hooksPath=/dev/null`, `core.fsmonitor=false`, `core.attributesFile=/dev/null` (with `GIT_ATTR_NOSYSTEM=1`), no pager, no signature check, `protocol.allow=never` with https, ssh and file (user) re-enabled, and clears inherited location, config and exec variables. Filters can only come from the user's own global config, which the allow-list does not cover.

### Single launch point

- `scripts/lib/launch.sh` owns provider process execution: `loomy_cli_resolve`,
  `loomy_cli_check`, `loomy_cli_run`, `loomy_cli_spawn`, and `loomy_cli_meta`.
  Feedback version reporting and repair metadata calls use the same boundary.
  The test guard runs first; model calls require catalog validation and provider
  availability. Bridges retain handover/pause semantics; ordinary callers return
  75 on unavailable providers. Metadata calls and bounded probes use only the guard
  and do not write model lifecycle events. A lead session (role `lead`) is not a
  delegation: it keeps its ids for child links but writes no `delegation_start` /
  `delegation` event. `LOOMY_TEST_STUBS` is a colon-separated list of trusted stub
  directories (a test appends its own opener stubs; real binaries stay refused).
- Bridges use the central lifecycle writers, retaining their usage, outcome,
  permissions and resumption data. A bridge worker keeps a process group for signal
  cleanup. Detached runners own their end event, after the provider returns.
- `LOOMY_PARENT_ID` and `LOOMY_ATTEMPT` identify the bridge and its unique attempt in
  the child environment; optional `LOOMY_PARENT_SESSION` / `LOOMY_PARENT_AGENT` carry
  upstream ownership. Launch-control flags are removed from the provider environment
  so nested Loomy launches cannot reuse the enclosing bridge's lifecycle.
- Codex remains ephemeral: its live JSON stream emits sanitized `bridge_link`
  records for `thread.started` and native spawn receiver IDs. No prompt or tool
  payload enters these events. Claude receives a unique `--session-id`; the matching
  transcript belongs to that bridge by explicit ID, with evidence `launch-session-id`.
  No session is paired by cwd, time or role. The reducer consumes
  `session_key`, `parent_delegation`, `attempt_id`, and optional `parent_session`,
  including late links. Bridged sessions disappear as separate leads and their children
  retain explicit nested parents in both views; mismatched attempts never attach.
- Terminal lead starts and Claude desktop handovers use the same boundary. Metadata
  checks use `loomy_cli_meta`; app/window openers use `loomy_cli_app`, which guards
  resolved executable paths and writes `app_open`, without inventing a model lifecycle. Interactive leads retain the
  terminal foreground group and project hooks; provider transport receives redirected stdin.
  The generated shell-hook passthrough of the user's typed command is the only exception.
- LM Studio uses provider class `local` (Claude as its transport): the test guard and
  start/end journal apply, without cloud availability or validated-chain checks.
  The model belongs to the user. Hook-only journals keep legacy request/model groups;
  actual transcript/rollout evidence enables the native session hierarchy.

Release boundary: launch validation shares pause/invalid-model diagnostics; local Codex caches are advisory and probes obey provider pauses. Terminal-only routing inherits owner PID/birth-time markers only through descendants. Diagnostics canonicalize the project root, reject links below it and retain two damaged checkpoint generations; doctor reports their count and bytes. Test gates isolate provider homes/PATH and allow a bounded three-second supervisor teardown grace.

## Codex multi-agent v2

- `codex-native.pl` accepts top-level v2 thread metadata and the older `source.subagent.thread_spawn` envelope. Explicit `parent_thread_id` takes precedence; `session_id` identifies the lead when a subagent has no parent field. Parent traversal retains depth-two nesting. Eligibility uses canonical cwd or a runtime workspace root under the project; unrelated workspace paths are not checkpointed. Granted nickname, role and final path component are stored as three separately scoped label records; structural journal events carry their references, not those names.
- Paginated children read at most 128 KiB of historical head and 128 KiB of current tail per poll, sharing the existing 2 MiB source/discovery budget. Recently written sources precede the rotating historical backlog; newly discovered children prioritize their explicit parent metadata. Byte-position fences prevent older catch-up from replacing newer lifecycle evidence. `item_completed` and `token_usage_record` can identify an active turn when its start lies outside the recent window; inter-agent metadata renews activity. Item completion alone is not turn completion. Explicit task/turn completion or abort records retain their real source end timestamp; trailing usage cannot reopen the same completed turn. Usage totals and message/tool contents remain unrecorded.
- Lead history keeps its bounded head/tail reader across every date directory. File modification time also renews the 120-second source lease, including oversized newest records; it never invents a terminal state and never reopens a closed session (only new records do). Source evidence updates the reducer without journal heartbeat appends. Metadata upgrades preserve cursors and stable lifecycle keys. v2 completed rows show done/interrupted; v1 persistent-agent idle semantics remain unchanged. If an unseen active turn is inferred from the tail, its displayed start is the earliest available observation, not an invented historical start.
- `tests/fixtures/codex-v2-sessions.pl` generates a 36 MiB old-date lead, four direct children and one nested child, with current writes and structural records only. Targeted native/live suites verify first-frame visibility, exact end timestamps, replay ordering, privacy and bounded reads; Mac PTY/process-leak validation remains a separate environment gate.

## Checkpoint cost

Checkpoint JSON uses a reused optional system `JSON::XS` codec with PP-compatible
booleans, falling back to `JSON::PP` without installing a dependency. Both encode
canonical UTF-8 JSON; shard hashes and byte bounds remain stable. A byte-identical
validated snapshot skips primary/backup replacement, while shard validation/cleanup
and private modes remain enforced. Changed generations keep synced atomic 0600 writes.
Migration, bounded reconstruction and quarantine retention follow the existing policy.

The checkpoint-cost fixture reports process CPU by stage, including fresh interpreter/module
startup, checkpoint load/save, remaining collection and parent fixture projection.
The complete measurement and 80 ms gate are unchanged. A 35-poll / 47.9 MiB Mac
comparison measured the following mean/max milliseconds:

| Stage | Before | After |
| --- | ---: | ---: |
| Startup | 26.108 / 28.763 | 25.901 / 30.501 |
| Checkpoint load | 5.811 / 6.369 | 1.597 / 2.088 |
| Checkpoint save | 13.191 / 14.550 | 1.040 / 2.138 |
| Remaining collection | 9.595 / 23.651 | 9.677 / 24.509 |
| Fixture projection | 15.136 / 19.567 | 15.103 / 19.475 |
| Complete N3 one-shot check | 69.842 / 80.115 | 53.317 / 68.701 |

The child alone measured 54.706 / 60.548 ms before and 38.215 / 53.206 ms after.
The 50 ms maximum target remains open: startup, collection and projection dominate
the remaining cost. PP-only installations retain the portable fallback, with a smaller
benefit limited to avoiding identical writes. `tests/live-growth.sh` exercises both
codecs, Unicode/boolean compatibility, unchanged snapshots/shards, backup recovery,
private modes and overflow preservation alongside the existing crash/migration cases.

## 0.17.1 rendering

Watch loads the classic status and tree renderers once. Its persistent sampler hooks
`LiveState::consume` to accumulate legacy delegation, usage, advisor and phase totals
alongside the native projection, without a second journal read. Bootstrap archives
are read once at initialization; complete appends update the cache, and incomplete
lines retry at the existing reducer cursor. `E` batches update the classic session
reducer; `K` snapshots update aggregates and the bounded log presentation only after
journal changes. Timer and navigation frames render cached data. No frame launches
`loomy-status.sh`, `loomy-tree.sh` or `loomy-log.sh` or parses journal history.

Native ownership indexes retain decoded rows across deltas. Title-only changes update
the fitted draw inputs without rebuilding ownership or layout; root ordering stays
cached until an ordering input changes. Full rebuilds remain checked against the
same frame output. The performance fixture measures changed lists below 120 ms and
complete tree/list draw rebuilds below 150 ms, including viewport composition and
painting. View switching warms the selected layout before measuring a data change.

Recaps fold ended agents to their identity row and last turn, retaining the turn
count and outcome glyph. Titles stop at the first sentence and at 60 complete UTF-8
characters/words; row fitting reserves outcome and elapsed text before optional
labels. Structural fixtures cover ten turns, failed bridges and long titles.
