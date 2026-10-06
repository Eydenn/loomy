#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Official agent skills for a Loomy project (catalog/skills.conf): chosen from the brief at init, suggested from the
# text of each task, analysed before installation, installed from their source at a pinned commit, recorded in
# .loomy/skills.lock (versioned) while the skill folders stay out of Git (they are fetched again on each machine,
# at the commit of the lock). Only the two official sources: github.com/anthropics/skills and github.com/openai/skills.
# Skills under a proprietary licence are never installed on their own, only for Claude, after the user asks.
# Policy: loomy config set skills auto|ask|off (auto: official skills installed on their own, each one announced).
# Bash 3.2. Every public function returns normally and never stops its caller (set -e / set -u callers).

SKILLS_REPO_anthropic="anthropics/skills"
SKILLS_REPO_openai="openai/skills"
SKILLS_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/loomy/skills"
# Each installation is logged (loomy watch, the agent tree): the log library is loaded when the caller hasn't.
# shellcheck source=journal.sh
declare -F ai_journal_write >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/journal.sh" 2>/dev/null || true
SK_LAST=""   # what the last call did, one line, for the caller to announce

# skills_catalog: the catalog file (the one fetched by loomy update --catalog when newer, otherwise the installed one).
skills_catalog() {
  local base="${LOOMY_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}" u
  u="${XDG_CONFIG_HOME:-$HOME/.config}/loomy/skills.conf"
  if [[ -f "$u" && ! -L "$u" ]] && [[ "$(sed -n 's/^date=//p' "$u" | head -1)" > "$(sed -n 's/^date=//p' "$base/catalog/skills.conf" 2>/dev/null | head -1)" ]]; then
    echo "$u"; else echo "$base/catalog/skills.conf"; fi
}

# skills_policy: auto, ask or off.
skills_policy() { local p; p="$(loomy_config_get skills 2>/dev/null || true)"; case "$p" in ask|off) echo "$p" ;; *) echo auto ;; esac; }

# _sk_valid <name>: a plain skill name (letters, digits, dashes), nothing that could be a path.
_sk_valid() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }

# skills_line <name>: the catalog line of a skill (name|source|path|commit|license|auto|keywords|summary).
skills_line() { _sk_valid "$1" || return 0; grep -v '^#' "$(skills_catalog)" | grep -v '^date=' | awk -F'|' -v n="$1" '$1 == n { print; exit }'; }

# skills_lock_line <root> <name>: the lock line of a skill (name|source|path|commit|license|date|reason|analysis).
skills_lock_line() { [[ -f "$1/.loomy/skills.lock" ]] && awk -F'|' -v n="$2" '$1 == n { print; exit }' "$1/.loomy/skills.lock"; return 0; }

# skills_installed <root> <name>: true when the lock holds it.
skills_installed() { [[ -n "$(skills_lock_line "$1" "$2")" ]]; }

# _sk_brief <root> <key>: a value of the project's brief.
_sk_brief() { sed -n "s/^$2: *//p" "$1/.loomy/brief.md" 2>/dev/null | head -1 | tr -d '"'; }

# skills_auto_for <root>: names whose "auto" condition matches the brief (type, traits, detail1), one per line.
skills_auto_for() {
  local r="$1" type traits d1
  type="$(_sk_brief "$r" type)"; traits="$(_sk_brief "$r" traits)"; [[ -n "$traits" ]] || traits="$(_sk_brief "$r" sensitive)"
  d1="$(_sk_brief "$r" detail1)"
  grep -v '^#' "$(skills_catalog)" | grep -v '^date=' | awk -F'|' -v ty="$type" -v tr=",$traits," -v d1=",$d1," '
    $6 == "no" || $6 == "" || $5 == "proprietary" { next }
    { n = split($6, cl, ";"); ok = 1
      for (i = 1; i <= n; i++) {
        split(cl[i], kv, "="); m = split(kv[2], vals, ","); hit = 0
        for (j = 1; j <= m; j++) {
          if (kv[1] == "type" && vals[j] == ty) hit = 1
          if (kv[1] == "trait" && index(tr, "," vals[j] ",")) hit = 1
          if (kv[1] == "detail1" && index(d1, "," vals[j] ",")) hit = 1
        }
        if (!hit) ok = 0
      }
      if (ok) print $1 }'
  return 0
}

