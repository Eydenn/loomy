#!/usr/bin/env bash
# Model / effort routing per role for this project. Bash 3.2 compatible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"

usage() {
  i18n_lines >&2 <<'EOF'
Usage: ai-route.sh [options] [command]

Commands:
  (none)                Shows the role → model / effort / tool matrix for this project
  get <role>            One "family model effort" line (for scripts)
  markdown              Matrix as Markdown (for .ai/AI_MODEL_ROUTING.md)
  all                   Matrix of the 4 environments side by side (Markdown)
  claude-agents [DIR]   Generates the Claude Code subagents (default: <project>/.claude/agents)
  codex-profiles        TOML excerpt of the Codex profiles per role (to add to ~/.codex/config.toml)
  lead                  Launch command of the main session (lead agent)

Options:
  --root DIR            Project (default: current project)
  --env ENV             claude | codex | hybrid-claude | hybrid-codex (default: detected)
  --profile P           econome | equilibre | qualite (default: brief, otherwise equilibre)

Roles: lead architect debugger security reviewer developer executor explorer documenter
EOF
}

ROOT=""; ENV_OPT=""; PROFILE_OPT=""; CMD="show"; ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --env) ENV_OPT="${2:-}"; shift ;;
    --profile) PROFILE_OPT="${2:-}"; shift ;;
    -h|--help) usage; exit 0 ;;
    get|claude-agents) CMD="$1"; if [[ $# -ge 2 && "$2" != -* ]]; then ARG="$2"; shift; fi ;;
    markdown|all|codex-profiles|lead|show) CMD="$1" ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -z "$ROOT" ]]; then
  if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
  else ROOT="$(ai_project_root)"; fi
fi
ROOT="$(cd "$ROOT" && pwd)"

[[ -n "$ENV_OPT" ]] && export AI_ROUTE_ENV="$ENV_OPT"
[[ -n "$PROFILE_OPT" ]] && export AI_ROUTE_PROFILE="$PROFILE_OPT"
ai_detect_env "$ROOT"
case "$AI_ENV" in claude|codex|hybrid-claude|hybrid-codex) ;; *) t "Unknown environment: %s" "$AI_ENV" >&2; echo >&2; exit 2 ;; esac
case "$AI_PROFILE" in econome|equilibre|qualite) ;; *) t "Unknown profile: %s" "$AI_PROFILE" >&2; echo >&2; exit 2 ;; esac

