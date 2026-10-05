#!/usr/bin/env bash
# Compatibility: the name of loomy-install-security-audit.sh before Loomy 0.10, kept for projects whose relays still use it. Removed in 1.0.
exec bash "$(dirname "${BASH_SOURCE[0]}")/loomy-install-security-audit.sh" "$@"
