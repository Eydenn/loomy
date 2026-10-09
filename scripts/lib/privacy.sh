#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Visibility of a Loomy project's AI files. To be sourced. Bash 3.2 compatible.
#
#   versioned  versioned with the project (default)
#   local      excluded from Git via .git/info/exclude: invisible in the repository, specific to this copy
#   private    excluded from the project repository and versioned in a separate private repository (.loomy/ai.git),
#              which only tracks these files, directly in the project folder

# Translated strings (t): the language layer is loaded if the script hasn't done it already.
if ! declare -F t >/dev/null 2>&1; then
  # shellcheck source=i18n.sh
  source "$(dirname "${BASH_SOURCE[0]}")/i18n.sh"
fi

# shellcheck source=project.sh
source "$(dirname "${BASH_SOURCE[0]}")/project.sh"

LOOMY_AI_PATHS=".loomy START.md AGENTS.md CLAUDE.md .ai .claude .codex"
PRIVACY_BEGIN="# >>> loomy : fichiers IA hors du dépôt (loomy privacy)"   # marker kept as is: existing exclude files use it
PRIVACY_END="# <<< loomy"

privacy_label() {
  case "$1" in
    local) t "local only"; echo ;;
    private) t "separate private repository"; echo ;;
    *) t "versioned with the project"; echo ;;
  esac
}

# privacy_mode <root>: mode recorded in the brief (versioned by default).
privacy_mode() {
  local m
  m="$(sed -n '/^---$/,/^---$/p' "$1/.loomy/brief.md" 2>/dev/null | sed -n 's/^ai_files:[[:space:]]*//p' | head -1 || true)"
  case "$m" in local|private) echo "$m" ;; *) echo "versioned" ;; esac
}

# privacy_set_mode <root> <mode>: writes ai_files in the brief's front matter.
privacy_set_mode() {
  local brief="$1/.loomy/brief.md" tmp
  [[ -f "$brief" ]] || return 0
  tmp="$brief.tmp.$$"
  if grep -q '^ai_files:' "$brief"; then
    sed "s/^ai_files:.*/ai_files: $2/" "$brief" >"$tmp"
  else
    awk -v m="$2" 'NR > 1 && !done && /^---$/ { print "ai_files: " m; done = 1 } { print }' "$brief" >"$tmp"
  fi
  mv "$tmp" "$brief"
}

# privacy_set_key <root> <key> <value>: writes a key in the brief's front matter.
privacy_set_key() {
  local brief="$1/.loomy/brief.md" tmp
  [[ -f "$brief" ]] || return 0
  tmp="$brief.tmp.$$"
  if grep -q "^$2:" "$brief"; then
    awk -v k="$2" -v v="$3" 'index($0, k ":") == 1 && !done { print k ": " v; done = 1; next } { print }' "$brief" >"$tmp"
  else
    awk -v k="$2" -v v="$3" 'NR > 1 && !done && /^---$/ { print k ": " v; done = 1 } { print }' "$brief" >"$tmp"
  fi
  mv "$tmp" "$brief"
}

# privacy_git_root <root>: root of the project's Git repository (empty when there is none).
privacy_git_root() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || true; }

# privacy_exclude_file <root>: the repository's local exclude file (specific to this copy, never versioned).
privacy_exclude_file() {
  local f
  f="$(git -C "$1" rev-parse --git-path info/exclude 2>/dev/null)" || return 1
  case "$f" in /*) echo "$f" ;; *) echo "$1/$f" ;; esac
}

# privacy_patterns <root>: anchored exclude patterns, prefixed when the project lives in a subfolder of the repository.
privacy_patterns() {
  local prefix p
  prefix="$(git -C "$1" rev-parse --show-prefix 2>/dev/null || true)"
  for p in $LOOMY_AI_PATHS; do echo "/${prefix}${p}"; done
}

privacy_remove_exclude() {
  local f tmp
  f="$(privacy_exclude_file "$1")" || return 0
  [[ -f "$f" ]] || return 0
  tmp="$f.tmp.$$"
  awk -v b="$PRIVACY_BEGIN" -v e="$PRIVACY_END" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip { print }' "$f" >"$tmp"
  mv "$tmp" "$f"
}

privacy_add_exclude() {
  local f
  f="$(privacy_exclude_file "$1")" || return 1
  mkdir -p "$(dirname "$f")"
  privacy_remove_exclude "$1"
  { echo "$PRIVACY_BEGIN"; privacy_patterns "$1"; echo "$PRIVACY_END"; } >>"$f"
}

privacy_excluded() {
  local f
  f="$(privacy_exclude_file "$1")" || return 1
  grep -qxF "$PRIVACY_BEGIN" "$f" 2>/dev/null
}

# privacy_tracked <root>: AI files still tracked by the project repository (one path per line).
privacy_tracked() {
  local p
  [[ -n "$(privacy_git_root "$1")" ]] || return 0
  for p in $LOOMY_AI_PATHS; do
    [[ -n "$(git -C "$1" ls-files -- "$p" 2>/dev/null || true)" ]] && echo "$p"
  done
  return 0
}

# Separate private repository: a Git repository whose working tree is the project, tracking only the AI files.
privacy_ai_git_dir() { echo "$1/.loomy/ai.git"; }
ai_git() { local root="$1"; shift; git --git-dir="$(privacy_ai_git_dir "$root")" --work-tree="$root" "$@"; }

privacy_companion_ready() { [[ -d "$(privacy_ai_git_dir "$1")" ]]; }

# privacy_companion_config <root>: private repository settings (only shows its files, ignores its own folder and the log).
privacy_companion_config() {
  local d p
  d="$(privacy_ai_git_dir "$1")"
  ai_git "$1" config status.showUntrackedFiles no
  ai_git "$1" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null || true
  mkdir -p "$d/info"
  # History and work files never go in the private repository either (STATE.md is force-added by the backup).
  grep -qxF '/.loomy/ai.git/' "$d/info/exclude" 2>/dev/null || printf '/.loomy/ai.git/\n/.loomy/logs/\n' >>"$d/info/exclude"
  while IFS= read -r p; do
    grep -qxF "/$p" "$d/info/exclude" 2>/dev/null || printf '/%s\n' "$p" >>"$d/info/exclude"
  done < <(loomy_history_paths)
}

# privacy_pending <root>: number of changes not yet backed up to the private repository.
privacy_pending() {
  local p paths=()
  for p in $LOOMY_AI_PATHS; do [[ -e "$1/$p" ]] && paths+=("$p"); done
  (( ${#paths[@]} )) || { echo 0; return 0; }
  ai_git "$1" status --porcelain --untracked-files=all -- "${paths[@]}" 2>/dev/null | wc -l | tr -d ' '
}
