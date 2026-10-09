#!/usr/bin/env bash
# Shared memory of a Loomy project: the work state kept by the lead agent and the results of the delegations.
#   loomy-memory.sh              work state, then the latest results in short
#   loomy-memory.sh -n N         the latest N results (10 by default)
#   loomy-memory.sh show [N]     the full text of a result (the latest by default, N = rank from the latest)
# Files: .loomy/memory/STATE.md (local, never versioned in the project repository; kept in the private repository in private mode), .loomy/memory/delegations/ (kept out of Git).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/memory.sh
source "$SCRIPT_DIR/lib/memory.sh"

ROOT=""; N=10; SHOW=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -n) N="${2:-10}"; shift ;;
    show) SHOW="${2:-1}"; [[ "$SHOW" =~ ^[0-9]+$ ]] && shift || SHOW=1 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//; s/loomy-memory.sh/loomy memory/g' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy memory --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
ROOT="${ROOT:-${LOOMY_PROJECT_ROOT:-$PWD}}"
[[ -f "$ROOT/.loomy/brief.md" ]] || { t "Not a Loomy project: %s" "$ROOT" >&2; echo >&2; exit 1; }
D="$(loomy_memory_dir "$ROOT")"

if [[ -n "$SHOW" ]]; then
  total="$(ls "$D/delegations" 2>/dev/null | wc -l | tr -d ' ')"
  (( total > 0 )) || { t "No delegation result yet."; echo; exit 0; }
  (( SHOW >= 1 && SHOW <= total )) || { t "Only %s result(s) kept: choose N from 1 to %s." "$total" "$total" >&2; echo >&2; exit 1; }
  f="$(ls "$D/delegations" 2>/dev/null | sort | tail -n "$SHOW" | head -1)"
  cat "$D/delegations/$f"
  exit 0
fi

ui_section "$(t "SHARED MEMORY")" "$(t "what carries the work from one session and one tool to the next")"
state="$(loomy_memory_state "$ROOT" 60)"
if [[ -n "$state" ]]; then
  ui_kv "$(t "Work state")" ".loomy/memory/STATE.md"
  while IFS= read -r l; do ui_rail "   $l"; done <<<"$state"
else
  ui_kv "$(t "Work state")" "${C_DIM}$(t "empty for now: the lead agent fills it in after each important step")${C_RESET}"
fi
ui_rail ""
dig="$(loomy_memory_digest "$ROOT" "$N")"
if [[ -n "$dig" ]]; then
  ui_kv "$(t "Latest results")" "$(t "%s kept" "$(ls "$D/delegations" 2>/dev/null | wc -l | tr -d ' ')") · loomy memory show [N]"
  while IFS= read -r l; do ui_rail " ${l# }"; done <<<"$dig"
else
  ui_kv "$(t "Latest results")" "${C_DIM}$(t "none yet: each delegation adds its result here")${C_RESET}"
fi
ui_rail_end ""
