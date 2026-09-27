#!/usr/bin/env bash
# Visibility of the project's AI files (AGENTS.md, CLAUDE.md, .ai/, .claude/, .loomy/, START.md). Bash 3.2 compatible.
#   loomy privacy                          status: mode, files still tracked, private repository
#   loomy privacy versioned                versioned with the project
#   loomy privacy local                    excluded from Git on this machine (invisible in the repository)
#   loomy privacy private [--name NAME | --remote URL]   excluded from the project, backed up in a separate private repository
#   loomy privacy sync                     backs up the AI files to the private repository
#   loomy privacy restore <URL|account/repo>   gets the AI files back on another machine
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
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//' | i18n_lines; exit 0 ;;
    *) t "Unknown argument: %s (loomy privacy --help)" "$1" >&2; echo >&2; exit 2 ;;
  esac
  shift
done
ROOT="$(cd "${ROOT:-$(ai_project_root)}" && pwd -P)"
# On a new machine, .loomy doesn't exist yet (outside the repository): only restore can do without it.
if [[ "$CMD" == "restore" ]]; then mkdir -p "$ROOT/.loomy"
elif [[ ! -d "$ROOT/.loomy" ]]; then t "No Loomy project in %s: loomy init first (or loomy privacy restore <account/repo> to recover its AI files)." "${ROOT/#$HOME/~}" >&2; echo >&2; exit 1; fi
GIT_ROOT="$(privacy_git_root "$ROOT")"
MODE="$(privacy_mode "$ROOT")"
# Private repository name: the project's (brief slug), so that everything has the same name.
NAME="$(sed -n '/^---$/,/^---$/p' "$ROOT/.loomy/brief.md" 2>/dev/null | sed -n 's/^slug:[[:space:]]*//p' | head -1 || true)"
if [[ -z "$NAME" ]]; then
  NAME="$(sed -n '/^---$/,/^---$/p' "$ROOT/.loomy/brief.md" 2>/dev/null | sed -n 's/^name:[[:space:]]*//p' | head -1 | sed 's/^"//; s/"$//' || true)"
  NAME="$(loomy_slug "${NAME:-$(basename "$ROOT")}")"
fi
# Private repository name: --name, otherwise the brief's (validated in the questionnaire), otherwise <project>-ai.
AI_REPO="${AI_REPO_OPT:-$(sed -n '/^---$/,/^---$/p' "$ROOT/.loomy/brief.md" 2>/dev/null | sed -n 's/^ai_repo_name:[[:space:]]*//p' | head -1 || true)}"
AI_REPO="${AI_REPO:-$NAME-ai}"

