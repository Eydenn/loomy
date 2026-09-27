# Model routing

Goal: the best reasoning for the lead agent (main session), and the cheapest reliable model for each piece of work.

## Roles
lead, architect, debugger, security, reviewer, developer, executor, explorer, documenter. See `templates/MODEL_ROUTING.md` for their scope and rules.

## Source of truth
`scripts/lib/models.sh` holds the model catalog and the routing rules. Use `scripts/ai-route.sh` to read them:
- `ai-route.sh` for the coloured matrix;
- `ai-route.sh markdown` or `all` for the tables;
- `ai-route.sh get <role>` for scripts;
- `ai-route.sh claude-agents` to generate `.claude/agents/`;
- `ai-route.sh codex-profiles` for the Codex profiles;
- `ai-route.sh lead` for the lead agent launch command.

## Environments
- Full Claude Code and full Codex are the single-tool fallbacks.
- In hybrid:
  - architect, security and debugger run on Claude Opus;
  - the executor runs on Codex GPT-6-Luna at max;
  - review comes from the family other than the main tool;
  - explorer, developer and documenter stay on the main tool.

## Budget profiles
The lead agent always stays on the best model. `econome` lowers the efforts, `equilibre` is the default profile, and `qualite` raises the efforts and puts reviews on the best model.

## Verification
`scripts/ai-doctor.sh` checks the CLI versions, model availability and, with `--live`, the actual answer of each routed model.

## Escalation
Move up one notch (executor → developer → lead agent, or effort +1) after two failed checks or evidence contradicting the result. Never loop on a cheap model.
