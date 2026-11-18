# Loomy commands

[← README](../README.md)

Every command with its variants and what it does in detail. Reference for Loomy **0.17.10**. In the terminal: `loomy help <command>`.

## Project

### `loomy`

```bash
loomy
```

Home: where the project stands, what is expected, and the next step in one choice (outside a project: create one)

### `loomy init [dir]`

```bash
loomy init [dir]
loomy init --update
loomy init --reset
loomy init --no-wizard
loomy init --yes
loomy init --answers <file>
loomy init --no-branch
```

Creates the folder if needed (or offers to create it from the project name), then initializes the project, new or existing: questionnaire, then structure set up by the lead agent; on an initialized project: resume, `--update`, `--reset` (`--no-wizard`, `--yes`, `--answers`; existing Git project: `--no-branch` to stay on the current branch)

### `loomy brief`

```bash
loomy brief
```

Reruns the questionnaire for the current project

### `loomy assess`

```bash
loomy assess
loomy assess --print
```

Assessment of an existing project, without AI: stack, commands, tests, CI, conventions, Git history, sensitive areas, debt (`.loomy/assessment.md`; `--print` to only show it)

### `loomy privacy`

```bash
loomy privacy
loomy privacy versioned
loomy privacy local
loomy privacy private
loomy privacy sync
loomy privacy adopt
loomy privacy restore <account/repo>
```

AI files visibility: `versioned`, `local`, `private`; `sync`, `restore` for the private repository. `adopt` verifies a `.loomy/ai.git` that Loomy did not create (older Loomy, a copied folder) and trusts it after you confirm its URLs (a local remote must be an absolute path outside the project); a companion shipped by a clone is refused until you adopt it, and nothing runs against it meanwhile. These modes do not grant permission to retain task text. The content controls below apply to the current project; worktrees sharing its registered logs also share its policy.

#### `loomy privacy content`

```bash
loomy privacy content
loomy privacy content structural
loomy privacy content legacy-excerpts
```

Shows the effective policy, source and project scope, or changes future journal writes. In 0.17.8, new journal entries and fresh rotation snapshots contain allowlisted structure by default, on new and upgraded projects. Existing files and archives are unchanged.

`legacy-excerpts` is a separate, explicit project grant. It permits only bounded top-level `task` (200 Unicode characters), `excerpt` (60), `why` (200), `nickname` (40) and `cwd_relative` (256, inside the project). It does not enable full task/result retention.

Widening a grant requires a human to run the command directly in an interactive terminal and confirm the project, fields and limits. Pipes, `--yes`, hooks and managed agent terminals cannot grant permission. Restricting the policy or turning capture off also works noninteractively.

`LOOMY_JOURNAL_CONTENT=structural` is a temporary restriction. Selecting `legacy-excerpts` through the environment also requires an existing human grant and `LOOMY_CONTENT_PROJECT` bound to the registered project; environment variables cannot create permission. `LOOMY_JOURNAL_TASKS=0` vetoes automatic excerpts, labels and full task/result capture, even with grants. `LOOMY_JOURNAL=0` disables journaling/collection, not every other work artifact.

#### `loomy privacy labels` · `loomy privacy label`

```bash
loomy privacy labels
loomy privacy labels recommended
loomy privacy labels set explicit-user,explicit-lead
loomy privacy labels off
loomy privacy label --id <id> [--attempt <id>] [--kind agent|task|session|delegation] "Short title"
```

`labels` shows the selected sources, limits and first-use choices. `recommended` grants all six sources: `explicit-user`, `explicit-lead`, `claude-description`, `codex-path-slug`, `codex-nickname`, `codex-role`. `set` replaces the exact source set; additions require human confirmation. `off` stops future label capture without deleting earlier labels.

Labels are stored separately from the journal: at most 96 graphemes / 384 UTF-8 bytes per label, with each Codex component limited to 40 ASCII characters, in a store capped at 1 MiB. Claude uses the bounded Agent/Task `description`, never its `prompt`. A full label store refuses the new save visibly and preserves the previous label.

The singular `label` command saves a deliberate human title for an exact ID, attempt and kind. It always requires a direct human terminal; it offers the `explicit-user` grant if missing. Kind defaults to `agent`, attempt to the supplied ID. Bridges use `--task-label` under the separate `explicit-lead` grant.

