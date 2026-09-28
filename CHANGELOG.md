# Changelog

Loomy stays at 0.x until the whole thing has been validated in real conditions. 1.0.0 will come after that validation.

## 0.5.3 — 2026-09-28

### Added
- **Real subscription quotas.** With a Claude or ChatGPT subscription (`loomy config set plan_claude|plan_codex …`), `loomy status` and `loomy watch` show the share of the plan's quota in use (5-hour and weekly windows, with their reset time) instead of a dollar value, and tokens instead of costs for each task; `loomy log` too. With the API, the real cost stays. Mixed setups (one tool on the API, the other on a subscription) are handled tool by tool.
  - Codex: read from the `rate_limits` events Codex writes into its own session logs (end of the latest log only, cached until it changes); "limit reached" is reported.
  - Claude Code: read from the documented `rate_limits` field Claude Code gives its status line command. `loomy init` (and `loomy init --update`) adds a Loomy status line to the project's `.claude/settings.json`, which saves the quota and then shows your own status line when you have one; a status line already set in the project is kept.
  - No network call, no credential read (the private usage endpoint some tools query with your login token is deliberately not used).
- `loomy watch` notifies when a quota crosses 80 %, then 95 %.
- **`loomy stats`**: detailed statistics over the whole history or a period (`--days N`, `--since YYYY-MM-DD`): delegations and success rate, total and average durations, tokens in / from cache / out, Claude Code's own work, then by role, by model (with cache share) and by day, and the plans with this month's API value next to the plan's price.

### Changed
- The plans lines have their own section ("PLANS"), shown even before the first delegation.
- Token counts are shown compactly (12.3k, 4.1M); weekday names follow the interface language.

### Fixed
- `loomy status` stopped with an error on a project without a log once the plans section was reached.
- A French word left in the per-model breakdown ("appel(s)").

## 0.5.2 — 2026-09-27

Security, robustness and good-practice review.

### Security
- `loomy start --watch`: the tracking launch script was written to a predictable path in the temporary folder before being run (a local user could plant a link or swap it); it is now created with `mktemp` (random name, owner-only).
- Values read from `.loomy/brief.md`, which may come from a cloned repository, are stripped of control characters (no escape sequence can reach the terminal), and every brief read goes through the same function.
- The private AI files repository name is always reduced to a plain technical name before reaching `gh` and `git`; technical names can no longer be only dots or start with a hyphen.
- Downloaded catalog and pinned models: a model id must start with a letter or digit, so it can never be read as an option by the CLIs.
- `.claude/settings.json` merge written atomically (temporary file, then replace).
- `SECURITY.md`: what Loomy guarantees, and how to report a vulnerability.

### Fixed
- After Ctrl-C in a menu or the questionnaire, the terminal stayed in raw mode (no line editing for the next programs): the terminal settings are now saved at start and fully restored.
- `loomy uninstall` suggested `rm <clone>/bin/loomy` when a clone's `bin/` is in the PATH, which would damage the clone: it now suggests removing that folder from the PATH (or `install.sh --uninstall`).
- `loomy update` with npm installs the latest release instead of the tip of `main`.
- `loomy assess`: file names with spaces were cut in "most changed files"; large files are found from Git's index (fast on large repositories); sizes in MB / Mo.

### Tests
- Hostile brief (command substitution, backticks, escape sequence, path traversal), catalog option injection, technical names, Ctrl-C terminal restore, uninstall advice for a clone, names with spaces, version consistency across VERSION, package.json, READMEs and CHANGELOG.

## 0.5.1 — 2026-09-27

### Fixed
Found by a screen-by-screen check of every command, in English and French:
- `loomy init` questionnaire: the "save" description and the "separate private repository" label showed raw code (`$save_desc`, `$(t …)`), a regression of 0.4.1.
- `loomy doctor`: the "LOOMY" section (installs found in the PATH) was always empty.
- `loomy route`: the "how to call it" column stayed in French in English ("session principale", "sous-agent"), and the lead agent label overflowed its column; `route markdown` printed a double blank line.
- `loomy start` and `loomy effort` menus: a "Cancel" option (q picks it).
- Views opened from the home screen (AI files visibility…) no longer show two closing lines; screens left in the history no longer repeat the guide line under the title.
- English interface: "lead agent" everywhere (no more "orchestrator"), "Log" instead of "Journal", durations with a decimal point (French keeps the comma), "START.md:" / "START.md :" and "(lead: …)" / "(lead : …)" per language.
- Tests: no raw code or French left on screens, installs listed by `doctor`, route without French, single blank lines.

