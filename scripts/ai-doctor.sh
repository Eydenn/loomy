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
    *) t "Argument inconnu : %s" "$1" >&2; echo >&2; usage; exit 2 ;;
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
  if (( ! FIX )) || ! ui_is_interactive; then ui_info "$(t "correction : %s" "$*")"; return 1; fi
  UI_DESCS=("$(t "Exécute : %s" "$*")" "$(t "Aucune modification.")")
  ui_choose "$q" 0 "$(t "Oui")" "$(t "Non")"
  if [[ "$UI_INDEX" == "0" ]]; then
    if "$@"; then ui_ok "$(t "Corrigé")"; return 0; fi
    ui_err "$(t "La correction a échoué")" "$*"
  fi
  return 1
}

# install_hint <commande recommandée> <alternative> <connexion> : commandes officielles d'installation d'une CLI absente.
install_hint() {
  ui_rail "    ${C_DIM}$(t "installer :")${C_RESET} ${C_BOLD}$1${C_RESET}"
  ui_rail "    ${C_DIM}$(t "ou        :")${C_RESET} $2"
  ui_rail "    ${C_DIM}$(t "puis      :")${C_RESET} $3"
}

# Diagnostic seul : sortie normale ; avec --fix (questions), écran de Loomy.
(( COMPACT )) || (( ! FIX )) || ui_clear
(( COMPACT )) || ui_banner "$(t "Diagnostic")" "$(t "Prérequis, modèles et corrections") · $(t "catalogue du %s" "$AI_CATALOG_DATE")"

# ---------------------------------------------------------------- installation de Loomy
LOOMY_BIN="$SCRIPT_DIR/../bin/loomy"
if (( ! COMPACT )) && [[ -x "$LOOMY_BIN" ]]; then
  ui_section "$(t "LOOMY")" "$(t "installations trouvées dans le PATH")"
  "$LOOMY_BIN" version --all >/dev/null || true
fi

# ---------------------------------------------------------------- système
ui_section "$(t "SYSTÈME")"
ui_ok "bash ${BASH_VERSION%%(*}" "$(uname -s)"
if command -v git >/dev/null 2>&1; then
  ui_ok "git" "$(git --version | awk '{print $3}')"
else
  ui_err "git" "$(t "requis — https://git-scm.com/downloads")"; MIN_OK=0
fi

# ---------------------------------------------------------------- CLI IA
ui_section "$(t "CLI IA")" "$(t "au moins une requise ; idéal : les deux, pour le mode hybride")"
HAS_C=0; HAS_X=0
if ai_has_claude; then
  ui_wait "$(t "Vérification de Claude Code")"; v="$(ai_claude_version)"; ui_wait_end
  if ai_version_ge "${v:-0.0.0}" "$AI_MIN_CLAUDE_VERSION"; then
    HAS_C=1; ui_ok "claude $v" "Claude Code · $(command -v claude | sed "s|^$HOME|~|")"
  else
    ui_warn "claude $v" "$(t "trop ancien pour %s (≥ %s)" "$AI_MODEL_CLAUDE_TOP" "$AI_MIN_CLAUDE_VERSION")"
    HAS_C=1; offer_fix "$(t "Mettre à jour Claude Code ?")" claude update || missing_ideal "$(t "Claude Code à jour")"
  fi
else
  ui_warn "claude" "$(t "Claude Code absent : orchestrateur sur %s et mode hybride indisponibles" "$AI_MODEL_CLAUDE_TOP")"
  install_hint "curl -fsSL https://claude.ai/install.sh | bash" "brew install --cask claude-code" "claude  ($(t "connexion au premier lancement"))"
  if (( FIX )) && offer_fix "$(t "Installer Claude Code maintenant (installateur officiel) ?")" sh -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
    ui_info "$(t "ouvre un nouveau terminal, lance claude pour te connecter, puis relance loomy doctor")"
  else
    missing_ideal "Claude Code"
  fi
fi

