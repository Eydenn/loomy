# CLAUDE.md

Use this repository's `AGENTS.md` as the main shared engineering rules.
The Loomy context (phase, what the user expects, latest delegations) is given to you automatically when each session opens, through a project hook (`.claude/settings.json`); rely on it to pick up where the project stands.
For substantial work or any Codex/Claude collaboration, read `.ai/AI_WORKFLOW.md` if it exists.
For delegation between models, read `.ai/AI_ORCHESTRATION.md` if it exists.
As the main session, you are the lead agent: follow `.ai/AI_MODEL_ROUTING.md` if it exists for roles, models and efforts. The project's subagents are in `.claude/agents/`. Codex roles go through `.loomy/scripts/delegate-to-codex.sh`.

Only read the project's durable sources when they are useful:
- `PROJECT.md` for product intent, scope and constraints;
- `ARCHITECTURE.md` for architecture and invariants;
- `docs/decisions/` for important accepted decisions;
- `docs/plans/` for ongoing work;
- `.ai/HANDOFF.md` only if a handoff is in progress.

Don't copy these documents here. Keep the context light.

Autonomy: follow the "Autonomy and stop points" section of `AGENTS.md`. In short, move forward alone on a bounded task, but stop and ask before any destructive or hard-to-undo operation (deleting data, migrations, `push --force`, `reset --hard`, production actions).

To work with Codex:
- never modify the same files at the same time in the same working tree;
- follow `.ai/AI_WORKFLOW.md` for the SOLO, REVIEW, HANDOFF, PARALLEL and ORCHESTRATED modes;
- use separate Git branches or worktrees for parallel implementation;
- use `.ai/HANDOFF.md` for a concise handoff from one tool to the other;
- when Codex calls you through the bridge, act as a specialist and give concise findings instead of taking over the project.

For an explicit security audit, use the official Cloudflare `security-audit` skill if available and keep its independent verification workflow.
