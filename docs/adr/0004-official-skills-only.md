# ADR-0004: Official skills only

Status: Accepted (2026-10-06)

## Context
Agent skills (Agent Skills format, `SKILL.md`) can ship scripts that run on the user's machine. Loomy 0.12.0 (2026-10-06) added skills chosen at init and at each task. A skill can run commands, reach the network or ask for credentials, and some licences forbid redistribution; Anthropic's `docx`, `pdf`, `pptx` and `xlsx` skills are proprietary and reserved to the vendor's customers.

## Decision
- The only sources are `github.com/anthropics/skills` and `github.com/openai/skills` (`scripts/lib/skills.sh`). The catalog `catalog/skills.conf` lists 24 selected skills, each with source, path, pinned commit, licence, an auto condition and keywords. It is refreshed with `loomy update --catalog`.
- Skills are fetched at the pinned commit from a cached tarball, never at the tip of a branch. Archives are checked (readable, no link, no absolute or `..` path), names are validated, and writes refuse symbolic links.
- Each skill is analysed before installation (`skills_analyse`: scripts, network, deletions, commands run, credentials asked). The result is recorded with the reason in `.loomy/skills.lock`, which is versioned, and logged. A skill that asks for credentials is installed only on request.
- Skill folders are git-ignored, so Loomy never redistributes a vendor's files. The lock restores them at the same commit on another clone (`loomy skills sync`).
- Proprietary skills are opt-in: only `loomy skills add <name>`, after a warning about the user's agreement with the vendor, and only into Claude's skills folder.
- The policy is `loomy config set skills auto|ask|off`; `auto` installs the matching official skills and announces each one.

## Consequences
- Updates are explicit (`loomy skills update`); a catalog commit change shows up as an available update.
- Skills outside the two sources cannot be installed through Loomy.
- The analysis is a keyword search over shipped code, not a sandbox; it informs and does not guarantee safety.

## Alternatives considered
- Any skill from any repository: rejected, since an untrusted script would run on the user's machine.
- Vendoring the skills in Loomy: rejected for licence reasons, as some are proprietary.
- Installing at the tip of the vendors' branches: not reproducible, and would skip the analysis of what is actually installed.
