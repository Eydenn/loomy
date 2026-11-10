#!/usr/bin/env bash
# Shared exact hook catalog and settings repair. Bash 3.2; sourced only.
# The helper owns JSON classification, directory locking and atomic replacement.
# Capture the installed helper while sourcing, so later cwd changes are harmless.
_LOOMY_HOOKS_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/hooks.pl" || return 1

# Both APIs emit sanitized JSON facts and return nonzero on failure. Inspection
# never creates directories; repair defaults to ensure-only shell registration.
loomy_hooks_inspect() {
  perl "$_LOOMY_HOOKS_HELPER" inspect "$@"
}

loomy_hooks_repair() {
  perl "$_LOOMY_HOOKS_HELPER" repair "$@"
}

# Compatibility for existing project/install callers. H2 migrates the remaining
# consumers to these shared typed APIs without a second JSON generator.
loomy_claude_hooks_merge() {
  loomy_hooks_repair "$1" claude >/dev/null
}

loomy_codex_hooks_merge() {
  loomy_hooks_repair "$1" codex >/dev/null
}