valid_role() { case " $AI_ROLES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

case "$CMD" in
  get)
    valid_role "$ARG" || { t "Unknown role: \"%s\"" "$ARG" >&2; echo >&2; exit 2; }
    ai_resolve "$ARG" "$AI_ENV" "$AI_PROFILE"
    echo "$R_FAMILY $R_MODEL $R_EFFORT"
    ;;

  lead)
    ai_lead_command "$AI_ENV" "$AI_PROFILE"
    ;;

  markdown)
    t "Environment: **%s** · profile **%s** · catalog from %s" "$(ai_env_label "$AI_ENV")" "$(ai_profile_label "$AI_PROFILE")" "$AI_CATALOG_DATE"; echo
    if [[ -n "$AI_ENV_NOTE" ]]; then echo ""; t "> Fallback: %s" "$AI_ENV_NOTE"; echo; fi
    echo ""
    t "| Role | Scope | Tool | Model | Effort | How to call it |"; echo
    echo "|---|---|---|---|---|---|"
    for r in $AI_ROLES; do
      ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
      echo "| $(ai_role_label "$r") | $(ai_role_scope "$r") | $R_FAMILY | \`$R_MODEL\` | $R_EFFORT | \`$R_VIA\` |"
    done
    echo ""
    t "Launch the lead agent: \`%s\`" "$(ai_lead_command "$AI_ENV" "$AI_PROFILE")"; echo
    ;;

  all)
    t "Profile **%s**" "$(ai_profile_label "$AI_PROFILE")"; echo
    echo ""
    t "| Role | Full Claude Code | Full Codex | Hybrid, Claude lead | Hybrid, Codex lead |"; echo
    echo "|---|---|---|---|---|"
    for r in $AI_ROLES; do
      line="| $(ai_role_label "$r") |"
      for e in claude codex hybrid-claude hybrid-codex; do
        ai_resolve "$r" "$e" "$AI_PROFILE"
        line="$line \`$R_MODEL\` $R_EFFORT |"
      done
      echo "$line"
    done
    ;;

  claude-agents)
    dest="${ARG:-$ROOT/.claude/agents}"
    # The project's own copy first (installed in its language), otherwise the one shipped with Loomy.
    tpl_dir="$ROOT/.loomy/templates/claude-agents"; [[ -d "$tpl_dir" ]] || tpl_dir="$SCRIPT_DIR/../templates/claude-agents"
    [[ -d "$tpl_dir" ]] || { t "Agent templates not found: %s" "$tpl_dir" >&2; echo >&2; exit 1; }
    lead="${AI_ENV#hybrid-}"
    if [[ "$lead" != "claude" ]]; then
      t "Codex lead: no native Claude subagent. Claude roles go through delegate-to-claude.sh." >&2; echo >&2
      exit 0
    fi
    mkdir -p "$dest"
    for r in $AI_ROLES; do
      [[ "$r" == "lead" ]] && continue
      ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
      [[ "$R_FAMILY" == "claude" ]] || continue
      [[ -f "$tpl_dir/$r.md" ]] || continue
      sed -e "s/__MODEL__/$R_MODEL/" -e "s/__EFFORT__/$R_EFFORT/" "$tpl_dir/$r.md" >"$dest/$r.md"
      # Structured delegations: the subagent answers the lead agent with the same fixed fields as the bridges.
      if [[ "$(ai_delegation_format "$ROOT")" == "structured" ]]; then printf '\n%s\n' "$(ai_result_contract)" >>"$dest/$r.md"; fi
      echo "$dest/$r.md  ($R_MODEL, $R_EFFORT)"
    done
    ;;

  codex-profiles)
    printf '# '; t "Loomy — Codex profiles per role (profile %s, catalog from %s)" "$(ai_profile_label "$AI_PROFILE")" "$AI_CATALOG_DATE"; echo
    echo "# Usage : codex --profile ai-lead | ai-developer | …"
    for r in $AI_ROLES; do
      ai_route "$r" codex "$AI_PROFILE"
      echo ""
      echo "[profiles.ai-$r]"
      echo "model = \"$R_MODEL\""
      echo "model_reasoning_effort = \"$R_EFFORT\""
    done
    ;;

  show)
    ui_banner "$(t "Model routing")" "$(ai_env_label "$AI_ENV") · $(t "%s profile" "$(ai_profile_label "$AI_PROFILE")") · $(t "catalog from %s" "$AI_CATALOG_DATE")"
    [[ -n "$AI_ENV_NOTE" ]] && ui_warn "$(t "Fallback")" "$AI_ENV_NOTE"
    ui_section "$(t "ROLES")" "$(t "model · effort · how to call it")"
    for r in $AI_ROLES; do
      ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
      _ui_pad "$(ai_role_label "$r")" 22; label="$UI_PADDED"
      _ui_pad "$R_MODEL" 18; model="$UI_PADDED"
      _ui_pad "$R_EFFORT" 8; effort="$UI_PADDED"
      color="$C_CYAN"; [[ "$R_TIER" == "TOP" ]] && color="$C_MAGENTA"; [[ "$R_TIER" == "FAST" ]] && color="$C_GREEN"
      if [[ "$r" == "lead" ]]; then label="${C_BRAND}${label}${C_RESET}"; else label="${C_BOLD}${label}${C_RESET}"; fi
      ui_rail "${label}${color}${model}${C_RESET}${effort}${C_DIM}${R_VIA}${C_RESET}"
      if [[ "$r" == "lead" && "$R_FAMILY" == "claude" ]]; then
        adv="$(ai_advisor_for "$R_MODEL" "$AI_PROFILE")"
        if [[ -n "$adv" ]]; then _ui_pad "  $(t "advisor")" 22; ui_rail "${C_DIM}${UI_PADDED}${C_RESET}${C_MAGENTA}$adv${C_RESET} ${C_DIM}$(t "consulted before a plan, when an error repeats, before done (loomy config set advisor)")${C_RESET}"; fi
      fi
    done
    ui_rail ""
    ui_rail "${C_DIM}$(t "colors:")${C_RESET} ${C_MAGENTA}$(t "top")${C_RESET} ${C_DIM}·${C_RESET} ${C_CYAN}$(t "standard")${C_RESET} ${C_DIM}·${C_RESET} ${C_GREEN}$(t "fast")${C_RESET}"
    ui_section "$(t "START THE LEAD AGENT")"
    ui_rail "${C_BOLD}$(ai_lead_command "$AI_ENV" "$AI_PROFILE")${C_RESET}"
    ui_end "$(t "compare environments: loomy route all · other profile: loomy route --profile qualite")"
    ;;
esac
