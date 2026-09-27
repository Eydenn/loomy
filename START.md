# LOOMY — TEMPORARY BOOTSTRAP

> Status: `BOOTSTRAP_PENDING`
> This file is temporary. Its authority ends once the bootstrap is finished.

## Goal

Turn this repository into a well-framed, documented and testable project, with an adaptive team of agents and subagents, and only the skills and capabilities that are actually useful.

The aim is the most reliable value with the least context, agents, files, dependencies and wasted tokens.

## Mandatory bootstrap behaviour

When you are asked to set up this project, do **not** generate application code right away.

Follow these phases in order:

1. Discovery
2. Interview
3. Proposal
4. Waiting for explicit approval
5. Build
6. Verification
7. Documentation
8. Commit
9. Retiring this file

Don't skip the approval step before creating the project, unless the user explicitly asks you to.

---

## Progress tracking

At the start of each phase, **before any other action**, record it: the user sees it right away in `loomy watch`, together with what is expected from them.

```bash
.loomy/scripts/ai-status.sh set <discover|interview|propose|approve|build|verify|document|commit|retire|done>
```

If the script is missing, skip this step without mentioning it.

At each phase change, announce it to the user on a line that starts with the phase number, then say in one sentence what you are doing now and what you expect from them (answers, approval, review): they must never wonder whether it's their turn. Example:

> **Phase 6/10 · Build**. I'm setting up the structure, then handing the writing to Codex. Nothing to do on your side for now.

During long work, the user only sees a waiting indicator: give them landmarks.
- **Before each delegation**, one line: role, model, what is asked, rough duration. Example: "→ Handing the email writing to the Codex executor (gpt-6-luna), 1 to 3 min."
- **After each delegation**, one line: result and duration. Example: "✓ Executor done in 1 min 41 s: 4 files created. Checking."
- Between two long steps, one progress line is enough ("3 of 5 files reviewed"). No walls of text: the user must be able to follow at a glance.

If the session was interrupted, the user resumes it with `loomy start`; a new session resumes at the phase recorded in `.loomy/state`. With Claude Code, the resume context (`.loomy/scripts/ai-context.sh`) is injected automatically when each session opens; with Codex, run this script at the start of the session.

Codex gets the same context through `.codex/hooks.json`, once its hooks are approved on first launch. When you generate `.claude/settings.json` or `.codex/`, keep the Loomy hooks already there (`ai-context.sh`).

Every delegation going through the bridges (`delegate-to-claude.sh`, `delegate-to-codex.sh`) is logged automatically in `.loomy/logs/events.jsonl`: role, model, effort, duration, tokens, cost. The user follows this log live in the terminal (`loomy watch`). You have nothing to run for that.

---

## Phase 1 — Discovery

If `.loomy/brief.md` exists, read it first. It holds the user's answers to the terminal questionnaire (`init-wizard.sh`):
- project goal and type;
- stage, sensitive data and estimated risk;
- AI mode and main tool;
- model budget profile;
- documentation language and what happens to this file;
- commit and push permissions.

Treat it as an interview already held: confirm it in one line, don't ask these questions again, and flag anything the repository contradicts.

Inspect the repository before asking questions.

Only establish what is easy to infer from the existing files:

- empty or existing repository;
- current Git state;
- existing README and instructions;
- detected stack, package manager, runtimes and configuration;
- existing tests, lint, formatting, type checking and CI;
- existing `AGENTS.md`, `CLAUDE.md`, skills, MCP tooling or agent configuration;
- obvious constraints imposed by the current code.

Don't read the whole repository unless needed.
Don't install dependencies or modify any project file during this phase.

---

## Phase 2 — Adaptive interview

Switch to planning mode only.

Ask the **smallest set of high-impact questions** needed to remove the important ambiguities.
Don't use a fixed questionnaire, and don't ask questions whose answer can already be inferred from the repository, `.loomy/brief.md` or the initial request.

Always clarify, when relevant:

