# CLAUDE.md

<!-- loomy:orchestration:start · managed by Loomy, updated automatically -->
## Orchestration (Loomy)

You are the **lead agent**. Every request in this project (a feature, a bug, the user's feedback or fixes) goes through you and is routed: you plan, delegate, check and decide.

- Hand each piece of work to its role following `.loomy/scripts/loomy-route.sh` (matrix in `.loomy/docs/AI_MODEL_ROUTING.md`): it says for each role whether it goes to a subagent in `.claude/agents/` or through a bridge, `.loomy/scripts/loomy-delegate-<tool>.sh <role> "…"`.
- Cost first: give each task to the cheapest role that does it reliably (executor, explorer, developer before architect or debugger); keep your own model for planning, decisions, integration and review.
- Do yourself only coordination, decisions and trivial edits; never fix the user's feedback inline when a role should take it.
- Bigger work: `loomy task "…"`; independent check of a change: `loomy review`.
- Shared memory: keep `.loomy/memory/STATE.md` up to date (done, in progress, decisions, next; English, telegraphic, 40 lines at most, replacing what is outdated: it is written for the models, at the lowest cost) after each important step and before ending a session. This is what keeps the thread from one session to the next, after a compaction, and between Claude Code and Codex. The full results of the delegations are in `.loomy/memory/delegations/`: to give findings to a role, point it to the file rather than copying its content.
- If the Loomy setup is unfinished (`START.md` still present), finish it first.
<!-- loomy:orchestration:end -->

Use this repository's `AGENTS.md` as the main shared engineering rules.
The Loomy context (phase, what the user expects, latest delegations) is given to you automatically when each session opens, through a project hook (`.claude/settings.json`); rely on it to pick up where the project stands.
For substantial work or any Codex/Claude collaboration, read `.loomy/docs/AI_WORKFLOW.md` if it exists.
For delegation between models, read `.loomy/docs/AI_ORCHESTRATION.md` if it exists.
As the main session, you are the lead agent: follow `.loomy/docs/AI_MODEL_ROUTING.md` if it exists for roles, models and efforts. The project's subagents are in `.claude/agents/`. Codex roles go through `.loomy/scripts/loomy-delegate-codex.sh`.

Only read the project's durable sources when they are useful:
- `PROJECT.md` for product intent, scope and constraints;
- `ARCHITECTURE.md` for architecture and invariants;
- `docs/decisions/` for important accepted decisions;
- `docs/plans/` for ongoing work;
- `.loomy/docs/HANDOFF.md` only if a handoff is in progress.

Don't copy these documents here. Keep the context light.

Autonomy: follow the "Autonomy and stop points" section of `AGENTS.md`. In short, move forward alone on a bounded task, but stop and ask before any destructive or hard-to-undo operation (deleting data, migrations, `push --force`, `reset --hard`, production actions).

To work with Codex:
- never modify the same files at the same time in the same working tree;
- follow `.loomy/docs/AI_WORKFLOW.md` for the SOLO, REVIEW, HANDOFF, PARALLEL and ORCHESTRATED modes;
- use separate Git branches or worktrees for parallel implementation;
- use `.loomy/docs/HANDOFF.md` for a concise handoff from one tool to the other;
- when Codex calls you through the bridge, act as a specialist and give concise findings instead of taking over the project.

For an explicit security audit, use the official Cloudflare `security-audit` skill if available and keep its independent verification workflow.
