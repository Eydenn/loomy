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
privacy_git_root() { loomy_git -C "$1" rev-parse --show-toplevel 2>/dev/null || true; }

# privacy_exclude_file <root>: the repository's local exclude file (specific to this copy, never versioned).
privacy_exclude_file() {
  local f
  f="$(loomy_git -C "$1" rev-parse --git-path info/exclude 2>/dev/null)" || return 1
  case "$f" in /*) echo "$f" ;; *) echo "$1/$f" ;; esac
}

# privacy_patterns <root>: anchored exclude patterns, prefixed when the project lives in a subfolder of the repository.
privacy_patterns() {
  local prefix p
  prefix="$(loomy_git -C "$1" rev-parse --show-prefix 2>/dev/null || true)"
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
    [[ -n "$(loomy_git -C "$1" ls-files -- "$p" 2>/dev/null || true)" ]] && echo "$p"
  done
  return 0
}

# Separate private repository: a Git repository whose working tree is the project, tracking only the AI files.
privacy_ai_git_dir() { echo "$1/.loomy/ai.git"; }

# A fully shared .loomy belongs to its registered owner, including the companion's index. Staging its symlink
# from a sibling worktree would replace the owner's authored files with that link. Resolve only this layout;
# ordinary projects and the versioned layout with just a logs symlink keep their own working tree.
privacy_companion_worktree() (
  local root shared owner root_top owner_top root_common owner_common field name found_root=0 found_owner=0
  # Registration checks must describe the supplied project, not a caller's inherited Git repository/index.
  while IFS= read -r name; do unset "$name"; done < <(compgen -A variable GIT_)
  root="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  if [[ ! -L "$root/.loomy" ]]; then printf '%s\n' "$root"; return 0; fi
  shared="$(cd "$root/.loomy" 2>/dev/null && pwd -P)" || return 1
  [[ "$shared" == */.loomy ]] || return 1
  owner="${shared%/.loomy}"
  root_top="$(loomy_git -C "$root" rev-parse --show-toplevel 2>/dev/null)" || return 1
  owner_top="$(loomy_git -C "$owner" rev-parse --show-toplevel 2>/dev/null)" || return 1
  root_top="$(cd "$root_top" 2>/dev/null && pwd -P)" || return 1
  owner_top="$(cd "$owner_top" 2>/dev/null && pwd -P)" || return 1
  [[ "$root" == "$root_top" || "$root" == "$root_top/"* ]] || return 1
  [[ "$owner" == "$owner_top" || "$owner" == "$owner_top/"* ]] || return 1
  [[ "${root#"$root_top"}" == "${owner#"$owner_top"}" ]] || return 1
  root_common="$(loomy_git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  owner_common="$(loomy_git -C "$owner" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$root_common" == /* ]] || root_common="$root/$root_common"
  [[ "$owner_common" == /* ]] || owner_common="$owner/$owner_common"
  root_common="$(cd "$root_common" 2>/dev/null && pwd -P)" || return 1
  owner_common="$(cd "$owner_common" 2>/dev/null && pwd -P)" || return 1
  [[ "$root_common" == "$owner_common" ]] || return 1
  while IFS= read -r -d '' field; do
    [[ "$field" != "worktree $root_top" ]] || found_root=1
    [[ "$field" != "worktree $owner_top" ]] || found_owner=1
  done < <(loomy_git -C "$root" worktree list --porcelain -z 2>/dev/null)
  (( found_root && found_owner )) || return 1
  printf '%s\n' "$owner"
)

# Inherited repository-location variables (from a git hook, an IDE or a wrapper) would redirect the index, the object
# store or the work tree of the companion repository to the project's own: they are cleared for every companion call.
# Identity, config and transport variables (GIT_AUTHOR_*, GIT_CONFIG_*, GIT_SSH*, ...) are kept.
_PRIVACY_GIT_LOCATION_VARS="GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_INDEX_VERSION GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_NO_REPLACE_OBJECTS GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM"
ai_git() {
  local root v
  root="$(privacy_companion_worktree "$1")" || return 1
  shift
  (
    for v in $_PRIVACY_GIT_LOCATION_VARS; do unset "$v"; done
    loomy_git_user --git-dir="$(privacy_ai_git_dir "$root")" --work-tree="$root" "$@"
  )
}

privacy_companion_ready() { [[ -d "$(privacy_ai_git_dir "$1")" ]]; }

# privacy_companion_config <root>: private repository settings and mandatory runtime exclusions.
privacy_companion_config() {
  local root d p
  root="$(privacy_companion_worktree "$1")" || return 1
  d="$(privacy_ai_git_dir "$root")"
  ai_git "$root" config status.showUntrackedFiles no
  ai_git "$root" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null || true
  mkdir -p "$d/info"
  # The project may have no managed .gitignore yet. The companion independently excludes every runtime path;
  # authored STATE.md, DEAD-ENDS.md and HANDOFF.md are the only force-added continuity exceptions.
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    grep -qxF "/$p" "$d/info/exclude" 2>/dev/null || printf '/%s\n' "$p" >>"$d/info/exclude"
  done <<<"$LOOMY_HISTORY_LIST"
}

# privacy_companion_restore_index <root>: select approved AI paths from HEAD without checking out any blobs.
# Ignore patterns do not filter a checkout of an old commit. Build the filtered index first, so both the local
# backup pass and checkout-index see only authored/config files and the three explicit continuity exceptions.
# Runtime objects remain in old commits; neither their on-disk originals nor repository history are removed.
privacy_companion_restore_index() {
  local p paths=() drop
  for p in $LOOMY_AI_PATHS; do paths+=("$p"); done
  loomy_history_specs_load || return 1
  ai_git "$1" read-tree --empty || return 1
  ai_git "$1" reset -q HEAD -- "${paths[@]}" || return 1
  # A historical worktree link is not a project directory and must never replace the live .loomy directory.
  ai_git "$1" update-index --force-remove -- .loomy || return 1
  ai_git "$1" rm -r --cached --quiet --ignore-unmatch -- "${LOOMY_HISTORY_SPECS[@]}" || return 1
  ai_git "$1" reset -q HEAD -- .loomy/memory/STATE.md .loomy/memory/DEAD-ENDS.md .loomy/docs/HANDOFF.md
  # Allowlist: only entries under the AI paths survive (a case variant such as .loomy/Logs or .loomy/AI.git that the
  # runtime specs missed, anything else a remote added), directory roots must be directories, and the three continuity
  # files must be regular stage-0 blobs: a link there would be read back by the session hooks.
  ai_git "$1" ls-files --stage -z 2>/dev/null | perl -0 -e '
    my @roots = @ARGV; my %dir = map { $_ => 1 } grep { /\A\.[a-z]+\z/ } @roots;
    my %cont = map { $_ => 1 } (".loomy/memory/STATE.md", ".loomy/memory/DEAD-ENDS.md", ".loomy/docs/HANDOFF.md");
    local $/ = "\0";
    while (my $rec = <STDIN>) {
      chomp $rec; $rec =~ /\A(\d+) [0-9a-f]+ (\d)\t(.*)\z/s or exit 1;
      my ($mode, $stage, $path) = ($1, $2, $3);
      my $ok = 0; for my $r (@roots) { $ok = 1 if $path eq $r || index($path, "$r/") == 0 }
      $ok = 0 if grep { lc($_) eq ".git" } split m{/}, $path;
      $ok = 0 if $dir{$path} && $mode eq "120000";
      $ok = 0 if $cont{$path} && ($mode !~ /\A100(?:644|755)\z/ || $stage ne "0");
      print "$path\0" unless $ok;
    }
  ' $LOOMY_AI_PATHS | ai_git "$1" update-index --force-remove -z --stdin
  [[ "${PIPESTATUS[0]}" == 0 && "${PIPESTATUS[1]}" == 0 && "${PIPESTATUS[2]}" == 0 ]] || return 1
  return 0
}

# privacy_companion_ref_safe <root> <ref>: inspect runtime path metadata before a rebase can check out its tree.
# --with-tree adds the reference's paths to ls-files without changing the live index or reading file bodies.
# The current index has already been filtered by sync; only its three authored continuity exceptions may match.
# Fail closed on an unreadable reference as well as runtime entries, without printing identifying filenames.
privacy_companion_ref_safe() (
  local root p continuity=(.loomy/memory/STATE.md .loomy/memory/DEAD-ENDS.md .loomy/docs/HANDOFF.md)
  root="$(privacy_companion_worktree "$1")" || return 1
  cd "$root" || return 1
  loomy_history_specs_load || return 1
  set -o pipefail
  # Allowlist first: every path of the reference and of the live index must sit under an AI path (anything else, such
  # as .env or .venv/, could overwrite an ignored local file at rebase), with no .git component at any depth.
  ai_git "$root" ls-files -z --with-tree="$2" 2>/dev/null | perl -0ne '
    BEGIN { our @roots = @ARGV; @ARGV = () }
    chomp; my $path = $_; my $ok = 0;
    for my $r (@roots) { $ok = 1 if $path eq $r || index($path, "$r/") == 0 }
    exit 1 unless $ok && !grep { lc($_) eq ".git" } split m{/}, $path;
  ' $LOOMY_AI_PATHS || return 1
  # A historical .loomy symlink has no slash and is outside the runtime pathspecs below. Even an exact
  # directory pathspec can list descendants, so reject only the root entry itself in this separate pass.
  ai_git "$root" ls-files -z --with-tree="$2" -- ':(glob).loomy' 2>/dev/null | perl -0ne '
    chomp; exit 1 if $_ eq ".loomy";
  ' || return 1
  # Continuity names authorize regular authored blobs only, never links, directories, gitlinks or conflicts.
  # Check the reference and the live index separately: --with-tree supplies names but cannot supply stages.
  ai_git "$root" ls-tree --full-tree -z "$2" -- "${continuity[@]}" 2>/dev/null | perl -0ne '
    chomp;
    exit 1 unless /\A100(?:644|755) blob [0-9a-f]+\t(?:\.loomy\/memory\/(?:STATE|DEAD-ENDS)\.md|\.loomy\/docs\/HANDOFF\.md)\z/;
  ' || return 1
  ai_git "$root" ls-files --stage -z -- "${continuity[@]}" 2>/dev/null | perl -0ne '
    chomp;
    exit 1 unless /\A100(?:644|755) [0-9a-f]+ 0\t(?:\.loomy\/memory\/(?:STATE|DEAD-ENDS)\.md|\.loomy\/docs\/HANDOFF\.md)\z/;
  ' || return 1
  ai_git "$root" ls-files -z --with-tree="$2" -- "${LOOMY_HISTORY_SPECS[@]}" 2>/dev/null | perl -0ne '
    chomp;
    next if $_ eq ".loomy/memory/STATE.md" || $_ eq ".loomy/memory/DEAD-ENDS.md" || $_ eq ".loomy/docs/HANDOFF.md";
    exit 1;
  '
)

# privacy_pending <root>: number of changes not yet backed up to the private repository.
privacy_pending() {
  local p paths=()
  for p in $LOOMY_AI_PATHS; do [[ -e "$1/$p" ]] && paths+=("$p"); done
  (( ${#paths[@]} )) || { echo 0; return 0; }
  ai_git "$1" status --porcelain --untracked-files=all -- "${paths[@]}" 2>/dev/null | wc -l | tr -d ' '
}