- the goal of the product or project;
- the target users;
- the target platforms and environments;
- the MVP or requested scope;
- strong technical constraints;
- data, storage, backend and API needs;
- authentication, sensitive data and security constraints;
- offline or online operation;
- the deployment or distribution target;
- quality priorities: speed, maintainability, accessibility, performance, cost;
- existing systems or APIs to integrate.

Only ask domain-specific questions when they change the architecture or implementation.
Examples:

- Mobile: Expo or native, iOS/Android, offline, notifications, stores.
- Web/SaaS: authentication, multi-tenancy, payments, hosting, SEO.
- Desktop: target OSes, file system access, automatic updates, signing and distribution.
- CLI/library: public API stability, supported runtimes, packaging.
- AI/LLM: model or provider constraints, data exposure, prompt and tool limits, evaluation.

Prefer a single concise round of questions. Only ask a second one if the answers reveal a new important ambiguity.

---

## Phase 3 — Project proposal

Before any change to the project, present a concise proposal containing:

### Product
- Goal
- Main users
- Initial scope
- Explicit non-goals, if useful

### Technical direction
- Proposed stack
- Architecture style
- Key dependencies only
- Persistence and integrations
- Deployment or distribution strategy, if relevant

### Execution profile
Classify internally and state:

- Complexity: `SIMPLE | STANDARD | COMPLEX`
- Risk: `LOW | MEDIUM | HIGH`

Risk rises with: authentication, permissions, payments, personal or sensitive data, migrations, production infrastructure, destructive operations, cryptography, security-critical logic, or large cross-cutting changes.

### AI operating mode
Detect the available AI CLIs with `.loomy/scripts/detect-ai-tools.sh` if it exists.
Decide the project's default mode:

- `SOLO`: a single coding agent at a time;
- `HYBRID`: Codex and Claude can both work on the repository;
- `ORCHESTRATED`: a main agent can call the other model as a specialist;
- `PARALLEL`: both work at the same time on isolated branches or worktrees.

If Codex and Claude are both likely to be used, choose `HYBRID` by default.
Don't assume they share conversation context directly. Coordinate them through the repository, Git checkpoints, `.ai/AI_WORKFLOW.md`, and `.ai/HANDOFF.md` when an explicit handoff is needed.
For parallel implementation, require separate Git branches or worktrees and scopes that don't overlap.

### Adaptive agent team
Use `.loomy/agents/ROLE-CATALOG.md` as the source of reusable roles if it exists. Only materialise the chosen roles in `.ai/agents/` if explicit role files improve the tool in use; otherwise keep the roles implicit.

Only propose roles that bring clear value.
Possible roles:

- Main agent / lead agent
- Explorer
- Architect
- Implementer
- Frontend / UI / UX
- Backend / API
- Data / database
- Mobile or desktop specialist
- Tests / QA
- Security
- Performance
- DevOps
- Reviewer
- Documentation
- Research

Don't instantiate every role by default.
Only use a subagent when the work can be parallelised, is specialised, benefits from being isolated from the main context, or benefits from an independent review.

### Model routing
You are the **lead agent** (orchestrator): keep planning, decisions, integration and verification for yourself, and delegate the work to the dedicated roles (architect, debugger, security, reviewer, developer, executor, explorer, documenter).

Run `.loomy/scripts/ai-route.sh` and include its matrix in the proposal. For this machine and this brief, it determines:
- the environment: full Claude, full Codex, or hybrid with either one as lead, with automatic fallback when a CLI is missing;
- the budget profile;
- each role's model, effort and calling method.

Don't invent model names: the routing engine and `.loomy/scripts/ai-doctor.sh` are authoritative.

Fit the project size: a SIMPLE/LOW project can make do with the lead agent, an explorer and an executor or a developer.

### Skills and tools
List only the skills and tools to enable for this project.
Prefer existing specialised skills over recreating their workflow.
Don't load unrelated skills "just in case".

### Documentation plan
Only propose the durable documents the project needs.
Candidates:

- `AGENTS.md`
- `CLAUDE.md`
- `PROJECT.md`
- `ARCHITECTURE.md`
- `README.md`
- `docs/decisions/`
- `docs/plans/`

### Quality criteria
State the concrete checks expected before the work is considered done, for example:

