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

# privacy_companion_present <root>: something sits at .loomy/ai.git (trusted or not).
privacy_companion_present() { local d; d="$(privacy_ai_git_dir "$1")"; [[ -e "$d" || -L "$d" ]]; }

# Companion provenance. A plain `git clone` can ship a `.loomy/ai.git` directory (git only refuses `.git` components), with its
# own config, hooks and filters: it must never be driven automatically. Loomy records the real path, device/inode, a random
# nonce (also stored 0600 inside the companion) and a digest of every remote url/pushurl of each companion IT creates, or the
# user explicitly adopts, in the per-user config (outside any project). Trust is re-checked on EVERY call: the record, the
# nonce, the unchanged remote URLs, the config allow-list and the absence of operations in progress. Any failure after the
# record exists REVOKES it: trust only comes back through `loomy privacy adopt`.
privacy_companions_file() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/companions"; }
privacy_verdict_file() { echo "${XDG_CACHE_HOME:-$HOME/.cache}/loomy/companion-verdicts"; }
# _privacy_mkdir700 <dir>: creates the missing levels one by one with mode 0700 (never changes a directory that already exists:
# it may not be ours). The user's cache base keeps its own mode; only the levels Loomy creates are private.
_privacy_mkdir700() {
  local d="$1" parent
  [[ -d "$d" ]] && return 0
  parent="$(dirname "$d")"
  [[ "$parent" == "$d" ]] || _privacy_mkdir700 "$parent"
  mkdir -m 700 "$d" 2>/dev/null || true
}
# privacy_canonical_remote <url>: a local remote (absolute, ./, ../ or file://) that exists becomes its canonical absolute path; anything else is unchanged.
privacy_canonical_remote() { _privacy_cpl canon "$1"; }
_privacy_cpl() { perl "$(dirname "${BASH_SOURCE[0]}")/companion.pl" "$@"; }

# privacy_companion_forget <root>: drops the record of the companion of <root> (the folder may already be gone).
privacy_companion_forget() {
  local real
  real="$(cd "$1" 2>/dev/null && pwd -P)" || return 0
  [[ -f "$(privacy_companions_file)" ]] || return 0
  _privacy_cpl forget "$(privacy_companions_file)" "$real/.loomy/ai.git" 2>/dev/null || true
}

# _privacy_worktree_roots <root>: fills _PRIVACY_WT with every worktree path git lists for the project (cold paths only: adopt and record).
_privacy_worktree_roots() {
  local f
  _PRIVACY_WT=()
  while IFS= read -r -d '' f; do
    case "$f" in "worktree "*) _PRIVACY_WT+=("${f#worktree }") ;; esac
  done < <(loomy_git -C "$1" worktree list --porcelain -z 2>/dev/null)
  return 0
}

# privacy_companion_scan <ai.git dir> <adopt|ready> [root...]: audit lines from companion.pl (P code arg, U url, L local, D digest).
# The roots (project work tree, repository top level) are where adopt refuses a local remote to live.
privacy_companion_scan() {
  local d="$1" mode="$2"
  shift 2
  [[ -f "$d/config" && ! -L "$d/config" ]] || { printf 'P\tconfig_missing\t-\n'; return 0; }
  { loomy_git config --no-includes --file "$d/config" --list -z 2>/dev/null || printf 'x\0'; } | _privacy_cpl scan "$mode" "$@"
  _privacy_cpl files "$d"
}

