# ADR-0012 — A consent record that the user's machine owns

Status: Accepted (2026-11-19).

## Context

`.loomy/logs/content-policy.conf` holds consents: private results, label sources, the first-use acknowledgement. It lives inside the project, so a clone can ship one (tracked, a submodule checkout, a file left behind by a cleanup). Checked out private, it passed every permission check and pre-granted consent. Closing each shipping layout one by one (tracked file, gitlink, symlink, leftover after `doctor --fix`) kept reopening the same bypass.

## Decision

- A policy is trusted only when this machine's Loomy wrote it. Every write of the file also writes a record outside the project, `${XDG_CONFIG_HOME:-~/.config}/loomy/policies/<sha256 of the project root realpath>` (0700 directory, 0600 file, temp file renamed into place under an flock on the directory), holding the device:inode of the policy file and the sha256 of its content (record format v3). Every policy Loomy writes carries a random `record_nonce=<32 hex>` line (ignored by readers), so the hash covers bytes nobody else can predict and a byte-identical file on a reused inode cannot match; metadata changes (sync tools, touch, restores) do not matter. The config base must be a directory of ours that is not world writable and is group writable only for the user's private group (Debian/Ubuntu default: the user's primary group, no other member, no other passwd entry with it as primary group; one shared rule in `scripts/lib/private-group.pl`, also used by the barrier cache and the quarantine); otherwise no policy is trusted and `loomy doctor` names the folder; the `loomy` and `policies` levels must be real directories of ours and are tightened to 0700. The entry is dropped when the policy file is moved aside by `doctor --fix` or no longer matches.
- Readers (`_stored`, the snapshot readers, the shell fast paths of `content-policy.sh`) trust the file only when root, inode and content all match. Otherwise the policy is absent: defaults, no grant, first-use consent pending. This holds for any layout, tracked or not, and for a hand-edited, replaced or moved project (a moved project is a new root: the grant is asked again).
- The leak barrier (ADR-0011) and `doctor --fix` stay: they keep Loomy from writing into tracked state and move shipped files aside. The record is what keeps a shipped file from being believed whatever they miss.

## Consequences

- Upgrading from 0.17.9 (no record) asks first-use consent once more. Conservative on purpose.
- A user who edits the file by hand, or restores it from a backup, must run a `loomy privacy` command (or accept the first-use screen) to record it.
- Cost on the hook path: one small read in a user directory and a sha256 of a file of at most 16 KiB; the shell fast paths run one Perl process for the barrier and the record check.
- The record is user-level state: a different `XDG_CONFIG_HOME` is a different set of consents.
