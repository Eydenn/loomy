# Design notes

Loomy separates the temporary bootstrap behaviour from the repository's permanent instructions.

- `START.md`: temporary setup and orchestration contract.
- `templates/AGENTS.md`: compact project rules for Codex.
- `templates/CLAUDE.md`: compact compatibility layer for Claude Code.
- `skills/project-bootstrap/`: reusable workflow, with progressively loaded references.
- `external-skills/`: integrations that must stay current with their original source.
- `fr/`: French copies of the agent-facing documents above, installed when French is detected.
- `scripts/`: deterministic setup tools.
- `scripts/init-wizard.sh`: terminal questionnaire that collects the easy, high-impact answers before spending a single token. It writes `.loomy/brief.md`, which the agent treats as an interview already held. `ai-status.sh` makes the bootstrap phases and the delegation activity visible.
- `scripts/lib/models.sh` and `ai-route.sh`: the lead agent and roles routing engine. It is the single source of truth for each role's model and effort in each environment. Its rationale is in `docs/MODEL_CATALOG.md`.
- `ai-doctor.sh`: checks that the machine can really run the routed models before spending tokens on the bootstrap.

- `bin/loomy`: single entry point, installed by npm, bun, Homebrew or `install.sh`. It calls the scripts above on the current project.
- `scripts/lib/i18n.sh` and `scripts/lib/i18n/fr.tsv`: interface language. Strings are English in the code (`t "English sentence"`); the French dictionary is compiled into a `case` function by `tools/i18n-build.sh`, fast even in bash 3.2. `tools/i18n-missing.sh` lists what isn't translated yet.
- `scripts/lib/journal.sh`: local activity log (`.loomy/logs/events.jsonl`). The bridges write an event at the start of each delegation (with the bridge's pid) and one at the end (same id); `ai-status.sh` derives the running delegations from it and discards those whose process is gone. Tracking stays in the terminal (`loomy watch`), without dependencies, and never starts on its own.
- `scripts/lib/config.sh`: user preferences (`~/.config/loomy/config`): Claude and Codex plans, to compare the API value consumed with the subscription price, language, screen mode, pinned models.
- `scripts/lib/phases.sh`: the ten bootstrap phases, each with what the lead agent does and what the user must do. Single source for `loomy status`, `loomy watch` and `loomy start`.
- `scripts/ai-start.sh` (`loomy start`): opens or resumes the lead agent session. It finds the folder's previous session on the machine (Claude stores its conversations per folder, Codex records each session's folder) and picks the prompt from the phase.
- `scripts/install-into-project.sh` (`loomy init`): on a project already set up, offers to resume, update (`--update`, brief, phase and log kept) or reset (`--reset`).
- `scripts/ai-privacy.sh` and `scripts/lib/privacy.sh` (`loomy privacy`): AI files visibility. Local mode: exclusion in `.git/info/exclude`, specific to the copy and invisible in the repository. Private mode: a second Git repository (`.loomy/ai.git`) whose working tree is the project itself and which only tracks the AI files; no copy, `sync` replays the changes on top of another machine's before pushing.
- `scripts/ai-context.sh`: resume context (phase, expectations, delegations, Git, AI files). Installed by `loomy init` as Claude Code `SessionStart` and `SessionEnd` hooks (`.claude/settings.json`) and Codex hooks (`.codex/hooks.json`, same format), merged with an existing file. Codex only runs a project's hooks once the folder is trusted and the hooks approved (it asks on first launch); the Codex hook command walks up from the session folder to the Loomy project. Session openings and closings go to the log; `loomy start` also records Codex sessions, whose process keeps its pid after `exec`.
- `scripts/ai-home.sh`: `loomy` without argument, the home screen leading to the next action.
- `scripts/lib/usage.sh`, `scripts/ai-statusline.sh` and `scripts/ai-stats.sh` (`loomy stats`): subscription quotas and usage figures. Codex quotas come from the `rate_limits` events in its session logs (end of the latest log, cached in `~/.config/loomy/codex-limits`); Claude quotas from the documented `rate_limits` field of the status line input, saved to `~/.config/loomy/claude-limits` by the project status line (which then runs the user's own status line, remembered by `loomy init` in `~/.config/loomy/statusline-user`). With a subscription, status and log show quota shares and tokens; with the API, costs.
- `scripts/ai-assess.sh` (`loomy assess`): assessment of an existing project, without AI, written to `.loomy/assessment.md`. `loomy init` runs it on an existing project, after switching a Git repository with a history to a dedicated `loomy/adopt` branch (the base branch is remembered in `branch.loomy/adopt.loomy-base`); START.md's "Existing project" section turns it into an adoption plan.
- Project technical name (`slug` in the brief, `loomy_slug`): a single source for the created folder, the GitHub repository (`repo_name`) and the private AI files repository (`ai_repo_name`).
- `tests/run.sh`: end-to-end test suite, without network or token (`claude` and `codex` doubles in `tests/stubs/`).

The design deliberately avoids preloading every specialised role or a large security workflow into every session.
