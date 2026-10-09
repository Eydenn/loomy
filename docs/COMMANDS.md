# Loomy commands

[← README](../README.md)

Every command with its variants and what it does in detail. In the terminal: `loomy help <command>`.

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
loomy privacy restore
```

AI files visibility: `versioned`, `local`, `private`; `sync`, `restore` for the private repository

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
```

Starts or resumes the lead agent session (`--resume`, `--new`, `--print`, `--watch`)

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

Two separate worktrees for parallel mode

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

🖥️ The same screen refreshed every second (or every N seconds): running delegation with spinner, timer and estimated progress, highlighted changes, notification (macOS) and bell on each phase, failure or end of bootstrap. A session log at the bottom scrolls as events arrive, the newest highlighted. Keys: `q` quit, `c` compact or full view (status screen: brief hidden, fewer delegations and log lines), `l` journal, `t` agent tree, `s` open the session. Compact view in a small terminal

### `loomy tree`

```bash
loomy tree
```

🌳 Agent tree: the lead agent with its model, effort, session and phase; its advisor and its consultations; every role with its model, effort and live state (a pulse travels along the branch of a running role, then done, duration, tokens); the session log; a status line. Also key `t` of `loomy watch`. In a large window (124 × 57) it is drawn as a diagram (boxes and animated links; up to four role boxes, the other roles summed up beside the final check, grouped by model, with what each one does), otherwise as a list; `v` switches, `loomy config set tree_view auto|diagram|list` chooses

### `loomy log`

```bash
loomy log [-n N] [-f]
loomy log --raw
loomy log --since YYYY-MM-DD
loomy log --csv
```

Readable journal in local time, optionally streamed (`--raw`: raw JSON); `--since YYYY-MM-DD` reaches into monthly archives; `--csv` exports costs

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

Project figures: bootstrap, tasks, delegations by role and model, tokens, cost; `--md [dir]` Markdown in `docs/reports/`; `--all` every project

### `loomy memory [show [N]]`

```bash
loomy memory [show [N]]
loomy memory show [N]
```

Shared memory: the work state kept by the lead agent and the latest delegation results in short; `show [N]` the full text of one

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

### `loomy delegate codex <role> "…"`

```bash
loomy delegate codex <role> "…"
```

Hands a role to Codex (executor, developer, documenter can write; the others are read-only)

### `loomy delegate claude <role> "…"`

```bash
loomy delegate claude <role> "…"
```

Hands a role to Claude, read-only (architect, debugger, security, reviewer, explorer)

### `loomy models`

```bash
loomy models
loomy models --thrifty on|off
loomy models --issue
```

Model chains and new models to evaluate; head of a chain with two fallbacks (this machine), `--thrifty on|off`, `--issue` (GitHub suggestion)

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

### `loomy doctor`

```bash
loomy doctor
loomy doctor --fix
loomy doctor --live
```

Checks prerequisites (`--fix` fixes, including the optional GitHub CLI: installs `gh` and logs in; `--live` tests every model)

### `loomy config`

```bash
loomy config
loomy config list
loomy config get <key>
loomy config set <key> <value>
```

Preferences (`list`, `get`, `set`): `plan_claude`, `plan_codex`, `plan_claude_price`, `plan_codex_price`, `start_watch` (`no`: `loomy start` no longer opens tracking alongside), `start_in` (`app`: `loomy start` opens the desktop app), `memory` (`off`: the shared memory is no longer given back), `skills` (`auto`, `ask` or `off`), `notify` (`no`: no notifications in `loomy watch`), `quota_switch` (95 by default: from this share of a subscription quota, work moves to the other tool; `off`: never), `lead_failover` (`auto` by default: when the lead's quota runs out, the other tool leads temporarily and `loomy start` chains the sessions; `off`: never), `quota_room` (80 by default: the lead tool takes the lead back once its quota is below this share), `delegation_format` (`structured`, `free` or `auto`: each project's choice), `lang` (`fr`, `en` or `auto`: interface language, detected by default)

### `loomy update` · `loomy version`

```bash
loomy update
loomy update --catalog
loomy version
loomy version --all
```

Updates Loomy, for every project at once; `update --catalog`: only the model and price catalog; `version --all` lists every install

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

Reports a bug or an idea: prefilled GitHub issue (versions, anonymized project state, no name, goal or task text), sent only after your approval; `--print` shows the text

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
