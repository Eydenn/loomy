# AI_ORCHESTRATION.md

## Goal
Orchestration contract between models for this repository.

The main session is the **lead agent**. It owns the task end to end. It delegates a role to the other model family when `.loomy/docs/AI_MODEL_ROUTING.md` sends it there; otherwise it hands it to its own subagents or does the work itself.

## Default policy
Only delegate when clearly useful: a cheaper model able to do the work reliably, a specialist who will decide better, an independent review, or context isolation.

Don't delegate trivial changes, simple searches the lead agent already has the context for, or tasks it has already solved with confidence.

## Bridges
Both bridges read each role's model and effort from the routing engine (`loomy-route.sh`).

### Codex → Claude: `loomy-delegate-claude.sh` (read-only)
For a Codex lead only. A Claude lead runs its Claude roles as native subagents (`.claude/agents/<role>.md`, Agent tool, in the foreground): the bridge's headless `claude -p` refuses any shell command that isn't pre-approved, so a role that must run measurements or scripts can't work through it.

```bash
.loomy/scripts/loomy-delegate-claude.sh <architect|debugger|security|reviewer|explorer> "<task>"
```
Claude inspects and reports; its file editing tools are disabled. Overrides: `DELEGATE_CLAUDE_MODEL`, `DELEGATE_CLAUDE_EFFORT`, `DELEGATE_CLAUDE_MAX_TURNS`.

### Claude → Codex: `loomy-delegate-codex.sh`
```bash
.loomy/scripts/loomy-delegate-codex.sh <executor|developer|documenter> "<task>"   # workspace-write sandbox
.loomy/scripts/loomy-delegate-codex.sh <reviewer|explorer|debugger|architect|security> "<task>"  # read-only sandbox
```
Roles that write modify the working tree; the script lists the changed files. Overrides: `DELEGATE_CODEX_MODEL`, `DELEGATE_CODEX_EFFORT`.

Pick the role from the intent of the work (design → architect, implementation → developer or executor, review → reviewer, and so on), not from the model the user names. When the user names a model or an effort ("a design by Sol high"), keep the role and pass them as options: `--model <id> --effort <level> --why "user request"`; add `--write` when that role must produce files (a design document, for example). The option wins over the routing and the journal records it as requested and off routing.

Near the end of a subscription quota (95 % by default), a bridge may hand the role to the other tool, with the model the routing gives that role there; it says so on stderr and logs it. Nothing changes for you: same call, same kind of answer; review the result as usual.

A Codex lead agent also uses `loomy-delegate-codex.sh` to run a role on its own routed model, for example GPT-6-Luna at max for the executor.

## Structured delegations
When the brief says `delegation_format: structured` (questionnaire choice, or `loomy config set delegation_format structured`), tasks and results are exchanged as fixed fields, without prose: fewer tokens, nothing lost in wording, and results the bridges check.

Write each delegated task as:
```
GOAL: the expected outcome, in one sentence
SCOPE: what may be touched, and what must not
FILES: the files or folders involved
ACCEPTANCE: the checks that prove it is done
```

Every role answers (the bridges add this contract to their prompt; generated Claude subagents carry it too):
```
STATUS: done | partial | blocked
SUMMARY: one or two sentences
FINDINGS:
- [high|medium|low] path:line — fact, with its evidence
FILES:
- path — what changed (or: none)
CHECKS:
- `command` — passed | failed | not run
RISKS:
- open risk (or: none)
NEXT: what the lead agent should do with this result
```

Act on STATUS: `partial` or `blocked` means the task is not done; read RISKS and NEXT before deciding. The log records the outcome (◐ partial, ■ blocked in `loomy status`), and `loomy stats` shows how many answers followed the format.

## Lead agent responsibilities
- decide whether a delegation is justified;
- write the delegated task with its scope, files and acceptance criteria;
- never modify files while a delegate writes in the same working tree;
- check findings and review diffs against the repository (`git diff`) before accepting them;
- run the quality criteria on the integrated result;
- give the final answer to the user.

A delegate's result is only an opinion until the lead agent has checked it.

## Activity log
Both bridges log each call in `.loomy/logs/events.jsonl` (model, effort, duration, tokens, real or estimated cost). This log feeds `loomy status` and `loomy watch`. The user opens or resumes the lead agent session with `loomy start`. Always run the bridges in the foreground and wait for their result: in the background, a delegation is interrupted if the session closes. Announce each delegation to the user before starting it (role, model, task, rough duration) and its result afterwards (status, duration): while it runs, they only see a waiting indicator. The log stays local (ignored by Git). `LOOMY_JOURNAL=0` turns it off, `LOOMY_JOURNAL_TASKS=0` doesn't record the task text.

## Review protocol
1. Point the reviewer to the actual diff, commit or files.
2. Ask only for concrete defects, with severity, reason and evidence.
3. The lead agent checks every important finding before changing the code.
4. Run the relevant checks again after the fixes.

Avoid generic "looks good" reviews and duplicate reimplementations.

## Token and cost guardrails
- Prefer one focused delegated call to conversational back-and-forth.
- Keep instructions scoped. Let the delegate read the repository instead of pasting code to it.
- Move up on evidence (failed checks, contradictions), not by default.

## Parallel mode
For real parallel implementation, give each tool its own worktree and Git branch (`loomy-worktrees.sh`), with disjoint scopes. After integration, run the quality criteria again on the integrated branch.
