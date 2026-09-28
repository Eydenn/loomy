# Model catalog and routing rationale

Checked on **2026-09-28** (Claude Sonnet 5.5 added; the rest as of 2026-09-23). The routing engine (`scripts/lib/models.sh`) applies the conclusions below.
Models change every few weeks: see [Updating the catalog](#updating-the-catalog).

Sources are listed at the end. "AA" means Artificial Analysis (independent measurements). "Vendor" means figures published by OpenAI or Anthropic.

## Prices and measured performance

| Model | Input / output price ($ per million tokens) | Cache read | Cost per task of the AA intelligence index (by effort) | AA agentic coding index | Terminal-Bench 4.0 | Positioning |
|---|---|---|---|---|---|---|
| GPT-6-Luna | 0.10 / 0.50 | 0.01 | **$0.07** (max) | 41 | 13% | cheapest capable executor |
| GPT-6-Sol | 2 / 10 | 0.20 | $0.13 (low) → $1.06 (max) | 57 ($2.99/task) | 43% | workhorse |
| GPT-6-Astra | 10 / 50 (fast 20 / 100) | 1.00 | $0.82 (low) → $3.26 (max) | **62** ($7.09/task) | 59% | OpenAI's frontier model, computer use |
| Claude Haiku 4.5 | 1 / 5 | 0.10 | not measured | not measured | not measured | fast Claude subagents |
| Claude Sonnet 5.5 | 2 / 10 | 0.20 | $0.41 (low) → $7.60 (max); intelligence from 36 to 56 | not published yet | **70.6%** (vendor; Opus 5.5: 66.4%) | everyday work on the Claude side, 1M context, fast (171 t/s at xhigh) |
| Claude Sonnet 5 | 2 / 10 | 0.20 | not yet compared with GPT-6 | not measured | not measured | fallback for Sonnet 5.5 |
| Claude Opus 5.5 | 4 / 20 (fast 8 / 40) | 0.20 | $0.55 (low) → $5.98 (max); intelligence from 42 to **58, 1st** | not published yet | **59.6%** (vendor: 66.4%) | best reasoning and best agentic work |
| Claude Fable 5.1 | 10 / 50 | 0.25 | $7.63 (max) | 62 | 55.8% (vendor) | replaced by Opus 5.5 |

## Findings driving the routing

1. **GPT-6-Luna (max) is the best executor for the price, but not an autonomous agent.**
   - Strength: on DeepSWE v1.1 (vendor), bounded fixes in real repositories, Luna max gets 66.6% for $0.22 per task, against 68.8% for $2.74 with Sol max. That is 12 times cheaper for 2 points less.
   - Weakness: on long, autonomous terminal work (Terminal-Bench 4.0, AA), it drops to 13%. Its agentic coding index is 41, and when it doesn't know, it answers wrong instead of abstaining in 77% of cases.
   - Consequence: Luna gets the **executor** role (bounded tickets under a lead agent), never the lead agent role.
2. **Claude Opus 5.5 is the best lead agent.**
   - It is 1st on the AA intelligence index (58 at max).
   - It leads agentic office work: GDPval-AA 1846 Elo, AA-Briefcase 1822 Elo.
   - It matches Astra on Terminal-Bench (59.6%). At medium effort, it already beats Sol at max (52.5% against 43.9%).
   - At high effort, it gets 53.6 for $1.82 per task. Astra at max gets 53 for $3.26.
3. **Opus 5.5 makes Fable 5.1 unnecessary.** It does better on most benchmarks, for about 40% of the price.
4. **GPT-6-Sol is Codex's workhorse.**
   - On business workflow automation (AutomationBench-AA), it matches Opus 5.5 at medium, 61.6% against 61.2%, for about 40% of the cost.
   - Caveats: it regresses from GPT-5.6-Sol on DeepSWE (72.7% → 68.8%) and on GDPval (about −100 Elo).
5. **GPT-6-Astra is the best fallback for deep work in full Codex**, and it leads graphical computer use: OSWorld 2.0 73.5%, against 64.4% for Sol.
6. **Sonnet 5 and Sol cost the same ($2 / $10).** No direct independent comparison exists yet, so each stays on its own tool.
7. **Claude Sonnet 5.5 (2026-09-28) replaces Sonnet 5 at the same price.**
   - Vendor figures: 97.8 % of Opus 5.5 on average across eight benchmarks, ahead on Terminal-Bench 4.0 (70.6 % against 66.4 %); up to 30 % fewer tokens per task (12 to 14 % in early customer tests).
   - AA: intelligence 52 at xhigh and 56 at max, against 58 for Opus 5.5 at max; but at max effort it costs $7.60 per task, far above Opus 5.5 at high ($1.82 for 53.6).
   - Consequence: it takes the head of the Claude `mid` chain (developer, reviewer, executor, documenter on the Claude side), Sonnet 5 as fallback. The lead agent and the high-stakes specialists stay on Opus 5.5 at high, which is still cheaper for the same level of reasoning. To be reviewed once independent agentic coding figures are out.
8. **Opus 5.5 produces about 1.6 times more output tokens** than Opus 5 at max effort. Its price cut keeps the cost per task stable, hence an effort capped at `high` for everyday specialist work.

## Resulting role matrix (Balanced profile)

| Role | Full Claude Code | Full Codex | Hybrid, Claude lead | Hybrid, Codex lead | Why |
|---|---|---|---|---|---|
| Lead agent | Opus 5.5 high | Astra high | Opus 5.5 high | Astra high | best reasoning to plan, delegate and verify |
| Architect | Opus 5.5 high | Astra high | Opus 5.5 high | Opus 5.5 high (bridge) | Opus leads on reasoning and office work |
| Debugger | Opus 5.5 high | Sol xhigh | Opus 5.5 high | Opus 5.5 high (bridge) | Terminal-Bench: Opus 59.6%, Sol 43% |
| Security | Opus 5.5 high | Astra high | Opus 5.5 high | Opus 5.5 high (bridge) | high-stakes judgement |
| Reviewer | Sonnet 5.5 high | Sol high | Sol high (Codex) | Sonnet 5.5 high (Claude) | cross-family review in hybrid |
| Developer | Sonnet 5.5 medium | Sol high | Sonnet 5 medium | Sol high | same price; stays on the main tool |
| Executor | Sonnet 5.5 medium | Luna max | Luna max (Codex) | Luna max | DeepSWE 66.6% for $0.22 |
| Explorer | Haiku 4.5 low | Luna low | Haiku 4.5 low | Luna low | cheap searches, on the main tool |
| Documenter | Sonnet 5.5 low | Sol low | Sonnet 5 low | Sol low | accuracy over price (Luna is wrong too often) |

Profiles:
- `econome` lowers the lead agent and specialists' effort by one notch.
- `qualite` raises it by one notch (the full Codex debugger moves to Astra xhigh), puts reviews on the best model and moves the executor to Sol or Sonnet high.

Run `ai-route.sh --profile <profile> all` to see the exact matrices.

## Limits
- **Recent data:** the models came out on 2026-09-22.
- **Vendor comparisons:** OpenAI's launch charts compare with Opus 5, not Opus 5.5.
- **Missing figures:** the AA agentic coding index isn't published yet for Opus 5.5 and Sonnet 5.
- **Harness effects:** agentic benchmarks measure a model with its harness, so scores from different harnesses aren't strictly comparable.
- **Subscriptions:** with Claude or ChatGPT plans, "cost" means quota consumption. The ratios between models still hold.

## Updating the catalog

Models change often: the catalog is updated **without a new Loomy version**. The reference file is `catalog/models.conf`, in the repository; everyone fetches it with `loomy update --catalog`, and both `loomy` (home) and `loomy doctor` flag when a newer catalog is published.

### `catalog/models.conf` format

One value per line, read strictly (never executed):

```
date=2026-10-15                                   # required: a catalog is only used when newer
model.claude.mid=claude-sonnet-5-5, claude-sonnet-5   # chain: the first available model is used
model.codex.top=gpt-6-5-astra, gpt-6-astra            # the next ones are fallbacks
price.claude-sonnet-5-5=2 10 0.20                 # $ per million tokens: input, output, cache read
route.claude.explorer=MID low                     # optional: rebalance a role (TOP|MID|FAST tier, effort)
```

### Fallback chains: not everyone has access to the latest models

Each tier (top, mid, fast) of each tool is a **chain**, from the newest model to the oldest. On each machine, Loomy takes the first **available** model:
- **Codex**: Codex's local model list (`~/.codex/models_cache.json`) is authoritative;
- **Claude**: `loomy doctor --live` tests each model of the chains and remembers the result (`~/.config/loomy/models.state`);
- **along the way**: when a delegation is refused ("model doesn't exist or no access"), the model is recorded as unavailable and the delegation moves straight on to the next one in its chain.

A model recorded as unavailable stays so until the next `loomy doctor --live` (after a plan change, for example).

### Priorities (strongest first)

1. `AI_MODEL_<CLAUDE|CODEX>_<TOP|MID|FAST>` environment variable (a one-off try);
2. model pinned on the machine: `loomy config set model.claude.mid <model>` (`auto` to go back to the catalog);
3. chain of the downloaded catalog, if newer than the one shipped with Loomy;
4. chain built into Loomy (`scripts/lib/models.sh`).

Effort is set separately, per project and per role: `loomy effort`.

### Protocol when a new model comes out

1. **Add the model at the head of its chain**, without removing the old one (fallback for those without access): `model.claude.mid=claude-sonnet-5-5, claude-sonnet-5`.
2. **Add its price**: `price.<model>=…`.
3. **Review the split** if the new model changes the balance (e.g. a Haiku 5 good enough for the explorer, a Sonnet 5.5 for the reviewer): `route.…` lines, and this document (tables, findings).
4. **Change the date**: `date=YYYY-MM-DD`.
5. **Check**: `loomy doctor --live` (does each model of the chains answer?), then `bash tests/run.sh`.
6. **Publish**: commit and push to `main`. Everyone gets it with `loomy update --catalog`; the home screen tells them.
7. **Later**, when the old model isn't offered anywhere anymore: remove it from the chain, and carry the new chain over into `scripts/lib/models.sh` (built-in values) in the next Loomy version. A test checks that the repository catalog and the built-in values stay consistent.

To try a model on one machine without changing anything: `AI_MODEL_CODEX_FAST=gpt-6-sol loomy route`.

## Sources
- [GPT-6 Sol and Luna launch (VentureBeat)](https://venturebeat.com/technology/openai-releases-gpt-6-sol-and-luna-models-slashing-api-costs-50-or-more)
- [GPT-6 Sol and Luna push the cost-efficiency frontier (Artificial Analysis)](https://artificialanalysis.ai/articles/gpt-6-sol-and-luna-push-the-cost-efficiency-frontier)
- [Benchmarking GPT-6 Astra (Artificial Analysis)](https://artificialanalysis.ai/articles/benchmarking-gpt-6-astra)
- [Claude Opus 5.5 takes first place (Artificial Analysis)](https://artificialanalysis.ai/articles/claude-opus-5-5)
- [Claude Opus 5.5 by effort level (Artificial Analysis)](https://artificialanalysis.ai/models/releases/claude-opus-5-5)
- [Anthropic's Opus 5.5 launch (VentureBeat)](https://venturebeat.com/technology/anthropic-releases-claude-opus-5-5-beating-fable-5-1-on-key-agentic-benchmarks-at-60-cheaper-api-price)
- [GPT-6 Sol and Luna comparison (Kingy AI)](https://kingy.ai/blog/gpt-6-sol-luna-specs-benchmarks-pricing-comparison/)
- [GPT-6 Sol vs Claude Sonnet 5 (Kingy AI)](https://kingy.ai/blog/gpt-6-sol-vs-claude-sonnet-5/)
- [GPT-6 Sol vs Claude Opus 5.5 cost per task (Digital Applied)](https://www.digitalapplied.com/blog/gpt-6-sol-vs-claude-opus-5-5-cost-benchmarks)
- [Claude API pricing (Anthropic)](https://platform.claude.com/docs/en/about-claude/pricing)
- [Claude Sonnet 5.5 at unchanged Sonnet 5 pricing (Unite.AI)](https://www.unite.ai/anthropic-releases-claude-sonnet-5-5-at-unchanged-sonnet-5-pricing/)
- [Claude Sonnet 5.5 by effort level (Artificial Analysis)](https://artificialanalysis.ai/models/releases/claude-sonnet-5-5)
- [Claude Sonnet 5.5 against Opus 5.5, cost per task (Roo)](https://roo.beehiiv.com/p/claude-sonnet-5-5-cost-benchmarks)
- Codex local model catalog (`~/.codex/models_cache.json`), and real tests with `ai-doctor.sh --live` on 2026-09-23.