CODEX_BIN="$(ai_codex_bin || true)"
if [[ -n "$CODEX_BIN" ]]; then
  ui_wait "$(t "Vérification de Codex")"; v="$(ai_codex_version)"; ui_wait_end
  if command -v codex >/dev/null 2>&1; then
    ui_ok "codex ${v:-?}" "Codex CLI · $(printf '%s' "$CODEX_BIN" | sed "s|^$HOME|~|")"
  else
    ui_warn "codex ${v:-?}" "$(t "trouvé dans %s mais absent du PATH" "$CODEX_BIN")"
    mkdir -p "$HOME/.local/bin"
    # Un petit script, pas un lien : la CLI livrée cherche ses programmes auxiliaires à côté du chemin par lequel on l'appelle.
    if offer_fix "$(t "Rendre la CLI Codex accessible (petit script ~/.local/bin/codex) ?")" \
         sh -c 'printf "#!/bin/sh\nexec \"%s\" \"\$@\"\n" "$1" > "$HOME/.local/bin/codex" && chmod +x "$HOME/.local/bin/codex"' _ "$CODEX_BIN"; then
      case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) ui_warn "$(t "%s absent du PATH" "$HOME/.local/bin")" "$(t "ajoutez :") export PATH=\"\$HOME/.local/bin:\$PATH\"" ;; esac
    fi
  fi
  HAS_X=1
  if [[ -n "$v" ]] && ! ai_version_ge "$v" "$AI_MIN_CODEX_VERSION"; then
    ui_warn "codex $v" "$(t "version antérieure à celle validée (%s) — mettez à jour l'app ChatGPT/Codex" "$AI_MIN_CODEX_VERSION")"
    missing_ideal "$(t "Codex à jour")"
  fi
  if [[ ! -f "$HOME/.codex/auth.json" ]]; then
    ui_warn "codex" "$(t "non connecté — lancez : codex login")"; missing_ideal "$(t "Codex connecté")"
  fi
  cache="$HOME/.codex/models_cache.json"
  if [[ -f "$cache" ]]; then
    miss=""
    for m in "$AI_MODEL_CODEX_TOP" "$AI_MODEL_CODEX_MID" "$AI_MODEL_CODEX_FAST"; do
      grep -q "\"$m\"" "$cache" || miss="${miss:+$miss, }$m"
    done
    if [[ -z "$miss" ]]; then ui_ok "$(t "modèles Codex")" "$(t "%s disponibles" "$AI_MODEL_CODEX_TOP, $AI_MODEL_CODEX_MID, $AI_MODEL_CODEX_FAST")"
    else ui_warn "$(t "modèles Codex")" "$(t "absents du catalogue local : %s (plan, région ou CLI à mettre à jour)" "$miss")"; missing_ideal "$(t "modèles Codex")"; fi
  fi
else
  ui_warn "codex" "$(t "Codex CLI absent : exécutant %s et mode hybride indisponibles" "$AI_MODEL_CODEX_FAST")"
  install_hint "curl -fsSL https://chatgpt.com/codex/install.sh | sh" "brew install --cask codex  ·  npm install -g @openai/codex" "codex  ($(t "connexion au premier lancement"))"
  if (( FIX )) && offer_fix "$(t "Installer la CLI Codex maintenant (installateur officiel) ?")" sh -c 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'; then
    ui_info "$(t "ouvre un nouveau terminal, lance codex pour te connecter, puis relance loomy doctor")"
  else
    missing_ideal "Codex CLI"
  fi
fi

if (( ! HAS_C && ! HAS_X )); then
  ui_err "$(t "Aucune CLI IA")" "$(t "installez Claude Code ou Codex (minimum requis)")"; MIN_OK=0
fi

# ---------------------------------------------------------------- confort
ui_section "$(t "CONFORT")" "$(t "facultatif")"
# GitHub : gh installé, connecté, et git qui s'authentifie avec lui (dépôts privés, dont le tap Loomy).
# Avec --fix, les trois étapes s'enchaînent.
if ! command -v gh >/dev/null 2>&1; then
  ui_warn "$(t "gh absent")" "$(t "utile pour créer les dépôts GitHub et installer Loomy depuis le tap privé")"
  if command -v brew >/dev/null 2>&1 && offer_fix "$(t "Installer gh (brew install gh) ?")" ui_external brew install gh; then :; else missing_ideal "gh"; fi
