#!/usr/bin/env bash
# shellcheck disable=SC2034  # UI_* are read by lib/ui.sh
# Environment check for Loomy: minimum and ideal requirements, model availability,
# optional real test of each routed model, and guided fixes. Bash 3.2 compatible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/journal.sh
source "$SCRIPT_DIR/lib/journal.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"
# shellcheck source=lib/repair.sh
source "$SCRIPT_DIR/lib/repair.sh"

usage() {
  i18n_lines >&2 <<'EOF'
Usage: ai-doctor.sh [--root DIR] [--fix] [--live] [--compact]

  --fix       Offers and applies the possible fixes (with confirmation)
  --live      Tests each model of the matrix with a real minimal call (a few cents)
  --compact   Short output (used by the questionnaire)
  --root DIR  Project to check (default: current project)

Exit code: 0 when the minimum is met, 1 otherwise.
EOF
}

ROOT=""; FIX=0; LIVE=0; COMPACT=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --fix) FIX=1 ;;
    --live) LIVE=1 ;;
    --compact) COMPACT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) t "Unknown argument: %s" "$1" >&2; echo >&2; usage; exit 2 ;;
  esac
  shift
done
if [[ -z "$ROOT" ]]; then
  if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
  else ROOT="$(ai_project_root)"; fi
fi
ROOT="$(cd "$ROOT" && pwd)"

MIN_OK=1          # minimum requirements met
IDEAL_MISSING=""  # missing ideal items, comma separated

missing_ideal() { IDEAL_MISSING="${IDEAL_MISSING:+$IDEAL_MISSING, }$1"; }

# offer_fix <question> <command...>: asks, then runs the command. Returns 0 when it was applied.
offer_fix() {
  local q="$1"; shift
  # Internal fixes (a small shell script) are described by their question, not by their raw command.
  local shown="$*"; [[ "$1" == "sh" && "${2:-}" == "-c" && "${3:-}" == *printf* ]] && shown="$q"
  if (( ! FIX )) || ! ui_is_interactive; then
    if [[ "$shown" == "$q" ]]; then ui_info "$(t "fix: %s" "loomy doctor --fix")"; else ui_info "$(t "fix: %s" "$shown")"; fi
    return 1
  fi
  UI_DESCS=("$(t "Runs: %s" "$shown")" "$(t "No change.")")
  ui_choose "$q" 0 "$(t "Yes")" "$(t "No")"
  if [[ "$UI_INDEX" == "0" ]]; then
    if "$@"; then ui_ok "$(t "Fixed")"; return 0; fi
    ui_err "$(t "The fix failed")" "$*"
  fi
  return 1
}

# install_hint <recommended command> <alternative> <login>: official install commands of a missing CLI.
install_hint() {
  ui_rail "    ${C_DIM}$(t "install:")${C_RESET} ${C_BOLD}$1${C_RESET}"
  ui_rail "    ${C_DIM}$(t "or:     ")${C_RESET} $2"
  ui_rail "    ${C_DIM}$(t "then:   ")${C_RESET} $3"
}

# Check only: normal output; with --fix (questions), Loomy screen.
(( COMPACT )) || (( ! FIX )) || ui_clear
(( COMPACT )) || ui_banner "$(t "Diagnostics")" "$(t "Prerequisites, models and fixes") · $(t "catalog from %s" "$AI_CATALOG_DATE")"

# ---------------------------------------------------------------- installation de Loomy
LOOMY_BIN="$SCRIPT_DIR/../bin/loomy"
if (( ! COMPACT )) && [[ -x "$LOOMY_BIN" ]]; then
  ui_section "$(t "LOOMY")" "$(t "installs found in the PATH")"
  # The installs listing (without its first "loomy x.y.z" line), drawn on this screen.
  while IFS= read -r l; do ui_print "$l"; done < <(LOOMY_NO_CLEAR=1 LOOMY_FORCE_COLOR="$( [[ -n "$C_RESET" ]] && echo 1)" "$LOOMY_BIN" version --all 2>&1 </dev/null | grep -v "^loomy [0-9]")
fi

# ---------------------------------------------------------------- system
ui_section "$(t "SYSTEM")"
ui_ok "bash ${BASH_VERSION%%(*}" "$(uname -s)"
if command -v git >/dev/null 2>&1; then
  ui_ok "git" "$(git --version | awk '{print $3}')"
