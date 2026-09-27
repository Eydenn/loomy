# AGENTS.md

## Mission
Build and maintain this repository with accuracy, relevance, simplicity, maintainability, verification and context economy.

## Shared AI workflow
For substantial work or any Codex/Claude collaboration, read `.ai/AI_WORKFLOW.md` if it exists.
For delegation between models, also read `.ai/AI_ORCHESTRATION.md` if it exists.
You are the lead agent for this repository's AI work: before delegating or picking a model and an effort level, follow `.ai/AI_MODEL_ROUTING.md` if it exists (roles, bridges, escalation).
Don't copy these rules here.

## Session resume
The Loomy context (current phase, what the user expects, latest delegations) arrives automatically at session start through a project hook (`.codex/hooks.json`, `.claude/settings.json`). If it doesn't show up (hooks not approved yet), run `.loomy/scripts/ai-context.sh`. Start by saying in one or two sentences where the project stands and what you propose.
Before closing a session, summarise what was done and the next step. If the AI files live in a separate private repository, back them up with `.loomy/scripts/ai-privacy.sh sync`.

## Project map
- Product context: `PROJECT.md`
- Architecture: `ARCHITECTURE.md` if it exists
- Important decisions: `docs/decisions/`
- Ongoing plans: `docs/plans/`
- Handoff between agents: `.ai/HANDOFF.md`, only if it exists and is current

Only read the sources useful to the current task.

## Working rules
- Inspect before changing; don't guess what the repository can tell you.
- Follow existing conventions before introducing new ones.
- Prefer the smallest correct change.
- Avoid speculative abstractions, unrelated refactorings and unnecessary dependencies.
- Only ask a question when the missing information really changes the implementation or the risk.
- Never claim tests or checks passed if they didn't actually succeed.
- Keep secrets and sensitive data out of code, logs, commits and examples.

## Autonomy and stop points
- For an understood, bounded task, move forward without asking at every step: inspect, change, verify, then report.
- Stop and ask for explicit approval before any destructive or hard-to-undo operation: deleting files or data, migrations, rewriting Git history (`push --force`, `reset --hard`, rebasing a shared branch), major dependency changes, actions on an external or production service.
- Also stop when missing information really changes the result, when the same error comes back after two attempts, or before going beyond the requested scope.
- Don't turn off the tool's permission prompts to go faster.
- For a long task, keep a short progress list (done, in progress, left to do) and finish with what is verified, inferred or not tested.

## Adaptive delegation
By default, the main Codex agent does the work.
Only delegate when the work can be parallelised, needs specialised expertise, benefits from being isolated from the main context, or needs an independent review.
Avoid duplicate work and several agents on the same area without a clear split.

When Claude Code is available and `.ai/AI_ORCHESTRATION.md` allows it, Codex can call Claude as an external specialist: architecture critique, independent review, hard debugging, second security opinion or focused research.
Codex remains the lead agent: check Claude's findings before acting.
Don't use cross-model delegation for trivial tasks.

## Skills
Only use a specialised skill when it matches the task directly.
For an explicit security audit or vulnerability review, prefer the official Cloudflare `security-audit` skill and keep its independent validation workflow.

## Verification
Use the strongest checks available, starting targeted and widening only when justified.
Usual order: targeted tests → types → lint → tests → build → runtime or framework diagnostics.

## End of task
Before declaring the work done, confirm that:
- the request is satisfied;
- the relevant checks have run;
- edge cases and security were considered in proportion to the risk;
- the documentation is up to date if needed;
- no debug, temporary or unrelated change is left.