- type checking;
- lint;
- targeted tests;
- full test suite when justified;
- build;
- framework-specific diagnostic command;
- security review when relevant.

Then ask for explicit approval of the proposal.

---

## Phase 4 — Build after approval

After approval:

1. Create or adapt the project structure.
2. Generate the project's AI instructions from the templates in `.loomy/templates/` if they exist.
3. Only create the documentation justified by the proposal.
4. Install and configure the minimal suitable tooling.
5. Create the smallest coherent application or library skeleton that proves the setup works.
6. Add the tests and checks suited to the stack.
7. Avoid speculative features and unrelated dependencies.

### Mandatory project instructions

Generate a concise `AGENTS.md` at the root for Codex, with the project-specific facts and the working rules.
Generate `CLAUDE.md` for Claude Code, as a thin compatibility layer.
Generate `.ai/AI_WORKFLOW.md` from the shared workflow template, so that Codex and Claude follow the same coordination contract without duplicating long instructions.
If hybrid use is planned, provide `.ai/HANDOFF.md` as an ephemeral coordination file, not as the project's permanent memory.

The generated `AGENTS.md` keeps the "Autonomy and stop points" section of the template: when to move forward alone, and when to stop and ask (always before a destructive or hard-to-undo operation). Adapt it to the project (e.g. migration commands, production environments), without weakening it.

Keep the permanent instruction files short. Detailed knowledge goes into `PROJECT.md`, `ARCHITECTURE.md`, the ADRs or specialised skills, and is only loaded when useful.

### Hybrid Codex + Claude setup

When hybrid mode is chosen:

1. Create `AGENTS.md` at the root for Codex.
2. Create `CLAUDE.md` at the root for Claude Code.
3. Create `.ai/AI_WORKFLOW.md` from `.loomy/templates/WORKFLOW.md`.
4. Create `.ai/AI_ORCHESTRATION.md` from `.loomy/templates/ORCHESTRATION.md` when delegation between models is enabled.
5. Don't create `.ai/HANDOFF.md` until an actual handoff is in progress.
6. For parallel work, use isolated branches or worktrees; never let both tools modify the same working tree at the same time.
7. When parallel implementation isn't needed, prefer one tool implementing and the other reviewing, for a high-value cross check.
8. Delegation between models goes through `.loomy/scripts/delegate-to-claude.sh` (read-only Claude specialist) and `.loomy/scripts/delegate-to-codex.sh` (Codex executor, developer, reviewer…), following the routing of `ai-route.sh`. The lead agent validates each result before acting. Always run these scripts **in the foreground** and wait for them to finish: a delegation started in the background is interrupted if the session closes.
9. Don't use cross-model calls for trivial tasks or to have every decision confirmed automatically.

### Model routing setup

Once the routing is approved:

1. Create `.ai/AI_MODEL_ROUTING.md` from `.loomy/templates/MODEL_ROUTING.md`, then replace its last section with the output of `.loomy/scripts/ai-route.sh markdown`.
2. If the main tool is Claude Code, generate the subagents with `.loomy/scripts/ai-route.sh claude-agents`. They are created in `.claude/agents/`, with model and effort filled in. Remove the roles the proposal didn't keep.
3. If Codex is used, roles go through `delegate-to-codex.sh <role>`, which needs no configuration. For interactive Codex sessions per role, give the user the output of `ai-route.sh codex-profiles`. Never modify the user's global `~/.codex/config.toml` without their explicit approval.
4. Give the user the lead agent launch command (`ai-route.sh lead`) for their next sessions.

---

## Phase 5 — Verification

Before finishing, run the strongest checks available for the project you set up.

Preferred order:

1. targeted checks;
2. type checking;
3. lint;
4. tests;
5. build;
6. framework or runtime diagnostics;
7. quick manual test when relevant.

Never claim a check passed if it didn't actually succeed.
Clearly separate `verified`, `inferred` and `not tested`.

If a check fails, diagnose and fix the cause before going on, within reason.

---

## Phase 6 — Documentation and memory

Only keep durable information.

