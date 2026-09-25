#!/usr/bin/env bash
# Visibilité des fichiers IA du projet (AGENTS.md, CLAUDE.md, .ai/, .claude/, .loomy/, START.md). Compatible bash 3.2.
#   loomy privacy                          état : mode, fichiers encore suivis, dépôt privé
#   loomy privacy versioned                versionnés avec le projet
#   loomy privacy local                    exclus de Git sur cette machine (invisibles dans le dépôt)
#   loomy privacy private [--name NOM | --remote URL]   exclus du projet, sauvegardés dans un dépôt privé séparé
#   loomy privacy sync                     sauvegarde les fichiers IA dans le dépôt privé
#   loomy privacy restore <URL|compte/dépôt>   récupère les fichiers IA sur une autre machine
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/models.sh
source "$SCRIPT_DIR/lib/models.sh"
# shellcheck source=lib/privacy.sh
source "$SCRIPT_DIR/lib/privacy.sh"

ROOT=""; CMD="show"; REMOTE=""; ARG=""; QUIET=0; AI_REPO_OPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift ;;
    --remote) REMOTE="${2:-}"; shift ;;
    --name) AI_REPO_OPT="${2:-}"; shift ;;
    --quiet) QUIET=1 ;;
    versioned|local|private|sync|apply|show) CMD="$1" ;;
    restore) CMD="restore"; ARG="${2:-}"; [[ $# -gt 1 ]] && shift ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Argument inconnu : $1 (loomy privacy --help)" >&2; exit 2 ;;
  esac
  shift
done
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd -P)"
# Sur une nouvelle machine, .loomy n'existe pas encore (hors du dépôt) : seul restore peut s'en passer.
if [[ "$CMD" == "restore" ]]; then mkdir -p "$ROOT/.loomy"
elif [[ ! -d "$ROOT/.loomy" ]]; then echo "Pas de projet Loomy dans ${ROOT/#$HOME/~} : loomy init d'abord (ou loomy privacy restore <compte/dépôt> pour récupérer ses fichiers IA)." >&2; exit 1; fi
GIT_ROOT="$(privacy_git_root "$ROOT")"
MODE="$(privacy_mode "$ROOT")"
# Nom du dépôt privé : celui du projet (slug du brief), pour que tout porte le même nom.
NAME="$(sed -n '/^---$/,/^---$/p' "$ROOT/.loomy/brief.md" 2>/dev/null | sed -n 's/^slug:[[:space:]]*//p' | head -1 || true)"
if [[ -z "$NAME" ]]; then
  NAME="$(sed -n '/^---$/,/^---$/p' "$ROOT/.loomy/brief.md" 2>/dev/null | sed -n 's/^name:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//' || true)"
  NAME="$(loomy_slug "${NAME:-$(basename "$ROOT")}")"
fi
# Nom du dépôt privé : --name, sinon celui du brief (validé dans le questionnaire), sinon <projet>-ai.
AI_REPO="${AI_REPO_OPT:-$(sed -n '/^---$/,/^---$/p' "$ROOT/.loomy/brief.md" 2>/dev/null | sed -n 's/^ai_repo_name:[[:space:]]*//p' | head -1 || true)}"
AI_REPO="${AI_REPO:-$NAME-ai}"

# ---------------------------------------------------------------- dépôt privé séparé
create_companion() {
  local url="$REMOTE" owner
  if privacy_companion_ready "$ROOT"; then return 0; fi
  if [[ -z "$url" ]]; then
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
      ui_err "Impossible de créer le dépôt privé $AI_REPO" "gh absent ou non connecté : gh auth login, ou indique un dépôt existant avec --remote URL"
      return 1
    fi
    owner="$(gh api user --jq .login 2>/dev/null || true)"
    [[ -n "$owner" ]] || { ui_err "Compte GitHub introuvable" "gh auth login"; return 1; }
    # Nom proposé à validation, modifiable (sauf s'il vient déjà de --name ou du questionnaire).
    if [[ -z "$AI_REPO_OPT" && "$CMD" != "apply" ]] && ui_is_interactive; then
      UI_LABEL="Dépôt privé"
      UI_HINT="Dépôt GitHub privé qui ne contiendra que les fichiers IA."
      ui_input "Nom du dépôt privé ($owner/…)" "$AI_REPO"
      AI_REPO="$(loomy_slug "$UI_VALUE")"
    fi
    if gh repo view "$owner/$AI_REPO" >/dev/null 2>&1; then
      ui_info "dépôt $owner/$AI_REPO déjà présent : utilisé tel quel"
    else
      gh repo create "$owner/$AI_REPO" --private --description "Fichiers IA du projet $NAME (Loomy)" >/dev/null || { ui_err "Création du dépôt privé échouée" "$owner/$AI_REPO"; return 1; }
      ui_ok "Dépôt privé créé" "$owner/$AI_REPO"
    fi
    url="https://github.com/$owner/$AI_REPO.git"
  fi
  git init --bare -q -b main "$(privacy_ai_git_dir "$ROOT")"
  privacy_set_key "$ROOT" ai_repo_name "$(basename "$url" .git)"
  ai_git "$ROOT" remote add origin "$url"
  privacy_companion_config "$ROOT"
  return 0
}

do_sync() {
  local p paths=() msg
  privacy_companion_ready "$ROOT" || { ui_err "Pas de dépôt privé pour ce projet" "loomy privacy private"; return 1; }
  for p in $LOOMY_AI_PATHS; do [[ -e "$ROOT/$p" ]] && paths+=("$p"); done
  (( ${#paths[@]} )) || { ui_info "aucun fichier IA à sauvegarder"; return 0; }
  ai_git "$ROOT" add -A -- "${paths[@]}"
  if ! ai_git "$ROOT" diff --cached --quiet 2>/dev/null; then
    msg="loomy : fichiers IA du $(date '+%Y-%m-%d %H:%M')"
    ai_git "$ROOT" commit -q -m "$msg"
  fi
  # Une autre machine a pu sauvegarder entre-temps : on rejoue nos changements par-dessus les siens.
  if ai_git "$ROOT" ls-remote --exit-code origin main >/dev/null 2>&1; then
    ai_git "$ROOT" fetch -q origin
    if ! ai_git "$ROOT" rebase -q origin/main >/dev/null 2>&1; then
      ai_git "$ROOT" rebase --abort >/dev/null 2>&1 || true
      ui_err "Les fichiers IA ont changé des deux côtés" "résous à la main : git --git-dir=.loomy/ai.git --work-tree=. pull --rebase origin main"
      return 1
    fi
  fi
  if ai_git "$ROOT" rev-parse -q --verify HEAD >/dev/null; then
    ai_git "$ROOT" push -q -u origin main || { ui_err "Envoi vers le dépôt privé échoué" "$(ai_git "$ROOT" remote get-url origin)"; return 1; }
  fi
  (( QUIET )) || ui_ok "Fichiers IA sauvegardés" "$(ai_git "$ROOT" remote get-url origin | sed 's|https://github.com/||; s|\.git$||')"
  return 0
}

# ---------------------------------------------------------------- application d'un mode
warn_tracked() {
  local t
  t="$(privacy_tracked "$ROOT" | tr '\n' ' ')"
  [[ -n "$t" ]] || return 0
  ui_warn "Encore suivis par le dépôt du projet" "$t"
  ui_rail "    ${C_DIM}pour arrêter de les suivre (ils restent sur ton disque) :${C_RESET} git rm -r --cached -- $t"
  ui_rail "    ${C_DIM}ce qui a déjà été envoyé reste dans l'historique du dépôt${C_RESET}"
}

apply_mode() {
  local m="$1"
  case "$m" in
    versioned)
      privacy_remove_exclude "$ROOT" || true
      if privacy_companion_ready "$ROOT"; then ui_info "le dépôt privé (.loomy/ai.git) reste en place ; il n'est plus mis à jour"; fi ;;
    local|private)
      if [[ -n "$GIT_ROOT" ]]; then privacy_add_exclude "$ROOT"; else ui_info "pas encore de dépôt Git : l'exclusion sera posée par loomy privacy $m une fois le dépôt créé"; fi
      if [[ "$m" == "private" ]]; then create_companion && do_sync || return 1; fi ;;
  esac
  privacy_set_mode "$ROOT" "$m"
  MODE="$m"
  return 0
}

show_state() {
  ui_section "FICHIERS IA" "$(echo "$LOOMY_AI_PATHS" | sed 's/ / · /g')"
  ui_kv "Mode" "${C_BOLD}$(privacy_label "$MODE")${C_RESET}"
  if [[ -z "$GIT_ROOT" ]]; then ui_kv "Dépôt Git" "${C_DIM}aucun${C_RESET}"
  elif [[ "$MODE" != "versioned" ]]; then
    if privacy_excluded "$ROOT"; then ui_kv "Exclusion" "${C_GREEN}active${C_RESET} ${C_DIM}(.git/info/exclude, propre à cette machine)${C_RESET}"
    else ui_kv "Exclusion" "${C_YELLOW}absente sur cette machine${C_RESET} ${C_DIM}→ loomy privacy $MODE${C_RESET}"; fi
  fi
  if [[ "$MODE" == "private" ]]; then
    if privacy_companion_ready "$ROOT"; then
      ui_kv "Dépôt privé" "$(ai_git "$ROOT" remote get-url origin 2>/dev/null | sed 's|https://github.com/||; s|\.git$||')"
      pending="$(privacy_pending "$ROOT")"
      if [[ "$pending" == "0" ]]; then ui_kv "Sauvegarde" "${C_GREEN}à jour${C_RESET}"
      else ui_kv "Sauvegarde" "${C_YELLOW}$pending changement(s) à sauvegarder${C_RESET} ${C_DIM}→ loomy privacy sync${C_RESET}"; fi
    else
      ui_kv "Dépôt privé" "${C_YELLOW}absent sur cette machine${C_RESET} ${C_DIM}→ loomy privacy restore <compte/dépôt>, ou loomy privacy private pour le créer${C_RESET}"
    fi
  fi
  if [[ "$MODE" != "versioned" ]]; then warn_tracked; fi
}

case "$CMD" in
  show)
    ui_banner "Visibilité des fichiers IA" "${ROOT/#$HOME/~}"
    show_state
    ui_section "CHANGER"
    ui_rail "${C_BOLD}loomy privacy versioned${C_RESET}  ${C_DIM}versionnés avec le projet (dépôt privé : recommandé)${C_RESET}"
    ui_rail "${C_BOLD}loomy privacy local${C_RESET}      ${C_DIM}jamais envoyés sur GitHub, propres à cette machine${C_RESET}"
    ui_rail "${C_BOLD}loomy privacy private${C_RESET}    ${C_DIM}hors du dépôt du projet, sauvegardés dans un dépôt privé (dépôt public : recommandé)${C_RESET}"
    ui_end "GitHub ne gère pas la visibilité fichier par fichier : un dépôt est entièrement public ou privé"
    ;;
  versioned|local|private)
    ui_banner "Visibilité des fichiers IA" "${ROOT/#$HOME/~}"
    ui_section "MODE" "$(privacy_label "$CMD")"
    apply_mode "$CMD" || { ui_end "mode inchangé : $(privacy_label "$(privacy_mode "$ROOT")")"; exit 1; }
    ui_ok "Mode enregistré" "$(privacy_label "$CMD") · dans .loomy/brief.md"
    [[ "$CMD" != "versioned" ]] && warn_tracked
    ui_end "état : loomy privacy$( [[ "$CMD" == private ]] && echo " · sauvegarde : loomy privacy sync")"
    ;;
  apply)
    # Utilisé par le questionnaire : applique le mode du brief, sans en-tête.
    apply_mode "$MODE" || exit 1
    ;;
  sync)
    if [[ "$MODE" != "private" ]]; then echo "Ce projet n'utilise pas de dépôt privé séparé (mode : $(privacy_label "$MODE"))." >&2; exit 1; fi
    do_sync || exit 1
    ;;
  restore)
    [[ -n "$ARG" ]] || { echo "Usage : loomy privacy restore <URL | compte/dépôt>" >&2; exit 2; }
    if privacy_companion_ready "$ROOT"; then echo "Le dépôt privé est déjà présent (.loomy/ai.git) : loomy privacy sync" >&2; exit 1; fi
    url="$ARG"
    if [[ "$ARG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ! -e "$ARG" ]]; then url="https://github.com/$ARG.git"; fi
    git clone --bare -q "$url" "$(privacy_ai_git_dir "$ROOT")" || { echo "Clonage impossible : $url" >&2; exit 1; }
    privacy_companion_config "$ROOT"
    # Fichiers déjà présents : identiques, on les garde ; différents, ils sont mis de côté avant la restauration.
    backup="$ROOT/.loomy/restore-backup-$(date +%Y%m%d-%H%M%S)"; moved=0
    while IFS= read -r f; do
      [[ -e "$ROOT/$f" ]] || continue
      if ai_git "$ROOT" show "HEAD:$f" 2>/dev/null | cmp -s - "$ROOT/$f"; then continue; fi
      mkdir -p "$backup/$(dirname "$f")" && mv "$ROOT/$f" "$backup/$f" && moved=$(( moved + 1 ))
    done < <(ai_git "$ROOT" ls-tree -r --name-only HEAD 2>/dev/null)
    if ! ai_git "$ROOT" checkout -f 2>/dev/null; then
      echo "Restauration impossible : $url" >&2
      rm -rf "$(privacy_ai_git_dir "$ROOT")"; exit 1
    fi
    if (( moved > 0 )); then ui_warn "$moved fichier(s) local(aux) différent(s) mis de côté" "${backup#"$ROOT"/}"; fi
    [[ -n "$GIT_ROOT" ]] && privacy_add_exclude "$ROOT"
    privacy_set_mode "$ROOT" private
    ui_ok "Fichiers IA récupérés" "$url"
    ;;
esac
