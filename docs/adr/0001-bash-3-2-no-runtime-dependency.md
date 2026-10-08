# ADR-0001: Bash 3.2 with no runtime dependency

Status: Accepted (2026-09-24)

## Context
Loomy is a terminal tool that runs on a developer's machine, mostly macOS, next to Claude Code and Codex. The shell macOS ships is bash 3.2: no associative arrays, no `mapfile`, slow forks. The first release (0.1.0, 2026-09-24) was already "100 % terminal", and the README lists macOS (Linux in CI), bash 3.2 or later and `git` as system prerequisites. Loomy is installed by Homebrew, npm, bun or `install.sh`, and none of these should pull in a runtime to run a command.

## Decision
Every script (`bin/loomy`, `scripts/`, `scripts/lib/`, `tests/run.sh`) is written for bash 3.2 and calls only tools present on a stock macOS or Linux: `awk`, `sed`, `grep`, `tar`, `curl`, `git`, and `perl` for a few migrations. `python3` is optional: a few features use it when present (merging hooks into settings files, reading subagent transcripts, URL-encoding a deep link) and are skipped otherwise. The questionnaire and the full-screen views are drawn by Loomy itself (`scripts/lib/ui.sh`, `scripts/lib/canvas.sh`), without `gum` or similar. The tests (`tests/run.sh`) run complete terminal walkthroughs without network or token, with test doubles for `claude`, `codex` and `gh` in `tests/stubs/`; skills are served from local fixtures. CI runs them on Linux (`.github/workflows/tests.yml`, with `shellcheck`); macOS is tested locally before each release.

## Consequences
- Installing Loomy needs nothing beyond the host's shell and `git`; the same files serve every distribution channel.
- Code avoids bash 4 features and pays attention to bash 3.2 quirks (for example `${var}` before an accented character outside a UTF-8 locale). Performance is handled by design: a compiled `case` dictionary (ADR-0002), a row-string canvas for the agent tree, reading only the end of the log in the status line.
- Data handling is done with `awk` and `sed` on line-oriented files (catalog, lock, log in JSON lines), which keeps formats simple but limits what can be parsed.
- Behaviour that depends on `python3` or `perl` must degrade silently when they are missing.

## Alternatives considered
- A compiled language (Go, Rust): one binary, but it needs a build and release pipeline per platform and a different contribution model; not chosen at the pre-release stage.
- Node.js or Python as the runtime: richer parsing, but a hard dependency on a machine that may have neither; npm and bun are only distribution channels.
- Requiring a newer bash (Homebrew's): rejected, since macOS's own bash must work.