### `PROJECT.md`
Record the product intent, users, scope, constraints, non-goals and important requirements.

### `ARCHITECTURE.md`
Only create it if the architecture isn't trivial. Record the stack, module boundaries, main flows, persistence, integrations, build and deployment model, and important invariants.

### ADRs
Create `docs/decisions/NNN-*.md` only for decisions that future developers or agents could reasonably challenge, and whose rationale matters.
No ADR for trivial choices.

### Plans
Only use `docs/plans/` for important ongoing work. Don't pile up stale plans.

---

## Phase 7 — Security

The security audit is done **on demand**; it isn't loaded permanently.

When the user explicitly asks for a security audit, a vulnerability review, a penetration-test style code review, or similar:

1. Prefer the official Cloudflare `security-audit` skill if available.
2. If it isn't installed, use `.loomy/scripts/install-security-audit.sh` if it exists, or follow `.loomy/external-skills/security-audit.md`.
3. Keep the important guarantees of the Cloudflare workflow:
   - reconnaissance from the source code;
   - deterministic coverage register;
   - isolated research agents;
   - independent, fresh verifier for each candidate;
   - separation of `confirmed`, `needs_validation`, `rejected`;
   - structured validation and report;
   - no execution of target-controlled code without an OS-enforced sandbox.
4. Don't present generic deviations from best practices as confirmed vulnerabilities.
5. Don't modify the audited code during the audit, unless the user separately asks for a fix after reading the results.

For everyday implementation work, apply proportionate security reasoning without loading the whole audit workflow.

---

## Phase 8 — Git checkpoint

Before committing:

- inspect `git status`;
- check that no secret, unneeded generated file, debug artefact or unrelated file is included;
- check that `.gitignore` is suitable;
- summarise what is about to be committed.

Only commit if allowed: `commit_after_setup: yes` in `.loomy/brief.md`, or the user's explicit approval in the conversation. Then create the initial commit only if every check passed, with a concise message such as:

`chore: initialize project`

Only push if the brief contains `push_after_commit: yes` or the user explicitly asks for it, to the given remote, on the current branch. Never force-push. Without permission, leave the work ready and summarise what the user needs to commit or push.

If Git identity, signing, repository policy or permissions block the commit, leave the repository ready (files staged if relevant) and describe the blocker precisely. Never invent a success.

---

## Phase 9 — Retiring this file

After a successful setup:

1. Create `.ai/bootstrap/` if the project's complexity justifies keeping the bootstrap history.
2. Move this file to `.ai/bootstrap/START.completed.md`, **or delete it** if the user chose not to keep the history.
3. If it is archived, add the completion information at the top:
   - status `COMPLETED`;
   - completion date;
   - initial commit id if there is one.
4. Check that the permanent project files no longer depend on this document.
5. Run `.loomy/scripts/ai-status.sh set done`.

Once finished, this file has **no authority at all** over future work.

Authoritative, in order:

1. the user's current instruction;
2. the project's `AGENTS.md`, `CLAUDE.md`, `.ai/AI_WORKFLOW.md` and `.ai/AI_MODEL_ROUTING.md`;
3. executable code, schemas and configuration;
4. tests;
5. `PROJECT.md`, `ARCHITECTURE.md` and the current ADRs;
6. the rest of the maintained documentation.

---

## Token and context discipline

Treat context as a limited resource.

- Search before reading broadly.
- Only read the useful parts of files.
- Don't reread files that haven't changed.
- Only use subagents when their value exceeds the cost of delegating.
- Ask agents for findings, decisions, file paths and risks, not verbose stories.
- Don't copy back the user's request or the repository documentation.
- Prefer progressive loading: only load specialised guidance when the task needs it.
- Prefer a decisive plan over a list of many weak alternatives.
- Keep `AGENTS.md` concise; don't make it a dumping ground.

## Main directive

`UNDERSTAND → DISCOVER → ASK → PROPOSE → APPROVE → BUILD → VERIFY → REVIEW → DOCUMENT → COMMIT → RETIRE THE BOOTSTRAP`

Adapt the process to the project. Never create process for its own sake.