else
  ui_err "git" "$(t "required — https://git-scm.com/downloads")"; MIN_OK=0
fi

# ---------------------------------------------------------------- CLI IA
ui_section "$(t "AI CLIS")" "$(t "at least one required; ideal: both, for hybrid mode")"
HAS_C=0; HAS_X=0
if ai_has_claude; then
  ui_wait "$(t "Checking Claude Code")"; v="$(ai_claude_version)"; ui_wait_end
  # Several copies in the PATH: the first one runs, whatever the others are (a frequent cause of "the update changed nothing").
  n_c="$(ai_tool_paths claude | wc -l | tr -d ' ')"
  if (( n_c > 1 )); then
    ui_info "$(t "%s copies of claude in the PATH, the first one runs: %s" "$n_c" "$(ai_tool_paths claude | while IFS= read -r p; do printf '%s (%s, %s) ' "${p/#$HOME/~}" "$(ai_tool_method claude "$p")" "$(ai_tool_version_of "$p")"; done)")"
  fi
  if ai_version_ge "${v:-0.0.0}" "$AI_MIN_CLAUDE_VERSION"; then
    HAS_C=1; ui_ok "claude $v" "Claude Code · $(command -v claude | sed "s|^$HOME|~|")"
  else
    ui_warn "claude $v" "$(t "too old for %s (≥ %s)" "$AI_MODEL_CLAUDE_TOP" "$AI_MIN_CLAUDE_VERSION")"
    HAS_C=1
    if (( FIX )) && ai_repair_tool claude; then ui_ok "claude $(ai_tool_state claude | cut -d' ' -f2)" "$(t "repaired")"
    else (( FIX )) || ui_info "$(t "fix: %s" "loomy doctor --fix")"; missing_ideal "$(t "Claude Code up to date")"; fi
  fi
else
  ui_warn "claude" "$(t "Claude Code missing: %s lead agent and hybrid mode unavailable" "$AI_MODEL_CLAUDE_TOP")"
  install_hint "curl -fsSL https://claude.ai/install.sh | bash" "brew install --cask claude-code" "claude  ($(t "log in on first launch"))"
  if (( FIX )) && ai_repair_tool claude; then
    ui_ok "claude $(ai_tool_state claude | cut -d' ' -f2)" "$(t "installed; run claude once to log in")"
  else
    missing_ideal "Claude Code"
  fi
fi

CODEX_BIN="$(ai_codex_bin || true)"
if [[ -n "$CODEX_BIN" ]]; then
  ui_wait "$(t "Checking Codex")"; v="$(ai_codex_version)"; ui_wait_end
  cpath="$(command -v codex 2>/dev/null || true)"
  if [[ -n "$cpath" ]] && _ai_wrapper_ok "$cpath"; then
    ui_ok "codex ${v:-?}" "Codex CLI · $(printf '%s' "$CODEX_BIN" | sed "s|^$HOME|~|")"
  else
    # A ~/.local/bin/codex script pointing to a bundled CLI that moved (desktop app update): Loomy uses the new one,
    # the codex command typed in a terminal is broken until the script is rewritten.
    if [[ -n "$cpath" ]]; then ui_warn "codex ${v:-?}" "$(t "%s points to a Codex CLI that no longer exists (desktop app updated); Loomy uses %s" "$(printf '%s' "$cpath" | sed "s|^$HOME|~|")" "$(printf '%s' "$CODEX_BIN" | sed "s|^$HOME|~|")")"
    else ui_warn "codex ${v:-?}" "$(t "found in %s but not in the PATH" "$CODEX_BIN")"; fi
    mkdir -p "$HOME/.local/bin"
    # A small script, not a link: the shipped CLI looks for its helper programs next to the path it is called by.
    if [[ -z "$cpath" || "$cpath" == "$HOME/.local/bin/codex" ]] && offer_fix "$(t "Make the Codex CLI reachable (small ~/.local/bin/codex script)?")" \
         sh -c 'printf "#!/bin/sh\nexec \"%s\" \"\$@\"\n" "$1" > "$HOME/.local/bin/codex" && chmod +x "$HOME/.local/bin/codex"' _ "$CODEX_BIN"; then
      case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) ui_warn "$(t "%s not in the PATH" "$HOME/.local/bin")" "$(t "add:") export PATH=\"\$HOME/.local/bin:\$PATH\"" ;; esac
    fi
  fi
  HAS_X=1
  if [[ -n "$v" ]] && ! ai_version_ge "$v" "$AI_MIN_CODEX_VERSION"; then
    ui_warn "codex $v" "$(t "older than the validated version (%s)" "$AI_MIN_CODEX_VERSION")"
    if (( FIX )) && ai_repair_tool codex; then ui_ok "codex $(ai_tool_state codex | cut -d' ' -f2)" "$(t "repaired")"
    else (( FIX )) || ui_info "$(t "fix: %s" "loomy doctor --fix")"; missing_ideal "$(t "Codex up to date")"; fi
  fi
  if [[ ! -f "$HOME/.codex/auth.json" ]]; then
    ui_warn "codex" "$(t "not logged in — run: codex login")"; missing_ideal "$(t "Codex logged in")"
  fi
  cache="$HOME/.codex/models_cache.json"
  if [[ -f "$cache" ]]; then
    miss=""
    for m in "$AI_MODEL_CODEX_TOP" "$AI_MODEL_CODEX_MID" "$AI_MODEL_CODEX_FAST"; do
      grep -q "\"$m\"" "$cache" || miss="${miss:+$miss, }$m"
    done
    if [[ -z "$miss" ]]; then ui_ok "$(t "Codex models")" "$(t "%s available" "$AI_MODEL_CODEX_TOP, $AI_MODEL_CODEX_MID, $AI_MODEL_CODEX_FAST")"
    else ui_warn "$(t "Codex models")" "$(t "missing from the local catalog: %s (plan, region or CLI to update)" "$miss")"; missing_ideal "$(t "Codex models")"; fi
  fi
