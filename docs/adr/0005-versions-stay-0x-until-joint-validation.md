# ADR-0005: Versions stay 0.x until joint validation

Status: Accepted (2026-09-24)

## Context
Loomy orchestrates two external CLIs (Claude Code and Codex), whose behaviour, flags, model names and hooks change often. Several parts depend on them: the routed models, the hooks, the quota readings, and the repair of the CLIs. The first release (0.1.0, 2026-09-24) was labelled a pre-version, and the roadmap of 2026-09-25 planned steps from 0.2 to 1.0. `CHANGELOG.md` and `README.md` still state it: Loomy stays at 0.x until the whole flow has been validated in real conditions, the stable release coming after a release-candidate phase validated by testers. Linux is tested in CI but not yet validated in real use.

## Decision
- The version stays 0.x. 1.0.0 is not published before the joint validation in real conditions, and a release-candidate phase comes before it (roadmap item "Release candidate").
- Each workstream ships as one version with one dated `CHANGELOG.md` entry; fixes get a patch number. For example 0.12.0 to 0.12.3 (2026-10-06) cover feedback follow-up, an audit-fix pass and the logo and README.
- `VERSION` is the reference; `package.json`, the READMEs and the changelog must agree, which the tests check.
- Compatibility shims are time-boxed to 1.0: the old script names were kept after 0.10 and removed in 0.13.0 (2026-10-07).
- Security reports go through GitHub's private vulnerability reporting, and only the latest version is supported (`SECURITY.md`).

## Consequences
- Breaking changes stay possible between 0.x versions and are described in the changelog, with a migration where needed (`.ai/` to `.loomy/docs/`, the `loomy-*` renaming).
- Users are warned that Loomy is a pre-release and that Linux is not yet validated in real use.
- The version number says little about size: a new feature and a fix both move it.

## Alternatives considered
- Declaring 1.0 at the public release (0.13.0, 2026-10-07): would promise stability that the two vendors' CLIs do not offer.
- Calendar versioning: does not tell users whether a change is a fix or a feature.
- Several parallel release lines: too heavy for a single maintainer, hence only the latest version is supported.
