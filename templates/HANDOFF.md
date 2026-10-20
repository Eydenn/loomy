# AI handoff

Status: ACTIVE
From: <Codex|Claude>
To: <Codex|Claude>
Branch/worktree: <name/path>
Commit: <hash or NONE>

## Goal
<one concise paragraph>

## Done
- <finished item>

## Files changed
- `<path>` — <why>

## Verification
- `<command>` — OK | FAILED | NOT RUN

## Dead ends
Before handing over, record evidence-backed rejections in the shared `.loomy/memory/STATE.md` under `## Dead ends`, oldest first:
- <approach> — <why it died> (<evidence path or ref>) · do not retry without a new reason

Keep STATE within 40 lines (`loomy memory` archives the oldest to `.loomy/memory/DEAD-ENDS.md`). The next lead must check both files before proposing an approach; never retry one without stating a new reason.

## Open issues and risks
- <only the important unresolved points>

## Next action
<the exact step the agent taking over must do>