else
  ui_warn "codex" "$(t "Codex CLI missing: %s executor and hybrid mode unavailable" "$AI_MODEL_CODEX_FAST")"
  install_hint "curl -fsSL https://chatgpt.com/codex/install.sh | sh" "brew install --cask codex  ·  npm install -g @openai/codex" "codex  ($(t "log in on first launch"))"
  if (( FIX )) && ai_repair_tool codex; then
    ui_ok "codex $(ai_tool_state codex | cut -d' ' -f2)" "$(t "installed; run codex once to log in")"
  else
    missing_ideal "Codex CLI"
  fi
fi

if (( ! HAS_C && ! HAS_X )); then
  ui_err "$(t "No AI CLI")" "$(t "install Claude Code or Codex (minimum required)")"; MIN_OK=0
fi

# ---------------------------------------------------------------- confort
ui_section "$(t "COMFORT")" "$(t "optional")"
# GitHub: gh installed, logged in, and git authenticating with it (private repositories, including the Loomy tap).
# With --fix, the three steps run one after the other.
if ! command -v gh >/dev/null 2>&1; then
  ui_warn "$(t "gh missing")" "$(t "useful to create GitHub repositories and install Loomy from the private tap")"
  if command -v brew >/dev/null 2>&1 && offer_fix "$(t "Install gh (brew install gh)?")" ui_external brew install gh; then :; else missing_ideal "gh"; fi
fi
if command -v gh >/dev/null 2>&1; then
  ui_wait "$(t "GitHub login (gh)")"; gh_ok=0; gh auth status >/dev/null 2>&1 && gh_ok=1; ui_wait_end
  if (( ! gh_ok )); then
    ui_warn "gh" "$(t "not logged in to GitHub")"
    offer_fix "$(t "Log in to GitHub now (gh auth login)?")" ui_external gh auth login && gh auth status >/dev/null 2>&1 && gh_ok=1
  fi
  if (( gh_ok )); then
    ui_ok "gh" "$(t "logged in to GitHub")"
    # Real git access to the Loomy repository (private during the pre-release): that's what the Homebrew tap needs.
    # Not in the loomy init check (--compact): unrelated to the project being created.
  fi
  if (( gh_ok )) && (( ! COMPACT )); then
    loomy_repo="https://github.com/${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}.git"
    ui_wait "$(t "Git access to the Loomy repository")"; git_ok=0
    GIT_TERMINAL_PROMPT=0 git ls-remote "$loomy_repo" HEAD >/dev/null 2>&1 && git_ok=1; ui_wait_end
    if (( ! git_ok )); then
      ui_warn "$(t "git → Loomy repository")" "$(t "access denied: git doesn't authenticate with GitHub (or the invitation isn't accepted yet)")"
      if offer_fix "$(t "Set git up to use your gh account (gh auth setup-git)?")" gh auth setup-git \
         && GIT_TERMINAL_PROMPT=0 git ls-remote "$loomy_repo" HEAD >/dev/null 2>&1; then git_ok=1
      else ui_info "$(t "repository invitation: %s" "https://github.com/${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}/invitations")"; missing_ideal "$(t "git access to the Loomy repository")"; fi
    fi
    (( git_ok )) && ui_ok "$(t "git → Loomy repository")" "$(t "access checked (Homebrew updates possible)")"
  elif (( ! gh_ok )); then
    missing_ideal "$(t "gh logged in")"
  fi