# privacy_problem_text <code> <argument>: translated sentence for a problem code printed by companion.pl (one line).
privacy_problem_text() {
  case "$1" in
    config_missing) t "config missing" ;;
    config_key) t "config key not allowed: %s" "$2" ;;
    remote_name) t "remote name not allowed: %s" "$2" ;;
    remote_other) t "remote other than origin: %s" "$2" ;;
    push_differs) t "pushurl differs from url: remote.%s" "$2" ;;
    url_several) t "remote.%s.url has several values" "$2" ;;
    local_rel) t "local remote refused: not an absolute path (%s)" "$2" ;;
    local_in) t "local remote refused: inside the project (%s)" "$2" ;;
    local_dir) t "local remote refused: not an existing directory (%s)" "$2" ;;
    local_own) t "local remote refused: not owned by you (%s)" "$2" ;;
    local_canon) t "local remote refused: not a canonical path, no symlink, '.', '..' or trailing slash allowed (%s)" "$2" ;;
    local_special) t "local remote refused: /proc and /dev paths are not allowed (%s)" "$2" ;;
    local_nogit) t "local remote refused: not a git directory by itself (needs HEAD, objects, refs; no .git inside, no sibling .git) (%s)" "$2" ;;
    local_anc) t "local remote refused: contains the project or its worktrees (%s)" "$2" ;;
    local_host) t "remote host is this machine, so its hooks would run through your own ssh: refused (%s)" "$2" ;;
    local_pct) t "local remote refused: use a plain absolute path, not an escaped file:// URL (%s)" "$2" ;;
    local_remedy) t "use the real absolute path of a bare repository outside the project and its worktrees: git --git-dir=.loomy/ai.git remote set-url origin <path>, then loomy privacy adopt" ;;
    redirect) t "redirecting file present: %s" "$2" ;;
    attributes) t "attributes present: %s" "$2" ;;
    legacy) t "legacy remote file present: %s" "$2" ;;
    hook) t "hook present: %s" "$2" ;;
    op) t "operation in progress: %s" "$2" ;;
    *) t "config key not allowed: %s" "$1" ;;
  esac
  echo
}

# privacy_problems_print: reads audit lines on stdin and prints every problem, translated, one per line.
privacy_problems_print() {
  local kind code arg
  while IFS=$'\t' read -r kind code arg; do
    [[ "$kind" == P ]] || continue
    privacy_problem_text "$code" "$arg"
  done
}

# privacy_companion_record <root> [adopt]: audits the companion and records it as created or adopted by the user.
# Created by Loomy: local remotes are allowed. Adopted ("adopt" mode): only an absolute path outside the project. On failure the
# translated problems are left in PRIVACY_RECORD_WHY.
privacy_companion_record() {
  local root d out digest cdir mode="${2:-ready}"
  PRIVACY_RECORD_WHY=""
  root="$(privacy_companion_worktree "$1")" || return 1
  d="$(privacy_ai_git_dir "$root")"
  _privacy_worktree_roots "$root"
  out="$(privacy_companion_scan "$d" "$mode" "$root" "$(privacy_git_root "$root")" ${_PRIVACY_WT[@]+"${_PRIVACY_WT[@]}"})" || return 1
  if grep -q '^P' <<<"$out"; then PRIVACY_RECORD_WHY="$(privacy_problems_print <<<"$out")"; return 1; fi
  digest="$(awk -F'\t' '$1=="D"{print $2}' <<<"$out")"
  [[ -n "$digest" ]] || return 1
  cdir="$(dirname "$(privacy_companions_file)")"
  _privacy_mkdir700 "$cdir"
  [[ ! -O "$cdir" ]] || chmod 700 "$cdir" 2>/dev/null || true
  _privacy_cpl write "$(privacy_companions_file)" "$d" "$digest" "$(awk -F'\t' '$1=="R"{print $2}' <<<"$out")"
}

