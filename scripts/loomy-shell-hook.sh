#!/usr/bin/env bash
# Optional shell hook: in a Loomy project, typing claude or codex alone (the project's lead tool) goes through
# loomy start, so the session always opens with live tracking and the project context. Never installed silently.
#   loomy-shell-hook.sh              status
#   loomy-shell-hook.sh install      adds the hook to ~/.zshrc or ~/.bashrc (between Loomy's markers)
#   loomy-shell-hook.sh remove       removes it
# Anything else (arguments, another folder, the other tool) runs the real command unchanged; LOOMY_SHELL_HOOK=0 skips it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ui.sh
source "$SCRIPT_DIR/lib/ui.sh"
# shellcheck source=lib/config.sh
source "$SCRIPT_DIR/lib/config.sh"

ACTION="${1:-status}"
case "$ACTION" in -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//; s/loomy-shell-hook.sh/loomy shell-hook/g' | i18n_lines; exit 0 ;; esac
case "${SHELL##*/}" in bash) RC="$HOME/.bashrc" ;; *) RC="$HOME/.zshrc" ;; esac
[[ -n "${LOOMY_SHELL_RC:-}" ]] && RC="$LOOMY_SHELL_RC"
START='# >>> loomy shell hook (loomy shell-hook remove to take it out) >>>'
END='# <<< loomy shell hook <<<'

hook_block() {
  cat <<'HOOK'
function _loomy_lead {
  local d="$PWD"
  while [ "$d" != "/" ]; do
    if [ -f "$d/.loomy/brief.md" ]; then sed -n 's/^ai_lead: *//p' "$d/.loomy/brief.md" | head -1; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}
function claude {
  if [ $# -eq 0 ] && [ "${LOOMY_SHELL_HOOK:-1}" != 0 ] && [ -z "${LOOMY_DELEGATION:-}" ] && command -v loomy >/dev/null 2>&1 && [ "$(_loomy_lead)" = claude ]; then loomy start
  else command claude "$@"; fi
}
function codex {
  if [ $# -eq 0 ] && [ "${LOOMY_SHELL_HOOK:-1}" != 0 ] && [ -z "${LOOMY_DELEGATION:-}" ] && command -v loomy >/dev/null 2>&1 && [ "$(_loomy_lead)" = codex ]; then loomy start
  else command codex "$@"; fi
}
HOOK
}

installed() { grep -qF "$START" "$RC" 2>/dev/null; }

remove_block() {
  [[ -f "$RC" && ! -L "$RC" ]] || return 0
  installed || return 0
  # A start marker without its end marker: nothing is cut (the rest of the file would go with it).
  if ! grep -qxF "$END" "$RC"; then ui_err "$(t "Loomy markers incomplete in %s" "${RC/#$HOME/~}")" "$(t "remove the hook by hand")"; return 1; fi
  cp -p "$RC" "$RC.loomy-backup" 2>/dev/null || return 1
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/loomy-rc.XXXXXX")" || return 1
  awk -v s="$START" -v e="$END" '$0 == s { skip = 1; next } skip && $0 == e { skip = 0; next } !skip' "$RC" >"$tmp" && cat "$tmp" >"$RC"
  rm -f "$tmp"
}

case "$ACTION" in
  status)
    if installed; then ui_ok "$(t "Shell hook installed")" "${RC/#$HOME/~}"
    else ui_info "$(t "shell hook not installed: loomy shell-hook install")"; fi ;;
  install)
    [[ -L "$RC" ]] && { ui_warn "$(t "%s is a symbolic link: add the hook by hand" "${RC/#$HOME/~}")" "loomy shell-hook --help"; exit 1; }
    if installed; then remove_block || exit 1; fi
    { printf '\n%s\n' "$START"; hook_block; printf '%s\n' "$END"; } >>"$RC"
    loomy_config_set shell_hook yes 2>/dev/null || true
    ui_ok "$(t "Shell hook installed")" "$(t "%s · open a new terminal, then claude or codex alone in a Loomy project goes through loomy start" "${RC/#$HOME/~}")" ;;
  remove)
    remove_block || exit 1; loomy_config_set shell_hook no 2>/dev/null || true
    ui_ok "$(t "Shell hook removed")" "${RC/#$HOME/~}" ;;
  *) t "Unknown argument: %s (loomy shell-hook --help)" "$ACTION" >&2; echo >&2; exit 2 ;;
esac
