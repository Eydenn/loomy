# Data & analysis

Load this reference only for a Data & analysis project (`type: data` in `.loomy/brief.md`). Apply these rules during discovery and the proposal, then record them in the permanent project instructions before retiring START.md.

## Evidence for every figure

Every figure in a deliverable comes from executed, versioned code: a query or script and its saved output. A model never states a number from memory or substitutes mental arithmetic for execution. If the calculation has not run, mark the figure as not computed.

Reports, notebooks, dashboards and model evaluations cite the producing script (path and revision), the output artifact and the data snapshot (immutable identifier or checksum and period). Version the code and retain reproducible outputs; do not commit private raw data to make a report reproducible. Keep raw snapshots unchanged and record the command, parameters, dependencies and transformations needed to regenerate the results.

## Temporal validation

When data is temporal, validate on a held-out period split by time, never a random split: shuffling leaks future information into the past. Record the timestamp field, cutoff and training/validation periods before fitting or choosing a result. Earlier periods are used for development; the later held-out period stays untouched until validation. Tune only on earlier periods and use only information available at each prediction time.

The agent that proposes a result is not the agent that validates it. Use the existing routing (`loomy route get reviewer`) for an independent cross review; in SOLO, use a different role/model of the same family in a separate reviewer context. If the routed reviewer authored the result, route another independent reviewer. The reviewer reruns the producing code against the cited snapshot, checks the saved outputs and cutoff, and reports discrepancies and leakage. Without an independent validation, label the result unvalidated.

For non-temporal data, choose and document a suitable held-out validation scheme; do not invent a time axis.

## Data stays local

Agents receive schemas, statistics and anonymised samples, never the full data set, regardless of volume. Local scripts process the full data; their outputs shown to agents must respect this boundary too. Keep private raw values out of prompts, logs and deliverables. With sensitive data, any model processing of real values must use a local model, or no model at all; this does not relax the full-data-set boundary.