# privacy_companion_why <root>: why the companion is refused (empty when it is trusted). One of
# missing | link | owner | tracked | unrecorded | changed. A tracked, changed or failing companion has its record revoked.
privacy_companion_why() {
  local root d out digest rec rinfo key cache scanned
  d="$(privacy_ai_git_dir "$1")"
  if ! privacy_companion_present "$1"; then privacy_companion_forget "$1"; echo missing; return 0; fi
  root="$(privacy_companion_worktree "$1")" || { echo unrecorded; return 0; }
  d="$(privacy_ai_git_dir "$root")"
  if [[ -L "$d" || ! -d "$d" ]]; then echo link; return 0; fi
  if [[ ! -O "$d" ]]; then echo owner; return 0; fi
  # Anything of it tracked by the project (any case spelling): it travelled with the clone. The record is revoked.
  if [[ -n "$(loomy_git -C "$root" ls-files -z -- ':(icase).loomy/ai.git' 2>/dev/null | head -c 1 || true)" ]]; then
    privacy_companion_forget "$root"; echo tracked; return 0
  fi
  rec="$(_privacy_cpl match "$(privacy_companions_file)" "$d" 2>/dev/null)" || { echo unrecorded; return 0; }
  rinfo="${rec#*$'\t'}"; rec="${rec%%$'\t'*}"
  # A local remote is checked on EVERY call, outside the verdict cache: git resolves its path again at each push, so a retargeted
  # symlink or a replaced directory (another device/inode) must stop the push. A few stats, no git spawn.
  if [[ -n "$rinfo" && "$rinfo" != "-" ]] && ! _privacy_cpl rcheck "$root" "$rinfo" 2>/dev/null; then privacy_companion_forget "$root"; echo changed; return 0; fi
  key="$(_privacy_cpl key "$d" "$rec")" || { echo changed; return 0; }
  cache="$(privacy_verdict_file)"
  if [[ -f "$cache" ]] && _privacy_cpl vhas "$cache" "$key" 2>/dev/null; then return 0; fi
  out="$(privacy_companion_scan "$d" ready "$root")"
  digest="$(awk -F'\t' '$1=="D"{print $2}' <<<"$out")"
  scanned="$(awk -F'\t' '$1=="R"{print $2}' <<<"$out")"
  if grep -q '^P' <<<"$out" || [[ -z "$digest" || "$digest" != "$rec" || "$scanned" != "$rinfo" ]]; then privacy_companion_forget "$root"; echo changed; return 0; fi
  _privacy_mkdir700 "$(dirname "$cache")"
  _privacy_cpl vadd "$cache" "$key" 2>/dev/null || true
  return 0
}

# privacy_companion_ready <root>: the companion exists AND is trusted. Foreign companions are never driven automatically.
privacy_companion_ready() { [[ -z "$(privacy_companion_why "$1")" ]]; }

# privacy_companion_note <root>: one-line note for a present but refused companion (empty otherwise).
privacy_companion_note() {
  case "$(privacy_companion_why "$1")" in
    ''|missing) return 0 ;;
    *) t "Private history not verified · run loomy privacy adopt"; echo ;;
  esac
}

# privacy_companion_adopt <root>: validates a present companion, shows every remote URL, asks for confirmation on a
# terminal, then records it. Explicit, user-run only. Problems on stdout (one per line, translated); returns 1 when refused.
privacy_companion_adopt() {
  local root d out urls answer
  _privacy_say() { t "$@"; echo; }
  privacy_companion_present "$1" || { _privacy_say "no companion at .loomy/ai.git"; return 1; }
  root="$(privacy_companion_worktree "$1")" || { _privacy_say "project layout not supported"; return 1; }
  d="$(privacy_ai_git_dir "$root")"
  if [[ -L "$d" || ! -d "$d" ]]; then _privacy_say "companion is a link"; return 1; fi
  if [[ ! -O "$d" ]]; then _privacy_say "companion is not owned by you"; return 1; fi
  if [[ -n "$(loomy_git -C "$root" ls-files -z -- ':(icase).loomy/ai.git' 2>/dev/null | head -c 1 || true)" ]]; then _privacy_say "companion is tracked by the project repository"; return 1; fi
  _privacy_worktree_roots "$root"
  out="$(privacy_companion_scan "$d" adopt "$root" "$(privacy_git_root "$root")" ${_PRIVACY_WT[@]+"${_PRIVACY_WT[@]}"})"
  if grep -q '^P' <<<"$out"; then privacy_problems_print <<<"$out"; return 1; fi
  grep -q '^U'$'\t''origin'$'\t''url'$'\t' <<<"$out" || { _privacy_say "no remote.origin.url in the companion config"; return 1; }
  urls="$(awk -F'\t' '$1=="U"{print $2" "$3" "$4}' <<<"$out")"
  if [[ ! -t 0 || ! -t 2 ]]; then _privacy_say "adopt needs a terminal to confirm the remote URLs"; return 1; fi
  { t "Remote URLs (fetch and push) this repository will use:"; echo; } >&2
  while IFS= read -r answer; do printf '  %s\n' "$answer" >&2; done <<<"${urls:-$(t "(none)")}"
  t "Trust this repository and these URLs? [y/N] " >&2
  IFS= read -r -t 300 answer || answer=""   # no answer in 5 minutes counts as "no": adopt never blocks forever
  # y/yes in English, o/oui in French, any case (the prompt shows the key of the current language).
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
  case "$answer" in y|yes|o|oui) ;; *) _privacy_say "not confirmed"; return 1 ;; esac
  privacy_companion_record "$root" adopt || { _privacy_say "cannot write the user config"; return 1; }
}