fi
if command -v pbcopy >/dev/null 2>&1 || command -v wl-copy >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1; then
  ui_ok "$(t "clipboard")" "$(t "automatic copy of the start prompt")"
else
  ui_info "$(t "clipboard unavailable (wl-copy or xclip on Linux)")"
fi

# ---------------------------------------------------------------- preferences
ui_section "$(t "PREFERENCES")" "$(t "loomy config")"
for fam in claude codex; do
  name="$(t "Claude plan")"; [[ "$fam" == "codex" ]] && name="$(t "Codex plan")"
  plan="$(loomy_config_get "plan_$fam" "")"
  if [[ -z "$plan" ]]; then ui_kv "$name" "$(t "not set") (loomy config set plan_$fam …)"
  else ui_kv "$name" "$(ai_plan_label "$fam" "$plan")${plan:+ $(p="$(loomy_plan_monthly "$fam")"; [[ -n "$p" ]] && echo "· $p \$/$(t "month")")}"; fi
done

# ---------------------------------------------------------------- routage
ai_detect_env "$ROOT"
# Advisor (Claude Code's advisor tool): it needs feature-flag fetching, which some variables turn off silently.
if (( HAS_C )); then
  ai_resolve lead "$AI_ENV" "$AI_PROFILE"
  adv="$(ai_advisor_for "$R_MODEL" "$AI_PROFILE")"
  if [[ -n "$adv" ]]; then
    blk=""; for vname in DISABLE_TELEMETRY CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC; do [[ -n "${!vname:-}" ]] && blk="${blk:+$blk, }$vname"; done
    if [[ -n "$blk" ]]; then ui_warn "$(t "advisor %s" "$adv")" "$(t "stays off: %s set (it blocks the feature flags the advisor needs)" "$blk")"
    else ui_ok "$(t "advisor %s" "$adv")" "$(t "for the %s lead agent (loomy config set advisor off to turn it off)" "$R_MODEL")"; fi
  fi
fi
ui_section "$(t "CATALOG")" "$(t "models and prices")"
cat_ep="$(ai_ts_epoch "${AI_CATALOG_DATE}T00:00:00Z")"; age=""
[[ -n "$cat_ep" ]] && age=$(( ( $(date +%s) - cat_ep ) / 86400 ))
if [[ -n "$age" ]] && (( age > 60 )); then ui_warn "$(t "catalog from %s" "$AI_CATALOG_DATE") ($(t "$AI_CATALOG_SOURCE"))" "$(t "it's %s days old: loomy update --catalog" "$age")"
else ui_ok "$(t "catalog from %s" "$AI_CATALOG_DATE")" "$(t "$AI_CATALOG_SOURCE")"; fi
newcat="$(bash "$SCRIPT_DIR/ai-catalog-check.sh" 2>/dev/null || true)"
[[ -n "$newcat" ]] && ui_warn "$(t "catalog from %s published" "$newcat")" "$(t "loomy update --catalog")"
# Models of a chain refused on this machine (fallback in progress): to test again after a plan change.
ko="$(grep '=ko$' "$(ai_models_state_file)" 2>/dev/null | cut -d= -f1 | paste -sd ',' - | sed 's/,/, /g' || true)"
[[ -n "$ko" ]] && ui_info "$(t "unavailable here (fallback used): %s · to retest: loomy doctor --live" "$ko")"

ui_section "$(t "ROUTING")"
ui_ok "$(ai_env_label "$AI_ENV")" "$(t "%s profile" "$(ai_profile_label "$AI_PROFILE")")"
[[ -n "$AI_ENV_NOTE" ]] && ui_warn "$(t "Fallback")" "$AI_ENV_NOTE"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
ui_info "$(t "lead agent: %s (%s) · details: loomy route" "$R_MODEL" "$R_EFFORT")"

