# ADR-0003: Model catalog as data

Status: Accepted (2026-09-25)

## Context
Models and prices change every few weeks (`docs/MODEL_CATALOG.md`: Sonnet 5.5 on 2026-09-28, GPT-6.1 Sol on 2026-09-30, Haiku 5.5 on 2026-10-07). Tying them to Loomy releases would force a new version for each change, and not every account has access to the newest model. Routing must also stay explainable: for each role and environment, one place says which model and effort run.

## Decision
- The catalog is the data file `catalog/models.conf` (introduced with 0.3.0, 2026-09-25): `date=`, `model.<claude|codex>.<top|mid|fast>` chains, `price.` and `price_long.` lines, optional `route.` rebalancing and `upcoming.` announced models. The format is strict, one value per line, and documented in `docs/MODEL_CATALOG.md`.
- It is read line by line against anchored regular expressions (`_ai_catalog_load` in `scripts/lib/models.sh`) and never executed or sourced. A model id must start with a letter or digit so that it can never be read as an option by the CLIs. A downloaded catalog is used only when its `date` is newer than the one shipped.
- Each tier is a fallback chain, newest first. The first model available on the machine is used: Codex's local model list, `loomy doctor --live` results in `models.state`, and models refused during a delegation, which are recorded and skipped.
- `loomy update --catalog` fetches the catalog from the repository without a Loomy release; the daily upkeep does it silently. Priorities: environment variable, model pinned on the machine, downloaded catalog, built-in chain.
- The routing engine in `scripts/lib/models.sh` (with `loomy-route.sh`) is the single source of truth for each role's model and effort; documents, subagents and the status screens derive from it.

## Consequences
- A new model or price reaches users without a release; a malformed or hostile catalog line is ignored.
- The built-in chains and prices in `models.sh` must stay consistent with the shipped catalog (the tests compare whole chains).
- Cost figures are estimates at list price; a long-prompt rate (`price_long`) applies to the whole request.

## Alternatives considered
- Hard-coded models, changed at each release: simple, but slow to follow vendors.
- Sourcing a shell file or executing downloaded content: rejected, since a downloaded file must never run.
- Reading the vendors' APIs at runtime: needs keys and network; they are only used by `loomy models` to suggest new models.
