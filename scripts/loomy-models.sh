#!/usr/bin/env bash
# Models: the chains in use, and new models to evaluate. Bash 3.2 compatible.
#   loomy-models.sh                  chains per tool and tier (✓ available, ✗ refused), then the new models spotted in
#                                 Codex's model list, the vendors' APIs when a key is set, and the published catalog;
#                                 in a terminal, offers to put a new model at the head of its chain (two fallbacks kept)
#   loomy-models.sh --thrifty on|off prefer the first available fallback over the newest model (low-cost mode)
#   loomy-models.sh --issue          opens (or updates) a GitHub suggestion issue per new model, after your approval
# A chain chosen here only applies to this machine (loomy config chain.<tool>.<tier>); the catalog is unchanged.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

ISSUE=0; THRIFTY=""; YES=0
REPO="${LOOMY_REPO:-Eydenn/loomy}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) shift ;;
    --issue) ISSUE=1 ;;
    --yes|-y) YES=1 ;;
    --thrifty) THRIFTY="${2:-}"; shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//; s/loomy-models.sh/loomy models/g' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy models --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "$THRIFTY" ]]; then
  case "$THRIFTY" in
    on) loomy_config_set models_mode thrifty; t "Low-cost model mode on: the first available fallback of each chain is used."; echo ;;
    off) loomy_config_set models_mode auto; t "Low-cost model mode off: the newest available model of each chain is used."; echo ;;
    *) t "--thrifty: on or off" >&2; echo >&2; exit 2 ;;
  esac
  exit 0
fi

# ---------------------------------------------------------------- known models
KNOWN=" "
for k in CLAUDE_TOP CLAUDE_MID CLAUDE_FAST CODEX_TOP CODEX_MID CODEX_FAST; do eval "KNOWN=\"\$KNOWN\${AI_CHAIN_$k} \""; done
# Older generations and technical entries stay out of the suggestions.
is_candidate() {
  case "$1" in
    *embed*|*audio*|*realtime*|*image*|*tts*|*whisper*|*transcribe*|*search*|*moderation*|*review*|*reserve*|*instant*|*mini-2*|*-latest) return 1 ;;
  esac
  [[ "$KNOWN" == *" $1 "* ]] && return 1
  case " $AI_UPCOMING " in *":$1 "*) return 1 ;; esac
  return 0
}
# tier_of <model>: top, mid or fast, from the naming conventions of each vendor.
tier_of() {
  case "$1" in
    *opus*|*astra*|*fable*|*pro*) echo top ;;
    *haiku*|*luna*|*mini*|*nano*|*flash*) echo fast ;;
    *) echo mid ;;
  esac
}
family_of() { case "$1" in claude-*) echo claude ;; *) echo codex ;; esac; }
# Only models newer than what the chain holds: a model of an older generation is never suggested.
gen_of() { printf '%s' "$1" | grep -oE '[0-9]+([.-][0-9]+)?' | head -1 | tr '-' '.'; }
newer_than_chain() {
  local m="$1" fam tier k chain g top_g
  fam="$(family_of "$m")"; tier="$(tier_of "$m")"; k="$(printf '%s' "${fam}_${tier}" | tr 'a-z' 'A-Z')"
  eval "chain=\"\${AI_CHAIN_$k:-}\""
  g="$(gen_of "$m")"; top_g="$(gen_of "${chain%% *}")"
  [[ -z "$g" || -z "$top_g" ]] && return 0
  awk -v a="$g" -v b="$top_g" 'BEGIN { exit !(a + 0 > b + 0) }'
}

