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
- `scripts/lib/journal.sh`: local activity log (`.loomy/logs/events.jsonl`). Bridges record delegation starts (pid) and completions (same id), including `requested`, `off_routing` and `why`. Native Claude subagents record starts from `PreToolUse` and matching completions from `SubagentStop`, with the actual model from usage when available; their completion events refer to usage costs rather than counting them twice. Session and request events delimit the live recap; dead processes become interrupted roles in the live view.
- The integrated tree journal reads a bounded 400-record JSON tail, keeps task identity and the latest useful observed activity per active native turn, and honors tool/PID/session closure and explicit reopening. Received responses remain distinct from unconfirmed endings and approval; these read-side labels never rewrite the raw journal. The historical detailed CLI journal remains unchanged.
- `scripts/lib/hooks.sh`: merges missing Claude lifecycle hooks (`SessionStart`, `SessionEnd`, `Stop`, `SubagentStop`, `UserPromptSubmit`, and `PreToolUse` matched to `Agent|Task`) into `.claude/settings.json` during installation and project repair. Existing user hooks, status line and file permissions are preserved; invalid JSON is left untouched.
- `scripts/lib/codex-native.pl`: local native Codex rollout adapter, loaded in the watch sampler and called once for snapshots. Project/parent ownership, per-turn lifecycle, observed root model/effort and last-observed activity feed the existing journal. Private cursors and recoverable context revisions support bounded head/tail reading, invalidation and deduplication; source freshness is separate from model identity. Native owner PIDs are explicit, conversations/tool arguments are not exported, usage is unknown, and distinct native identities remain separate tree nodes. See ADR-0007 for limits; phases are still lead-maintained.
- `scripts/lib/claude-native.pl`: Claude CLI/Code-tab hooks and bounded incremental transcript tails feed the shared `live-state.pl` projection. Agent calls and transcript agent IDs are aliased within each session, including stops preceding returns; asynchronous launch returns never finish a child. Explicit transcript stop/error metadata fills missing hooks, with unknown usage and a 120-second source-presence lease. Separate Claude/Codex leads remain visible together. The private checkpoint stores structural metadata only (optional existing hook task labels obey `LOOMY_JOURNAL_TASKS`); warm watch polls signatures every 200 ms. Source replay does not add costs. Atomic v2 checkpoint recovery, progressive reconstruction and bounded history are verified by the S4 fixtures below; full CPU and real-app checks remain S5 gates.
- `scripts/lib/failover.sh`: temporary lead relay. The brief's lead (the master) never changes; the state is `.loomy/failover` (`master`, `acting`, `since`, `reason`, `resume_at`, optional `manual=1`). `lf_decide` returns the lead tool and a kind (`normal`, `handover`, `continue`, `return`) from the quotas (`quota_switch`, `quota_room`, `lead_failover`, `LOOMY_NO_SWITCH`), `lf_apply` records it and journals `lead_failover` / `lead_return`. `loomy start --lead codex|claude` explicitly selects a temporary lead; manual relays persist when the master has room, but automatic relay can return to the master if the acting lead saturates and the master has room. `--lead auto` or `--lead <master>` explicitly returns to the brief's lead; manual relays are shown as `(manual)`. The chain loop of `loomy-start.sh` (6 sessions at most, `LOOMY_CHAIN_DELAY` seconds to cancel) starts the next session; `loomy-context.sh` prints the prepare and return notices (prompt hook, at most every 10 minutes, Claude Code only) and the start context lines; `loomy-status.sh` and `loomy-statusline.sh` show it (⇄). See ADR-0006.
- `scripts/lib/config.sh`: user preferences (`~/.config/loomy/config`): Claude and Codex plans, to compare the API value consumed with the subscription price, language, screen mode, pinned models.
- `scripts/lib/phases.sh`: the ten bootstrap phases, each with what the lead agent does and what the user must do. Single source for `loomy status`, `loomy watch` and `loomy start`.
- `scripts/loomy-start.sh` (`loomy start`): opens or resumes the lead agent session. It finds the folder's previous session on the machine (Claude stores its conversations per folder, Codex records each session's folder) and picks the prompt from the phase.
- `scripts/loomy-install-project.sh` (`loomy init`): on a project already set up, offers to resume, update (`--update`, brief, phase and log kept) or reset (`--reset`).
- `scripts/loomy-privacy.sh` and `scripts/lib/privacy.sh` (`loomy privacy`): AI files visibility. Local mode: exclusion in `.git/info/exclude`, specific to the copy and invisible in the repository. Private mode: a second Git repository (`.loomy/ai.git`) whose working tree is the project itself and which only tracks the AI files; no copy, `sync` replays the changes on top of another machine's before pushing.
- `scripts/loomy-context.sh`: resume context (phase, expectations, delegations, Git, AI files). Installed by `loomy init` as Claude Code `SessionStart` and `SessionEnd` hooks (`.claude/settings.json`) and Codex hooks (`.codex/hooks.json`, same format), merged with an existing file. Codex only runs a project's hooks once the folder is trusted and the hooks approved (it asks on first launch); the Codex hook command walks up from the session folder to the Loomy project. Claude's prompt hook logs request excerpts (omitted with `LOOMY_JOURNAL_TASKS=0`); native subagent hooks log their lifecycle, while `Stop` and `SubagentStop` collect usage. Session openings and closings go to the log; `loomy start` also records Codex sessions, whose process keeps its pid after `exec`.
- `scripts/loomy-home.sh`: `loomy` without argument, the home screen leading to the next action.
- `scripts/lib/usage.sh`, `scripts/loomy-statusline.sh` and `scripts/loomy-stats.sh` (`loomy stats`): subscription quotas and usage figures. Codex quotas come from the `rate_limits` events in its session logs (end of the latest log, cached in `~/.config/loomy/codex-limits`); Claude quotas from the documented `rate_limits` field of the status line input, saved to `~/.config/loomy/claude-limits` by the project status line (which then runs the user's own status line, remembered by `loomy init` in `~/.config/loomy/statusline-user`). With a subscription, status and log show quota shares and tokens; with the API, costs.
- `scripts/loomy-delegate-codex.sh`, `scripts/loomy-delegate-claude.sh` and `ai_delegate_*` in `scripts/lib/models.sh`: delegation overrides (`--model`, `--effort`, `--write`, `--read-only`, `--why`) precede the task text and take precedence over model/effort environment variables. Codex sandbox overrides also adjust the task guidance. Claude refuses `--write` outside a quota failover; during that relay, writes use `acceptEdits` with sandboxing. Requested overrides and differences from routing (tool, model, effort, sandbox) are journaled and shown in the banner; a quota failover itself is not a tool-routing difference.
- Structured delegations (`ai_delegation_format`, `ai_result_contract`, `ai_result_outcome`, `ai_result_json` in `scripts/lib/models.sh`): when the brief (or `loomy config`) asks for them, the bridges append a fixed answer contract to their prompt and record whether the answer followed it (`format`, `outcome` in the log); generated Claude subagents carry the same contract. TRIED follows empty/none FINDINGS only, with at most 8 attack/result bullets; required for reviewer/security and optional otherwise. The shared rule also reaches free-form review prompts and managed lead instructions for native subagents. Session-start context repeats the rule only when the current tool's managed block is absent or lacks the current rule, using the project's document language to check it. The lead treats a review with no findings and no TRIED as partial; outcome parsing stays backward compatible and records the reported STATUS. Successful structured bridge answers from reviewer/security with a recognized outcome and empty/none FINDINGS but no TRIED evidence also carry `review:"incomplete"`; an empty/none TRIED section supplies no evidence. The classifier accepts common English and French empty markers, case-insensitive field labels, surrounding whitespace and Markdown-bold field labels; any nonempty finding line prevents the flag. Review metadata is best-effort: a Perl failure discards it while preserving the reported outcome and terminal journal event. Stats and status count these flags, and the readable log labels each flagged result, including cached watch views. Old journals without the flag remain unclassified; no outcome is rewritten. Old untouched generated Claude roles are upgraded through project repair; custom roles and orchestration documents stay intact.
- `scripts/loomy-assess.sh` (`loomy assess`): assessment of an existing project, without AI, written to `.loomy/assessment.md`. `loomy init` runs it on an existing project, after switching a Git repository with a history to a dedicated `loomy/adopt` branch (the base branch is remembered in `branch.loomy/adopt.loomy-base`); START.md's "Existing project" section turns it into an adoption plan.
- Project technical name (`slug` in the brief, `loomy_slug`): a single source for the created folder, the GitHub repository (`repo_name`) and the private AI files repository (`ai_repo_name`).
- `bootstrap/START.md`: the setup contract template. Only the copy shipped with Loomy lives here, so that Loomy's own repository never looks like an unfinished setup. It defines nine ordered phases (discovery, adaptive interview, proposal with explicit approval, build, verification, documentation and memory, security, Git checkpoint, retirement of the file), an "Existing project (adoption)" section, token and context discipline rules, and the order of authority once the setup is over. `loomy init` (`scripts/loomy-install-project.sh`) copies it to the project root, from `fr/bootstrap/` when the interface language is French; `--reset` copies it again. The file is retired in the last phase (`loomy-status.sh set done`) and has no authority afterwards.
- `scripts/lib/project.sh`: integrity of a Loomy project. `loomy_project_repair` runs at each `loomy` command that opens a project (`bin/loomy`) and at each Claude Code session start (`scripts/loomy-context.sh`), also from `loomy init` and `loomy doctor`. It migrates `.ai/` to `.loomy/docs/`, adds the relays under the `loomy-*` names, rewrites the old script names in hooks and agent files and removes the unmodified old relays (script rename migration), creates the missing routing documents in `.loomy/docs/`, adds the missing role subagents of a Claude lead in `.claude/agents/`, creates `.loomy/memory/STATE.md` (migrating existing states with a missing `## Dead ends` section; context readers only migrate existing files) and git-ignores `.loomy/memory/`, and keeps the managed orchestration block (between Loomy's markers) current in `AGENTS.md` and `CLAUDE.md`. Existing files are never overwritten except that block and the subagents that are untouched: same text as generated apart from the `model:` and `effort:` lines, and a model Loomy routes. Those follow the routing; a hand-set model or any other change is kept. `loomy_relays_sync` (`scripts/lib/upkeep.sh`) adds the relays that a project created by an older Loomy lacks in `.loomy/scripts/`.
- `scripts/lib/upkeep.sh` and `scripts/lib/repair.sh`: upkeep at launch. Before the commands that open a session or a project, `loomy_upkeep` updates the model catalog silently, probes announced models once a day, compares the latest published Loomy release (cache `~/.config/loomy/loomy.remote`, refreshed in the background at most once a day; the tag comes from the public GitHub API with `curl`, `gh` only as a fallback) and checks Claude Code and Codex against the minimum version of the routed models. When something needs updating it asks once, does everything in one go and the command goes on (`LOOMY_NO_AUTOUPDATE=1` or `loomy config set auto_update no` turn it off). `repair.sh` brings the CLI that the PATH runs to a working version, whatever the install method (npm, Homebrew, native installer, desktop app), by escalating steps each checked in turn: update in place, reinstall with the same method, removal of an older copy that shadows a good one, clean reinstall with the official installer. Each step is logged in `~/.config/loomy/logs/repair-<tool>.log`; settings, logins and conversations are never touched.
- `scripts/lib/skills.sh`, `scripts/loomy-skills.sh` (`loomy skills`) and `catalog/skills.conf`: official agent skills only, from `github.com/anthropics/skills` and `github.com/openai/skills`. The catalog has one line per skill (name, source, path, pinned commit, licence, auto condition, keywords, summary), read line by line and refreshed with `loomy update --catalog` when newer. Skills are chosen from the brief at init (`skills_auto_for`) and suggested from the words of each task (`skills_suggest`, used by `loomy task`); the policy is `loomy config set skills auto|ask|off`. Before installation each skill is fetched at its pinned commit and analysed (`skills_analyse`: scripts, network, deletions, commands run, credentials asked). The fetch goes through a tarball cache in `~/.cache/loomy/skills` whose archives are checked (readable, no link, no absolute or `..` path). Skills that ask for credentials or have a proprietary licence are installed only on request (`loomy skills add`), the proprietary ones for Claude only. Installed folders (`.claude/skills`, `.agents/skills`) are git-ignored; the versioned `.loomy/skills.lock` records source, path, commit, licence, date, reason and analysis, and `loomy skills sync` restores missing folders at the locked commit on another clone. Writes refuse symbolic links, and the lock is rewritten under a lock directory. Each addition or removal goes to the log.
- `scripts/lib/memory.sh` and `scripts/loomy-memory.sh` (`loomy memory`): shared memory in `.loomy/memory/`. `STATE.md` is the work state kept by the lead agent (done, in progress, decisions, dead ends, next), with a target of 40 physical lines. Evidence-backed rejected approaches are appended oldest first under `## Dead ends`: `- <approach> — <why it died> (<evidence path or ref>) · do not retry without a new reason`. Entries use one physical line; indented continuations are tolerated, kept with their bullet during archiving, and joined for display. Other free text stays in STATE and is ignored by the dead-end context. When over budget, the oldest dead ends move to `DEAD-ENDS.md`, always keeping the latest three in STATE; other state content is preserved, even if STATE remains over budget (the lead must condense it). Readers (`loomy_memory_state`, the context hook and `loomy memory`) only migrate or archive an existing STATE, never create one. Migration and archiving preserve the state timestamp, so unincorporated delegation results are not hidden. Both files are local: never versioned in the project repository (kept in the private repository in private mode). `delegations/` holds the task and full result of each delegation (bridges and native subagents, the latter read from their transcript by the `SubagentStop` hook, which needs `python3`), git-ignored because findings can be sensitive and pruned to the latest 200. At session start (and after a compaction) `scripts/loomy-context.sh` injects `STATE.md` and a digest of the latest results, as data to check rather than instructions; both tool families see up to three recent dead ends first (one line each, 320 characters at most, inside the 40-line context budget), falling back to the latest archived entries when STATE has no dead-end bullets, and a pointer to the full ledger and archive. The reminder to check before proposing and state a new reason before retrying appears only when the current tool's complete managed block lacks the current Dead ends rule, checked in the project's document language; the ledger data stays in context regardless. `loomy config set memory off` turns it off. `loomy memory` shows the state and the digest, `loomy memory show [N]` the full text of a result.
- `scripts/loomy-feedback.sh` (`loomy feedback`) and `scripts/lib/feedback-triage.sh`: tester feedback. `loomy feedback` prepares a GitHub issue with anonymised context (versions, project type, stage, mode, phase, latest log events without task text) and sends it only after confirmation; `--print` only prints it. `list` shows the tester's feedback and its state, and the launch says once when one is fixed in the installed version. For the maintainer, `triage` groups the open untriaged issues by cause, with a priority and a proposed reply, written by a fast model that cannot act (Codex read-only sandbox, or Claude without any tool, since issues are untrusted text; `LOOMY_TRIAGE_AI=none` skips the model), into a Markdown report; each reply and label is then posted only after the maintainer's choice. `mark` and `close` label a feedback `fixed-in:<version>` and close it at release after approval.
- `scripts/loomy-shell-hook.sh` (`loomy shell-hook`): opt-in `claude` and `codex` shell functions, added to `~/.zshrc` or `~/.bashrc` between Loomy's markers (never installed silently, a backup is kept, removable). Typed alone in a Loomy project whose lead tool it is, the command goes through `loomy start`; with arguments, in another folder, for the other tool, inside a delegation or with `LOOMY_SHELL_HOOK=0`, the real command runs unchanged.
- `scripts/loomy-status.sh` and `scripts/loomy-tree.sh`: session and live rendering. `loomy watch` defaults to the tree, with a live list in compact side panes; `a` selects the live list with running roles first and finished roles from the current lead session. A persistent sampler checks journal/state changes every 250 ms; queued timer tuples are coalesced up to the first key, retaining dirty state and key order, and quit runs before expensive rendering. The incremental reducer reads complete appended events and detects rotation or truncation. Timers redraw every second while running. `v` switches diagram/list or request/model grouping; `o` opens the acting orchestrator in an available desktop app or a separate terminal window with tracking. Rows use observed models/efforts, updated from usage or native session contexts, and show elapsed time, tasks, outcomes and requested/off-routing markers. `t` switches tree/status; `l` opens the journal. `loomy tree --once` prints the live view. The regular diagram uses adaptive padded boxes, two fixed title rows and clipped canvas slots (`tree_view`, `scripts/lib/canvas.sh`) without changing box heights for long labels.
- `scripts/loomy-statusline.sh`: Claude Code status line segment. Besides saving quotas, it shows the bootstrap phase while setup is unfinished and the number of running delegations whose process is alive; it appends the segment to the user's own status line (run with a 2 second limit) or shows a short Loomy line. It never fails.
- `tests/run.sh`: end-to-end test suite, without network or token (`claude` and `codex` doubles in `tests/stubs/`). `--section 'Native Codex'` runs the native rollout regressions alone; their fixture clock is saved at seed so appends and snapshots survive UTC midnight. `LOOMY_TEST_NATIVE_PTY=0` explicitly skips its terminal test in a restricted sandbox; the default Mac run keeps that test enabled.

**Test hermeticity.** Every suite sources `tests/lib/guard.sh`: `XDG_STATE_HOME`, temporary files and tmux sockets stay inside its disposable work directory, desktop launchers are stubs, and AI launch sites reject binaries outside the declared stub directory under `LOOMY_TEST_GUARD=1`. Exit cleanup reports and stops leaked processes before removing the work directory; the main suite also checks remaining sessions and guard violations.

**Core test selection.** `LOOMY_TEST_CORE=shell|next` defaults to shell. The guard's private `BASH_ENV` hook selects CLI and executable relay calls without changing assertions. `next` uses `LOOMY_TEST_NEXT_ROOT` (default `tests/next/compat`): executable `bin/loomy` plus matching `scripts/loomy-*.sh` wrappers. An unavailable CLI prints a named suite SKIP; a missing relay fails without fallback. `$WORK/core-entrypoints.tsv` records selector, logical entrypoint and selected path without arguments, then disappears on cleanup. This is dispatch accounting, not Rust-hit proof; sourced libraries remain implementation tests. P1 wrappers must supply actual Rust-hit evidence. `--section 'Core seam'` checks selection with synthetic wrappers and the existing process gate.

The design deliberately avoids preloading every specialised role or a large security workflow into every session.

- `tools/capture-watch.sh`: regenerates the animated README live-view SVG with `tools/capture-watch.sh <en|fr> <out.svg>`, using an isolated disposable project, CLI test stubs and synthetic journal events with live local processes; renders 24 frames through `scripts/loomy-tree.sh --once`, converts them with `tools/ansi2svg.py`, and checks the heading, local-path exclusion and size below 300 KB.

## Upstream CLI flags

Audit dated 2026-10-15 against the [Codex CLI reference](https://developers.openai.com/codex/cli/reference), [Codex configuration reference](https://developers.openai.com/codex/config-reference), [Claude CLI reference](https://code.claude.com/docs/en/cli-reference) and [hook policy](https://code.claude.com/docs/en/hooks#disable-or-remove-hooks) (study checks W03c/W03h/W04b/W04c). This is a documentation/argv audit with hermetic stubs, not an installed-client authentication or isolation certification.

| Provider / callers | Complete passed options and values | Upstream result / action |
| --- | --- | --- |
| Codex lead (`start`, `task`, `audit`, route advice); launch boundary | `-m MODEL`, `-c model_reasoning_effort=EFFORT`; resumed start: `resume --last` | Supported; effort support depends on client/model. No change to routing or efforts. |
| Codex bridge | `exec -m MODEL -c model_reasoning_effort=EFFORT -s read-only\|workspace-write -C ROOT --skip-git-repo-check --ephemeral --json -o FILE` | Supported; `-s` is sandbox, not approval policy. |
| Codex doctor/models probe; feedback triage | `exec -m MODEL -c model_reasoning_effort=low\|medium -s read-only --skip-git-repo-check --ephemeral -o FILE` | Supported. Probe runs only when requested; this audit never runs a real probe. |
| Codex route `codex-profiles` (printed advice only) | Before 0.134: `--profile ai-ROLE` with `[profiles.ai-ROLE]`; 0.134+ or unknown version: explicit `-m MODEL -c model_reasoning_effort=EFFORT` | Legacy sections removed in 0.134.0 (W03h); version read through `loomy_cli_meta codex --version`. Unknown/failed detection gets an explicit note and per-call advice. No user config writes. Current `--profile` uses separate files; Loomy does not generate them. |
| Claude lead (`start`, `task`, `audit`, route advice); launch boundary | `--model MODEL --effort EFFORT`, optional `--advisor MODEL`; resumed start: `--continue` | Supported; effort/advisor availability depends on client/model. |
| Claude Desktop handover | `--desktop --resume SESSION_ID` | Requires 2.1.285+ (existing version gate). Desktop rejects model flags; the launch boundary now omits its automatic `--model` addition for this handover. |
| Claude bridge, default `off` | `-p PROMPT --session-id UUID --output-format json --max-turns N --model MODEL --effort EFFORT`; read: `--disallowedTools Edit,Write,NotebookEdit`; quota-write: `--permission-mode acceptEdits --settings '{"sandbox":{"enabled":true,"autoAllowBashIfSandboxed":true}}'` | Supported (W04b/W04c); existing argv unchanged. Unresolved headless permission requests remain denied. Project MCP/hooks can load without a trust prompt. |
| Claude bridge, internal `bare` candidate | Default bridge options plus `--bare` | Documented minimal discovery mode; auth/config/isolation effects must be tested on the installed version before rollout. |
| Claude bridge, internal `strict` candidate | Default bridge options plus `--strict-mcp-config --mcp-config '{"mcpServers":{}}' --setting-sources ''`; `--settings` adds `"disableAllHooks":true` (merged with sandbox settings for quota-write) | Explicit empty MCP set and per-run hook denial; no inherited user/project/local settings. Auth store stays in place. Managed policy may still require MCP/hooks; this is not certified plugin/config isolation. |
| Claude doctor/models probe | `-p PROMPT --output-format json --max-turns 1 --model MODEL --effort low --tools '' --strict-mcp-config` | Supported; no tools. Probe changes are outside the bridge isolation switch. |
| Claude local writer / feedback triage | `-p --model MODEL --tools '' --strict-mcp-config PROMPT` | Supported; no tools. Local writer also uses a disposable `CLAUDE_CONFIG_DIR` and the local API endpoint. That empty user directory is precedent, not proof that project hooks are disabled; bridge strict uses explicit hook denial without replacing the subscription auth store. |
| Both providers, metadata / repair | `--version`; Claude repair: `update` | Through `loomy_cli_meta`; no model call. Its allowlisted `login`/`auth` subcommands have no current caller. |

Loomy passes neither `--full-auto` nor `--approve-for-me`, and sets no Codex `approval_policy` or `-a` option. W03c's removal of `--full-auto` therefore requires no launch replacement. Current approval values are `on-request`, `never`, or granular config; `untrusted` is unsupported and `on-failure` deprecated. Inherited user policy is unchanged. `--approve-for-me` conflicts with an explicit `-s` sandbox and must not be substituted blindly. Claude's newer `--permission-prompts none` is not added to the unchanged default bridge.

`LOOMY_CLAUDE_ISOLATION=off|bare|strict` is internal; unset means `strict`, invalid values fail before launch. Real test on Claude Code 2.1.296 with subscription auth (2026-10-15, trap project with a project MCP server and a project hook): `off` started both; `bare` failed with "Not logged in" (subscription auth unavailable), so it stays an unused candidate; `strict` answered with neither started, in read and write modes. `off` remains available for diagnosis. No mode falls back to another on failure.

StatusLine freshness remains event-driven (W05). Upstream's optional `refreshInterval` (at least one second) is **not implemented by Loomy**: no timer registration, user statusLine rewrite, or provider refresh call is added. Idle silence is not a fresh quota zero.



## Live performance and resilient watch

The sampler and timer coalescer live for the watch lifetime. Watch-owned snapshots
skip source collection. Native tree/list ownership and fitted-row inputs are indexed
on deltas; warm timers update elapsed text without decoding unchanged wire rows or
spawning row helpers. Duration-width transitions still refit the original row inputs.
Captured lines are joined once per frame, avoiding repeated multibyte concatenation.
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
are fixture results; S5 remains partial because hook-only diagram, changed status
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
lease stays running. Agent-call descriptions are private and never used as labels: `agent <id>` is the label without a task.
The live block of a live group shows running agents first (newest first), then agents that ended within the last 30 minutes
(newest first); everything older and every lost agent folds into one line `+N earlier · M lost` and is listed only in the
recap, which is ordered newest first (the fold forces the recap pass). The list view and the compact modes keep their
`+N finished` summary. `tests/watch-real-data.sh` covers these cases with structural fixtures.

## Checkpoint and journal policy

S4 native checkpoints use version 2, with a 2 MiB snapshot and content-addressed source
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
seconds. `tests/live-growth.sh` covers these Round 4 fixes, 50,000-event idle growth,
65,000-key migration, pruning, crash recovery across multiple rotations, corruption,
shards, private modes and idempotent repair. It is registered in `tests/run.sh` with the launch, resume,
availability, live and watch-exit suites.
**W2/W3 — desktop resume and session-only routing.** `scripts/lib/resume.pl` reuses native metadata/slug helpers read-only: Codex date directories are inspected newest first, at most 256 KiB of metadata per candidate, stopping at the first matching project/subfolder lead; Claude transcript filenames identify the newest root session. Live Claude cwd ownership or a fresh transcript with a live journal owner prevents desktop handover. `loomy-start.sh` uses the shared `launch.sh` check/run/spawn/meta API. Terminal `--lead <tool> --only` owns `.loomy/session-only` with its PID; routing ignores and cleans dead owners, and start removes its own marker on exit. Desktop-only overrides are refused until a session-owned lifetime is available. The brief remains unchanged.
## W47 — parallel requests and coherence

- Project repair is limited to project/session opening commands (`home`, `start`, `resume`, `init`, `install`, `task`, `tasks`, `audit`, `review`) and Claude session start; read-only `status`, `watch` and `route` do not repair a project.
- Managed orchestration and templates split requests into disjoint subtasks, launch native roles of the lead family together and use bridges only across families. Background bridges are all awaited before integration; review, security and documentation then run together with disjoint scopes. Routed efforts remain unchanged. `max_parallel` defaults to 4; `loomy config set max_parallel N` accepts 1–999 (`auto` restores 4). The prompt reminder includes the configured cap.
- `loomy worktrees <task> [base] --count N` creates numbered branches `loomy/<task>/<n>` and paths `<repo>-<task>-<n>`; the legacy family pair remains the default. Worktrees link to the main project's `.loomy` (or, when the AI files are versioned and each worktree checks out its own `.loomy`, to its `.loomy/logs`), so every bridge writes into the same watch journal. Preflight rejects existing branches/paths and a tracked `.loomy` (a tracked `.loomy/logs` when the AI files are versioned) at the base before creating any worktree.
- `loomy stats` counts completed requests from Claude request/lead-stop evidence and Codex lead rollout user turns/terminal events (one user record per turn, no prompt output). Incomplete requests are excluded. Parallelism = summed worker durations / the union of their active intervals; 1x is sequential, 2x is two fully overlapping workers. These lifecycle measurements are independent of native usage/cost, which remain unknown. Rollout discovery is read-only, scans the local session history only when stats is requested, and accepts project subfolders and worktrees sharing `.loomy`.
- Row allocation reserves state/outcome and elapsed, shrinking task, then model, then effort bar; extremely narrow rows wrap identity. The dictionary test builds in its private work directory and never rewrites a tracked file; translation discovery handles both shell quote styles.
### Single launch point

- `scripts/lib/launch.sh` owns provider process execution: `loomy_cli_resolve`,
  `loomy_cli_check`, `loomy_cli_run`, `loomy_cli_spawn`, and `loomy_cli_meta`.
  Feedback version reporting and repair metadata calls use the same boundary.
  The test guard runs first; model calls require catalog validation and provider
  availability. Bridges retain W8 handover/pause semantics; ordinary callers return
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

- `codex-native.pl` accepts top-level v2 thread metadata and the older `source.subagent.thread_spawn` envelope. Explicit `parent_thread_id` takes precedence; `session_id` identifies the lead when a subagent has no parent field. Parent traversal retains depth-two nesting. Eligibility uses canonical cwd or a runtime workspace root under the project; unrelated workspace paths are not checkpointed. Task labels combine sanitized nickname, free-form role and path slug, obeying journal task privacy.
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

The Round 3 fixture reports process CPU by stage, including fresh interpreter/module
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