### Removed
- Unused `_ui_len` helper.

## 0.5.0 — 2026-09-27

### Added
- **Adopting an existing project.** `loomy init` on a project that already has files:
  - **dedicated branch**: on a Git repository with a history, Loomy switches to `loomy/adopt`, created from the current branch, which stays untouched; uncommitted work stays as it is and is flagged so that it is never committed by the agents. `--no-branch` stays on the current branch;
  - **assessment without AI** (`.loomy/assessment.md`, also shown as a setup step): languages, frameworks and dependencies, lock files, structure, real test / lint / build commands (package.json scripts, Makefile, Cargo, Go, Maven, Gradle, Swift, Flutter), test files, CI, conventions and existing agent instructions, documentation, Git history (commits, activity, authors, remotes, branches, conventional commits, most changed files), sensitive paths, files that look like committed secrets, TODO / FIXME markers, large files, size and estimated risk;
  - **adoption plan** in START.md ("Existing project" section, English and French): nothing existing is overwritten, no application code change without approval, `PROJECT.md`, `ARCHITECTURE.md` and ADRs rebuilt from the code, `AGENTS.md` and `CLAUDE.md` aligned with the repository's real commands and conventions, roles, routing and effort sized to the project's size and risk, existing checks run as a baseline, commit on the adoption branch and a pull request offered towards the original branch;
  - the brief records `adopt_branch` and `base_branch`, and tells the agent to stay on the adoption branch.
- **`loomy assess`**: runs the assessment again at any time (`--print` to only show it).
- Tests: adoption of a React/TypeScript project with two authors, CI, a committed `.env` and uncommitted work; `--no-branch`; project without Git; French assessment.

## 0.4.1 — 2026-09-27

### Changed
- **English first.** Loomy is written in English and translated into French, instead of the other way round:
  - interface strings are English in the code (`t "English sentence"`), and the French translations live in `scripts/lib/i18n/fr.tsv` (compiled into `fr.sh` by `tools/i18n-build.sh`);
  - `--help` of every command, startup brief, resume context, delegation prompts and bridge messages go through the same dictionary;
  - the documents the agents read (`START.md`, templates, Claude subagents, role catalog, skills) are in English; the French copies live in `fr/` and are installed when French is detected;
  - README in English (`README.md`), French in `README.fr.md`; changelog, code comments and tests in English.
- French is still picked automatically when the system language starts with `fr` (or with `loomy config set lang fr`).
- English interface: "log" instead of "journal".

### Fixed
- Some `loomy init` hints (starting point, collaboration mode, main tool, GitHub repository) and the plan descriptions stayed in French in the English interface; the coverage check missed them and now sees them.
- Help lines starting with a hyphen broke the translation of formatted strings.

## 0.4.0 — 2026-09-27

### Added
- **English and French interface.** Language detected automatically (`LC_ALL`, `LC_MESSAGES`, `LANG`, then the macOS system language): French when it starts with `fr`, English otherwise, and English when nothing can be detected. Setting: `loomy config set lang fr|en|auto` (or `LOOMY_LANG`).
- Every screen is translated: frame and home, `status`, `watch`, `log`, `start`, `effort`, `feedback`, `privacy`, `route`, `doctor`, `init` and its questionnaire, setup, help, `config`, `update`, `version` and uninstall.
- Dictionary `scripts/lib/i18n/en.tsv` (the French sentence was the key, falling back to French when a translation was missing), compiled by `tools/i18n-build.sh`; `tools/i18n-missing.sh` lists the untranslated sentences.
- The project documents language is suggested from the interface language.
- Tests: language detection, English screens, compiled dictionary up to date, full translation coverage.

### Changed
- Menus rely on the position of the choice instead of its label, to work in both languages.

### Not covered
- Agent-facing texts (brief, prompts, delegation script messages) stayed in French (done in 0.4.1).