fi
if command -v gh >/dev/null 2>&1; then
  ui_wait "$(t "Connexion GitHub (gh)")"; gh_ok=0; gh auth status >/dev/null 2>&1 && gh_ok=1; ui_wait_end
  if (( ! gh_ok )); then
    ui_warn "gh" "$(t "non connecté à GitHub")"
    offer_fix "$(t "Te connecter à GitHub maintenant (gh auth login) ?")" ui_external gh auth login && gh auth status >/dev/null 2>&1 && gh_ok=1
  fi
  if (( gh_ok )); then
    ui_ok "gh" "$(t "connecté à GitHub")"
    # Accès réel de git au dépôt de Loomy (privé pendant la pré-version) : c'est ce dont le tap Homebrew a besoin.
    # Pas dans le diagnostic de loomy init (--compact) : sans rapport avec le projet créé.
  fi
  if (( gh_ok )) && (( ! COMPACT )); then
    loomy_repo="https://github.com/${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}.git"
    ui_wait "$(t "Accès de git au dépôt Loomy")"; git_ok=0
    GIT_TERMINAL_PROMPT=0 git ls-remote "$loomy_repo" HEAD >/dev/null 2>&1 && git_ok=1; ui_wait_end
    if (( ! git_ok )); then
      ui_warn "$(t "git → dépôt Loomy")" "$(t "accès refusé : git ne s'authentifie pas auprès de GitHub (ou invitation pas encore acceptée)")"
      if offer_fix "$(t "Configurer git pour utiliser ton compte gh (gh auth setup-git) ?")" gh auth setup-git \
         && GIT_TERMINAL_PROMPT=0 git ls-remote "$loomy_repo" HEAD >/dev/null 2>&1; then git_ok=1
      else ui_info "$(t "invitation au dépôt : %s" "https://github.com/${LOOMY_FEEDBACK_REPO:-Eydenn/loomy}/invitations")"; missing_ideal "$(t "accès git au dépôt Loomy")"; fi
    fi
    (( git_ok )) && ui_ok "$(t "git → dépôt Loomy")" "$(t "accès vérifié (mises à jour Homebrew possibles)")"
  elif (( ! gh_ok )); then
    missing_ideal "$(t "gh connecté")"
  fi
fi
if command -v pbcopy >/dev/null 2>&1 || command -v wl-copy >/dev/null 2>&1 || command -v xclip >/dev/null 2>&1; then
  ui_ok "$(t "presse-papiers")" "$(t "copie automatique du prompt de démarrage")"
else
  ui_info "$(t "presse-papiers indisponible (wl-copy ou xclip sous Linux)")"
fi

# ---------------------------------------------------------------- préférences
ui_section "$(t "PRÉFÉRENCES")" "$(t "loomy config")"
for fam in claude codex; do
  name="$(t "Forfait Claude")"; [[ "$fam" == "codex" ]] && name="$(t "Forfait Codex")"
  plan="$(loomy_config_get "plan_$fam" "")"
  if [[ -z "$plan" ]]; then ui_kv "$name" "$(t "non renseigné") (loomy config set plan_$fam …)"
  else ui_kv "$name" "$(ai_plan_label "$fam" "$plan")${plan:+ $(p="$(loomy_plan_monthly "$fam")"; [[ -n "$p" ]] && echo "· $p \$/$(t "mois")")}"; fi
done

# ---------------------------------------------------------------- routage
ai_detect_env "$ROOT"
ui_section "$(t "CATALOGUE")" "$(t "modèles et prix")"
cat_ep="$(ai_ts_epoch "${AI_CATALOG_DATE}T00:00:00Z")"; age=""
[[ -n "$cat_ep" ]] && age=$(( ( $(date +%s) - cat_ep ) / 86400 ))
if [[ -n "$age" ]] && (( age > 60 )); then ui_warn "$(t "catalogue du %s" "$AI_CATALOG_DATE") ($AI_CATALOG_SOURCE)" "$(t "il a %s jours : loomy update --catalog" "$age")"
else ui_ok "$(t "catalogue du %s" "$AI_CATALOG_DATE")" "$(t "$AI_CATALOG_SOURCE")"; fi
newcat="$(bash "$SCRIPT_DIR/ai-catalog-check.sh" 2>/dev/null || true)"
[[ -n "$newcat" ]] && ui_warn "catalogue du $newcat publié" "$(t "loomy update --catalog")"
# Modèles d'une chaîne refusés sur cette machine (repli en cours) : à retester après un changement de forfait.
ko="$(grep '=ko$' "$(ai_models_state_file)" 2>/dev/null | cut -d= -f1 | paste -sd ',' - | sed 's/,/, /g' || true)"
[[ -n "$ko" ]] && ui_info "$(t "indisponibles ici (repli utilisé) : %s · à retester : loomy doctor --live" "$ko")"

