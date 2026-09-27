#!/usr/bin/env bash
# shellcheck disable=SC2034  # UI_* are read by lib/ui.sh
# Diagnostic de l'environnement pour Loomy : prérequis minimum et idéaux, disponibilité des modèles,
# test réel facultatif de chaque modèle routé, et corrections guidées. Compatible bash 3.2.
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

usage() {
  cat >&2 <<'EOF'
Usage: ai-doctor.sh [--root DIR] [--fix] [--live] [--compact]

  --fix       Propose et applique les corrections possibles (avec confirmation)
  --live      Teste chaque modèle de la matrice par un appel minimal réel (quelques centimes)
  --compact   Affichage court (utilisé par le questionnaire)
  --root DIR  Projet à analyser (défaut : projet courant)

Code de sortie : 0 si le minimum est atteint, 1 sinon.
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

MIN_OK=1          # prérequis minimum atteints
IDEAL_MISSING=""  # éléments idéaux manquants, séparés par des virgules

missing_ideal() { IDEAL_MISSING="${IDEAL_MISSING:+$IDEAL_MISSING, }$1"; }

# offer_fix <question> <commande...> : demande, puis lance la commande. Renvoie 0 si elle est appliquée.
offer_fix() {
  local q="$1"; shift
  if (( ! FIX )) || ! ui_is_interactive; then ui_info "$(t "fix: %s" "$*")"; return 1; fi
  UI_DESCS=("$(t "Runs: %s" "$*")" "$(t "No change.")")
  ui_choose "$q" 0 "$(t "Yes")" "$(t "No")"
  if [[ "$UI_INDEX" == "0" ]]; then
    if "$@"; then ui_ok "$(t "Fixed")"; return 0; fi
    ui_err "$(t "The fix failed")" "$*"
  fi
  return 1
}

# install_hint <commande recommandée> <alternative> <connexion> : commandes officielles d'installation d'une CLI absente.
install_hint() {
  ui_rail "    ${C_DIM}$(t "install:")${C_RESET} ${C_BOLD}$1${C_RESET}"
  ui_rail "    ${C_DIM}$(t "or:     ")${C_RESET} $2"
  ui_rail "    ${C_DIM}$(t "then:   ")${C_RESET} $3"
}

# Diagnostic seul : sortie normale ; avec --fix (questions), écran de Loomy.
(( COMPACT )) || (( ! FIX )) || ui_clear
(( COMPACT )) || ui_banner "$(t "Diagnostics")" "$(t "Prerequisites, models and fixes") · $(t "catalog from %s" "$AI_CATALOG_DATE")"

# ---------------------------------------------------------------- installation de Loomy
LOOMY_BIN="$SCRIPT_DIR/../bin/loomy"
if (( ! COMPACT )) && [[ -x "$LOOMY_BIN" ]]; then
  ui_section "$(t "LOOMY")" "$(t "installs found in the PATH")"
  "$LOOMY_BIN" version --all >/dev/null || true
fi

# ---------------------------------------------------------------- système
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
  if ai_version_ge "${v:-0.0.0}" "$AI_MIN_CLAUDE_VERSION"; then
    HAS_C=1; ui_ok "claude $v" "Claude Code · $(command -v claude | sed "s|^$HOME|~|")"
  else
    ui_warn "claude $v" "$(t "too old for %s (≥ %s)" "$AI_MODEL_CLAUDE_TOP" "$AI_MIN_CLAUDE_VERSION")"
    HAS_C=1; offer_fix "$(t "Update Claude Code?")" claude update || missing_ideal "$(t "Claude Code up to date")"
  fi
else
  ui_warn "claude" "$(t "Claude Code missing: %s lead agent and hybrid mode unavailable" "$AI_MODEL_CLAUDE_TOP")"
  install_hint "curl -fsSL https://claude.ai/install.sh | bash" "brew install --cask claude-code" "claude  ($(t "log in on first launch"))"
  if (( FIX )) && offer_fix "$(t "Install Claude Code now (official installer)?")" sh -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
    ui_info "$(t "open a new terminal, run claude to log in, then run loomy doctor again")"
  else
    missing_ideal "Claude Code"
  fi
fi

CODEX_BIN="$(ai_codex_bin || true)"
if [[ -n "$CODEX_BIN" ]]; then
  ui_wait "$(t "Checking Codex")"; v="$(ai_codex_version)"; ui_wait_end
  if command -v codex >/dev/null 2>&1; then
    ui_ok "codex ${v:-?}" "Codex CLI · $(printf '%s' "$CODEX_BIN" | sed "s|^$HOME|~|")"
  else
    ui_warn "codex ${v:-?}" "$(t "found in %s but not in the PATH" "$CODEX_BIN")"
    mkdir -p "$HOME/.local/bin"
    # Un petit script, pas un lien : la CLI livrée cherche ses programmes auxiliaires à côté du chemin par lequel on l'appelle.
    if offer_fix "$(t "Make the Codex CLI reachable (small ~/.local/bin/codex script)?")" \
         sh -c 'printf "#!/bin/sh\nexec \"%s\" \"\$@\"\n" "$1" > "$HOME/.local/bin/codex" && chmod +x "$HOME/.local/bin/codex"' _ "$CODEX_BIN"; then
      case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) ui_warn "$(t "%s not in the PATH" "$HOME/.local/bin")" "$(t "add:") export PATH=\"\$HOME/.local/bin:\$PATH\"" ;; esac
    fi
  fi
  HAS_X=1
  if [[ -n "$v" ]] && ! ai_version_ge "$v" "$AI_MIN_CODEX_VERSION"; then
    ui_warn "codex $v" "$(t "older than the validated version (%s) — update the ChatGPT/Codex app" "$AI_MIN_CODEX_VERSION")"
    missing_ideal "$(t "Codex up to date")"
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
  if (( FIX )) && offer_fix "$(t "Install the Codex CLI now (official installer)?")" sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'; then
    ui_info "$(t "open a new terminal, run codex to log in, then run loomy doctor again")"
  else
    missing_ideal "Codex CLI"
  fi