# skills_suggest <root> <text> [max]: skills whose keywords appear in the text as whole words, best first, not
# installed yet.
skills_suggest() {
  local r="$1" txt max="${3:-2}"
  # Lower case; every character that isn't a letter, a digit or . + # becomes a space: keywords match whole words.
  txt="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | sed 's/[^[:alnum:]àâäçéèêëîïôöùûüÿœ.+#]/ /g')"
  grep -v '^#' "$(skills_catalog)" | grep -v '^date=' | awk -F'|' -v t=" $txt " '
    { n = split($7, kw, ","); s = 0
      for (i = 1; i <= n; i++) { k = kw[i]; gsub(/^ +| +$/, "", k); if (length(k) >= 2 && index(t, " " k " ")) s += (index(k, " ") ? 2 : 1) }
      if (s > 0) print s "|" $1 }' | sort -t'|' -k1,1nr | cut -d'|' -f2 | while IFS= read -r n; do
        skills_installed "$r" "$n" || echo "$n"
      done | head -n "$max"
  return 0
}

# _sk_dirs <root> <license>: the folders the agents of this project read (.claude/skills for Claude, .agents/skills
# for Codex). A proprietary skill only goes to Claude's folder.
_sk_dirs() {
  local mode lead; mode="$(_sk_brief "$1" ai_mode)"; lead="$(_sk_brief "$1" ai_lead)"
  if [[ "${2:-}" == proprietary ]]; then echo ".claude/skills"; return 0; fi
  if [[ "$mode" == "SOLO" ]]; then
    if [[ "$lead" == codex ]]; then echo ".agents/skills"; else echo ".claude/skills"; fi
  else echo ".claude/skills"; echo ".agents/skills"; fi
}

