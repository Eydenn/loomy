#!/usr/bin/env bash
# Shared memory of a Loomy project: the work state kept by the lead agent and the results of the delegations.
#   loomy-memory.sh              work state, then the latest results in short
#   loomy-memory.sh -n N         the latest N results (10 by default)
#   loomy-memory.sh show [N]     receipt and authorized private result (N = rank from the latest)
#   loomy-memory.sh show legacy [N]    older sensitive result (read-only)
# Files: .loomy/memory/STATE.md, DEAD-ENDS.md, receipts-v1/, private-results-v1/; historical delegations/ (read-only).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/memory.sh
source "$SCRIPT_DIR/lib/memory.sh"

ROOT=""; N=10; SHOW=""; LEGACY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    -n) N="${2:-10}"; shift ;;
    show)
      if [[ "${2:-}" == legacy ]]; then LEGACY=1; shift; fi
      SHOW="${2:-1}"; [[ "$SHOW" =~ ^[0-9]+$ ]] && shift || SHOW=1 ;;
    -h|--help)
      sed -n '2,4p' "$0" | sed 's/^# \{0,1\}//; s/loomy-memory.sh/loomy memory/g' | i18n_lines
      printf '  loomy memory show [N]          %s\n' "$(t "Latest results")"
      printf '  loomy memory show legacy [N]   %s\n' "$(t "older sensitive results")"
      exit 0 ;;
    *) t "Unknown argument: %s (loomy memory --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
ROOT="${ROOT:-${LOOMY_PROJECT_ROOT:-$PWD}}"
[[ -f "$ROOT/.loomy/brief.md" ]] || { t "Not a Loomy project: %s" "$ROOT" >&2; echo >&2; exit 1; }
D="$(loomy_memory_dir "$ROOT")"

if [[ -n "$SHOW" ]]; then
  if (( LEGACY )); then
    t "older sensitive results"; echo
    loomy_memory_legacy "$ROOT" "$SHOW"
    exit $?
  fi
  total="$(loomy_memory_count "$ROOT")" || exit 1
  if (( total == 0 )); then
    legacy="$(loomy_memory_legacy "$ROOT")" || exit 1
    if [[ -n "$legacy" ]]; then t "Older sensitive results are available: loomy memory show legacy [N]"
    elif (( $(loomy_memory_unavailable_count "$ROOT") > 0 )); then t "result not retained; consult authorized task artifact"
    else t "No delegation result yet."; fi
    echo; exit 0
  fi
  (( SHOW >= 1 && SHOW <= total )) || { t "Only %s result(s) kept: choose N from 1 to %s." "$total" "$total" >&2; echo >&2; exit 1; }
  loomy_memory_show "$ROOT" "$SHOW"
  exit $?
fi

ui_section "$(t "SHARED MEMORY")" "$(t "what carries the work from one session and one tool to the next")"
state="$(loomy_memory_state "$ROOT" 40)"
if [[ -n "$state" ]]; then
  ui_kv "$(t "Work state")" ".loomy/memory/STATE.md"
  while IFS= read -r l; do ui_rail "   $l"; done <<<"$state"
else
  ui_kv "$(t "Work state")" "${C_DIM}$(t "empty for now: the lead agent fills it in after each important step")${C_RESET}"
fi
ui_rail "   $(t "Check Dead ends before proposing an approach; never retry one without a new reason, and say which.")"
if [[ -f "$D/DEAD-ENDS.md" ]]; then
  ui_kv "$(t "Dead ends archive")" ".loomy/memory/DEAD-ENDS.md"
fi
ui_rail ""
if loomy_memory_capture_enabled "$ROOT"; then
  ui_rail "$(t "Private results: enabled · local only · 30 days / 200 records / 16 MiB")"
else
  ui_rail "$(t "Private results: off · receipts available; new summaries not retained")"
fi
hint="$(loomy_content_status_hint "$ROOT")"
while IFS= read -r l; do [[ -z "$l" ]] || ui_rail "$l"; done <<<"$hint"
dig="$(loomy_memory_digest "$ROOT" "$N")" || exit 1
if [[ -n "$dig" ]]; then
  ui_kv "$(t "Latest results")" "$(t "%s kept" "$(loomy_memory_count "$ROOT")") · loomy memory show [N]"
  while IFS= read -r l; do ui_rail " ${l# }"; done <<<"$dig"
else
  if (( $(loomy_memory_unavailable_count "$ROOT") > 0 )); then
    ui_kv "$(t "Latest results")" "$(t "result not retained; consult authorized task artifact")"
  else
    ui_kv "$(t "Latest results")" "${C_DIM}$(t "none yet: each delegation adds its result here")${C_RESET}"
  fi
fi
legacy="$(loomy_memory_legacy "$ROOT")" || exit 1
if [[ -n "$legacy" ]]; then
  ui_kv "$(t "older sensitive results")" "loomy memory show legacy [N]"
  while IFS= read -r l; do ui_rail " ${l# }"; done <<<"$legacy"
fi
ui_rail_end ""