## 0.3.8 — 2026-09-25

### Added
- **Fallback chains per model tier** in the catalog (`model.claude.mid=claude-sonnet-5-5, claude-sonnet-5`): the first model available on the machine is used, the next ones are fallbacks for people without access to the latest models.
- **Availability learnt on each machine**: Codex's local model list; `loomy doctor --live` tests each model of the chains and remembers the result; a refused delegation (model doesn't exist or no access) records the model as unavailable and moves straight on to the next one.
- **Model pinned per machine**: `loomy config set model.<claude|codex>.<top|mid|fast> <model>` (`auto` to go back to the catalog).
- **Rebalancing without a new version**: `route.<family>.<role>=<TIER> <effort>` in the catalog.
- **New catalog flagged** on the home screen and in `loomy doctor` (background check, at most once a day; `LOOMY_CATALOG_CHECK=0` turns it off).
- **Model update protocol** in `docs/MODEL_CATALOG.md`.

## 0.3.7 — 2026-09-25

### Added
- **Autonomy and stop points** in the instructions generated for the agents, following Anthropic's recommendations for Opus 5.5: dedicated section in the `AGENTS.md` template (move forward alone on a bounded task; stop and ask before any destructive or hard-to-undo operation — deleting data, migrations, `push --force`, `reset --hard`, production actions — when an error comes back, or before going beyond the scope; keep permission prompts; progress list and verified / inferred / not tested summary for long tasks). Reminder in `CLAUDE.md` and instruction in START.md.
- Roadmap: `TASKS.md` progress file added to the `loomy task` work.

## 0.3.6 — 2026-09-25