# ---------------------------------------------------------------- project
# A Loomy project whose setup is unfinished (bootstrap abandoned, subagents never generated, hooks missing) works
# silently wrong: the lead agent does the roles' work itself. Each gap is a warning with its fix, and keeps the
# summary from saying "ideal". Not in the questionnaire (--compact): the project is being created there.
if (( ! COMPACT )) && [[ -f "$ROOT/.loomy/brief.md" ]]; then
  ui_section "$(t "PROJECT")" "$(t "setup of %s" "$(_ai_brief_get "$ROOT/.loomy/brief.md" name)")"
  p_gaps=0
  p_phase="$(sed -n 's/^phase=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
  p_since="$(sed -n 's/^updated=//p' "$ROOT/.loomy/state" 2>/dev/null | head -1 || true)"
  p_pending=0; grep -q 'BOOTSTRAP_PENDING' "$ROOT/START.md" 2>/dev/null && p_pending=1
  p_unfinished=0
  if [[ -n "$p_phase" && "$p_phase" != "done" ]] || (( p_pending )); then p_unfinished=1; fi
  if (( p_unfinished )); then
    ui_warn "$(t "bootstrap unfinished")" "$(t "START.md still pending (phase: %s%s)" "${p_phase:-?}" "${p_since:+, $(t "since %s" "$p_since")}")"
    ui_info "$(t "fix: %s" "loomy start")  ($(t "or archive START.md in .ai/bootstrap/ if the setup is in fact complete"))"
    missing_ideal "$(t "bootstrap finished")"; p_gaps=$(( p_gaps + 1 ))
  else
    ui_ok "$(t "bootstrap finished")" "$(t "START.md archived")"
  fi
  if [[ ! -d "$ROOT/.ai" ]]; then
    ui_warn "$(t ".ai/ folder missing")" "$(t "created by the bootstrap: routing, workflow and orchestration rules")"
    ui_info "$(t "fix: %s" "loomy start")"
    missing_ideal ".ai/"; p_gaps=$(( p_gaps + 1 ))
  else
    ui_ok ".ai/" "$(t "present")"
  fi
  p_lead="${AI_LEAD:-${AI_ENV#hybrid-}}"
  if [[ "$p_lead" == "claude" ]]; then
    # Subagents of the roles the routing keeps on Claude (the same ones ai-route.sh claude-agents generates).
    p_tpl="$ROOT/.loomy/templates/claude-agents"; [[ -d "$p_tpl" ]] || p_tpl="$SCRIPT_DIR/../templates/claude-agents"
    p_miss=""
    for r in $AI_ROLES; do
      [[ "$r" == "lead" ]] && continue
      ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"
      [[ "$R_FAMILY" == "claude" && -f "$p_tpl/$r.md" ]] || continue
      [[ -f "$ROOT/.claude/agents/$r.md" ]] || p_miss="${p_miss:+$p_miss, }$r"
    done
    if [[ -n "$p_miss" ]]; then
      ui_warn "$(t "subagents missing in .claude/agents/")" "$p_miss"
      ui_info "$(t "fix: %s" ".loomy/scripts/ai-route.sh claude-agents")"
      missing_ideal "$(t "Claude subagents")"; p_gaps=$(( p_gaps + 1 ))
    else
      ui_ok "$(t "Claude subagents")" "$(t "every routed role has its .claude/agents/ file")"
    fi
    p_hmiss=""
    for h in start end stop subagent; do grep -qF -- "--hook $h" "$ROOT/.claude/settings.json" 2>/dev/null || p_hmiss="${p_hmiss:+$p_hmiss, }$h"; done
    [[ "$AI_MODE" == "ORCHESTRATED" ]] && ! grep -qF -- "--hook prompt" "$ROOT/.claude/settings.json" 2>/dev/null && p_hmiss="${p_hmiss:+$p_hmiss, }prompt"
    if [[ -n "$p_hmiss" ]]; then
      ui_warn "$(t "Loomy hooks missing in .claude/settings.json")" "$p_hmiss"
      ui_info "$(t "fix: %s" "loomy init --update")"
      missing_ideal "$(t "Claude Code hooks")"; p_gaps=$(( p_gaps + 1 ))
    else
      ui_ok "$(t "Claude Code hooks")" "$(t "in .claude/settings.json")"
    fi
  elif [[ "$p_lead" == "codex" ]]; then
    if ! grep -qF -- "--hook start" "$ROOT/.codex/hooks.json" 2>/dev/null; then
      ui_warn "$(t "Loomy hooks missing in .codex/hooks.json")" "SessionStart"
      ui_info "$(t "fix: %s" "loomy init --update")"
      missing_ideal "$(t "Codex hooks")"; p_gaps=$(( p_gaps + 1 ))
    else
      ui_ok "$(t "Codex hooks")" "$(t "in .codex/hooks.json")"
    fi
  fi
