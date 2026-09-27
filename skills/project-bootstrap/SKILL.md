---
name: project-bootstrap
description: Sets up or resets a software repository with an adaptive workflow (discovery, interview, approval), hybrid Codex + Claude Code instructions, chosen agents and skills, durable project and architecture documentation, verification criteria, Git checkpoints and bootstrap retirement. Use to create a new project, turn an empty repository into a working project, standardise an existing repository, or when the user asks to initialise, bootstrap or start this project.
---

# Project bootstrap

Use the repository's `START.md` as a temporary control plane if it exists.
Otherwise, follow the same lifecycle described here.

## Lifecycle

1. Discover cheaply before asking questions.
2. Only ask the high-impact questions still open.
3. Present a concise project proposal.
4. Require explicit approval before creating the project, unless the user waived it.
5. Build the minimal coherent project.
6. Only configure the useful agents, skills and tools.
7. Configure the AI operating mode (SOLO, HYBRID, ORCHESTRATED or PARALLEL) to the project's needs.
8. Verify with real checks.
9. Record the durable context in the project documentation.
10. Commit when allowed and possible.
11. Archive or delete the bootstrap instructions.

## Adaptive team

By default, the lead agent works alone. Only add specialists when parallelism, expertise, context isolation or an independent review bring clear value. Avoid multiplying roles.

When Codex and Claude Code are both used, prefer a shared workflow file and thin per-tool entry points, rather than duplicating a large instruction set.

Read `references/orchestration.md` to decide complexity, risk, delegation, review, Codex/Claude collaboration, cross-model orchestration and token budget.
Read `references/documentation.md` to generate the permanent project files.
Read `references/model-routing.md` to choose models, reasoning effort or subagent tiers.
Only read `references/security.md` for a security-sensitive architecture or an explicit audit request.

## Hybrid project layout

For a project that will use both tools, prefer:

```text
AGENTS.md
CLAUDE.md
.ai/AI_WORKFLOW.md
.ai/AI_ORCHESTRATION.md  # when cross-model delegation is enabled
.ai/AI_MODEL_ROUTING.md  # role → model → effort matrix
.claude/agents/          # only the chosen Claude subagents
PROJECT.md
ARCHITECTURE.md          # when justified
.ai/HANDOFF.md           # only during a handoff
```

Don't let Codex and Claude modify the same files at the same time in one working tree. Use separate Git worktrees or branches for parallel implementation, or have one tool implement and the other review.

## Production discipline

Keep the project's permanent instructions compact.
Prefer progressive loading over copying long instructions into `AGENTS.md` or `CLAUDE.md`.
Only generate the files justified by the project's complexity.

## Verification

Never announce a check as passed without running it.
When possible, start with targeted checks before full suites.
After integrating parallel work streams, run the relevant checks again on the integrated result.

## Security audits

For an explicit security audit, prefer the official Cloudflare `security-audit` skill. Don't reimplement a weaker checklist if the skill is available. Keep independent validation and safe execution limits.