### Fixed
- **Terminals without a separate screen** (the Claude app's, `TERM_PROGRAM=claude-desktop`): Loomy showed up after the previous commands, which stayed visible when scrolling up. The terminal screen and history are now cleared on entry and on exit: Loomy is alone on screen, its header at the very top; on exit, only the result (if any) remains. Setting: `loomy config set screen auto|alt|clear` (or `LOOMY_SCREEN`).

## 0.3.5 — 2026-09-25

### Changed
- **A fixed-frame interface, consistent everywhere.** Loomy's interactive screens (`loomy`, `init` and its questionnaire, setup, `start`, `effort`, `feedback`, `doctor --fix`, `watch`) show in the same frame: fixed header (logo, title, context: project, current question, tracking time), fixed footer (useful keys, version), and a body that is the only area that changes. No more stacked screens or repeated logo.
- **The home screen (`loomy`) is a real app**: detailed status, log, AI files visibility and help open inside the frame, with scrolling (↑↓, space, b), then ⏎ or ← goes back home; q quits from anywhere. On exit, the terminal is back as it was.
- **On leaving a screen that produces a result** (end of `init`, `start` commands, `effort` setting…), only that result stays in the history, under its title, without logo or earlier checks. Moving from one screen to another leaves nothing.
- **Direct commands** (`loomy status`, `route`, `privacy`, `doctor` without `--fix`): normal output, like `git status`, without switching screens.
- `loomy watch`: frame header (project, "live tracking", time) and footer (keys); ↑↓ scroll the body.
- Menus: the q key picks "Quit" or "Cancel" directly.

### Fixed
- Terminals reporting a zero size: 80 × 24 by default (the body stayed empty).
- The `loomy init` check no longer offers to set up git access to the Loomy repository (unrelated to the project being created); `loomy doctor` still does.
- Lines too long for the viewer are cut to the screen width.

## 0.3.0 — 2026-09-25

Second roadmap step: make it reliable.

### Changed
- **No more script copies in projects.** `.loomy/scripts/` only holds small relays (same names, same arguments) to the installed Loomy, found through `$LOOMY_HOME`, the `loomy` command or its usual locations. A Loomy update applies right away to every project; `loomy init --update` is only for new document templates (and once, to convert pre-0.3 projects: `loomy status` flags it). The version warning on every update is gone.

### Added
- **Real Claude Code cost**: `Stop` (lead agent replies) and `SubagentStop` (native subagents) hooks. Tokens are read from the session transcript (no duplicates, no rereading), and the cost is computed at public price, 5 min or 1 h cache writes included: identical to the cost Claude Code reports. Shown in `loomy status` and `loomy watch`, counted in the plan value and in the bootstrap summary. Loomy delegations aren't counted twice (nor recorded as sessions).
- **Model and price catalog updated without a new version**: `loomy update --catalog` fetches `catalog/models.conf` from the repository; read line by line (never executed), used when newer. `loomy doctor` shows its date and warns after 60 days.
- **Log archived every month** (`.loomy/logs/archive/`); `loomy log --since YYYY-MM-DD` goes back through the archives; `loomy log --csv` exports costs (delegations and Claude Code, without the task text).
- Existing projects get the new hooks through `loomy init --update`, merged without touching your own hooks.

### Continuous integration
- Linux only (macOS is tested locally before each release).

## 0.2.0 — 2026-09-25

First roadmap step: consolidate before testers arrive.

### Added
- **`loomy feedback`**: prepares a GitHub issue with your message and the useful context (versions of Loomy, the system, bash, git, Claude Code, Codex and gh; project type, stage, AI mode and phase; latest log events). Anonymised: no name, goal, path or task text. Preview, then your choice: create the issue, open it prefilled in the browser, copy the text or cancel. `--print` only prints the text.
- **`loomy doctor --fix` handles GitHub**: installs `gh` (Homebrew), runs the login (`gh auth login`), then checks that git really reaches the Loomy repository (private during the pre-release) and runs `gh auth setup-git` if needed; otherwise reminds the invitation link.
- **Automatic tests on macOS and Ubuntu** on every push (GitHub Actions); the 276 checks pass on both.

### Fixed
- **`loomy start --watch` no longer closes a session already open** for the same project: it offers to join it (default), open another one alongside, or cancel.
- **Temporary tracking scripts**: each one deletes itself as soon as it starts; leftovers from previous versions are cleaned up.
- Log dates read the same way on macOS and Linux (the "Project ready" summary only worked on macOS).
- README: macOS announced, Linux "tested automatically, not validated in real use yet".

## 0.1.31 — 2026-09-25

### Changed
- Titles and project name in the brand's light purple, bold: visible even in terminals (or through tmux) that don't show bold.

## 0.1.30 — 2026-09-25

### Changed
- **A single logo in the terminal**: the two-thirds logo (3 lines, proportions and style of the original drawing) replaces the large one everywhere (home, status, start, questionnaire, help, tracking). The SVG logos of the documentation don't change.
- **Titles and project name in bold bright white** (PHASES, ACTIVITY, GIT, screen titles, questionnaire groups, project name in headers): clearly visible even in a terminal that renders bold poorly.

## 0.1.29 — 2026-09-25

### Changed
- Small logo of the compact view redrawn at two thirds of the large one: same proportions and style (3 lines, no distortion), followed by a blank line.

## 0.1.28 — 2026-09-25

### Changed
- Small logo of the compact view: exactly the pixels of the large logo, four per character (half width), instead of a simplified drawing.

## 0.1.27 — 2026-09-25

### Changed
- Compact view of `loomy watch`: small logo (half size, three lines), same drawing and same blinking cursor.

## 0.1.26 — 2026-09-25

### Changed
- The Loomy logo also heads the compact view (`loomy watch` in a pane), and its purple cursor blinks with each refresh, like a terminal cursor.

## 0.1.25 — 2026-09-25

### Added
- **`loomy effort`**: sets the reasoning effort of the project's lead agent (`loomy effort low`, or a menu without argument), or of another role (`loomy effort executor high`). Takes priority over the brief's profile, saved in `.loomy/efforts`, used at the next `loomy start` (new session or resume) and by the following delegations. `--list` shows every role, `--reset` goes back to the profile.
- Help: `loomy log` and `loomy watch` descriptions updated.

## 0.1.24 — 2026-09-25

### Fixed
- **Compact tracking in `loomy start --watch`**: lines wrapped and broke the rail. The pane inherited the screen of the process that opened it; it now opens its own. On top of that, each `loomy watch` line is cut to the terminal width ("…"), even in a terminal that ignores turning off line wrap.
- **Resumed session seen as closed**: `claude --continue` keeps the session id; a new start after an end now counts as an open session.
- In the tracking pane, the `s` key (open a session) is no longer offered: the agent is already alongside.

## 0.1.23 — 2026-09-25

### Added
- **A livelier `loomy watch`**: refreshed every second; running delegation with spinner, timer and progress estimated from past delegations of the same role on the same model ("▰▰▰▱▱▱ 45 s / ~1 min 40 s", "longer than usual" beyond that); new phase and just-finished delegation highlighted (✦) for a few seconds.
- **Notifications** (macOS) and beep: phase change (with what is expected from you), failed delegation, bootstrap finished, lead agent session closed in the middle of the bootstrap. `loomy config set notify no` turns them off.
- **Keys in `loomy watch`**: `c` compact or full view, `l` log, `s` open the session, `q` quit; the footer stays visible even when the full view overflows.
- **Final summary**: "✦ Project ready · bootstrap in 42 min · 8 delegations · $0.80".
- **Readable `loomy log`**: phases, delegations (duration, cost), sessions, in local time; `--raw` for JSON.

## 0.1.22 — 2026-09-25

### Added
- **`loomy start --watch`**: the lead agent session and live tracking in the same terminal, side by side (≥ 160 columns) or one above the other. Already in tmux: a pane opens alongside; iTerm2: native pane; otherwise a dedicated tmux session (mouse on, everything closes with the agent); Terminal.app without tmux: a second window. Tracking closes by itself at the end of the session. `loomy config set start_watch yes` to get it every time.
- **Compact view of `loomy watch`** (`--compact`): timeline, "Your turn", session, running delegations and the last 3, Git on one line. Picked automatically in a small terminal or a pane; `--full` for the full view.

### Fixed
- Delegation times shown in local time (they were in UTC).

## 0.1.21 — 2026-09-25

### Added
- **Live setup at the end of `loomy init`.** The steps (Git repository, GitHub repository, brief, AI files, session) are announced in advance, with a progress bar, a spinner and a timer on the current step, and each step's duration.
- **Live check**: each slow check (Claude Code, Codex, GitHub login, real model test) shows an animated line with its timer, instead of dead time.
- The lead agent announces each phase ("Phase 6/10 · Build") and each delegation, before (role, model, task, rough duration) and after (result, duration): the user always knows what is going on.

### Fixed
- **Much snappier questionnaire**: moving from one question to the next in ~60 ms instead of 0.4 to 2.2 s, arrows in ~17 ms, in terminals without a declared UTF-8 locale. The UTF-8 locale was never picked because of `pipefail`, which slowed down every text measurement and sometimes split an accented character in two.
- Texts truncated by characters, whatever the locale.
- CLI output checks (delegation error, model output, files tracked by Git) reliable even on very long outputs.

## 0.1.20 — 2026-09-25

### Changed
- `loomy status` and `loomy watch`: a blank line under the phase timeline, for breathing room.

## 0.1.19 — 2026-09-25

### Changed
- **Full-screen interface, updated in place.** Interactive commands (`loomy`, `loomy init`, `loomy start`, `loomy watch`, menus) show in the terminal's alternate screen, like an app: each update redraws the same screen, nothing piles up in the scrollback, and lines that are too long are cut instead of wrapping. On exit, the normal screen comes back with, once, the last screen shown. `LOOMY_NO_CLEAR=1` keeps the old line-by-line display.
- `loomy watch`: `q` to quit (Ctrl-C still works); no more copy of the screen in the history at each refresh.

## 0.1.18 — 2026-09-25

### Fixed
- Malformed `VERSION` file in 0.1.17.

## 0.1.17 — 2026-09-25

### Fixed
- **Project created in a folder already inside a Git repository** (for example `~/Projects`): `loomy init` offers a dedicated Git repository for the project (recommended), or staying in the parent repository (monorepo). Before, the GitHub repository failed without explanation.
- The reason a `gh repo create` failed is shown.

### Added
- `loomy init` in a folder that is itself a Loomy project: new "Create a new project in a subfolder" option.

## 0.1.16 — 2026-09-24

### Fixed
Defects found by a full real walkthrough (init, lead agent, delegations, commit, push):
- Fast typing during a question was printed in a mess on screen: terminal echo is off during questions.
- A brand-new folder was detected as an "existing project" because of the `.claude/` and `.codex/` folders created by Loomy.
- Outside a UTF-8 locale, a truncated text could split an accented character: Loomy picks an available UTF-8 locale.
- Agents are asked to run delegations in the foreground (START.md, ORCHESTRATION.md, resume context): in the background, they stopped when the session closed.

## 0.1.15 — 2026-09-24

### Added
- **Automatic resume with Codex too.** `loomy init` installs the same hooks for Codex (`.codex/hooks.json`): context passed on opening, session recorded on opening and closing, AI files backed up in private repository mode. Checked with the real Codex and Claude Code CLIs. On first launch, Codex asks to trust the folder and then to approve the hooks; `loomy start` reminds you.
- `.codex/` is part of the AI files (local and private repository modes).

## 0.1.14 — 2026-09-24

### Added
- **Automatic session resume.** `loomy init` installs Claude Code hooks (`.claude/settings.json`, merged with an existing file): each session opened in the project automatically gets the Loomy context (phase, what the user expects, latest delegations, Git), and its closing is recorded; in private repository mode, the AI files are backed up on closing. Codex reads this context (`.loomy/scripts/ai-context.sh`) as asked by `AGENTS.md` and the `loomy start` prompt.
- **`loomy` without argument: home screen.** In a project: where it stands, what is expected, and a choice for what's next (open or resume the session, track, status, AI files). Outside a project: create a project, check the machine.
- `loomy status`, `watch` and the home screen show whether the lead agent session is open, and since when; the "Your turn" instruction takes it into account.
- **GitHub repository named after the project.** The questionnaire offers to create it (private or public; never in `--yes` mode), with a name derived from the project to confirm or change. In separate private repository mode, the AI files repository name is offered too, and both are confirmed together. `loomy privacy private` offers the name for approval (`--name` to force it).

### Changed
- A single technical name for everything (`slug` in the brief): created folder, GitHub repository, private AI files repository (previously named after the folder). An existing repository with a different name is flagged in the questionnaire and the brief, without being renamed.
- `loomy privacy restore` sets aside different local files (`.loomy/restore-backup-…`) instead of failing.

## 0.1.13 — 2026-09-24

### Changed
- **No need to create the folder before `loomy init` anymore.** Without a folder, `loomy init` asks for the project name and offers: a new folder named after it (`./project-name`, without accents or spaces), the current folder (offered by default when empty or looking like a project), or another location. `loomy init my-project` creates the folder if it doesn't exist.
- End of the questionnaire: `cd` reminder when the project is elsewhere than the starting folder, `loomy start` highlighted, and an offer to open the lead agent session right away, in the project folder.
- README: quick start without the `mkdir` step.

### Fixed
- A word longer than a box's width (a path, for example) overflowed it: it is now cut.

## 0.1.12 — 2026-09-24

### Added
- **AI files visibility** (`AGENTS.md`, `CLAUDE.md`, `.ai/`, `.claude/`, `.loomy/`, `START.md`), chosen in the questionnaire and changeable with `loomy privacy`:
  - **versioned** with the project (default; recommended for a private repository);
  - **local**: excluded through `.git/info/exclude`, invisible in the repository;
  - **separate private repository**: excluded from the project and backed up in a private GitHub repository `<project>-ai` (or any URL with `--remote`), which only tracks these files, directly in the project folder. `loomy privacy sync` backs up, `loomy privacy restore` gets them back on another machine.
  The default depends on the GitHub repository visibility. Files still tracked are flagged, with the command to stop tracking them without deleting them. `loomy status` flags a late backup or a missing exclusion.
- The brief passes the mode to the lead agent: never force-add these files, and back up the private repository at the end of each step.

## 0.1.11 — 2026-09-24

### Added
- `loomy uninstall`: the uninstall command for each install found, and how to remove Loomy from a project.
- `loomy help <command>`: help for one command.

### Changed
- **Larger phase timeline**: ten wide boxes (█ done, ▓ in progress, ░ upcoming) across the full width, and the current phase name under its box.
- Commands find the nearest Loomy project by walking up from the current folder: a project can live in a subfolder of a Git repository, and `loomy status`, `start`, `brief` and delegations find it from any subfolder.

### Fixed
- `loomy brief` outside a Loomy project created an isolated brief: it now points to `loomy init`.
- Redoing the questionnaire midway reset the phase to "Discovery": the current phase is kept.
- `loomy init` in the home folder or at the disk root is refused.
- `loomy update --help` ran the update.

## 0.1.10 — 2026-09-24

### Added
- **Install detection**: `loomy version --all` and `loomy doctor` list each `loomy` in the PATH (Homebrew, npm, bun, shell script), show the one in use and give the command to remove the others. `loomy version` and `loomy update` flag when there are several.
- `loomy init`, `brief`, `start`, `status`, `watch` and `doctor` clear the screen before printing (interactive terminal only; `LOOMY_NO_CLEAR=1` to keep the history).

### Changed
- `loomy update` with npm reinstalls into the same folder as the original install, even if the active Node version changed (nvm).
- README: one command per block, to copy the right one directly (quick start in steps, one install method per block, plans, CLI install).

### Fixed
- `loomy start` failed when opening the session ("tool_label?: unbound variable") with macOS bash outside a UTF-8 locale. Every variable followed by an accented character is checked by the tests, which also run `loomy start` in the C locale.

## 0.1.9 — 2026-09-24

### Fixed
- An npm install made with Homebrew's Node (`/opt/homebrew/lib/node_modules`) was taken for a Homebrew install: `loomy update` then ran `brew upgrade` and failed. Detection checks `node_modules` first, and only keeps Homebrew for an installed formula (`Cellar`).
- `loomy update` calls Homebrew with the full formula name (`eydenn/tap/loomy`) and, on failure, shows the detected method and the command to run by hand.

## 0.1.8 — 2026-09-24

### Added
- **`loomy start`**: starts or resumes the lead agent session. It detects a previous session of the project on the machine and offers to resume it (`claude --continue`, `codex resume --last`) or open a new one with the prompt suited to the phase: bootstrap start, resume at the recorded phase, or everyday work. `--resume`, `--new`, `--print`; in print mode, instructions for the desktop apps.
- **`loomy init` on a project already set up**: instead of refusing, offers to resume, update, redo the questionnaire or reset. `--update` (project Loomy files upgraded; brief, phase and log kept) and `--reset` (bootstrap started over, old answers as defaults) options.
- `loomy update` reminds you to upgrade each project; `loomy status` flags a project left on an older version.

### Changed
- **Guided phases** in `loomy status` and `loomy watch`: one-line timeline (●━◉━○…), current phase, what the lead agent does and "Your turn:" what the user must do; notes when activity or AI files are still empty. Single source: `scripts/lib/phases.sh`.
- `START.md` asks the lead agent to record each phase before any other action and to tell the user what it expects from them.
- README: new "Moving your project forward" section (open or resume the session in the terminal or the apps, phases and the user's role, everyday development, update and reset); what is really live in the tracking.

### Fixed
- `loomy start` and reading the phase failed on a project that hadn't recorded any phase yet.
- The "Other" project type showed as "other" in `loomy status`.
- Sessions are found on the project's real path (symlinks resolved), as Claude and Codex record them.

## 0.1.7 — 2026-09-24

### Changed
- **Ideal requirement: Claude Code and Codex installed in the terminal.** `loomy doctor` shows each detected CLI with its location; for a missing CLI, it gives the official install commands (recommended installer, Homebrew or npm alternative) and the first login. `loomy doctor --fix` offers to run the install.
- README: ideal requirements detailed, with the install commands of both CLIs.

## 0.1.6 — 2026-09-24

### Changed
- Loomy's description rewritten everywhere (help, README, npm, GitHub, Homebrew formula): Loomy starts and structures projects (questionnaire, agent-ready structure), then moves them forward (lead agent and dedicated roles, live tracking).
- `loomy init` is described for what it does: create or set up a project, new or existing.

## 0.1.5 — 2026-09-24

### Fixed
- A bun install in a custom folder (`BUN_INSTALL`) was recognised as an npm install: `loomy update` then used npm instead of bun.
- Tests: the install method (npm, bun, Homebrew) is checked for each location.

## 0.1.4 — 2026-09-24

### Changed
- **A single style for every command**: logo, `┌` opening line, `◇` sections in capitals, purple `│` guide line and `└` closing line with the useful shortcuts. Applies to `loomy status` and `loomy watch`, `loomy doctor`, `loomy route`, `loomy worktrees` and `loomy init --no-wizard`, on top of the questionnaire and help.
- `loomy status`: the phase timeline, which overflowed, becomes a progress bar with the current phase and the next ones.
- Messages point to the `loomy` commands (`loomy route`, `loomy doctor`) rather than the internal scripts.
- Outputs meant for machines or agents stay plain text: `loomy log`, `loomy config list`, `loomy version`, bridge messages, `loomy route markdown`.

## 0.1.3 — 2026-09-24

### Changed
- **`loomy` help** structured like the questionnaire: logo, Project / Tracking / Machine groups, commands in bold, arguments in colour, descriptions aligned and wrapped to the terminal width (under the command below 80 columns). Written to standard output, without colours when redirected.
- `--help` works for every command, including `log`, `config`, `delegate` and `worktrees`.

### Fixed
- `loomy worktrees --help` created two worktrees named "--help": help is now handled, and a task name must start with a letter or a digit.
- The help still mentioned `loomy route json`, which was removed.

## 0.1.2 — 2026-09-24

### Changed
- **New questionnaire rendering**, without dependencies (gum is no longer used):
  - questions grouped by theme (Project, Requirements, AI team, Deliverables, Plans), finished groups folded on one line;
  - each question as a card: why it matters, the options, and a "What it implies" box following the hovered option;
  - back to the previous question with ←, answer already given kept;
  - recap and next steps in the same style.
- **Logo**: terminal-style pixel grid, in the README (light and dark themes) and at the top of `loomy` commands (half blocks, prompt and cursor in purple).
- `loomy doctor --live` tests every model of each installed CLI; a failure only blocks for a model used by the project.
- README: Method, Role and Model columns without wrapping; update summarised under the install table.

### Fixed
- An empty folder was detected as an "existing project" because of the `.gitignore` added by Loomy.
- Without a terminal (redirected output), the display wrote "/dev/tty: Device not configured".
- Tests: routing environments are really checked one by one; new test for going back in the questionnaire.

## 0.1.1 — 2026-09-24

### Fixed
- Homebrew install: since Homebrew 7, downloading happens in a sandbox without access to the macOS keychain, and the private repository could no longer be cloned. The formula now gets the GitHub token through `HOMEBREW_GITHUB_API_TOKEN`, only for the download; `loomy update` provides it automatically from `gh auth token`.

## 0.1.0 — 2026-09-24

First pre-release, 100% terminal.

### Content
- **`loomy` command**: `init`, `brief`, `doctor`, `route`, `delegate`, `status`, `watch`, `log`, `config`, `worktrees`, `update`, `version`.
- **Install**: Homebrew (private tap), npm, bun (release archive) and shell script. `loomy update` detects the method used.
- **Questionnaire** (`loomy init`, `loomy brief`): twelve questions in French, each with the consequence of each choice; a thirteenth, the first time, for the Claude and ChatGPT plans. Non-interactive mode (`--yes`, `--answers`) and display with or without gum.
- **Check** (`loomy doctor`): minimum CLI versions, Codex CLI shipped with the ChatGPT and Codex apps, guided fixes (`--fix`) and a real call to each routed model (`--live`).
- **Lead agent + roles routing**: the lead agent on the best model, eight roles on the cheapest reliable model and effort, three budget profiles, four environments (full Claude, full Codex, hybrid with either one as lead) and automatic fallback when a CLI is missing. Rationale in `docs/MODEL_CATALOG.md`.
- **Bridges**: `delegate-to-codex.sh` (writing roles in the `workspace-write` sandbox, the others read-only) and `delegate-to-claude.sh` (read-only).
- **Log** (`.loomy/logs/events.jsonl`, local, excluded from Git): start and end of each delegation with role, model, effort, duration, tokens and cost (real for Claude, estimated for Codex), and phase changes.
- **Live tracking in the terminal** (`loomy status`, `loomy watch`): phases, running delegations with their timer, cost per model, plans (API cost, or value consumed against the subscription price), latest delegations, Git.
- **Test suite** (`tests/run.sh`): every command in real conditions, without network or token, thanks to `claude` and `codex` doubles.