After upgrade, a project with pending choices gets a one-time screen at its first interactive `loomy init` or standalone `loomy watch`: recommended labels **Yes** by default, then private results as a separate **Yes** default. The screen saves no new grant until both human answers are complete; EOF or an aborted screen grants nothing. Declines are remembered. An explicit human `privacy labels` decision also completes the first-use acknowledgement; turning capture off does not reopen the prompt. Managed/noninteractive use grants nothing and leaves the choices pending; status shows `Task labels off · run loomy privacy labels recommended` when needed.

Tree/list, diagram, status, session log, readable `loomy log` and recap resolve authorized labels. Without a usable label, a known role shows its mission prefixed `Role:`; unknown roles show unavailable context. A role mission describes its remit, not work completed. Older journal rows may still display their existing text.

#### `loomy privacy results`

```bash
loomy privacy results
loomy privacy results on
loomy privacy results off
```

Shows or changes the separate grant for full private tasks/results. Capture is off until the first-use result answer or an explicit human `results on` confirmation; accepting labels or compatibility excerpts does not enable it. `off` stops future capture and preserves previously authorized records.

New records use private directories (0700) and files (0600), with limits of 200 records, 1 MiB per record, 16 MiB total and 30 days. Retention runs on saves. A running pin requires a live owner and an age under 24 hours; a paused pin lasts until 30 days after its reset/recheck time (or last save if unset). Oversized records or a store filled by pins cause a visible capture refusal. These limits do not purge historical Markdown results. Labels, receipts and private results are excluded from project/companion Git, sync and automatic feedback. Permissions do not encrypt them. See [`loomy memory`](#loomy-memory) for receipts and available results.

#### `loomy privacy inventory`

```bash
loomy privacy inventory [--root DIR] [--json] [--paths] [--git-history] [--host]
```

Read-only metadata inventory of known storage locations: counts, bytes, retention/exposure categories and incomplete coverage. It does not inspect file bodies, follow arbitrary links, repair stores, run collectors, copy, send or remove files. Default output omits filenames; `--json` uses the same metadata fields, while `--paths` explicitly adds escaped local paths and file metadata.

`--git-history` checks local project/companion index and history path metadata, without fetching or rewriting history. `--host` adds known Loomy host and temporary-file locations; a matching name does not prove a file is abandoned. Provider transcripts, remote clones, backups and arbitrary export locations remain outside proven coverage. An inventory is not proof that files contain no sensitive text.

The 0.17.8 repair covers new journal writes/rotation snapshots, receipts and automatic feedback staging. Native checkpoints/cursors, execution/display temporary files and diagnostics can still retain text or paths. `log --raw` and explicit `report --md` exports retain their existing behavior. Older files, Git history and provider-managed transcripts are not purged or sanitized by these controls.

## Sessions and work

### `loomy start`

```bash
loomy start
loomy start --resume
loomy start --new
loomy start --print
loomy start --watch
loomy start --no-watch
loomy start --app
loomy start --lead codex
loomy start --lead claude
loomy start --lead auto
loomy start --lead codex --only
loomy start --lead claude --only
```

Starts or resumes the lead agent session (`--resume`, `--new`, `--print`, `--watch`)

`--lead codex|claude` temporarily selects the lead tool without changing the brief, replacing `AI_ROUTE_ENV=hybrid-codex loomy start` for this use. A switch starts a new session with the handoff and shared state prompt, even with `--resume`; repeating the acting tool keeps the session choice and adds no relay event. `--lead auto` or the brief's lead clears the relay and starts that lead with the return prompt. Manual relays stay until an explicit return, except when the acting tool reaches its quota threshold and the master has room. A missing tool is refused (exit 2); a saturated quota or pay-per-use plan produces a warning and remains allowed. Works with `--app` and tracking; `--print` previews without writing state.

`--only` routes every role to the explicit lead during the terminal session, without changing the brief or copying the project. Watch and `loomy route` display the choice; only descendants inherit its PID/birth-time marker, and session exit removes its own marker. Another terminal or `--lead auto` preserves other live sessions. Without `--lead codex|claude`, exit status is 2. `--print` creates no marker. `--only` keeps the launch in the terminal even with `start_in=app`; `--only --app` is refused because the app exposes no session-owned process.

`--app` and `o` in watch reopen the latest Codex thread of the project (including subfolders), or the latest Claude session with `claude --desktop --resume` (CLI ≥ 2.1.285). A Claude session busy in a terminal is refused with a `/desktop` hint; no other window opens. Without a compatible session, with an older Claude CLI, or if launch fails, the usual link opens a new conversation with the prompt prefilled, never sent. An active relay’s acting lead is respected.

🪟 The lead agent session on the left and live tracking on the right, by default (stacked in a narrow terminal), through tmux or iTerm2; tracking closes with the session. `--no-watch`, or `loomy config set start_watch no`, opens the session alone. In every session, Claude Code's status line shows the phase and the delegations running (⟳ n), also after your own status line; a session opened without tracking is told to mention `loomy watch`

### `loomy task "…"`

```bash
loomy task "…"
loomy task --resume
loomy task --print
```

A named task for the lead agent: plan, approval, build, verification, commit, followed in `watch`; without argument, the list; `--resume`, `--print`

### `loomy review`

```bash
loomy review
loomy review --working
loomy review --staged
```

On-demand cross review of the current branch (`[base]`) or of uncommitted changes (`--working`, `--staged`), read-only, saved in `.loomy/reviews/`

### `loomy effort`

```bash
loomy effort
loomy effort --list
loomy effort --reset
```

Reasoning effort of the lead agent for this project (`loomy effort low`, menu without argument), or of a role (`loomy effort executor high`); `--list`, `--reset`; applied at the next `loomy start`

### `loomy shell-hook [install|remove]`

```bash
loomy shell-hook
loomy shell-hook install
loomy shell-hook remove
```

Optional: in a Loomy project, `claude` or `codex` typed alone (the project's lead tool) goes through `loomy start`, so the session always opens with live tracking and the context; anything else runs the real command. Offered once by `loomy doctor --fix`, never installed silently

### `loomy worktrees <task>`

```bash
loomy worktrees <task>
```

Two worktrees by default; `--count N` creates N numbered worktrees sharing the live journal. Split independent scopes, launch together, then wait for all results before integration; review/security/documentation run in parallel afterwards.

## Tracking and figures

### `loomy status`

```bash
loomy status
```

Snapshot: phases, running delegations, activity, cost per model, subscriptions, Git

### `loomy watch`

```bash
loomy watch [N]
```

🖥️ Live project agents: the orchestrator, then **IN PROGRESS** (native Claude subagents and bridges), then **SESSION**, containing only finished roles from the current lead session. Starts are polled every 250 ms; timers tick every second, including when an older refresh interval `N` is supplied. In the live list, `v` switches grouping by request/model and saves `watch_group` (`request` by default). Task context follows the [privacy grants](#loomy-privacy). Keys shown in the footer depend on the view: `q` quits; `o` opens the acting orchestrator in its desktop app, or a separate terminal with tracking (failure is shown in the footer and tracking continues); `l` opens the journal, then returns to status; `t` switches tree/status; `a` opens the live list, then returns to status. In the tree, `v` switches diagram/list; in the live list, it groups by request/model and saves `watch_group`. In status, `c` switches compact/full. `s` opens the session outside a tracking pane and without `--until-exit`; arrows scroll when the body exceeds the screen. `watch_view` (`tree` by default; `list` selects the live list) remembers the view chosen with `t` or `a`. The tree uses boxes from 124 columns, with scrolling in a shorter terminal, and its own compact list below that width. The compact side pane opened by `loomy start` starts in the live list. Rows show the translated role, tool, actual model, effort word and four-cell bar, elapsed time, task context and recorded outcome; explicit requests and routing overrides are flagged. Narrow panes drop task context, model and bar in that order, keeping the tool and effort word; routing annotations move to an indented continuation when needed. The banner shows the lead state once setup is done; active means a live lead process with a prompt or usage event in the last two minutes. The view redraws on journal/state changes, or every second for running timers; at rest the clock holds at the last refresh. Native subagent costs come from usage events only, while bridges retain their own costs.

Native Codex agents are also observed from the local rollout files under
`CODEX_HOME` (default `~/.codex`). File discovery is bounded; lifecycle tailing
is incremental, so historical catch-up may take several polls. The collector
records native thread/turn identities and last observed activity without
copying prompts, tool arguments or conversations. Missing results are unknown,
not successful assignments; native Codex usage/cost is not invented. See
[ADR-0007](adr/0007-native-codex-observability.md) for evidence limits. Phase
labels remain the lead's last recorded metadata, not inferred progress.

The main Codex model and effort come from observed root turn contexts, including
later changes. Catch-up is marked separately; invalidated evidence is cleared
rather than presented as current or replaced by a guessed configured model.

When multiple tool sessions remain open, `LOOMY_WATCH_TOOL=codex loomy watch`
(or `claude`) explicitly selects which tool's session to display. This optional
filter does not switch the acting lead or modify routing. Unset or invalid values
fall back to the current lead; `o` clears the filter when opening that lead.

Only one view per project collects native activity (the first `watch`, or a one-shot `status`/`tree` while it runs); any other `watch` shows `Following another watch · q closes this view`, reads stored data and writes nothing. `q` closes only that view; the owner finishes its batch and releases on `q`. Close an older Loomy's `watch` with `q` before upgrading or rolling back.

### `loomy tree`

```bash
loomy tree
```

🌳 Agent tree: the lead agent with its model, effort, session and phase; its advisor and its consultations; every role with its model, effort and live state (a pulse travels along the branch of a running role, then its recorded completion state, duration and token counts when available); the session log; a status line. `loomy tree --once` prints a single frame of the live watch view. In a large window (124 × 57) it is drawn as a diagram (boxes and animated links; up to four role boxes), otherwise as a list; `loomy config set tree_view auto|diagram|list` chooses. Completion does not establish that tests passed; paused or missing results do not mean success.

### `loomy log`

```bash
loomy log [-n N] [-f]
loomy log --raw
loomy log --since YYYY-MM-DD
loomy log --csv
```

Readable journal in local time, optionally streamed, with authorized labels resolved for new entries. `--since YYYY-MM-DD` reaches into monthly archives; `--csv` exports costs. In 0.17.8, `--raw` still emits original JSON, including any text in older or compatibility records; it is not a sanitized export.

### `loomy stats`

```bash
loomy stats
loomy stats --days N
loomy stats --since YYYY-MM-DD
```

Detailed statistics: by role, model and day, durations, tokens, cost or quota (`--days N`, `--since YYYY-MM-DD`)

### `loomy report`

```bash
loomy report
loomy report --md [dir]
loomy report --all
```

Project figures: bootstrap, tasks, delegations by role and model, tokens, cost; `--md [dir]` writes Markdown in `docs/reports/` or the chosen directory; `--all` every project. Plain `report` creates no Markdown file. In 0.17.8, an explicit Markdown report can still contain the project name and task titles; review it before sharing.

### `loomy memory`

```bash
loomy memory
loomy memory -n N
loomy memory show [N]
loomy memory show legacy [N]
```

Shared memory keeps authored work state and Dead ends alongside automatic delegation receipts. Receipts in `.loomy/memory/receipts-v1/` contain structural facts such as ID, role/model/effort, state, times, file count and authorized references. They contain no full task or result.

With the separate [private-results grant](#loomy-privacy-results), full tasks/results and structured bridge resume options are saved in `.loomy/memory/private-results-v1/` within its retention limits. The digest resolves SUMMARY/NEXT from available private bodies; `show [N]` prints the same ranked receipt and any available authorized task/result and resume descriptor. Without a retained body, it says the result was not retained; without the original paused task, it says `original task required to resume`.

Older sensitive Markdown results remain separate and readable with `show legacy [N]`; they are not migrated, pruned or permission-changed by the new capture policy. `loomy config set memory off` disables context injection, not retention; use `loomy privacy results off` to stop future private capture. Neither command deletes existing records.

## Agents, models and skills

### `loomy route`

```bash
loomy route
loomy route lead
loomy route get <role>
loomy route markdown
loomy route claude-agents
```

Role → model → effort matrix · `lead` · `get <role>` · `markdown` · `all` · `claude-agents` · `codex-profiles`

`codex-profiles` prints version-aware advice without changing user configuration. Before Codex 0.134 it prints legacy TOML profiles; from 0.134 (or when the version is unknown) it shows how Loomy pins each role's model and effort per call with `-m` and `-c model_reasoning_effort=…`. Version detection uses only `codex --version` through Loomy's launch boundary.

### `loomy delegate codex <role> "…"`

```bash
loomy delegate codex <role> [options] "…"
```

Hands a role to Codex (executor, developer, documenter can write; the others are read-only)

### `loomy delegate claude <role> "…"`

```bash
loomy delegate claude <role> [options] "…"
```

Hands a role to Claude, read-only (architect, debugger, security, reviewer, explorer)

Options before the task text (they win over `DELEGATE_*_MODEL` / `DELEGATE_*_EFFORT`): `--model <id>` (letters, digits, `. _ -`; for Claude a `claude-*` id or `opus`, `sonnet`, `haiku`), `--effort <low|medium|high|xhigh|max>`, `--write` / `--read-only` (override the role's sandbox; on Claude, `--write` is refused outside a quota failover), `--why "reason"` (for example `user request`), `--task-label "Short title"`.

A model, effort, sandbox or reason override marks the delegation `requested` in the journal; differences from project routing (tool, model, effort, sandbox) are listed in `off_routing`. The reason text is omitted from structural journal entries; only a `legacy-excerpts` grant permits its bounded `why`. `--task-label` supplies a deliberate display title under the human-approved `explicit-lead` source, within the label limits; it does not itself mark a routing override or grant permission. Never derive it automatically from the full task. Example: `loomy delegate codex architect --model gpt-6.2-sol --effort high --write --why "user request" --task-label "Architecture review" "…"`.

Provider availability: exit 75 means paused. The final delegation event records `status: "paused"`, `outcome: "waiting_for_reset"` and `resume_at` (Unix epoch). Reaching that time does not mean the work resumed or succeeded. Retain the exact role/provider/model/effort/sandbox/options; after reset, relaunch once using the original live task or an authorized task/private-result reference. `loomy memory show N` exposes a retained bridge’s structured resume descriptor, not an executable command. Review existing edits before relaunching. If the original task/options are unavailable, report `original task required to resume` and stop dependent work; never guess or choose a weaker model. If another pause occurs, use its new `resume_at`.

Out of credits: exit 69 means the provider has no credits left ("out of credits", "insufficient credits", "credit balance is too low", billing or HTTP 402 payment required). It is not a timed reset: the final delegation event records `status: "error"`, `outcome: "credits"` and no `resume_at`. A role is first handed once to the other provider when it can serve; otherwise the bridge exits 69. Do not wait or relaunch: tell the user to add credits or switch provider/model. A message that carries an explicit reset time stays a rate limit (exit 75).

Delegations pause only after a real refusal or at 100 % / reached; the lead session’s configurable early relay threshold stays separate.

### `loomy models`

```bash
loomy models
loomy models --issue
```

Validated current model chains and new candidates to evaluate; `--issue` suggests candidates on GitHub. `chain.<family>.<tier>` only accepts catalog-validated models for that tier; unknown ids are refused explicitly. `--thrifty` is retired (exit 2); the Thrifty budget profile still lowers effort.

Announced-model discovery may run one bounded, read-only/tool-free probe per day, never while its provider is paused. A successful candidate probe does not promote it into routing. Codex’s local model cache is advisory; a missing entry warns without blocking a validated model.

### `loomy skills [suggest|add|remove|update|catalog]`

```bash
loomy skills [suggest|add|remove|update|catalog]
loomy skills suggest "…"
loomy skills add <name>
loomy skills remove <name>
loomy skills update
loomy skills catalog
```

Official agent skills of the project: installed, why, analysis; `suggest "…"` for a task, `add`/`remove`, `update`, `catalog`

### `loomy audit`

```bash
loomy audit
loomy audit --resume
loomy audit --print
loomy audit --yes
loomy audit --scope <folders>
loomy audit --depth quick|standard|deep
loomy audit --fixes report|plan|branch
```

Security audit of an existing Git repository, a mission rather than a project (see below): `--resume`, `--print`, `--yes`, `--scope`, `--depth quick|standard|deep`, `--fixes report|plan|branch`

## Maintenance and help

### `loomy hooks [status|repair [--shell]]`

```bash
loomy hooks status
loomy hooks repair
loomy hooks repair --shell
```

Scoped inspection and repair of the Loomy hook registrations in `.claude/settings.json` and `.codex/hooks.json`; no other project file, content grant or provider call is involved. `status` is read-only and lists, per provider and event, `shell`, `native`, `mixed`, `custom`, `missing`, `invalid` or `ambiguous`, and whether action is needed. `repair` fills missing registrations and keeps recognized active ones and your own hooks, matchers, status line and file permissions; it reports `changed` or `unchanged` per file. `repair --shell` restores recognized shell registrations and is the step to run before going back to an older Loomy. `repair` acts only in a Loomy project and only for the providers it uses (the other is reported as skipped); `--root DIR` targets another project. Nothing is rewritten when the file is invalid, unsafe or changed meanwhile, and your own commands are never echoed. Native registration is not available in this release (`--native` is refused).

Rollback before an older Loomy, while this version is installed: `loomy hooks status`, then `loomy hooks repair --shell`, then `loomy hooks status` again; resolve any conflicting event it lists by hand, and only then install the older version. Repeating the upgrade and the repair does not duplicate registrations.

### `loomy doctor`

```bash
loomy doctor
loomy doctor --fix
loomy doctor --live
```

Checks prerequisites, the live tracking owner (build, pid, boot, epoch, or none), content-policy health, a full label store, and Loomy history files tracked by Git (`--fix` fixes, and also removes clone-shipped runtime files from the Git index (only the entries live tracking refused; the files stay on disk), including the optional GitHub CLI: installs `gh` and logs in; `--live` tests every model). These health facts do not certify older files as free of sensitive text.

### `loomy config`

```bash
loomy config
loomy config list
loomy config get <key>
loomy config set <key> <value>
```

Preferences (`list`, `get`, `set`): `plan_claude`, `plan_codex`, `plan_claude_price`, `plan_codex_price`, `start_watch` (`no`: `loomy start` no longer opens tracking alongside), `start_in` (`app`: `loomy start` opens the desktop app), `memory` (`off`: the shared memory is no longer given back), `skills` (`auto`, `ask` or `off`), `notify` (`no`: no notifications in `loomy watch`), `quota_switch` (95 by default: preventive lead relay threshold; `off`: no preventive relay; real refusals and exhausted quotas still protect delegations), `lead_failover` (`auto` by default: when the lead's quota runs out, the other tool leads temporarily and `loomy start` chains the sessions; `off`: never), `quota_room` (80 by default: the lead tool takes the lead back once its quota is below this share), `max_parallel` (4 by default; 1–999 independent workers; `auto` restores 4), `delegation_format` (`structured`, `free` or `auto`: each project's choice), `lang` (`fr`, `en` or `auto`: interface language, detected by default)

### `loomy update` · `loomy version`

```bash
loomy update
loomy update --catalog
loomy version
loomy version --all
```

Updates Loomy, for every project at once; `update --catalog`: only the model and price catalog; `version --all` lists every install

An update running the old 0.17.6 code cannot show the new content-grant screen. After upgrading, the first interactive `loomy init` or standalone `loomy watch` offers any pending per-project choices; noninteractive use creates no grant.

### `loomy uninstall`

```bash
loomy uninstall
```

Shows how to uninstall Loomy for your install method, and how to remove it from a project

### `loomy feedback`

```bash
loomy feedback
loomy feedback --print
```

Reports a bug or an idea: prefilled GitHub issue with versions, allowlisted project-state facts and the last 15 projected journal events. Automatic context omits project name/goal, task text, labels, private results and project paths; it stages no whole brief or raw journal copy. Your own message remains part of the preview. Sent only after your approval; `--print` shows the text without posting or network access.

### `loomy feedback list`

```bash
loomy feedback list
loomy feedback triage
loomy feedback mark <n> <version>
loomy feedback close <version>
```

Your feedback and where it stands: received, being handled, fixed in X.Y.Z (the launch says once when one of yours is fixed in the installed version). Maintainers: `triage` groups the open feedback by cause with a priority and a proposed reply (fast model), each reply posted only after approval; `mark <n> <version>` then `close <version>` at release

### `loomy help [command]`

```bash
loomy help [command]
```

General help, or help for one command
