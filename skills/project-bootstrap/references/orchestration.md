# Orchestration

## Complexity
- SIMPLE: narrow scope, few moving parts, little coordination.
- STANDARD: several components or significant design choices.
- COMPLEX: cross-cutting architecture, many integrations, broad or long-lived scope, or high uncertainty.

## Risk
Risk rises with: authentication and authorisation, payments, secrets, personal data, migrations, production infrastructure, cryptography, destructive actions, public APIs, multi-tenancy, security boundaries, or irreversible external actions.

## Delegation
Only delegate when at least one of these applies:
- independent work can run in parallel;
- specialised expertise clearly improves quality;
- exploration would clutter the lead agent's context;
- an independent check or review reduces a real risk.

Don't delegate trivial changes, sequential work, duplicate searches or small single-file changes.

## Suggested specialist pool
Architect, Explorer, Implementer, Frontend/UX, Backend/API, Data, Mobile/Desktop, QA/Tests, Security, Performance, DevOps, Reviewer, Documentation, Research.
Only instantiate what is needed.

## Hybrid Codex + Claude operation
When both tools are used, the repository and the Git history are the shared state. Don't assume conversation context is shared between the two products.

Use one of five modes:
- SOLO: a single tool owns the task.
- REVIEW: one implements, the other independently reviews the actual diff or commit.
- HANDOFF: one creates a clean checkpoint and a concise `.loomy/docs/HANDOFF.md`; the other checks the state and takes over.
- PARALLEL: separate branches or worktrees with disjoint scopes, followed by a verification after integration.
- ORCHESTRATED: the lead agent delegates roles to the other model (see "Cross-model orchestration" below).

Prefer REVIEW over two duplicate independent implementations, unless diversity of solutions is the goal.
In PARALLEL mode, never let both tools modify the same working tree or overlapping files at the same time without explicit coordination.

## Review step
An independent review is strongly recommended for cross-cutting changes, architecture changes, authentication, security or business-critical logic, migrations, significant regression risks, and complex debugging or algorithms.
The reviewer inspects the actual diff and reports concrete defects and risks, not a generic approval.

## Context economy
- Search before reading broadly.
- Reuse established facts instead of rediscovering them.
- Ask subagents for concise findings, with file paths and decisions.
- Don't dump raw exploration into the lead agent's context.
- Only load specialised references when needed.
- Use short handoff files rather than replaying past conversations.

## Cross-model orchestration
The main session is the lead agent. It delegates roles from one model family to the other following the routing of `scripts/loomy-route.sh`: a Codex lead reaches Claude through `scripts/loomy-delegate-claude.sh` (read-only); a Claude lead runs its Claude roles as native subagents (`.claude/agents/`, Agent tool) and reaches Codex through `scripts/loomy-delegate-codex.sh` (writing or read-only depending on the role).

Use these calls for an independent review, an architecture critique, hard debugging, a second security opinion or focused research. The lead agent remains responsible for checking the findings and for the final integration.

Don't use these calls for trivial tasks, routine confirmations or repeated back-and-forth. Prefer a single focused call.
