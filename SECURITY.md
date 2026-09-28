# Security

## What Loomy guarantees

- **Nothing runs without you.** Loomy never pushes your project repository, force-pushes, merges, deletes a branch or rewrites history. The only push it makes itself is the backup of the AI files to the separate private repository, when you chose that mode (`loomy privacy sync`, and at the end of each session). Creating a GitHub repository, installing a CLI or logging in to GitHub only happens after an explicit answer in the questionnaire or in `loomy doctor --fix`.
- **Existing projects stay intact.** On a Git repository with a history, `loomy init` works on a dedicated `loomy/adopt` branch; the original branch and uncommitted work are left untouched. Existing files are never overwritten: `.claude/settings.json` and `.codex/hooks.json` are merged (an unreadable file is left as is), `.gitignore` only gets one line appended.
- **The model catalog is data, never code.** `loomy update --catalog` reads `catalog/models.conf` line by line against strict patterns (model ids start with a letter or digit, prices are numbers, efforts and tiers come from fixed lists); anything else is ignored.
- **Project files are untrusted input.** Values read from `.loomy/brief.md` (which may come from a cloned repository) are stripped of control characters before being shown, and repository names are reduced to plain technical names before reaching `git` or `gh`.
- **No secret leaves your machine.** `loomy assess` flags files that look like committed secrets without reading or copying their content. The activity log (`.loomy/logs/`, which holds delegated task text) is ignored by Git. `loomy feedback` attaches versions and project settings only, never names, goals, paths, code or task text, and sends nothing without your approval.
- **Quotas are read locally, never with your credentials.** Subscription quotas come from Codex's own session logs and from the `rate_limits` field Claude Code hands to its status line; Loomy never reads your login tokens and never calls private usage endpoints. The project status line Loomy adds is only set when the project has none, and it shows your own status line command when you have one.
- **Temporary files are private.** They are created with `mktemp` (random names, owner-only), never at predictable paths.
- **Agents keep their guardrails.** Delegations to Claude are read-only; Codex roles that write run in the `workspace-write` sandbox; the generated instructions tell agents to stop before any destructive or hard-to-undo operation.

## Reporting a vulnerability

Please don't open a public issue. Contact the maintainer privately (GitHub: [@Eydenn](https://github.com/Eydenn)) with the steps to reproduce; you'll get an answer within a few days.
