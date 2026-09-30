#!/usr/bin/env bash
# shellcheck disable=SC2034  # library sourced by other scripts
# Repair of the AI CLIs (Claude Code, Codex): brings the one the PATH runs to a working version recent enough for the
# routed models, whatever the install method (official installer, npm, Homebrew, desktop app), by escalating steps,
# checked one by one: update in place → reinstall with the same method → remove an older copy shadowing a good one →
# clean reinstall with the official installer. Settings, logins and conversations (~/.claude, ~/.codex) are never touched.
# To be sourced after models.sh and ui.sh. Bash 3.2 compatible.
#   LOOMY_CLAUDE_INSTALLER / LOOMY_CODEX_INSTALLER   replace the official installer command (tests)

AI_CLAUDE_INSTALLER="${LOOMY_CLAUDE_INSTALLER:-curl -fsSL https://claude.ai/install.sh | bash}"
AI_CODEX_INSTALLER="${LOOMY_CODEX_INSTALLER:-curl -fsSL https://chatgpt.com/codex/install.sh | sh}"

# _rp_real <path>: the path with every symbolic link resolved.
_rp_real() {
  local p="$1" d n=0
  while [[ -L "$p" && $n -lt 20 ]]; do
    d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)"; p="$(readlink "$p")"; [[ "$p" == /* ]] || p="$d/$p"; n=$(( n + 1 ))
  done
  d="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || { echo "$p"; return 0; }
  echo "$d/$(basename "$p")"
}

