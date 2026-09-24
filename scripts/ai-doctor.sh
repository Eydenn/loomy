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
    *) echo "Argument inconnu : $1" >&2; usage; exit 2 ;;
  esac
  shift
done
if [[ -z "$ROOT" ]]; then
  if [[ "$(basename "$(dirname "$SCRIPT_DIR")")" == ".loomy" ]]; then ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
  else ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
fi
ROOT="$(cd "$ROOT" && pwd)"

MIN_OK=1          # prérequis minimum atteints
IDEAL_MISSING=""  # éléments idéaux manquants, séparés par des virgules

missing_ideal() { IDEAL_MISSING="${IDEAL_MISSING:+$IDEAL_MISSING, }$1"; }

# offer_fix <question> <commande...> : demande, puis lance la commande. Renvoie 0 si elle est appliquée.
offer_fix() {
  local q="$1"; shift
  if (( ! FIX )) || ! ui_is_interactive; then ui_info "correction : $*"; return 1; fi
  UI_DESCS=("Exécute : $*" "Aucune modification.")
  ui_choose "$q" 0 "Oui" "Non"
  if [[ "$UI_VALUE" == "Oui" ]]; then
    if "$@"; then ui_ok "Corrigé"; return 0; fi
    ui_err "La correction a échoué" "$*"
  fi
  return 1
}

(( COMPACT )) || ui_banner "Diagnostic" "Prérequis, modèles et corrections · catalogue du $AI_CATALOG_DATE"

# ---------------------------------------------------------------- système
ui_section "Système"
ui_ok "bash ${BASH_VERSION%%(*}" "$(uname -s)"
if command -v git >/dev/null 2>&1; then
  ui_ok "git" "$(git --version | awk '{print $3}')"
else
  ui_err "git" "requis — https://git-scm.com/downloads"; MIN_OK=0
fi

# ---------------------------------------------------------------- CLI IA
ui_section "CLI IA (au moins une requise, les deux pour le mode hybride)"
HAS_C=0; HAS_X=0
if ai_has_claude; then
  v="$(ai_claude_version)"
  if ai_version_ge "${v:-0.0.0}" "$AI_MIN_CLAUDE_VERSION"; then
    HAS_C=1; ui_ok "claude $v" "Claude Code (≥ $AI_MIN_CLAUDE_VERSION requis pour $AI_MODEL_CLAUDE_TOP)"
  else
    ui_warn "claude $v" "trop ancien pour $AI_MODEL_CLAUDE_TOP (≥ $AI_MIN_CLAUDE_VERSION)"
    HAS_C=1; offer_fix "Mettre à jour Claude Code ?" claude update || missing_ideal "Claude Code à jour"
  fi
else
  ui_warn "claude" "absent — installation : https://docs.claude.com/en/docs/claude-code/setup"
  missing_ideal "Claude Code"
fi

CODEX_BIN="$(ai_codex_bin || true)"
if [[ -n "$CODEX_BIN" ]]; then
  v="$(ai_codex_version)"
  if command -v codex >/dev/null 2>&1; then
    ui_ok "codex ${v:-?}" "$CODEX_BIN"
  else
    ui_warn "codex ${v:-?}" "trouvé dans $CODEX_BIN mais absent du PATH"
    mkdir -p "$HOME/.local/bin"
    # Un petit script, pas un lien : la CLI livrée cherche ses programmes auxiliaires à côté du chemin par lequel on l'appelle.
    if offer_fix "Rendre la CLI Codex accessible (petit script ~/.local/bin/codex) ?" \
         sh -c 'printf "#!/bin/sh\nexec \"%s\" \"\$@\"\n" "$1" > "$HOME/.local/bin/codex" && chmod +x "$HOME/.local/bin/codex"' _ "$CODEX_BIN"; then
      case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) ui_warn "$HOME/.local/bin absent du PATH" "ajoutez : export PATH=\"\$HOME/.local/bin:\$PATH\"" ;; esac
    fi
  fi
  HAS_X=1
  if [[ -n "$v" ]] && ! ai_version_ge "$v" "$AI_MIN_CODEX_VERSION"; then
    ui_warn "codex $v" "version antérieure à celle validée ($AI_MIN_CODEX_VERSION) — mettez à jour l'app ChatGPT/Codex"
    missing_ideal "Codex à jour"
  fi
  if [[ ! -f "$HOME/.codex/auth.json" ]]; then
    ui_warn "codex" "non connecté — lancez : codex login"; missing_ideal "Codex connecté"
  fi
  cache="$HOME/.codex/models_cache.json"
  if [[ -f "$cache" ]]; then
    miss=""
    for m in "$AI_MODEL_CODEX_TOP" "$AI_MODEL_CODEX_MID" "$AI_MODEL_CODEX_FAST"; do
      grep -q "\"$m\"" "$cache" || miss="${miss:+$miss, }$m"
    done
    if [[ -z "$miss" ]]; then ui_ok "modèles Codex" "$AI_MODEL_CODEX_TOP, $AI_MODEL_CODEX_MID, $AI_MODEL_CODEX_FAST disponibles"
    else ui_warn "modèles Codex" "absents du catalogue local : $miss (plan, région ou CLI à mettre à jour)"; missing_ideal "modèles Codex"; fi
  fi
