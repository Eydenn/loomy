# ADR-0009 — Structural journal and per-store content policy

Status: Accepted (2026-10-26).

## Context

Live tracking needs identities, lifecycle facts and usage. Keeping task excerpts,
display titles and full results in the same history creates unnecessary sensitive
copies and makes a single journal switch an unclear retention contract.

## Decision

- New journal writes and rotation snapshots use a closed per-event structural
  allowlist. Existing installations use this default for future writes. An explicit
  project grant can enable only the five bounded compatibility excerpt fields;
  it cannot enable full-result retention.
- Give each content store its own contract. Display labels require named source
  grants and a bounded local store. Automatic memory keeps structural receipts;
  full task/result bodies require a separate bounded private-results grant.
  Sensitive runtime stores stay outside project/companion sync and automatic
  feedback attachments. Authored work documents retain their intended content.
- Bind grants and references to a stable local project identity. Validated
  worktrees sharing the project runtime share its policy; moving the project with
  its `.loomy` directory preserves references.
- Require direct human TTY confirmation to widen grants or limits. First-use
  questions offer labels and private results separately, with Yes defaults but
  no capture until the human answers. Managed execution cannot grant for the user.
- Resolve authorized labels/results at read time. Keep exact typed pause/relaunch
  options; when the original task and an authorized stored reference are both
  unavailable, report that the original task is required instead of guessing.

## Consequences and limits

The journal remains useful without retaining task text. Users who authorize
labels and private results keep readable tracking and cross-session continuity;
receipt-only operation cannot reconstruct lost task instructions. Policy changes
affect future capture, not historical copies. Private permissions and exclusions
do not provide encryption or erase old Git objects. The execution-path guard is
not OS isolation from a same-UID process able to edit files or alter its environment.
Older writers and downgrades cannot enforce these contracts; stop collectors and
bridges before switching writer generations.

The current boundary does not sanitize native checkpoints, cursors, execution/UI
temporary files, desktop/installer diagnostics, raw log or Markdown report exports,
provider arguments, or provider-managed transcripts. These retain separate risks
and need separate handling. See [the store contracts](../DESIGN.md#per-store-content-policy).

## Alternatives considered

Keep excerpts everywhere, remove all useful labels/results, or treat local Git
ignores as a universal privacy guarantee. None gives each store a clear purpose,
grant and retention limit while preserving authorized memory and display text.