fi

if (( ! HAS_C && ! HAS_X )); then
  ui_err "$(t "No AI CLI")" "$(t "install Claude Code or Codex (minimum required)")"; MIN_OK=0
fi

# ---------------------------------------------------------------- confort
ui_section "$(t "COMFORT")" "$(t "optional")"
# GitHub : gh installé, connecté, et git qui s'authentifie avec lui (dépôts privés, dont le tap Loomy).
# Avec --fix, les trois étapes s'enchaînent.
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
    # Accès réel de git au dépôt de Loomy (privé pendant la pré-version) : c'est ce dont le tap Homebrew a besoin.
    # Pas dans le diagnostic de loomy init (--compact) : sans rapport avec le projet créé.
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

# ---------------------------------------------------------------- préférences
ui_section "$(t "PREFERENCES")" "$(t "loomy config")"
for fam in claude codex; do
  name="$(t "Claude plan")"; [[ "$fam" == "codex" ]] && name="$(t "Codex plan")"
  plan="$(loomy_config_get "plan_$fam" "")"
  if [[ -z "$plan" ]]; then ui_kv "$name" "$(t "not set") (loomy config set plan_$fam …)"
  else ui_kv "$name" "$(ai_plan_label "$fam" "$plan")${plan:+ $(p="$(loomy_plan_monthly "$fam")"; [[ -n "$p" ]] && echo "· $p \$/$(t "month")")}"; fi
done

# ---------------------------------------------------------------- routage
ai_detect_env "$ROOT"
ui_section "$(t "CATALOG")" "$(t "models and prices")"
cat_ep="$(ai_ts_epoch "${AI_CATALOG_DATE}T00:00:00Z")"; age=""
[[ -n "$cat_ep" ]] && age=$(( ( $(date +%s) - cat_ep ) / 86400 ))
if [[ -n "$age" ]] && (( age > 60 )); then ui_warn "$(t "catalog from %s" "$AI_CATALOG_DATE") ($(t "$AI_CATALOG_SOURCE"))" "$(t "it's %s days old: loomy update --catalog" "$age")"
else ui_ok "$(t "catalog from %s" "$AI_CATALOG_DATE")" "$(t "$AI_CATALOG_SOURCE")"; fi
newcat="$(bash "$SCRIPT_DIR/ai-catalog-check.sh" 2>/dev/null || true)"
[[ -n "$newcat" ]] && ui_warn "catalogue du $newcat publié" "$(t "loomy update --catalog")"
# Modèles d'une chaîne refusés sur cette machine (repli en cours) : à retester après un changement de forfait.
ko="$(grep '=ko$' "$(ai_models_state_file)" 2>/dev/null | cut -d= -f1 | paste -sd ',' - | sed 's/,/, /g' || true)"
[[ -n "$ko" ]] && ui_info "$(t "unavailable here (fallback used): %s · to retest: loomy doctor --live" "$ko")"