else
  ui_warn "codex" "absent — installation : https://developers.openai.com/codex/cli (ou npm install -g @openai/codex)"
  missing_ideal "Codex CLI"
fi

if (( ! HAS_C && ! HAS_X )); then
  ui_err "Aucune CLI IA" "installez Claude Code ou Codex (minimum requis)"; MIN_OK=0
fi

# ---------------------------------------------------------------- confort
ui_section "Confort (facultatif)"
if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then ui_ok "gh" "authentifié"
  else ui_warn "gh" "non authentifié — lancez : gh auth login"; missing_ideal "gh authentifié"; fi
else
  ui_info "gh absent (utile pour créer un repo GitHub : brew install gh)"; missing_ideal "gh"
fi
if command -v pbcopy >/dev/null 2>&1 || command -v wl-copy >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1; then
  ui_ok "presse-papiers" "copie automatique du prompt de démarrage"
else
  ui_info "presse-papiers indisponible (wl-copy ou xclip sous Linux)"
fi

# ---------------------------------------------------------------- préférences
ui_section "Préférences (loomy config)"
for fam in claude codex; do
  plan="$(loomy_config_get "plan_$fam" "")"
  if [[ -z "$plan" ]]; then ui_kv "Forfait $fam" "non renseigné (loomy config set plan_$fam …)"
  else ui_kv "Forfait $fam" "$(ai_plan_label "$fam" "$plan")${plan:+ $(p="$(loomy_plan_monthly "$fam")"; [[ -n "$p" ]] && echo "· $p \$/mois")}"; fi
done

# ---------------------------------------------------------------- routage
ai_detect_env "$ROOT"
ui_section "Routage"
ui_ok "$(ai_env_label "$AI_ENV")" "profil $(ai_profile_label "$AI_PROFILE")"
[[ -n "$AI_ENV_NOTE" ]] && ui_warn "Repli" "$AI_ENV_NOTE"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
ui_info "orchestrateur : $R_MODEL ($R_EFFORT) · détail : ai-route.sh"

# ---------------------------------------------------------------- test réel
if (( LIVE )); then
  ui_section "Test réel des modèles"
  ui_info "tous les modèles du catalogue pour chaque CLI installée (un « OK » en effort bas par modèle)"
  # Modèles utilisés par le routage courant : un échec y est bloquant, ailleurs c'est un avertissement.
  routed=" "
  for r in $AI_ROLES; do ai_resolve "$r" "$AI_ENV" "$AI_PROFILE"; routed="$routed$R_FAMILY:$R_MODEL "; done
  for key in "claude:$AI_MODEL_CLAUDE_TOP" "claude:$AI_MODEL_CLAUDE_MID" "claude:$AI_MODEL_CLAUDE_FAST" \
             "codex:$AI_MODEL_CODEX_TOP" "codex:$AI_MODEL_CODEX_MID" "codex:$AI_MODEL_CODEX_FAST"; do
    fam="${key%%:*}"; model="${key#*:}"
    if [[ "$fam" == "claude" ]]; then
      (( HAS_C )) || continue
      out="$(cd "${TMPDIR:-/tmp}" && claude -p "Réponds exactement : OK" --output-format json --max-turns 1 --model "$model" --effort low 2>&1 || true)"
      if printf '%s' "$out" | grep -q '"is_error":false'; then ok=1; why=""
      else ok=0; why="$(printf '%s' "$out" | grep -oE '"result":"[^"]{0,120}' | head -1 | sed 's/"result":"//' || true)"; fi
    else
      (( HAS_X )) || continue
      tmpf="$(mktemp)"
      if "$CODEX_BIN" exec -m "$model" -c model_reasoning_effort=low -s read-only --skip-git-repo-check --ephemeral \
           -o "$tmpf" "Réponds exactement : OK" </dev/null >/dev/null 2>&1 && grep -q OK "$tmpf"; then ok=1; why=""
      else ok=0; why="pas de réponse (connexion, forfait ou nom de modèle)"; fi
      rm -f "$tmpf"
    fi
    case "$routed" in *" $key "*) used="utilisé par ce projet" ;; *) used="" ;; esac
    if (( ok )); then ui_ok "$model" "répond${used:+ · $used}"
    elif [[ -n "$used" ]]; then ui_err "$model" "${why:-échec} · $used"; MIN_OK=0
    else ui_warn "$model" "${why:-échec} · non utilisé par le routage actuel"; missing_ideal "$model"; fi
  done
fi

# ---------------------------------------------------------------- bilan
ui_section "Bilan"
if (( MIN_OK )); then
  if [[ -z "$IDEAL_MISSING" ]]; then ui_ok "Configuration idéale" "tout est en place"
  else ui_ok "Minimum atteint" ""; ui_info "pour l'idéal : $IDEAL_MISSING"; fi
  (( LIVE )) || ui_info "test réel des modèles : ai-doctor.sh --live"
  exit 0
fi
ui_err "Minimum non atteint" "corrigez les points ✗ ci-dessus"
exit 1
