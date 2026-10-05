#!/usr/bin/env bash
set -euo pipefail

SCOPE_ARGS=()
if [[ "${1:-}" == "--global" ]]; then
  SCOPE_ARGS+=(--global)
elif [[ -n "${1:-}" ]]; then
  echo "Usage : $0 [--global]" >&2
  exit 2
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "Error: npx is required to install the official Cloudflare security-audit skill." >&2
  exit 1
fi

exec npx skills add https://github.com/cloudflare/security-audit-skill \
  --skill security-audit \
  "${SCOPE_ARGS[@]}"