ui_section "$(t "ROUTING")"
ui_ok "$(ai_env_label "$AI_ENV")" "$(t "%s profile" "$(ai_profile_label "$AI_PROFILE")")"
[[ -n "$AI_ENV_NOTE" ]] && ui_warn "$(t "Fallback")" "$AI_ENV_NOTE"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
ui_info "$(t "lead agent: %s (%s) · details: loomy route" "$R_MODEL" "$R_EFFORT")"

# ---------------------------------------------------------------- test réel
if (( LIVE )); then
  ui_section "$(t "LIVE MODEL TEST")"
  ui_info "$(t "every catalog model for each installed CLI (one low-effort \"OK\" per model)")"
  # Modèles utilisés par le routage courant : un échec y est bloquant, ailleurs c'est un avertissement.
  routed=" "
  for r in $AI_ROLES; do ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"; routed="$routed$R_FAMILY:$R_MODEL "; done
  # Tous les modèles des chaînes du catalogue (repli compris) ; le résultat est retenu pour cette machine.
  keys=""
  for m in $AI_CHAIN_CLAUDE_TOP $AI_CHAIN_CLAUDE_MID $AI_CHAIN_CLAUDE_FAST; do keys="$keys claude:$m"; done
  for m in $AI_CHAIN_CODEX_TOP $AI_CHAIN_CODEX_MID $AI_CHAIN_CODEX_FAST; do keys="$keys codex:$m"; done
  for key in $keys; do
    fam="${key%%:*}"; model="${key#*:}"
    if [[ "$fam" == "claude" ]]; then
      (( HAS_C )) || continue
      ui_wait "$(t "Testing %s" "$model")"
      out="$(cd "${TMPDIR:-/tmp}" && claude -p "Réponds exactement : OK" --output-format json --max-turns 1 --model "$model" --effort low 2>&1 || true)"
      if grep -q '"is_error":false' <<<"$out"; then ok=1; why=""
      else ok=0; why="$(printf '%s' "$out" | grep -oE '"result":"[^"]{0,120}' | head -1 | sed 's/"result":"//' || true)"; fi
    else
      (( HAS_X )) || continue
      tmpf="$(mktemp)"
      ui_wait "$(t "Testing %s" "$model")"
      if "$CODEX_BIN" exec -m "$model" -c model_reasoning_effort=low -s read-only --skip-git-repo-check --ephemeral \
           -o "$tmpf" "Réponds exactement : OK" </dev/null >/dev/null 2>&1 && grep -q OK "$tmpf"; then ok=1; why=""
      else ok=0; why="pas de réponse (connexion, forfait ou nom de modèle)"; fi
      rm -f "$tmpf"
    fi
    ui_wait_end
    if (( ok )); then ai_model_mark "$model" ok; else ai_model_mark "$model" ko; fi
    case "$routed" in *" $key "*) used="utilisé par ce projet" ;; *) used="" ;; esac
    if (( ok )); then ui_ok "$model" "$(t "answers")${used:+ · $used}"
    elif [[ -n "$used" ]]; then ui_err "$model" "${why:-$(t "failed")} · $used"; MIN_OK=0
    else ui_warn "$model" "${why:-$(t "failed")} · $(t "not used by the current routing")"; missing_ideal "$model"; fi
  done
fi

# ---------------------------------------------------------------- bilan
ui_section "$(t "SUMMARY")"
# Dans le questionnaire (--compact), c'est lui qui ferme le fil.
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