# ---------------------------------------------------------------- separate private repository
create_companion() {
  local url="$REMOTE" owner
  if privacy_companion_ready "$ROOT"; then return 0; fi
  if [[ -z "$url" ]]; then
    if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
      ui_err "$(t "Can't create the private repository %s" "$AI_REPO")" "$(t "gh missing or not logged in: gh auth login, or give an existing repository with --remote URL")"
      return 1
    fi
    owner="$(gh api user --jq .login 2>/dev/null || true)"
    [[ -n "$owner" ]] || { ui_err "$(t "GitHub account not found")" "$(t "gh auth login")"; return 1; }
    # Name offered for approval, editable (unless it already comes from --name or the questionnaire).
    if [[ -z "$AI_REPO_OPT" && "$CMD" != "apply" ]] && ui_is_interactive; then
      UI_LABEL="$(t "Private repository")"
      UI_HINT="$(t "Private GitHub repository that will only hold the AI files.")"
      ui_input "$(t "Private repository name (%s/…)" "$owner")" "$AI_REPO"
      AI_REPO="$(loomy_slug "$UI_VALUE")"
    fi
    if gh repo view "$owner/$AI_REPO" >/dev/null 2>&1; then
      ui_info "$(t "repository %s already exists: used as is" "$owner/$AI_REPO")"
    else
      gh repo create "$owner/$AI_REPO" --private --description "Fichiers IA du projet $NAME (Loomy)" >/dev/null || { ui_err "$(t "Private repository creation failed")" "$owner/$AI_REPO"; return 1; }
      ui_ok "$(t "Private repository created")" "$owner/$AI_REPO"
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
  privacy_companion_ready "$ROOT" || { ui_err "$(t "No private repository for this project")" "$(t "loomy privacy private")"; return 1; }
  for p in $LOOMY_AI_PATHS; do [[ -e "$ROOT/$p" ]] && paths+=("$p"); done
  (( ${#paths[@]} )) || { ui_info "$(t "no AI file to back up")"; return 0; }
  ai_git "$ROOT" add -A -- "${paths[@]}"
  if ! ai_git "$ROOT" diff --cached --quiet 2>/dev/null; then
    msg="loomy : fichiers IA du $(date '+%Y-%m-%d %H:%M')"
    ai_git "$ROOT" commit -q -m "$msg"
  fi
  # Another machine may have backed up in the meantime: we replay our changes on top of theirs.
  if ai_git "$ROOT" ls-remote --exit-code origin main >/dev/null 2>&1; then
    ai_git "$ROOT" fetch -q origin
    if ! ai_git "$ROOT" rebase -q origin/main >/dev/null 2>&1; then
      ai_git "$ROOT" rebase --abort >/dev/null 2>&1 || true
      ui_err "$(t "The AI files changed on both sides")" "$(t "resolve by hand: git --git-dir=.loomy/ai.git --work-tree=. pull --rebase origin main")"
      return 1
    fi
  fi
  if ai_git "$ROOT" rev-parse -q --verify HEAD >/dev/null; then
    ai_git "$ROOT" push -q -u origin main || { ui_err "$(t "Push to the private repository failed")" "$(ai_git "$ROOT" remote get-url origin)"; return 1; }
  fi
  (( QUIET )) || ui_ok "$(t "AI files backed up")" "$(ai_git "$ROOT" remote get-url origin | sed 's|https://github.com/||; s|\.git$||')"
  return 0
}

# ---------------------------------------------------------------- application d'un mode
warn_tracked() {
  local t
  t="$(privacy_tracked "$ROOT" | tr '\n' ' ')"
  [[ -n "$t" ]] || return 0
  ui_warn "$(t "Still tracked by the project repository")" "$t"
  ui_rail "    ${C_DIM}$(t "to stop tracking them (they stay on your disk):")${C_RESET} git rm -r --cached -- $t"
  ui_rail "    ${C_DIM}$(t "what was already pushed stays in the repository history")${C_RESET}"
}

apply_mode() {
  local m="$1"
  case "$m" in
    versioned)
      privacy_remove_exclude "$ROOT" || true
      if privacy_companion_ready "$ROOT"; then ui_info "$(t "the private repository (.loomy/ai.git) stays in place; it's no longer updated")"; fi ;;
    local|private)
      if [[ -n "$GIT_ROOT" ]]; then privacy_add_exclude "$ROOT"; else ui_info "$(t "no Git repository yet: loomy privacy %s will set the exclusion once the repository exists" "$m")"; fi
      if [[ "$m" == "private" ]]; then create_companion && do_sync || return 1; fi ;;
  esac
  privacy_set_mode "$ROOT" "$m"
  MODE="$m"
  return 0
}

show_state() {
  ui_section "$(t "AI FILES")" "$(echo "$LOOMY_AI_PATHS" | sed 's/ / · /g')"
  ui_kv "$(t "Mode")" "${C_BOLD}$(privacy_label "$MODE")${C_RESET}"
  if [[ -z "$GIT_ROOT" ]]; then ui_kv "$(t "Git repository")" "${C_DIM}$(t "none")${C_RESET}"
  elif [[ "$MODE" != "versioned" ]]; then
    if privacy_excluded "$ROOT"; then ui_kv "$(t "Exclusion")" "${C_GREEN}$(t "active")${C_RESET} ${C_DIM}($(t ".git/info/exclude, specific to this machine"))${C_RESET}"
    else ui_kv "$(t "Exclusion")" "${C_YELLOW}$(t "not set on this machine")${C_RESET} ${C_DIM}→ loomy privacy $MODE${C_RESET}"; fi
  fi
  if [[ "$MODE" == "private" ]]; then
    if privacy_companion_ready "$ROOT"; then
      ui_kv "$(t "Private repository")" "$(ai_git "$ROOT" remote get-url origin 2>/dev/null | sed 's|https://github.com/||; s|\.git$||')"
      pending="$(privacy_pending "$ROOT")"
      if [[ "$pending" == "0" ]]; then ui_kv "$(t "Backup")" "${C_GREEN}$(t "up to date")${C_RESET}"
      else ui_kv "$(t "Backup")" "${C_YELLOW}$(t "%s change(s) to back up" "$pending")${C_RESET} ${C_DIM}→ loomy privacy sync${C_RESET}"; fi
    else
      ui_kv "$(t "Private repository")" "${C_YELLOW}$(t "missing on this machine")${C_RESET} ${C_DIM}→ $(t "loomy privacy restore <account/repo>, or loomy privacy private to create it")${C_RESET}"
    fi
  fi
  if [[ "$MODE" != "versioned" ]]; then warn_tracked; fi
}

case "$CMD" in
  show)
    ui_banner "$(t "AI files visibility")" "${ROOT/#$HOME/~}"
    show_state
    ui_section "$(t "CHANGE")"
    ui_rail "${C_BOLD}loomy privacy versioned${C_RESET}  ${C_DIM}$(t "versioned with the project (private repository: recommended)")${C_RESET}"
    ui_rail "${C_BOLD}loomy privacy local${C_RESET}      ${C_DIM}$(t "never pushed to GitHub, specific to this machine")${C_RESET}"
    ui_rail "${C_BOLD}loomy privacy private${C_RESET}    ${C_DIM}$(t "outside the project repository, backed up in a private repository (public repository: recommended)")${C_RESET}"
    ui_end "$(t "GitHub doesn't handle visibility file by file: a repository is entirely public or private")"
    ;;
  versioned|local|private)
    ui_banner "$(t "AI files visibility")" "${ROOT/#$HOME/~}"
    ui_section "$(t "MODE")" "$(privacy_label "$CMD")"
    apply_mode "$CMD" || { ui_end "$(t "mode unchanged: %s" "$(privacy_label "$(privacy_mode "$ROOT")")")"; exit 1; }
    ui_ok "$(t "Mode saved")" "$(privacy_label "$CMD") · $(t "in .loomy/brief.md")"
    [[ "$CMD" != "versioned" ]] && warn_tracked
    ui_end "$(t "status: loomy privacy")$( [[ "$CMD" == private ]] && echo " · $(t "backup: loomy privacy sync")")"
    ;;
  apply)
    # Used by the questionnaire: applies the brief's mode, without header.
    apply_mode "$MODE" || exit 1
    ;;
  sync)
    if [[ "$MODE" != "private" ]]; then t "This project doesn't use a separate private repository (mode: %s)." "$(privacy_label "$MODE")" >&2; echo >&2; exit 1; fi
    do_sync || exit 1
    ;;
  restore)
    [[ -n "$ARG" ]] || { t "Usage: loomy privacy restore <URL | account/repo>" >&2; echo >&2; exit 2; }
    if privacy_companion_ready "$ROOT"; then t "The private repository is already here (.loomy/ai.git): loomy privacy sync" >&2; echo >&2; exit 1; fi
    url="$ARG"
    if [[ "$ARG" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ && ! -e "$ARG" ]]; then url="https://github.com/$ARG.git"; fi
    git clone --bare -q "$url" "$(privacy_ai_git_dir "$ROOT")" || { t "Can't clone: %s" "$url" >&2; echo >&2; exit 1; }
    privacy_companion_config "$ROOT"
    # Files already present: identical ones are kept; different ones are set aside before restoring.
    backup="$ROOT/.loomy/restore-backup-$(date +%Y%m%d-%H%M%S)"; moved=0
    while IFS= read -r f; do
      [[ -e "$ROOT/$f" ]] || continue
      if ai_git "$ROOT" show "HEAD:$f" 2>/dev/null | cmp -s - "$ROOT/$f"; then continue; fi
      mkdir -p "$backup/$(dirname "$f")" && mv "$ROOT/$f" "$backup/$f" && moved=$(( moved + 1 ))
    done < <(ai_git "$ROOT" ls-tree -r --name-only HEAD 2>/dev/null)
    if ! ai_git "$ROOT" checkout -f 2>/dev/null; then
      t "Can't restore: %s" "$url" >&2; echo >&2
      rm -rf "$(privacy_ai_git_dir "$ROOT")"; exit 1
    fi
    if (( moved > 0 )); then ui_warn "$(t "%s different local file(s) set aside" "$moved")" "${backup#"$ROOT"/}"; fi
    [[ -n "$GIT_ROOT" ]] && privacy_add_exclude "$ROOT"
    privacy_set_mode "$ROOT" private
    ui_ok "$(t "AI files recovered")" "$url"
    ;;
esac