# Inherited repository-location, config and exec variables (from a git hook, an IDE or a wrapper) would redirect the index,
# the object store or the work tree of the companion repository to the project's own, or run a program: they are cleared for
# every companion call. Identity and credential/transport variables (GIT_AUTHOR_*, GIT_ASKPASS, SSH_ASKPASS, GIT_SSH_COMMAND, ...)
# are kept: they are the user's own, and the SessionEnd sync (no terminal) may need them to push over HTTPS. A hostile clone cannot
# set the environment; a repository's own core.sshCommand or askpass setting never passes the audit.
_PRIVACY_GIT_LOCATION_VARS="GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_INDEX_VERSION GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_PREFIX GIT_IMPLICIT_WORK_TREE GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE GIT_GRAFT_FILE GIT_SHALLOW_FILE GIT_NO_REPLACE_OBJECTS GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT GIT_EXEC_PATH GIT_EXTERNAL_DIFF GIT_PAGER GIT_ALLOW_PROTOCOL"

# Filter drivers named in the user's own global/system config (git-lfs...): a project .gitattributes could select one when the
# companion adds a file. They are neutralised for every companion call (the companion's own config cannot define any).
_privacy_filter_args() {
  local n
  [[ -z "${_PRIVACY_FILTER_ARGS_SET:-}" ]] || return 0
  _PRIVACY_FILTER_ARGS=()
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    _PRIVACY_FILTER_ARGS+=(-c "$n.clean=" -c "$n.smudge=" -c "$n.process=" -c "$n.required=false")
  done < <(cd / && loomy_git config --name-only --list 2>/dev/null | sed -n 's/^\(filter\.[^.]*\)\.[^.]*$/\1/p' | sort -u)
  _PRIVACY_FILTER_ARGS_SET=1
}

# ai_git <root> <git args>: every companion call is hardened (the repository is only trusted after privacy_companion_ready):
# no hooks, no fsmonitor, no pager, no signature check, no lazy fetch, only https/ssh transports (GIT_ALLOW_PROTOCOL beats a
# repository's protocol.<name>.allow; `file` only when the config names a local remote), no ext:: or git://, no global or
# system attributes, user filter drivers neutralised, no optional index lock for status.
ai_git() {
  local root v lock=() proto="https:ssh" gd
  root="$(privacy_companion_worktree "$1")" || return 1
  shift
  gd="$(privacy_ai_git_dir "$root")"
  [[ ! -L "$gd" ]] || return 1
  [[ "${1:-}" != status ]] || lock=(--no-optional-locks)
  # `file` joins the allowed transports only when a url or pushurl CONFIGURED in the companion config (after the user's global
  # insteadOf) is a local path. Never resolved through the remote name: git also reads legacy remotes/ and branches/ files there.
  case "${1:-}" in
    fetch|ls-remote|push|pull)
      while IFS= read -r v; do
        [[ -n "$v" && "$v" != -* ]] || continue
        if (cd / && unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR && loomy_git_user -c core.hooksPath=/dev/null ls-remote --get-url "$v" 2>/dev/null) | grep -Eq '^(/|\.\.?/|file://)'; then proto="https:ssh:file"; break; fi
      done < <(loomy_git config --no-includes --file "$gd/config" --get-all remote.origin.url 2>/dev/null; loomy_git config --no-includes --file "$gd/config" --get-all remote.origin.pushurl 2>/dev/null)
      ;;
  esac
  _privacy_filter_args
  (
    for v in $_PRIVACY_GIT_LOCATION_VARS; do unset "$v"; done
    export GIT_NO_LAZY_FETCH=1 GIT_ATTR_NOSYSTEM=1 GIT_ALLOW_PROTOCOL="$proto"
    loomy_git_user -c core.hooksPath=/dev/null -c core.fsmonitor=false -c core.attributesFile=/dev/null -c core.pager=cat \
      -c log.showSignature=false -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always \
      -c protocol.file.allow=user ${_PRIVACY_FILTER_ARGS[@]+"${_PRIVACY_FILTER_ARGS[@]}"} ${lock[@]+"${lock[@]}"} --no-pager \
      --git-dir="$gd" --work-tree="$root" "$@"
  )
}

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