ui_section "$(t "ROUTAGE")"
ui_ok "$(ai_env_label "$AI_ENV")" "$(t "profil %s" "$(ai_profile_label "$AI_PROFILE")")"
[[ -n "$AI_ENV_NOTE" ]] && ui_warn "$(t "Repli")" "$AI_ENV_NOTE"
ai_resolve lead "$AI_ENV" "$AI_PROFILE"
ui_info "$(t "orchestrateur : %s (%s) · détail : loomy route" "$R_MODEL" "$R_EFFORT")"

# ---------------------------------------------------------------- test réel
if (( LIVE )); then
  ui_section "$(t "TEST RÉEL DES MODÈLES")"
  ui_info "$(t "tous les modèles du catalogue pour chaque CLI installée (un « OK » en effort bas par modèle)")"
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
      ui_wait "$(t "Test de %s" "$model")"
      out="$(cd "${TMPDIR:-/tmp}" && claude -p "Réponds exactement : OK" --output-format json --max-turns 1 --model "$model" --effort low 2>&1 || true)"
      if grep -q '"is_error":false' <<<"$out"; then ok=1; why=""
      else ok=0; why="$(printf '%s' "$out" | grep -oE '"result":"[^"]{0,120}' | head -1 | sed 's/"result":"//' || true)"; fi
    else
      (( HAS_X )) || continue
      tmpf="$(mktemp)"
      ui_wait "$(t "Test de %s" "$model")"
      if "$CODEX_BIN" exec -m "$model" -c model_reasoning_effort=low -s read-only --skip-git-repo-check --ephemeral \
           -o "$tmpf" "Réponds exactement : OK" </dev/null >/dev/null 2>&1 && grep -q OK "$tmpf"; then ok=1; why=""
      else ok=0; why="pas de réponse (connexion, forfait ou nom de modèle)"; fi
      rm -f "$tmpf"
    fi
    ui_wait_end
    if (( ok )); then ai_model_mark "$model" ok; else ai_model_mark "$model" ko; fi
    case "$routed" in *" $key "*) used="utilisé par ce projet" ;; *) used="" ;; esac
    if (( ok )); then ui_ok "$model" "$(t "répond")${used:+ · $used}"
    elif [[ -n "$used" ]]; then ui_err "$model" "${why:-$(t "échec")} · $used"; MIN_OK=0
    else ui_warn "$model" "${why:-$(t "échec")} · $(t "non utilisé par le routage actuel")"; missing_ideal "$model"; fi
  done
fi

# ---------------------------------------------------------------- bilan
ui_section "$(t "BILAN")"
# Dans le questionnaire (--compact), c'est lui qui ferme le fil.
doctor_end() { (( COMPACT )) || ui_end "$1"; }
if (( MIN_OK )); then
  if [[ -z "$IDEAL_MISSING" ]]; then ui_ok "$(t "Configuration idéale")" "$(t "tout est en place")"
  else ui_ok "$(t "Minimum atteint")" ""; ui_info "$(t "pour l'idéal : %s" "$IDEAL_MISSING")"; fi
  if (( LIVE )); then doctor_end "$(t "corrections guidées : loomy doctor --fix")"
  else doctor_end "$(t "test réel des modèles : loomy doctor --live · corrections guidées : loomy doctor --fix")"; fi
  exit 0
fi
ui_err "$(t "Minimum non atteint")" "$(t "corrigez les points ✗ ci-dessus")"
doctor_end "$(t "corrections guidées : loomy doctor --fix")"
exit 1