# _sk_safe_dir <root> <relative path>: true when no part of the path is a symbolic link (writes stay in the project).
_sk_safe_dir() {
  local p="$1" part rest="$2"
  [[ -L "$p" ]] && return 1
  while [[ -n "$rest" ]]; do
    part="${rest%%/*}"; if [[ "$rest" == */* ]]; then rest="${rest#*/}"; else rest=""; fi
    p="$p/$part"; [[ -L "$p" ]] && return 1
  done
  return 0
}

# _sk_archive_ok <archive>: a readable gzip tar with no absolute path, no "..", no link.
_sk_archive_ok() {
  local list
  list="$(tar -tzvf "$1" 2>/dev/null)" || return 1
  [[ -n "$list" ]] || return 1
  printf '%s\n' "$list" | grep -qE '^[lh]' && return 1
  tar -tzf "$1" 2>/dev/null | grep -qE '(^/|(^|/)\.\.(/|$))' && return 1
  return 0
}

# _sk_fetch <source> <path> <commit> <dest>: the skill folder at that commit, from the cached archive of its
# repository (codeload, or gh). LOOMY_SKILLS_FIXTURES=<dir> serves <dir>/<source>/<path> (tests).
_sk_fetch() {
  local src="$1" path="$2" commit="$3" dest="$4" repo arch top part
  [[ "$commit" =~ ^[0-9a-f]{7,40}$ && "$path" =~ ^[A-Za-z0-9._/-]+$ && "$path" != *..* ]] || return 1
  if [[ -n "${LOOMY_SKILLS_FIXTURES:-}" ]]; then
    [[ -d "$LOOMY_SKILLS_FIXTURES/$src/$path" ]] || return 1
    mkdir -p "$dest" && cp -R "$LOOMY_SKILLS_FIXTURES/$src/$path/." "$dest/"; return $?
  fi
  repo="SKILLS_REPO_$src"; repo="${!repo:-}"; [[ -n "$repo" ]] || return 1
  [[ -L "$SKILLS_CACHE" ]] && return 1
  mkdir -p "$SKILLS_CACHE" || return 1
  arch="$SKILLS_CACHE/${repo//\//-}-$commit.tar.gz"
  [[ -L "$arch" ]] && return 1
  # A cached archive that doesn't check out is fetched again.
  if [[ -s "$arch" ]] && ! _sk_archive_ok "$arch"; then rm -f "$arch"; fi
  if [[ ! -s "$arch" ]]; then
    part="$(mktemp "$SKILLS_CACHE/.download.XXXXXX")" || return 1
    if ! curl -fsSL "https://codeload.github.com/$repo/tar.gz/$commit" -o "$part" 2>/dev/null \
       && ! { command -v gh >/dev/null 2>&1 && gh api "repos/$repo/tarball/$commit" >"$part" 2>/dev/null; }; then
      rm -f "$part"; return 1
    fi
    _sk_archive_ok "$part" || { rm -f "$part"; return 1; }
    mv -f "$part" "$arch" || { rm -f "$part"; return 1; }
  fi
  top="$(tar -tzf "$arch" 2>/dev/null | head -1 | cut -d/ -f1)"; [[ -n "$top" ]] || return 1
  mkdir -p "$dest" || return 1
  if ! tar -xzf "$arch" -C "$dest" --strip-components="$(( $(printf '%s' "$path" | tr -cd '/' | wc -c) + 2 ))" "$top/$path" 2>/dev/null; then
    rm -f "$arch"; return 1
  fi
  return 0
}

# skills_analyse <folder>: what the skill can do on the machine, in one line (scripts, network, deletions, commands
# run, credentials it asks for). Only the code it ships is searched (its instructions describe commands).
skills_analyse() {
  local d="$1" n net=no del=no run=no cred=no files
  files="$(find "$d" -type f \( -name '*.py' -o -name '*.sh' -o -name '*.js' -o -name '*.ts' -o -name '*.mjs' -o -name '*.rb' \) 2>/dev/null)"
  n="$(printf '%s' "$files" | grep -c . || true)"
  if [[ -n "$files" ]]; then
    printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -qsE 'curl |wget |requests\.(get|post)|urllib|fetch\(|http\.client|axios' && net=yes
    printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -qsE 'rm -rf|shutil\.rmtree|os\.remove|unlink\(|fs\.rm' && del=yes
    printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep -qsE 'subprocess|child_process|os\.system|eval\(|exec\(' && run=yes
  fi
  # Credentials the skill asks the user for (an environment variable such as SENTRY_AUTH_TOKEN), read in its
  # instructions only: its reference documents quote keys as examples.
  grep -qsE '(^|[^A-Za-z0-9_])[A-Z][A-Z0-9]*_(AUTH_TOKEN|API_KEY|ACCESS_TOKEN|API_TOKEN)([^A-Za-z0-9_]|$)' "$d/SKILL.md" && cred=yes
  printf '%s script(s) · network %s · deletes files %s · runs commands %s%s' "$n" "$net" "$del" "$run" "$( [[ "$cred" == yes ]] && echo " · credentials")"
}

# _sk_with_lock <root> <command…>: runs the command with the project's skills lock held (one writer at a time).
_sk_with_lock() {
  local r="$1" l i=0 rc; shift
  l="$r/.loomy/skills.lock.d"
  while ! mkdir "$l" 2>/dev/null; do
    i=$(( i + 1 ))
    if (( i > 50 )); then rm -rf "$l"; mkdir "$l" 2>/dev/null || return 1; break; fi
    sleep 0.1
  done
  "$@"; rc=$?
  rmdir "$l" 2>/dev/null
  return $rc
}

# _sk_lock_write <root> <name> [line]: the lock without that skill, plus the new line when given.
_sk_lock_write() {
  local r="$1" name="$2" line="${3:-}" f tmp
  f="$r/.loomy/skills.lock"
  [[ -L "$f" || -L "$r/.loomy" ]] && return 1
  tmp="$(mktemp "$r/.loomy/.skills.lock.XXXXXX")" || return 1
  { if [[ -f "$f" ]]; then awk -F'|' -v n="$name" '$1 != n' "$f"; fi; if [[ -n "$line" ]]; then printf '%s\n' "$line"; fi; } >"$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$f"
}

# _sk_gitignore <root> <entry>: the entry in .gitignore once (created when missing, a newline added when needed).
_sk_gitignore() {
  local f="$1/.gitignore"
  [[ -L "$f" ]] && return 0
  grep -qxF "$2" "$f" 2>/dev/null && return 0
  if [[ -s "$f" && -n "$(tail -c1 "$f")" ]]; then printf '\n' >>"$f"; fi
  printf '%s\n' "$2" >>"$f"
}

# skills_install <root> <name> <reason> [force] [lock]: fetches, analyses and installs one skill. "force": asked by the
# user (credentials and proprietary licences accepted); "lock": source, path and commit taken from the lock (sync).
# SK_LAST says what happened. Returns 0 only when the skill is in place in every folder.
skills_install() { local rc=0; SK_LAST=""; _sk_install "$@" || rc=1; return $rc; }
_sk_install() {
  local r="$1" name="$2" reason="$3" force="${4:-}" fromlock="${5:-}" line src path commit lic tmp an d n=0 dirs
  _sk_valid "$name" || { SK_LAST="$name: invalid name"; return 1; }
  [[ -d "$r/.loomy" && ! -L "$r/.loomy" ]] || { SK_LAST="$name: not a Loomy project"; return 1; }
  if [[ -n "$fromlock" ]]; then
    # Sync: the source, path and commit of the lock, so another clone gets exactly the same skill.
    line="$(skills_lock_line "$r" "$name")"; [[ -n "$line" ]] || return 1
  else
    line="$(skills_line "$name")"; [[ -n "$line" ]] || { SK_LAST="$name: not in the catalog"; return 1; }
  fi
  IFS='|' read -r _ src path commit lic _ <<<"$line"
  if [[ "$lic" == proprietary && -z "$force" ]]; then SK_LAST="$name: proprietary licence, installed only on request (loomy skills add $name)"; return 1; fi
  if skills_installed "$r" "$name" && [[ -z "$force" ]]; then return 0; fi
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/loomy-skill.XXXXXX")" || return 1
  if ! _sk_fetch "$src" "$path" "$commit" "$tmp/s" || [[ ! -f "$tmp/s/SKILL.md" || -L "$tmp/s/SKILL.md" ]] || [[ -n "$(find "$tmp/s" -type l 2>/dev/null | head -1)" ]]; then
    rm -rf "$tmp"; SK_LAST="$name: download failed or not a valid skill"; return 1
  fi
  an="$(skills_analyse "$tmp/s")"
  if [[ "$an" == *credentials* && -z "$force" ]]; then rm -rf "$tmp"; SK_LAST="$name: needs credentials, installed only on request (loomy skills add $name)"; return 1; fi
  dirs="$(_sk_dirs "$r" "$lic")"
  for d in $dirs; do
    _sk_safe_dir "$r" "$d/$name" || continue
    _sk_safe_dir "$r" "$d/$name.loomy-new" || continue
    mkdir -p "$r/$d" || continue
    rm -rf "${r:?}/$d/${name:?}.loomy-new"
    cp -R "$tmp/s" "$r/$d/$name.loomy-new" || continue
    rm -rf "${r:?}/$d/${name:?}"
    mv "$r/$d/$name.loomy-new" "$r/$d/$name" || continue
    # Out of Git: licences may forbid redistribution; the lock brings them back on another machine.
    _sk_gitignore "$r" "/$d/$name/"
    n=$(( n + 1 ))
  done
  rm -rf "$tmp"
  if [[ "$n" -ne "$(printf '%s\n' "$dirs" | grep -c .)" ]]; then SK_LAST="$name: not written in every skills folder (symbolic link?)"; return 1; fi
  _sk_with_lock "$r" _sk_lock_write "$r" "$name" "$name|$src|$path|$commit|$lic|$(date +%Y-%m-%d)|${reason//|/ }|$an" || { SK_LAST="$name: lock not written"; return 1; }
  ai_journal_write "$r" "\"type\":\"skill\",\"event\":\"$( [[ -n "$fromlock" ]] && echo restored || echo added)\",\"name\":\"$name\",\"source\":\"$src\",\"reason\":$(ai_json_str "$reason"),\"analysis\":$(ai_json_str "$an")" 2>/dev/null || true
  SK_LAST="$name ($src${lic:+, $lic}): $reason · $an"
  return 0
}

# skills_remove <root> <name>: only a skill of the lock or the catalog, only in the project's skills folders.
skills_remove() {
  local r="$1" name="$2" d
  SK_LAST=""
  _sk_valid "$name" || { SK_LAST="$name: invalid name"; return 1; }
  if ! skills_installed "$r" "$name" && [[ -z "$(skills_line "$name")" ]]; then SK_LAST="$name: unknown skill"; return 1; fi
  for d in .claude/skills .agents/skills; do
    _sk_safe_dir "$r" "$d/$name" || continue
    if [[ -d "$r/$d/$name" ]]; then rm -rf "${r:?}/$d/${name:?}"; fi
  done
  _sk_with_lock "$r" _sk_lock_write "$r" "$name" || true
  ai_journal_write "$r" "\"type\":\"skill\",\"event\":\"removed\",\"name\":\"$name\",\"reason\":\"\"" 2>/dev/null || true
  return 0
}

# skills_sync <root>: the skills of the lock missing on this machine (another clone), installed again at their commit.
skills_sync() {
  local r="$1" name lic reason d miss
  [[ -f "$r/.loomy/skills.lock" ]] || return 0
  while IFS='|' read -r name _ _ _ lic _ reason _; do
    _sk_valid "$name" || continue
    miss=0; for d in $(_sk_dirs "$r" "$lic"); do [[ -f "$r/$d/$name/SKILL.md" ]] || miss=1; done
    if (( miss )); then skills_install "$r" "$name" "$reason" force lock >/dev/null 2>&1 || true; fi
  done < "$r/.loomy/skills.lock"
  return 0
}

# skills_updates <root>: "name old→new" for each installed skill whose catalog commit changed.
skills_updates() {
  local r="$1" name commit line cur
  [[ -f "$r/.loomy/skills.lock" ]] || return 0
  while IFS='|' read -r name _ _ commit _; do
    _sk_valid "$name" || continue
    line="$(skills_line "$name")"; [[ -n "$line" ]] || continue
    cur="$(printf '%s' "$line" | cut -d'|' -f4)"
    if [[ "$cur" != "$commit" ]]; then echo "$name ${commit:0:7}→${cur:0:7}"; fi
  done < "$r/.loomy/skills.lock"
  return 0
}
