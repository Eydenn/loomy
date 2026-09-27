# AI_WORKFLOW.md

## Goal
Shared operating contract for Codex and Claude Code in this repository.
`AGENTS.md` and `CLAUDE.md` are just each tool's entry points.

## Default mode
A single main agent at a time per working tree.
Only use both models when an independent review, specialised expertise, context isolation, an explicit handoff or truly independent work streams justify the extra cost.

Never let Codex and Claude modify the same files at the same time in the same working tree.

## Shared source of truth
By priority:
1. the user's current instruction;
2. the repository instructions (`AGENTS.md`, `CLAUDE.md`, this file, `.ai/AI_ORCHESTRATION.md`);
3. executable code, configuration and schemas;
4. tests;
5. `PROJECT.md` and `ARCHITECTURE.md`;
6. accepted ADRs;
7. the rest of the maintained documentation.

Flag contradictions instead of settling them silently.

## Working modes

### SOLO
A single main agent handles investigation, implementation and verification.
For small or tightly related tasks.

### REVIEW
Agent A implements. Agent B independently reviews the actual diff or commit.
The reviewer looks for concrete defects: regressions, missed edge cases, security, tests, needless complexity.
They don't reimplement, unless asked.

### HANDOFF
Agent A stops at a clean checkpoint and writes `.ai/HANDOFF.md`.
Agent B checks the repository state and takes over.
Delete or update stale handoffs.

### PARALLEL
Separate Git branches or worktrees, with scopes that don't overlap.
Each agent verifies and commits its work before integration.
Run the project's quality criteria again after integration.

### ORCHESTRATED
The lead agent calls the other model as a specialist, following `.ai/AI_ORCHESTRATION.md`.
Usual uses: review, architecture, debugging, second security opinion, focused research.
The specialist returns findings; the lead agent checks, decides and integrates.

## Git coordination
Suggested branch naming:
- `codex/<task>`
- `claude/<task>`

Before parallel work:
1. create a clean base commit;
2. define who owns which files or areas;
3. create separate worktrees or branches;
4. give both agents the same brief and the same acceptance criteria;
5. require each to commit before integration.

Never rely on uncommitted changes as the only way to hand over.

## Handoff content
Only record:
- the goal;
- the finished work;
- the changed files and the commit;
- the checks and their results;
- open issues and risks;
- the exact next action.

Don't paste conversation history or copy the repository documentation.

## Planning and delegation
- SIMPLE: inspect → implement → verify.
- STANDARD: short plan → implement → verify → optional independent review.
- COMPLEX or HIGH risk: explicit work streams → isolated scopes → verification → independent review → integration.

Only use subagents or cross-model calls when their value exceeds the coordination and token cost.

## Context and token discipline
- Search before reading broadly.
- Only read the useful files and sections.
- Reuse durable documentation rather than retelling history.
- Don't load unrelated skills.
- Prefer concise state or handoff files over rereading conversations.
- Keep the root instruction files short.
- Prefer one focused call to another model over repeated back-and-forth.
- Pick the cheapest model and effort that do the task reliably (`.ai/AI_MODEL_ROUTING.md`); move up on evidence, not by default.

## Verification
No agent announces success without running the relevant checks.
Start with targeted checks, then types, lint, tests, build and framework diagnostics as needed.
For integrated work, run the checks again on the integrated branch.

## Security
For everyday implementation, apply a proportionate security review.
For an explicit security audit or vulnerability hunt, prefer the official Cloudflare `security-audit` skill and keep its independent verification and sandbox requirements.

## End of a multi-agent task
A multi-agent task is only finished when:
- scope conflicts are resolved;
- the integrated code is verified;
- review comments are addressed or explicitly accepted;
- durable documentation is up to date if needed;
- temporary handoff files are deleted or current;
- the Git state is clean, or its state is deliberately documented.
