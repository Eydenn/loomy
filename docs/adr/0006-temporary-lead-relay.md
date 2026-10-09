# ADR-0006: Temporary lead relay when a subscription runs out

Status: Accepted (2026-10-09)

## Context
The lead agent runs in a Claude Code or Codex session on a subscription whose quota can run out in the middle of the work. Delegations already move to the other tool near the end of a quota (`quota_switch`), but the lead session itself stayed on the exhausted tool. A CLI session cannot change model family while it runs, so the lead can only change between two sessions.

## Decision
- The lead set in the brief (the master) never changes. A relay is a state file, `.loomy/failover` (`scripts/lib/failover.sh`).
- At 90 % (switch threshold minus 5), a Claude Code master is told at each message (at most every 10 minutes) to finish the step, write `.loomy/docs/HANDOFF.md` and `STATE.md`, commit and end the session. Codex has no per-message hook: its master is warned by `loomy watch` and at session start.
- At 95 % (`quota_switch`), if the other tool is installed and below `quota_room` (80 %), the chain of `loomy start` opens it as lead with a relay prompt, after 5 seconds during which Ctrl+C cancels. At most 6 sessions per chain.
- Routing follows the acting lead. As soon as the master is below `quota_room` or its window reset time has passed, the acting lead is told the same way and the master takes the lead back with a return prompt.
- Never on API plans. `lead_failover off` or `LOOMY_NO_SWITCH=1` disables it. Events `lead_failover` and `lead_return` go to the journal.

## Consequences
- Work continues without the user choosing a tool, and the brief stays the reference.
- The handover relies on the lead writing `HANDOFF.md` and `STATE.md` when told; if it does not, the next lead reads less context.
- A Codex master gets less notice than a Claude Code one.
- Quota readings drive the decision, so a missing reading counts as room.

## Alternatives considered
- Switching the brief's lead permanently: loses the user's choice and needs a manual switch back.
- Asking the user each time: interrupts the work at the moment the quota is nearly gone.
- Relaying inside the running session: impossible, a CLI session cannot change model family.
