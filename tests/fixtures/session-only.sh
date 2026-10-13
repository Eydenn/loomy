#!/usr/bin/env bash
# Runs inside the stub lead, so routing assertions observe an actual owner descendant.
set -euo pipefail
unset LOOMY_SCREEN_OWNER LOOMY_PAGE_OUT
export STUB_ONLY_DESCENDANT=1 LOOMY_LANG=en LOOMY_UI_LANG=en
root="$STUB_ONLY_ROOT"; repo="$STUB_ONLY_REPO"; out="$STUB_ONLY_OUT"
printf '%s\n' "$LOOMY_SESSION_ONLY" >"$out/marker"
for role in lead architect debugger security reviewer developer executor explorer documenter; do
  AI_ROUTE_ENV=hybrid-claude bash "$repo/scripts/loomy-route.sh" --root "$root" get "$role" >"$out/$role"
done
bash "$repo/scripts/loomy-route.sh" --root "$root" >"$out/route" 2>&1
LOOMY_UI_LANG=fr bash "$repo/scripts/loomy-route.sh" --root "$root" >"$out/fr" 2>&1
bash -c 'source "$1/scripts/lib/ui.sh"; source "$1/scripts/lib/models.sh"; source "$1/scripts/lib/phases.sh"; source "$1/scripts/lib/usage.sh"; source "$1/scripts/loomy-tree.sh" --library; ROOT="$2"; loomy_live_init; loomy_live_metadata; loomy_live_header; printf "%s\n" "$LV_HEADER"' _ "$repo" "$root" >"$out/header"
touch "$out/ready"