fi

# ---------------------------------------------------------------- real test
if (( LIVE )); then
  ui_section "$(t "LIVE MODEL TEST")"
  ui_info "$(t "every catalog model for each installed CLI (one low-effort \"OK\" per model)")"
  # Models used by the current routing: a failure there is blocking, elsewhere it's a warning.
  routed=" "
  for r in $AI_ROLES; do ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"; routed="$routed$R_FAMILY:$R_MODEL "; done
  # Every model of the catalog chains (fallbacks included); the result is remembered for this machine.
  keys=""
  for m in $AI_CHAIN_CLAUDE_TOP $AI_CHAIN_CLAUDE_MID $AI_CHAIN_CLAUDE_FAST; do keys="$keys claude:$m"; done
  for m in $AI_CHAIN_CODEX_TOP $AI_CHAIN_CODEX_MID $AI_CHAIN_CODEX_FAST; do keys="$keys codex:$m"; done
  # Announced models not in a chain yet: tested too (a success puts them at the head of their chain).
  for e in $AI_UPCOMING; do case "$keys " in *":${e##*:} "*) ;; *) keys="$keys ${e%%:*}:${e##*:}" ;; esac; done
  for key in $keys; do
    fam="${key%%:*}"; model="${key#*:}"
    if [[ "$fam" == "claude" ]]; then
      (( HAS_C )) || continue
      ui_wait "$(t "Testing %s" "$model")"
      out="$(cd "${TMPDIR:-/tmp}" && claude -p "Reply exactly: OK" --output-format json --max-turns 1 --model "$model" --effort low 2>&1 || true)"
      if grep -q '"is_error":false' <<<"$out"; then ok=1; why=""
      else ok=0; why="$(printf '%s' "$out" | grep -oE '"result":"[^"]{0,120}' | head -1 | sed 's/"result":"//' || true)"; fi
    else
      (( HAS_X )) || continue
      tmpf="$(mktemp)"
      ui_wait "$(t "Testing %s" "$model")"
      if "$CODEX_BIN" exec -m "$model" -c model_reasoning_effort=low -s read-only --skip-git-repo-check --ephemeral \
           -o "$tmpf" "Reply exactly: OK" </dev/null >/dev/null 2>&1 && grep -q OK "$tmpf"; then ok=1; why=""
      else ok=0; why="$(t "no answer (connection, plan or model name)")"; fi
      rm -f "$tmpf"
    fi
    ui_wait_end
    if (( ok )); then ai_model_mark "$model" ok; else ai_model_mark "$model" ko; fi
    case "$routed" in *" $key "*) used="$(t "used by this project")" ;; *) used="" ;; esac
    if (( ok )); then ui_ok "$model" "$(t "answers")${used:+ · $used}"
    elif [[ -n "$used" ]]; then ui_err "$model" "${why:-$(t "failed")} · $used"; MIN_OK=0
    else ui_warn "$model" "${why:-$(t "failed")} · $(t "not used by the current routing")"; missing_ideal "$model"; fi
  done
fi

# ---------------------------------------------------------------- bilan
ui_section "$(t "SUMMARY")"
# In the questionnaire (--compact), it closes the thread.
doctor_end() { (( COMPACT )) || ui_end "$1"; }
if (( MIN_OK )); then
  if [[ -z "$IDEAL_MISSING" ]]; then ui_ok "$(t "Ideal setup")" "$(t "everything is in place")"
  else ui_ok "$(t "Minimum met")" ""; ui_info "$(t "for the ideal: %s" "$IDEAL_MISSING")"; fi
  if (( LIVE )); then doctor_end "$(t "guided fixes: loomy doctor --fix")"
  else doctor_end "$(t "live model test: loomy doctor --live · guided fixes: loomy doctor --fix")"; fi
  exit 0
fi
ui_err "$(t "Minimum not met")" "$(t "fix the ✗ items above")"
doctor_end "$(t "guided fixes: loomy doctor --fix")"
exit 1
