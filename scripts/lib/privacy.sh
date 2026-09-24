#!/usr/bin/env bash
# shellcheck disable=SC2034  # bibliothèque chargée par d'autres scripts
# Visibilité des fichiers IA d'un projet Loomy. À charger (source). Compatible bash 3.2.
#
#   versioned  versionnés avec le projet (par défaut)
#   local      exclus de Git via .git/info/exclude : invisibles dans le dépôt, propres à cette copie
#   private    exclus du dépôt du projet et versionnés dans un dépôt privé séparé (.loomy/ai.git),
#              qui suit uniquement ces fichiers, directement dans le dossier du projet

LOOMY_AI_PATHS=".loomy START.md AGENTS.md CLAUDE.md .ai .claude"
PRIVACY_BEGIN="# >>> loomy : fichiers IA hors du dépôt (loomy privacy)"
PRIVACY_END="# <<< loomy"

privacy_label() {
  case "$1" in
    local) echo "locaux uniquement" ;;
    private) echo "dépôt privé séparé" ;;
    *) echo "versionnés avec le projet" ;;
  esac
}

# privacy_mode <racine> : mode enregistré dans le brief (versioned par défaut).
privacy_mode() {
  local m
  m="$(sed -n '/^---$/,/^---$/p' "$1/.loomy/brief.md" 2>/dev/null | sed -n 's/^ai_files:[[:space:]]*//p' | head -1 || true)"
  case "$m" in local|private) echo "$m" ;; *) echo "versioned" ;; esac
}

# privacy_set_mode <racine> <mode> : écrit ai_files dans le front matter du brief.
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

# privacy_set_key <racine> <clé> <valeur> : écrit une clé dans le front matter du brief.
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

# privacy_git_root <racine> : racine du dépôt Git du projet (vide s'il n'y en a pas).
privacy_git_root() { git -C "$1" rev-parse --show-toplevel 2>/dev/null || true; }

# privacy_exclude_file <racine> : fichier d'exclusion local du dépôt (propre à cette copie, jamais versionné).
privacy_exclude_file() {
  local f
  f="$(git -C "$1" rev-parse --git-path info/exclude 2>/dev/null)" || return 1
  case "$f" in /*) echo "$f" ;; *) echo "$1/$f" ;; esac
}

# privacy_patterns <racine> : motifs d'exclusion ancrés, préfixés si le projet vit dans un sous-dossier du dépôt.
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

# privacy_tracked <racine> : fichiers IA encore suivis par le dépôt du projet (un chemin par ligne).
privacy_tracked() {
  local p
  [[ -n "$(privacy_git_root "$1")" ]] || return 0
  for p in $LOOMY_AI_PATHS; do
    git -C "$1" ls-files -- "$p" 2>/dev/null | head -1 | grep -q . && echo "$p"
  done
  return 0
}

# Dépôt privé séparé : un dépôt Git dont le dossier de travail est le projet, qui ne suit que les fichiers IA.
privacy_ai_git_dir() { echo "$1/.loomy/ai.git"; }
ai_git() { local root="$1"; shift; git --git-dir="$(privacy_ai_git_dir "$root")" --work-tree="$root" "$@"; }

privacy_companion_ready() { [[ -d "$(privacy_ai_git_dir "$1")" ]]; }

# privacy_companion_config <racine> : réglages du dépôt privé (n'affiche que ses fichiers, ignore son propre dossier et le journal).
privacy_companion_config() {
  local d
  d="$(privacy_ai_git_dir "$1")"
  ai_git "$1" config status.showUntrackedFiles no
  ai_git "$1" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null || true
  mkdir -p "$d/info"
  grep -qxF '/.loomy/ai.git/' "$d/info/exclude" 2>/dev/null || printf '/.loomy/ai.git/\n/.loomy/logs/\n' >>"$d/info/exclude"
}

# privacy_pending <racine> : nombre de changements pas encore sauvegardés dans le dépôt privé.
privacy_pending() {
  local p paths=()
  for p in $LOOMY_AI_PATHS; do [[ -e "$1/$p" ]] && paths+=("$p"); done
  (( ${#paths[@]} )) || { echo 0; return 0; }
  ai_git "$1" status --porcelain --untracked-files=all -- "${paths[@]}" 2>/dev/null | wc -l | tr -d ' '
}
