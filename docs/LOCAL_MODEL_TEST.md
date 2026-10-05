# Local model test: LM Studio + Qwen 3.8 27B

Feasibility test for the roadmap idea "local model through LM Studio" (to be decided). No Loomy code was changed:
the goal was to know whether Codex CLI and Claude Code can run a small real task on a local model, and at what speed.

## Setup (2026-09-28)

| | |
|---|---|
| Machine | MacBook Pro M3 Max, 48 GB RAM, macOS |
| Server | LM Studio, local server on `http://127.0.0.1:1234`, authentication off (local only) |
| Model | `qwen/qwen3.8-27b` (16 GB on disk), context 119,552 tokens, 4 parallel slots (LM Studio defaults) |
| Endpoints | LM Studio exposes both an OpenAI-compatible and an Anthropic-compatible API (`/v1/messages`) |
| Tools | Codex CLI 0.158, Claude Code 2.1.283 |

## Task

The same for every run, in a throwaway Git repository: fix a boundary bug in a Bash function (`1000` must print
`1.0k`), write a test script with four cases, run it, and answer in fixed fields (STATUS, SUMMARY, FILES, CHECKS),
like a Loomy structured delegation.

## Results

| Run | How | Time | Result |
|---|---|---|---|
| Codex | `codex exec --oss --local-provider lmstudio -m qwen/qwen3.8-27b --sandbox workspace-write` | 2 min 52 | ✅ fix, test written and run, 4/4 pass, answer in the requested fields (~15k tokens) |
| Claude Code, default | `ANTHROPIC_BASE_URL=http://127.0.0.1:1234`, usual user setup (plugins, MCP servers, all tools) | stopped after ~17 min | ⚠️ fix and test correct in the files, but ~30 messages and no final answer |
| Claude Code, light | same, plus `--tools "Bash,Read,Edit,Write" --strict-mcp-config` and an empty `CLAUDE_CONFIG_DIR` | 2 min 36 | ✅ fix, test written and run, 4/4 pass, answer in the requested fields |

Checked independently after each run: the diff and `bash test.sh`.

## Findings

- **Feasible with both tools.** The quality was right for a small, well-bounded task, and the structured answer
  format was followed.
- **Prompt size is what matters.** On Apple Silicon, reading the prompt (GPU, not CPU: an idle CPU is normal) is the
  slow part. With the usual setup, Claude Code sends a heavy system prompt, tool definitions, MCP servers and plugin
  context on every turn; trimming them cut a turn from ~60 s to ~30 s and the whole task from 17+ min to 2.5 min.
- **No prompt cache reuse.** The LM Studio log shows prompt processing restarting at 0 % on every turn
  (`cache_read_input_tokens: 0`), and Codex's `prompt_cache_key` is ignored. Each turn rereads the whole context.
- **Reasoning.** Claude Code asks for effort `high`, which Qwen does not know; LM Studio falls back to reasoning `on`.
- Harmless log lines: `HEAD /api/hello` (Claude Code's connectivity check), unknown model warning in Claude Code
  (`CLAUDE_CODE_MAX_CONTEXT_TOKENS` sets the real window).

## Still to try (one change at a time, same task)

1. LM Studio: prompt cache kept between requests, Flash Attention, `--gpu max`, `--parallel 1`, smaller context.
2. Reasoning effort lower or off for simple tasks.
3. A longer task (several files) to see where quality drops.

## Conclusion for Loomy

A local role is feasible and useful for mechanical tasks (saves API cost or subscription quota) and for code that
must stay on the machine, provided the delegation runs light (few tools, no MCP, no plugins). The simplest way in is
still a Codex profile pointed at LM Studio, with Claude Code possible through its Anthropic-compatible endpoint.
Still to be decided; no version assigned.

## First integration (0.6.2)

The audit writer of `loomy audit` falls back to the local model when Codex is not available: `scripts/loomy-local-writer.sh`, text only, in the light Claude Code setup above.
Real check on 2026-09-29: `qwen/qwen3.8-27b` drafted the findings section of a report (two validated findings, in French) in 48 s, faithful to the input.
Local models stay out of anything that judges code in an audit.
