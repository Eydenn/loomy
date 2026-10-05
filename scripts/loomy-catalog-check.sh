#!/usr/bin/env bash
# Is the published model catalog newer than the one in use? Bash 3.2 compatible.
#   loomy-catalog-check.sh     prints the published catalog date when it is newer (nothing otherwise)
# Never slows anything down: the published date is read from a cache (~/.config/loomy/catalog.remote), refreshed in the background
# at most once a day (gh for the private repository, otherwise the public URL). LOOMY_CATALOG_CHECK=0 turns it off.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

[[ "${LOOMY_CATALOG_CHECK:-1}" == "0" ]] && exit 0
REPO="${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}"
CACHE="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/catalog.remote"
today="$(date +%Y-%m-%d)"
checked="$(sed -n 's/^checked=//p' "$CACHE" 2>/dev/null | head -1)"
remote="$(sed -n 's/^remote=//p' "$CACHE" 2>/dev/null | head -1)"

if [[ "$checked" != "$today" ]]; then
  mkdir -p "$(dirname "$CACHE")" 2>/dev/null || exit 0
  (
    d=""
    if command -v gh >/dev/null 2>&1; then
      d="$(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/catalog/models.conf" 2>/dev/null | sed -n 's/^date=\([0-9-]*\)$/\1/p' | head -1)"
    fi
    [[ -z "$d" ]] && d="$(curl -fsSL "https://raw.githubusercontent.com/$REPO/main/catalog/models.conf" 2>/dev/null | sed -n 's/^date=\([0-9-]*\)$/\1/p' | head -1)"
    printf 'checked=%s\nremote=%s\n' "$today" "${d:-$remote}" >"$CACHE"
  ) >/dev/null 2>&1 &
fi

if [[ -n "$remote" && "$remote" > "$AI_CATALOG_DATE" ]]; then echo "$remote"; fi
exit 0