CANDS=()   # "model|source"
add_cand() { local c; for c in ${CANDS[@]+"${CANDS[@]}"}; do [[ "${c%%|*}" == "$1" ]] && return 0; done; CANDS+=("$1|$2"); }
cache="${CODEX_HOME:-$HOME/.codex}/models_cache.json"
if [[ -f "$cache" ]]; then
  for m in $(grep -o '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' "$cache" | sed 's/.*"\([^"]*\)"$/\1/'); do
    [[ "$m" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
    is_candidate "$m" && newer_than_chain "$m" && add_cand "$m" "$(t "Codex model list")"
  done
fi
if [[ -n "${ANTHROPIC_API_KEY:-}" ]] && command -v curl >/dev/null 2>&1; then
  for m in $(curl -s -m 8 https://api.anthropic.com/v1/models -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" 2>/dev/null \
      | grep -o '"id"[[:space:]]*:[[:space:]]*"claude-[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/'); do
    [[ "$m" =~ ^claude-[a-z0-9.-]+$ ]] || continue
    m="$(printf '%s' "$m" | sed -E 's/-[0-9]{8}$//')"
    is_candidate "$m" && newer_than_chain "$m" && add_cand "$m" "Anthropic API"
  done
fi
if [[ -n "${OPENAI_API_KEY:-}" ]] && command -v curl >/dev/null 2>&1; then
  for m in $(curl -s -m 8 https://api.openai.com/v1/models -H "Authorization: Bearer $OPENAI_API_KEY" 2>/dev/null \
      | grep -o '"id"[[:space:]]*:[[:space:]]*"gpt-[^"]*"' | sed 's/.*"\([^"]*\)"$/\1/'); do
    [[ "$m" =~ ^gpt-[a-z0-9.-]+$ ]] || continue
    is_candidate "$m" && newer_than_chain "$m" && add_cand "$m" "OpenAI API"
  done
fi
newcat="$(bash "$SCRIPT_DIR/loomy-catalog-check.sh" 2>/dev/null || true)"

# ---------------------------------------------------------------- display
ui_clear
ui_banner "$(t "Models")" "${C_RESET}${C_DIM}$(t "catalog of %s" "$AI_CATALOG_DATE")$(grep -qx 'models_mode=thrifty' "$(loomy_config_file)" 2>/dev/null && printf ' · %s' "$(t "low-cost mode")")${C_RESET}"
ui_section "$(t "CHAINS")" "$(t "newest first; the first available one is used")"
for fam in claude codex; do
  for tier in top mid fast; do
    k="$(printf '%s' "${fam}_${tier}" | tr 'a-z' 'A-Z')"
    eval "chain=\"\${AI_CHAIN_$k:-}\"; used=\"\${AI_MODEL_$k:-}\""
    line=""; used="${used:-}"
    for m in $chain; do
      if ai_model_usable "$m" "$fam"; then mk="${C_GREEN}✓${C_RESET}"; else mk="${C_RED}✗${C_RESET}"; fi
      [[ "$m" == "$used" ]] && m="${C_BOLD}$m${C_RESET}"
      line="${line:+$line ${C_DIM}→${C_RESET} }$mk $m"
    done
    _ui_pad "$fam.$tier" 12
    ui_rail "${C_DIM}${UI_PADDED}${C_RESET}$line"
  done
done
if [[ -n "$AI_UPCOMING" ]]; then
  ui_section "$(t "ANNOUNCED")" "$(t "tested once a day; used as soon as they answer")"
  for e in $AI_UPCOMING; do
    m="${e##*:}"; tier="${e#*:}"; tier="${tier%%:*}"
    if grep -qx "$m=ok" "$(ai_models_state_file)" 2>/dev/null; then ui_rail "${C_GREEN}✓${C_RESET} $m  ${C_DIM}$(t "available · heads %s" "${e%%:*}.$tier")${C_RESET}"
    else ui_rail "${C_DIM}○ $m  $(t "not available yet · will head %s" "${e%%:*}.$tier")${C_RESET}"; fi
  done
fi
ui_section "$(t "NEW MODELS")"
if [[ -n "$newcat" ]]; then ui_rail "${C_YELLOW}!${C_RESET} $(t "a newer catalog is published (%s): loomy update --catalog" "$newcat")"; fi
if (( ! ${#CANDS[@]} )); then
  ui_info "$(t "none spotted (Codex model list%s)" "$( [[ -n "${ANTHROPIC_API_KEY:-}${OPENAI_API_KEY:-}" ]] && printf ', %s' "$(t "vendor APIs")")")"
  [[ -z "${ANTHROPIC_API_KEY:-}${OPENAI_API_KEY:-}" ]] && ui_info "$(t "with ANTHROPIC_API_KEY or OPENAI_API_KEY set, the vendors' model lists are checked too")"
  ui_end "$(t "low-cost mode: loomy models --thrifty on")"
  exit 0
fi
for c in "${CANDS[@]}"; do
  m="${c%%|*}"; fam="$(family_of "$m")"; tier="$(tier_of "$m")"
  ui_rail "${C_BRAND}✦${C_RESET} ${C_BOLD}$m${C_RESET}  ${C_DIM}${c#*|} · $(t "tier %s" "$fam.$tier")${C_RESET}"
done

# ---------------------------------------------------------------- put at the head of a chain
if ui_is_interactive; then
  for c in "${CANDS[@]}"; do
    m="${c%%|*}"; fam="$(family_of "$m")"; tier="$(tier_of "$m")"; k="$(printf '%s' "${fam}_${tier}" | tr 'a-z' 'A-Z')"
    eval "chain=\"\${AI_CHAIN_$k:-}\""
    new="$m $(printf '%s' "$chain" | cut -d' ' -f1-2)"; new="$(printf '%s' "$new" | sed 's/ *$//')"
    UI_DESCS=("$(t "This machine only: %s. The previous models stay as fallbacks." "$(printf '%s' "$new" | sed 's/ / → /g')")" "$(t "Keeps the catalog's chain.")")
    ui_choose "$(t "Try %s at the head of %s?" "$m" "$fam.$tier")" 1 "$(t "Yes, put it first")" "$(t "No")"
    if [[ "$UI_INDEX" == "0" ]]; then loomy_config_set "chain.$fam.$tier" "$(printf '%s' "$new" | sed 's/ /, /g')"; ui_ok "$(t "chain %s: %s" "$fam.$tier" "$new")"; fi
  done
fi

# ---------------------------------------------------------------- GitHub suggestion issues
if (( ISSUE )); then
  command -v gh >/dev/null 2>&1 || { ui_err "$(t "gh not found")" "$(t "loomy doctor --fix installs it")"; exit 1; }
  if ! (( YES )); then
    if ! ui_is_interactive; then ui_err "$(t "confirmation needed")" "loomy models --issue --yes"; exit 1; fi
    UI_DESCS=("$(t "One issue per model on %s (label models); an existing one gets a comment instead." "$REPO")" "$(t "Nothing is sent.")")
    ui_choose "$(t "Send %s suggestion(s) to GitHub?" "${#CANDS[@]}")" 1 "$(t "Yes, send")" "$(t "No")"
    [[ "$UI_INDEX" == "0" ]] || { ui_end "$(t "nothing sent")"; exit 0; }
  fi
  gh label create models -R "$REPO" --color 7C5CFF --description "New model to evaluate" >/dev/null 2>&1 || true
  for c in "${CANDS[@]}"; do
    m="${c%%|*}"; src="${c#*|}"; fam="$(family_of "$m")"; tier="$(tier_of "$m")"
    body="Spotted by \`loomy models\` ($src) on $(date +%Y-%m-%d), Loomy $(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null).
Suggested tier: \`$fam.$tier\`. To evaluate before the catalog is published (docs/MODEL_CATALOG.md, protocol when a new model comes out)."
    num="$(gh issue list -R "$REPO" --label models --state all --search "\"$m\" in:title" --json number,title --jq ".[] | select(.title | contains(\"$m\")) | .number" 2>/dev/null | head -1)"
    if [[ -n "$num" ]]; then
      gh issue comment "$num" -R "$REPO" --body "$body" >/dev/null 2>&1 && ui_ok "$(t "issue #%s updated: %s" "$num" "$m")" || ui_warn "$(t "issue not updated: %s" "$m")" ""
    else
      url="$(gh issue create -R "$REPO" --label models --title "Model to evaluate: $m" --body "$body" 2>/dev/null)" && ui_ok "$(t "issue created: %s" "$url")" || ui_warn "$(t "issue not created: %s" "$m")" ""
    fi
  done
fi
ui_end "$(t "suggest them on GitHub: loomy models --issue · low-cost mode: loomy models --thrifty on")"