# ai_tool_method <claude|codex> <path>: native, npm, brew, app or other.
ai_tool_method() {
  local r; r="$(_rp_real "$2")"
  case "$r" in
    */node_modules/@anthropic-ai/claude-code/*|*/node_modules/@openai/codex/*) echo npm ;;
    */Caskroom/*|*/Cellar/*) echo brew ;;
    */.local/share/claude/*|*/.claude/local/*) echo native ;;
    *.app/Contents/*) echo app ;;
    *)
      # A small script pointing into a desktop app (Loomy's ~/.local/bin/codex).
      if [[ "$1" == "codex" ]] && grep -qs '\.app/Contents' "$r" 2>/dev/null && [[ "$(wc -c <"$r" 2>/dev/null)" -lt 2000 ]]; then echo app
      else echo other; fi ;;
  esac
}
# _rp_npm_prefix <path>: the npm prefix an npm install lives in (…/lib/node_modules/… → …).
_rp_npm_prefix() { local r; r="$(_rp_real "$1")"; echo "${r%%/lib/node_modules/*}"; }

# ai_tool_paths <claude|codex>: every copy of the command in the PATH, first one first (same file listed once).
ai_tool_paths() {
  local p seen="" r d
  local IFS=:
  for d in $PATH; do
    p="$d/$1"; [[ -x "$p" && ! -d "$p" ]] || continue
    r="$(_rp_real "$p")"; case "$seen" in *"|$r|"*) continue ;; esac
    seen="$seen|$r|"; printf '%s\n' "$p"
  done
}
ai_tool_version_of() { "$1" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true; }
ai_tool_min() { if [[ "$1" == "claude" ]]; then echo "$AI_MIN_CLAUDE_VERSION"; else echo "$AI_MIN_CODEX_VERSION"; fi; }

# ai_tool_state <claude|codex>: "ok <version> <path>", "old <version> <path>", "broken - <path>" or "missing".
# Codex also counts when only a desktop app ships it (ai_codex_bin).
ai_tool_state() {
  local first v
  hash -r 2>/dev/null || true
  first="$(ai_tool_paths "$1" | head -1)"
  if [[ -z "$first" && "$1" == "codex" ]]; then first="$(ai_codex_bin 2>/dev/null || true)"; fi
  [[ -n "$first" ]] || { echo "missing"; return 0; }
  v="$(ai_tool_version_of "$first")"
  if [[ -z "$v" ]]; then echo "broken - $first"
  elif ai_version_ge "$v" "$(ai_tool_min "$1")"; then echo "ok $v $first"
  else echo "old $v $first"; fi
}

_rp_log() { echo "${XDG_CONFIG_HOME:-$HOME/.config}/loomy/logs/repair-$1.log"; }
# _rp_run <tool> <label> <shell command>: one step, its output in the repair log; true when the tool is then fine.
_rp_run() {
  local tool="$1" label="$2" cmd="$3" log st
  log="$(_rp_log "$tool")"; mkdir -p "$(dirname "$log")"
  ui_info "$label"
  { printf '\n=== %s · %s\n$ %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$label" "$cmd"; } >>"$log"
  bash -c "$cmd" </dev/null >>"$log" 2>&1 || true
  # A fresh official install lands in ~/.local/bin: reachable right away in this session.
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) [[ -d "$HOME/.local/bin" ]] && PATH="$HOME/.local/bin:$PATH" ;; esac
  st="$(ai_tool_state "$tool")"
  printf 'result: %s\n' "$st" >>"$log"
  [[ "$st" == ok* ]]
}
# _rp_uninstall_cmd <tool> <path>: the command that removes that copy (empty when Loomy can't remove it).
_rp_uninstall_cmd() {
  local tool="$1" p="$2" m pkg cask
  m="$(ai_tool_method "$tool" "$p")"
  if [[ "$tool" == "claude" ]]; then pkg="@anthropic-ai/claude-code"; cask="claude-code"; else pkg="@openai/codex"; cask="codex"; fi
  case "$m" in
    npm) printf 'npm uninstall -g --prefix %q %s' "$(_rp_npm_prefix "$p")" "$pkg" ;;
    brew) printf 'brew uninstall --cask %s 2>/dev/null || brew uninstall %s' "$cask" "$cask" ;;
    native) printf 'rm -f %q' "$p" ;;
    app) [[ "$(_rp_real "$p")" == *.app/Contents/* ]] || printf 'rm -f %q' "$p" ;;   # never the app itself
    *) [[ "$p" == "$HOME/.local/bin/$tool" ]] && printf 'rm -f %q' "$p" ;;
  esac
}

# ai_repair_tool <claude|codex>: runs the steps until the tool works; true on success. Asks once, unless LOOMY_REPAIR_YES=1.
ai_repair_tool() {
  local tool="$1" st ver first m label pkg cask installer p other good="" un c why
  st="$(ai_tool_state "$tool")"
  [[ "$st" == ok* ]] && return 0
  if [[ "$tool" == "claude" ]]; then label="Claude Code"; pkg="@anthropic-ai/claude-code"; cask="claude-code"; installer="$AI_CLAUDE_INSTALLER"
  else label="Codex"; pkg="@openai/codex"; cask="codex"; installer="$AI_CODEX_INSTALLER"; fi
  read -r st ver first <<<"$st"
  if [[ "${LOOMY_REPAIR_YES:-}" != "1" ]]; then
    ui_is_interactive || { ui_info "$(t "repair: loomy doctor --fix")"; return 1; }
    case "$st" in
      missing) why="$(t "not installed")" ;;
      old) why="$(t "version %s, %s needed" "$ver" "$(ai_tool_min "$tool")")" ;;
      *) why="$(t "does not start")" ;;
    esac
    UI_DESCS=("$(t "In order, each step checked: update, reinstall, removal of an old copy, clean reinstall with the official installer. Your settings, logins and conversations are kept.")" "$(t "Nothing is changed.")")
    ui_choose "$(t "Repair %s (%s)?" "$label" "$why")" 0 "$(t "Yes, repair it")" "$(t "No")"
    [[ "$UI_INDEX" == "0" ]] || return 1
  fi
  if [[ "$st" != "missing" ]]; then
    m="$(ai_tool_method "$tool" "$first")"
    # 1. Update in place, with the install's own method.
    case "$m" in
      npm) _rp_run "$tool" "$(t "%s: update with npm" "$label")" "npm install -g --prefix $(printf '%q' "$(_rp_npm_prefix "$first")") $pkg@latest" && return 0 ;;
      brew) _rp_run "$tool" "$(t "%s: update with Homebrew" "$label")" "brew upgrade --cask $cask 2>/dev/null || brew upgrade $cask" && return 0 ;;
      app) _rp_run "$tool" "$(t "%s: point to the Codex CLI shipped with the updated app" "$label")" "b=$(printf '%q' "$(ai_codex_bin 2>/dev/null)"); [ -x \"\$b\" ] && mkdir -p \"\$HOME/.local/bin\" && printf '#!/bin/sh\nexec \"%s\" \"\$@\"\n' \"\$b\" > \"\$HOME/.local/bin/codex\" && chmod +x \"\$HOME/.local/bin/codex\"" && return 0 ;;
      *) [[ "$tool" == "claude" ]] && _rp_run "$tool" "$(t "%s: built-in update" "$label")" "$(printf '%q' "$first") update" && return 0 ;;
    esac
    # 2. Reinstall with the same method.
    case "$m" in
      npm) _rp_run "$tool" "$(t "%s: reinstall with npm" "$label")" "npm uninstall -g --prefix $(printf '%q' "$(_rp_npm_prefix "$first")") $pkg; npm install -g --prefix $(printf '%q' "$(_rp_npm_prefix "$first")") $pkg@latest" && return 0 ;;
      brew) _rp_run "$tool" "$(t "%s: reinstall with Homebrew" "$label")" "brew reinstall --cask $cask 2>/dev/null || brew reinstall $cask" && return 0 ;;
      native) _rp_run "$tool" "$(t "%s: reinstall with the official installer" "$label")" "$installer" && return 0 ;;
    esac
    # 3. An older copy first in the PATH hides a good one: the older copy is removed.
    while IFS= read -r p; do
      [[ "$p" == "$first" ]] && continue
      other="$(ai_tool_version_of "$p")"
      [[ -n "$other" ]] && ai_version_ge "$other" "$(ai_tool_min "$tool")" && { good="$p"; break; }
    done < <(ai_tool_paths "$tool")
    if [[ -n "$good" ]]; then
      un="$(_rp_uninstall_cmd "$tool" "$first")"
      [[ -n "$un" ]] && _rp_run "$tool" "$(t "%s: remove the old copy %s (a recent one is in %s)" "$label" "${first/#$HOME/~}" "${good/#$HOME/~}")" "$un" && return 0
    fi
    # 4. Clean reinstall: every copy Loomy can remove, then the official installer.
    un=""
    while IFS= read -r p; do
      c="$(_rp_uninstall_cmd "$tool" "$p")"; [[ -n "$c" ]] && un="${un:+$un; }$c"
    done < <(ai_tool_paths "$tool")
    [[ "$tool" == "claude" ]] && un="${un:+$un; }rm -rf \"\$HOME/.local/share/claude/versions\""
    _rp_run "$tool" "$(t "%s: clean reinstall (removal, then official installer)" "$label")" "${un:+$un; }$installer" && return 0
  else
    _rp_run "$tool" "$(t "%s: install with the official installer" "$label")" "$installer" && return 0
    command -v npm >/dev/null 2>&1 && _rp_run "$tool" "$(t "%s: install with npm" "$label")" "npm install -g $pkg@latest" && return 0
    command -v brew >/dev/null 2>&1 && _rp_run "$tool" "$(t "%s: install with Homebrew" "$label")" "brew install --cask $cask" && return 0
  fi
  ui_err "$(t "%s could not be repaired automatically" "$label")" "$(t "details: %s" "$(_rp_log "$tool" | sed "s|^$HOME|~|")")"
  ui_info "$(t "copies found: %s" "$(ai_tool_paths "$tool" | sed "s|^$HOME|~|" | paste -sd ',' - | sed 's/,/, /g')")"
  return 1
}
